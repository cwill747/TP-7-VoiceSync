//
//  SyncService.swift
//  TeenageEngVoiceSync
//
//  Orchestrates the full sync pipeline: detect -> debounce -> hash -> upload -> transcribe -> note
//

import Foundation
import os
import SwiftData
import Observation

@Observable
@MainActor
final class SyncService {
    private(set) var isSyncing = false
    private(set) var pendingCount = 0
    private(set) var lastError: String?

    private let modelContext: ModelContext
    private(set) var deviceWatch: DeviceWatchService
    private let debouncer: Debouncer
    private let notificationService: NotificationService
    private let deviceWatchEnabledKey = "devicewatch.enabled"

    private var s3Service: S3Service?
    private var transcriptionProvider: (any TranscriptionProvider)?
    private var transcriptionProviderKind: TranscriptionProviderKind?
    private let openRouterService = OpenRouterService()
    private let localAudioService = LocalAudioService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.deviceWatch = DeviceWatchService()
        self.debouncer = Debouncer(delay: 2.0)
        self.notificationService = NotificationService.shared

        setupCallbacks()
    }

    private func setupCallbacks() {
        deviceWatch.onDeviceConnected = { [weak self] serial in
            Task { @MainActor in
                await self?.handleDeviceConnected(serial: serial)
            }
        }

        deviceWatch.onDeviceDisconnected = { [weak self] serial in
            Task { @MainActor in
                await self?.handleDeviceDisconnected(serial: serial)
            }
        }

        deviceWatch.onNewRecordings = { [weak self] urls, serial in
            Task { @MainActor in
                await self?.handleNewRecordings(urls: urls, serial: serial)
            }
        }
    }

    // MARK: - Public API

    func start() async {
        AppLogger.sync.info("Starting sync service")

        ensureDeviceWatchDefault()

        // Request notification permission
        _ = try? await notificationService.requestPermission()

        // Load credentials and create services
        await loadServices()
        AppLogger.sync.info("Services loaded (s3=\(self.s3Service != nil), transcription=\(self.transcriptionProvider != nil), provider=\(self.transcriptionProviderKind?.shortName ?? "none"))")

        let shouldWatch = UserDefaults.standard.bool(forKey: deviceWatchEnabledKey)
        await updateDeviceWatch(enabled: shouldWatch)
    }

    func stop() {
        deviceWatch.stopWatching()
        Task {
            await debouncer.stopProcessing()
        }
    }

    /// Reload services with current settings (called when settings change)
    func reloadServices() async {
        AppLogger.sync.info("Reloading services with updated settings")

        // Clear existing services
        s3Service = nil
        transcriptionProvider = nil
        transcriptionProviderKind = nil

        // Reload from current settings
        await loadServices()

        AppLogger.sync.info("Services reloaded (s3=\(self.s3Service != nil), transcription=\(self.transcriptionProvider != nil), provider=\(self.transcriptionProviderKind?.shortName ?? "none"))")
    }

    /// Enable or disable device watching and debounce processing.
    func setDeviceWatchEnabled(_ enabled: Bool) async {
        await updateDeviceWatch(enabled: enabled)
    }

    /// Manually trigger sync for a recording
    func syncRecording(_ recording: Recording) async {
        await processRecording(recording)
    }

    /// Retranscribe a recording
    func retranscribe(_ recording: Recording) async {
        guard let transcriber = transcriptionProvider else {
            return
        }

        let provider = transcriptionProviderKind ?? .elevenLabs
        recording.transcriptionStatus = .processing

        do {
            let result: TranscriptionResult
            switch provider {
            case .elevenLabs:
                if let s3Key = recording.s3Key, let s3 = s3Service {
                    let presignedURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: 3600)
                    result = try await transcriber.transcribe(cloudStorageURL: presignedURL.absoluteString)
                } else if let localCopyPath = recording.localCopyPath {
                    result = try await transcriber.transcribe(localPath: localCopyPath)
                } else {
                    result = try await transcriber.transcribe(localPath: recording.localPath)
                }
            case .whisperKit:
                let sourcePath = recording.localCopyPath ?? recording.localPath
                result = try await transcriber.transcribe(localPath: sourcePath)
            case .parakeet:
                let sourcePath = recording.localCopyPath ?? recording.localPath
                result = try await transcriber.transcribe(localPath: sourcePath)
            }

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()
            if let segs = result.speakerSegments, !segs.isEmpty {
                recording.speakerSegmentsData = try? JSONEncoder().encode(segs)
            }

            // Reset note tracking to allow new note creation after retranscription
            recording.appleNoteCreatedAt = nil
            recording.notionPageCreatedAt = nil

            // Create Apple Note
            await createAppleNote(for: recording, transcription: result)
            await createNotionPage(for: recording, transcription: result)

            // Notify
            if UserDefaults.standard.bool(forKey: "notify.onSync") {
                await notificationService.transcriptionComplete(preview: result.text)
            }
        } catch {
            recording.transcriptionStatus = .failed
            lastError = error.localizedDescription
        }
    }

    /// Delete a recording from device, S3, and mark as deleted in database
    func deleteRecording(_ recording: Recording) async {
        AppLogger.sync.info("Delete requested for recording \(recording.filename, privacy: .private)")

        // 1. Try device deletion over MTP (if connected)
        if deviceWatch.isConnected {
            switch await deviceWatch.deleteFromDevice(filename: recording.filename) {
            case .success:
                AppLogger.sync.info("Removed recording from device: \(recording.filename, privacy: .private)")
            case .failure(let error):
                AppLogger.sync.info("Could not delete from device: \(error.localizedDescription, privacy: .public)")
                // Continue - not a fatal error
            }
        }

        // Remove the locally cached copy downloaded from the device
        if FileManager.default.fileExists(atPath: recording.localPath) {
            try? FileManager.default.removeItem(atPath: recording.localPath)
        }

        // 2. Delete from S3
        if let s3Key = recording.s3Key, let s3 = s3Service {
            do {
                try await s3.deleteObject(s3Key: s3Key)
                AppLogger.sync.info("Removed recording from S3 (key=\(s3Key, privacy: .private))")
            } catch {
                AppLogger.sync.error("Failed to delete from S3 (key=\(s3Key, privacy: .private)): \(String(describing: error), privacy: .public)")
                lastError = error.localizedDescription
                // Continue - still mark as deleted locally
            }
        }

        // 3. Soft delete in database (keeps record to prevent re-sync)
        recording.deletedAt = Date()
        recording.updatedAt = Date()
        try? modelContext.save()
        AppLogger.sync.info("Marked as deleted in database: \(recording.filename, privacy: .private)")

        // 4. Update device recording count
        if let serial = recording.deviceSerial {
            let descriptor = FetchDescriptor<Device>(predicate: #Predicate { $0.serial == serial })
            if let device = try? modelContext.fetch(descriptor).first {
                device.recordingsCount = max(0, device.recordingsCount - 1)
                try? modelContext.save()
            }
        }
    }

    // MARK: - Private Methods

    private func loadServices() async {
        do {
            registerTranscriptionDefaults()

            // Load S3 credentials only if S3 is enabled
            let s3Enabled = UserDefaults.standard.bool(forKey: "s3.enabled")
            let bucket = UserDefaults.standard.string(forKey: "s3.bucket") ?? ""
            let s3Provider = S3Provider(rawValue: UserDefaults.standard.string(forKey: "s3.provider") ?? "") ?? .aws
            let region = UserDefaults.standard.string(forKey: "s3.region") ?? s3Provider.defaultRegion
            let prefix = UserDefaults.standard.string(forKey: "s3.prefix") ?? "recordings/"

            if s3Enabled && !bucket.isEmpty {
                let accessKey = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
                let secretKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""

                if !accessKey.isEmpty && !secretKey.isEmpty {
                    s3Service = S3Service(
                        bucket: bucket,
                        region: region,
                        prefix: prefix,
                        accessKeyId: accessKey,
                        secretAccessKey: secretKey,
                        provider: s3Provider
                    )
                }
            }

            let transcriptionEnabled = resolveTranscriptionEnabled()
            let providerRaw = UserDefaults.standard.string(forKey: "transcription.provider") ?? TranscriptionProviderKind.elevenLabs.rawValue
            let provider = TranscriptionProviderKind(rawValue: providerRaw) ?? .elevenLabs
            transcriptionProviderKind = provider

            if transcriptionEnabled {
                switch provider {
                case .elevenLabs:
                    let apiKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey) ?? ""
                    let modelID = UserDefaults.standard.string(forKey: "elevenlabs.model") ?? "scribe_v1"
                    if !apiKey.isEmpty {
                        transcriptionProvider = ElevenLabsTranscriptionService(apiKey: apiKey, modelID: modelID)
                    }
                case .whisperKit:
                    let modelID = UserDefaults.standard.string(forKey: "whisperkit.model") ?? "base"
                    transcriptionProvider = WhisperKitService(modelID: modelID)
                case .parakeet:
                    let modelVersion = UserDefaults.standard.string(forKey: ParakeetService.modelKey) ?? ParakeetModelVariant.v2.rawValue
                    let diarizationEnabled = UserDefaults.standard.bool(forKey: ParakeetService.diarizationEnabledKey)
                    let profiles = fetchKnownPersonProfiles()
                    transcriptionProvider = ParakeetService(
                        modelVersion: modelVersion,
                        diarizationEnabled: diarizationEnabled,
                        knownPersonProfiles: profiles
                    )
                }
            }
        } catch {
            lastError = "Failed to load credentials: \(error.localizedDescription)"
        }
    }

    /// Refreshes the known speaker roster in the active ParakeetService.
    /// Call this after adding, removing, or re-enrolling a Person.
    func refreshKnownSpeakers() async {
        guard let parakeet = transcriptionProvider as? ParakeetService else { return }
        let profiles = fetchKnownPersonProfiles()
        await parakeet.updateKnownSpeakers(profiles)
    }

    private func fetchKnownPersonProfiles() -> [KnownPersonProfile] {
        let descriptor = FetchDescriptor<Person>()
        guard let persons = try? modelContext.fetch(descriptor) else { return [] }
        return persons.compactMap { person in
            guard !person.embedding.isEmpty else { return nil }
            return KnownPersonProfile(personId: person.id, name: person.name, embedding: person.embedding)
        }
    }

    private func handleDeviceConnected(serial: String) async {
        // Update or create device record
        let descriptor = FetchDescriptor<Device>(predicate: #Predicate { $0.serial == serial })
        if let device = try? modelContext.fetch(descriptor).first {
            device.markSeen()
        } else {
            let device = Device(serial: serial)
            modelContext.insert(device)
        }
        try? modelContext.save()

        // Notify
        if UserDefaults.standard.bool(forKey: "notify.onConnect") {
            await notificationService.deviceConnected(serial)
        }
    }

    private func updateDeviceWatch(enabled: Bool) async {
        if enabled {
            deviceWatch.startWatching()
            AppLogger.sync.info("Device watch started")

            await debouncer.startProcessing { [weak self] stablePaths in
                guard let self else { return }
                Task { @MainActor in
                    await self.processStableFiles(paths: stablePaths)
                }
            }
            AppLogger.sync.info("Debounce processing started")
        } else {
            deviceWatch.stopWatching()
            await debouncer.stopProcessing()
            await debouncer.clear()
            pendingCount = 0
            AppLogger.sync.info("Device watch disabled")
        }
    }

    private func handleDeviceDisconnected(serial: String) async {
        if UserDefaults.standard.bool(forKey: "notify.onConnect") {
            await notificationService.deviceDisconnected(serial)
        }
    }

    private func handleNewRecordings(urls: [URL], serial: String) async {
        // Debug: Count total recordings in database
        let countDescriptor = FetchDescriptor<Recording>()
        let totalCount = (try? modelContext.fetch(countDescriptor).count) ?? 0
        AppLogger.sync.debug("Database has \(totalCount, privacy: .public) total recordings")

        for url in urls {
            let filename = url.lastPathComponent

            // Check if already in database (excluding soft-deleted recordings)
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt == nil })
            if (try? modelContext.fetch(descriptor).first) != nil {
                AppLogger.sync.debug("Skipping already tracked recording \(filename, privacy: .private)")
                continue // Already tracked
            }

            // Check if it exists but is deleted
            let deletedDescriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt != nil })
            if let deleted = try? modelContext.fetch(deletedDescriptor).first {
                AppLogger.sync.debug("Skipping soft-deleted recording \(filename, privacy: .private) (deletedAt=\(String(describing: deleted.deletedAt), privacy: .public))")
                continue // Skip soft-deleted recordings too
            }

            AppLogger.sync.info("New recording detected: \(filename, privacy: .private)")

            // Add to debouncer
            await debouncer.recordEvent(for: url.path)
        }

        pendingCount = await debouncer.pendingCount
    }

    private func processStableFiles(paths: [String]) async {
        guard !paths.isEmpty else { return }

        isSyncing = true
        pendingCount = await debouncer.pendingCount

        if UserDefaults.standard.bool(forKey: "notify.onSync") {
            await notificationService.syncStarted(count: paths.count)
        }

        var successCount = 0

        for path in paths {
            let url = URL(fileURLWithPath: path)

            do {
                // Create recording record
                let recording = try await createRecording(from: url)

                // Process the recording
                await processRecording(recording)
                successCount += 1
            } catch {
                lastError = error.localizedDescription
            }
        }

        if successCount > 0 && UserDefaults.standard.bool(forKey: "notify.onSync") {
            await notificationService.syncComplete(count: successCount)
        }

        isSyncing = false
        pendingCount = await debouncer.pendingCount
    }

    private func createRecording(from url: URL) async throws -> Recording {
        let filename = url.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let modDate = attributes[.modificationDate] as? Date ?? Date()

        let recording = Recording(
            filename: filename,
            localPath: url.path,
            fileSize: fileSize,
            recordedAt: modDate
        )

        // Parse WAV metadata
        if let metadata = try? await WAVParser.parse(url: url) {
            recording.duration = metadata.duration
            recording.sampleRate = metadata.sampleRate
        }

        // Calculate hash
        recording.fileHash = try await FileHasher.sha256(url: url)

        // Set device serial
        recording.deviceSerial = deviceWatch.currentDeviceSerial

        modelContext.insert(recording)
        try modelContext.save()

        // Update device recordings count
        if let serial = recording.deviceSerial {
            let descriptor = FetchDescriptor<Device>(predicate: #Predicate { $0.serial == serial })
            if let device = try? modelContext.fetch(descriptor).first {
                device.incrementRecordings()
                try? modelContext.save()
            }
        }

        return recording
    }

    private func processRecording(_ recording: Recording) async {
        // Skip if already processed
        guard recording.s3Key == nil,
              recording.localCopyPath == nil,
              recording.transcriptionStatus == .none else { return }

        // Check for duplicate by hash
        if let hash = recording.fileHash {
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate {
                $0.fileHash == hash && ($0.s3Key != nil || $0.localCopyPath != nil)
            })
            if let existing = try? modelContext.fetch(descriptor).first,
               existing.id != recording.id {
                // Duplicate found, copy info
                recording.s3Key = existing.s3Key
                recording.s3UploadedAt = existing.s3UploadedAt
                recording.localCopyPath = existing.localCopyPath
                recording.transcriptionText = existing.transcriptionText
                recording.transcriptionLanguage = existing.transcriptionLanguage
                recording.transcriptionStatus = existing.transcriptionStatus
                recording.transcribedAt = existing.transcribedAt
                recording.updatedAt = Date()
                try? modelContext.save()
                return
            }
        }

        let provider = transcriptionProviderKind ?? .elevenLabs
        let backupToS3 = UserDefaults.standard.bool(forKey: "s3.backupAfterTranscription")
        let isLocalProvider = provider == .whisperKit || provider == .parakeet
        let shouldTranscribeFirst = isLocalProvider && transcriptionProvider != nil

        if shouldTranscribeFirst {
            let transcriptionResult = await transcribeRecording(recording, provider: provider)
            _ = await storeRecording(recording, allowS3Upload: backupToS3)

            if let transcriptionResult {
                await createAppleNote(for: recording, transcription: transcriptionResult)
                await createNotionPage(for: recording, transcription: transcriptionResult)
                if UserDefaults.standard.bool(forKey: "notify.onSync") {
                    await notificationService.transcriptionComplete(preview: transcriptionResult.text)
                }
            }
        } else {
            let allowS3Upload = !isLocalProvider || backupToS3
            let storageOk = await storeRecording(recording, allowS3Upload: allowS3Upload)
            guard storageOk else { return }

            let transcriptionResult = await transcribeRecording(recording, provider: provider)
            if let transcriptionResult {
                await createAppleNote(for: recording, transcription: transcriptionResult)
                await createNotionPage(for: recording, transcription: transcriptionResult)
                if UserDefaults.standard.bool(forKey: "notify.onSync") {
                    await notificationService.transcriptionComplete(preview: transcriptionResult.text)
                }
            }
        }
    }

    private func storeRecording(_ recording: Recording, allowS3Upload: Bool) async -> Bool {
        let sourceURL = URL(fileURLWithPath: recording.localPath)

        // Check if user explicitly chose local storage (takes priority over S3)
        let useLocalStorage = UserDefaults.standard.bool(forKey: "localaudio.enabled")
        let localFolderPath = UserDefaults.standard.string(forKey: "localaudio.folderPath") ?? ""
        AppLogger.sync.debug("Storage check: useLocalStorage=\(useLocalStorage), localFolderPath=\(localFolderPath, privacy: .private), s3Service=\(self.s3Service != nil)")

        if useLocalStorage && LocalAudioService.isConfigured {
            do {
                let destinationURL = try await localAudioService.copyToLocalFolder(sourceURL: sourceURL)
                recording.localCopyPath = destinationURL.path
                recording.updatedAt = Date()
                try? modelContext.save()
                AppLogger.sync.info("Copied to local folder: \(recording.filename, privacy: .private)")
                return true
            } catch {
                lastError = error.localizedDescription
                AppLogger.sync.error("Failed to copy to local folder: \(error.localizedDescription, privacy: .public)")
                await notificationService.storageError("Failed to copy to local folder: \(error.localizedDescription)")
                return false
            }
        } else if allowS3Upload, let s3 = s3Service {
            do {
                let result = try await s3.upload(fileURL: sourceURL)
                recording.s3Key = result.s3Key
                recording.s3UploadedAt = result.uploadedAt
                recording.updatedAt = Date()
                try? modelContext.save()
                AppLogger.sync.info("Uploaded to S3: \(recording.filename, privacy: .private)")
                return true
            } catch {
                lastError = error.localizedDescription
                await notificationService.storageError("S3 upload failed: \(error.localizedDescription)")
                return false
            }
        } else if allowS3Upload {
            lastError = "No storage configured (S3 or local folder)"
            AppLogger.sync.error("No storage configured")
            await notificationService.storageError("No storage configured. Please configure S3 or local folder in Settings.")
            return false
        } else {
            AppLogger.sync.debug("Skipping S3 upload (backup disabled)")
            return true
        }
    }

    private func transcribeRecording(_ recording: Recording, provider: TranscriptionProviderKind) async -> TranscriptionResult? {
        guard let transcriber = transcriptionProvider else {
            AppLogger.sync.debug("Skipping transcription (transcription provider not configured)")
            return nil
        }

        recording.transcriptionStatus = .processing
        AppLogger.sync.info("Starting transcription for \(recording.filename, privacy: .private) (provider=\(provider.shortName))")

        do {
            let result: TranscriptionResult

            switch provider {
            case .elevenLabs:
                if let s3Key = recording.s3Key, let s3 = s3Service {
                    let presignedURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: 3600)
                    result = try await transcriber.transcribe(cloudStorageURL: presignedURL.absoluteString)
                    AppLogger.sync.debug("Transcribed via cloud URL")
                } else if let localCopyPath = recording.localCopyPath {
                    result = try await transcriber.transcribe(localPath: localCopyPath)
                    AppLogger.sync.debug("Transcribed via local copy")
                } else {
                    result = try await transcriber.transcribe(localPath: recording.localPath)
                    AppLogger.sync.debug("Transcribed via device file")
                }
            case .whisperKit:
                let sourcePath = recording.localCopyPath ?? recording.localPath
                result = try await transcriber.transcribe(localPath: sourcePath)
                AppLogger.sync.debug("Transcribed locally with WhisperKit")
            case .parakeet:
                let sourcePath = recording.localCopyPath ?? recording.localPath
                result = try await transcriber.transcribe(localPath: sourcePath)
                AppLogger.sync.debug("Transcribed locally with Parakeet")
            }

            AppLogger.sync.info("Transcription complete for \(recording.filename, privacy: .private) (language=\(result.languageCode, privacy: .public), chars=\(result.text.count, privacy: .public))")

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()
            if let segs = result.speakerSegments, !segs.isEmpty {
                recording.speakerSegmentsData = try? JSONEncoder().encode(segs)
            }
            try? modelContext.save()
            return result
        } catch {
            AppLogger.sync.error("Transcription failed for \(recording.filename, privacy: .private): \(String(describing: error), privacy: .public)")
            recording.transcriptionStatus = .failed
            recording.updatedAt = Date()
            try? modelContext.save()
            lastError = error.localizedDescription

            await notificationService.transcriptionError(error.localizedDescription, filename: recording.filename)
            return nil
        }
    }

    private func createNotionPage(for recording: Recording, transcription: TranscriptionResult) async {
        guard recording.notionPageCreatedAt == nil else { return }
        guard UserDefaults.standard.bool(forKey: "notion.enabled") else { return }

        let databaseId = UserDefaults.standard.string(forKey: "notion.databaseId") ?? ""
        guard !databaseId.isEmpty,
              let apiKey = try? await KeychainService.shared.retrieve(for: .notionAPIKey),
              !apiKey.isEmpty else {
            AppLogger.notes.debug("Notion not configured; skipping")
            return
        }

        // Resolve audio URLs the same way createAppleNote does.
        var playURLString = ""
        var downloadURLString = ""
        if let s3Key = recording.s3Key, let s3 = s3Service {
            let expiry = parseLinkExpiry(UserDefaults.standard.string(forKey: "applenotes.linkExpiry") ?? "7d")
            playURLString = (try? s3.generatePresignedURL(s3Key: s3Key, expiry: expiry).absoluteString) ?? ""
            downloadURLString = (try? s3.generateDownloadURL(s3Key: s3Key, filename: recording.filename, expiry: expiry).absoluteString) ?? ""
        } else if let localCopyPath = recording.localCopyPath {
            let u = URL(fileURLWithPath: localCopyPath).absoluteString
            playURLString = u; downloadURLString = u
        }

        let service = NotionService(apiKey: apiKey, databaseId: databaseId, props: .loadStored())
        do {
            try await service.createTranscriptionNote(
                transcription: transcription.text,
                filename: recording.filename,
                tpDeviceFilename: recording.filename,
                recordedAt: recording.recordedAt,
                fileSize: recording.fileSize,
                duration: recording.duration,
                language: transcription.languageCode,
                playURL: playURLString,
                downloadURL: downloadURLString,
                customTitle: recording.llmTitle,
                summary: recording.llmSummary
            )
            recording.notionPageCreatedAt = Date()
            recording.updatedAt = Date()
            try? modelContext.save()
            AppLogger.notes.info("Created Notion page for \(recording.filename, privacy: .private)")
        } catch {
            AppLogger.notes.error("Notion delivery failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Notion: \(error.localizedDescription)"
        }
    }

    private func createAppleNote(for recording: Recording, transcription: TranscriptionResult) async {
        AppLogger.notes.debug("createAppleNote called for \(recording.filename, privacy: .private)")

        // Prevent duplicate note creation
        guard recording.appleNoteCreatedAt == nil else {
            AppLogger.notes.debug("Skipping note creation (already created)")
            return
        }

        // Check which note type to use - markdown takes priority if enabled
        let markdownEnabled = UserDefaults.standard.bool(forKey: "markdown.enabled")
        let markdownFolderPath = UserDefaults.standard.string(forKey: "markdown.folderPath") ?? ""
        let appleNotesEnabled = UserDefaults.standard.bool(forKey: "applenotes.enabled")
        AppLogger.notes.debug("Note settings: markdownEnabled=\(markdownEnabled), markdownPath=\(markdownFolderPath, privacy: .private), appleNotesEnabled=\(appleNotesEnabled)")

        guard markdownEnabled || appleNotesEnabled else {
            AppLogger.notes.debug("Skipping note creation (both disabled in settings)")
            return
        }

        // Determine which service to use
        let useMarkdown = markdownEnabled

        // Determine audio URLs - either S3 presigned URLs or local file:// URLs
        var playURLString: String
        var downloadURLString: String

        if let s3Key = recording.s3Key, let s3 = s3Service {
            // Use S3 presigned URLs
            let expiryString = UserDefaults.standard.string(forKey: "applenotes.linkExpiry") ?? "7d"
            let expiry = parseLinkExpiry(expiryString)
            do {
                let playURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: expiry)
                let downloadURL = try s3.generateDownloadURL(s3Key: s3Key, filename: recording.filename, expiry: expiry)
                playURLString = playURL.absoluteString
                downloadURLString = downloadURL.absoluteString
                AppLogger.notes.debug("Using S3 URLs for note")
            } catch {
                AppLogger.notes.error("Failed to generate S3 URLs: \(error.localizedDescription, privacy: .public)")
                lastError = "Failed to generate S3 URLs: \(error.localizedDescription)"
                return
            }
        } else if let localCopyPath = recording.localCopyPath {
            // Use local file:// URLs
            let localURL = URL(fileURLWithPath: localCopyPath)
            playURLString = localURL.absoluteString
            downloadURLString = localURL.absoluteString
            AppLogger.notes.debug("Using local file URL for note")
        } else {
            AppLogger.notes.info("Skipping note creation (no S3 key or local copy)")
            return
        }

        let folder = UserDefaults.standard.string(forKey: "applenotes.folder") ?? "TP-7 Transcripts"
        AppLogger.notes.debug("Creating note (folder=\(folder, privacy: .private))")

        // Generate LLM title if enabled
        var customTitle: String?
        var summary: String?

        if UserDefaults.standard.bool(forKey: "openrouter.enabled") {
            let llmResult = await generateLLMTitle(for: transcription.text)
            if let result = llmResult {
                customTitle = result.title
                summary = result.summary

                // Store in recording
                recording.llmTitle = result.title
                recording.llmSummary = result.summary
                recording.llmProcessedAt = Date()
                recording.updatedAt = Date()
                try? modelContext.save()

                AppLogger.notes.debug("Using LLM-generated title: \(result.title, privacy: .private)")
            }
        }

        do {
            if useMarkdown {
                // Create local markdown file (takes priority)
                let markdownService = LocalMarkdownService()
                try await markdownService.createTranscriptionNote(
                    transcription: transcription.text,
                    filename: recording.filename,
                    tpDeviceFilename: recording.filename,
                    recordedAt: recording.recordedAt,
                    fileSize: recording.fileSize,
                    language: transcription.languageCode,
                    playURL: playURLString,
                    downloadURL: downloadURLString,
                    customTitle: customTitle,
                    summary: summary
                )
                AppLogger.notes.info("Successfully created markdown file for \(recording.filename, privacy: .private)")
            } else if appleNotesEnabled {
                // Create Apple Note
                let notesService = AppleNotesService()
                try await notesService.createTranscriptionNote(
                    transcription: transcription.text,
                    filename: recording.filename,
                    tpDeviceFilename: recording.filename,
                    recordedAt: recording.recordedAt,
                    fileSize: recording.fileSize,
                    language: transcription.languageCode,
                    playURL: playURLString,
                    downloadURL: downloadURLString,
                    folder: folder,
                    customTitle: customTitle,
                    summary: summary
                )
                AppLogger.notes.info("Successfully created Apple Note for \(recording.filename, privacy: .private)")
            }

            // Mark that note was created to prevent duplicates
            recording.appleNoteCreatedAt = Date()
            recording.updatedAt = Date()
            try? modelContext.save()
        } catch {
            AppLogger.notes.error("Failed to create note for \(recording.filename, privacy: .private): \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to create note: \(error.localizedDescription)"
            await notificationService.noteError(error.localizedDescription)
        }
    }

    /// Generates a title and summary using OpenRouter LLM
    private func generateLLMTitle(for transcription: String) async -> LLMResult? {
        guard let apiKey = try? await KeychainService.shared.retrieve(for: .openRouterAPIKey),
              !apiKey.isEmpty else {
            AppLogger.network.debug("OpenRouter API key not configured")
            return nil
        }

        let model = UserDefaults.standard.string(forKey: "openrouter.model") ?? ""
        guard !model.isEmpty else {
            AppLogger.network.debug("OpenRouter model not selected")
            return nil
        }

        AppLogger.network.info("Generating title/summary (model=\(model, privacy: .public))")

        // Get custom prompt if configured
        let customPrompt = UserDefaults.standard.string(forKey: "llm.customPrompt")

        do {
            let result = try await openRouterService.generateTitleAndSummary(
                transcription: transcription,
                model: model,
                apiKey: apiKey,
                customPrompt: customPrompt
            )
            AppLogger.network.debug("Generated title: \(result.title, privacy: .private)")
            return result
        } catch {
            AppLogger.network.error("Failed to generate title/summary: \(error.localizedDescription, privacy: .public)")
            // Fall back to nil - the note will use the date-based title
            return nil
        }
    }

    /// Manually send a transcribed recording to Apple Notes
    func sendToAppleNotes(_ recording: Recording) async throws {
        AppLogger.notes.info("Manual sendToAppleNotes called for \(recording.filename, privacy: .private)")

        guard let text = recording.transcriptionText else {
            throw AppleNotesError.executionFailed("No transcription text available")
        }

        guard let s3 = s3Service else {
            throw AppleNotesError.executionFailed("S3 service not configured")
        }

        guard let s3Key = recording.s3Key else {
            throw AppleNotesError.executionFailed("Recording not uploaded to S3")
        }

        let folder = UserDefaults.standard.string(forKey: "applenotes.folder") ?? "TP-7 Transcripts"
        let expiryString = UserDefaults.standard.string(forKey: "applenotes.linkExpiry") ?? "7d"
        let expiry = parseLinkExpiry(expiryString)

        // Generate LLM title if enabled and not already generated
        var customTitle = recording.llmTitle
        var summary = recording.llmSummary

        if customTitle == nil && UserDefaults.standard.bool(forKey: "openrouter.enabled") {
            let llmResult = await generateLLMTitle(for: text)
            if let result = llmResult {
                customTitle = result.title
                summary = result.summary

                // Store in recording
                recording.llmTitle = result.title
                recording.llmSummary = result.summary
                recording.llmProcessedAt = Date()
                recording.updatedAt = Date()
                try? modelContext.save()

                AppLogger.notes.debug("Using LLM-generated title: \(result.title, privacy: .private)")
            }
        }

        let playURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: expiry)
        let downloadURL = try s3.generateDownloadURL(s3Key: s3Key, filename: recording.filename, expiry: expiry)

        let notesService = AppleNotesService()
        try await notesService.createTranscriptionNote(
            transcription: text,
            filename: recording.filename,
            tpDeviceFilename: recording.filename,
            recordedAt: recording.recordedAt,
            fileSize: recording.fileSize,
            language: recording.transcriptionLanguage ?? "unknown",
            playURL: playURL.absoluteString,
            downloadURL: downloadURL.absoluteString,
            folder: folder,
            customTitle: customTitle,
            summary: summary
        )

        // Track that a note was created
        recording.appleNoteCreatedAt = Date()
        recording.updatedAt = Date()
        try? modelContext.save()

        AppLogger.notes.info("Successfully created note for \(recording.filename, privacy: .private)")
    }

    private func registerTranscriptionDefaults() {
        UserDefaults.standard.register(defaults: [
            "transcription.provider": TranscriptionProviderKind.elevenLabs.rawValue,
            "whisperkit.model": "base",
            "parakeet.model": ParakeetModelVariant.v2.rawValue,
            "notion.enabled": false,
            "s3.backupAfterTranscription": true
        ])
    }

    private func ensureDeviceWatchDefault() {
        let defaults = UserDefaults.standard

        // If the user has never set this preference, default to watching.
        // This does not override an explicit user choice (true/false).
        if defaults.object(forKey: deviceWatchEnabledKey) == nil {
            defaults.set(true, forKey: deviceWatchEnabledKey)
        }
    }

    private func resolveTranscriptionEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: "transcription.enabled") as? Bool {
            return stored
        }

        let legacyEnabled = defaults.bool(forKey: "elevenlabs.enabled")
        defaults.set(legacyEnabled, forKey: "transcription.enabled")
        return legacyEnabled
    }

    private func parseLinkExpiry(_ string: String) -> TimeInterval {
        let value = string.dropLast()
        let unit = string.last

        guard let number = Double(value) else {
            return 7 * 24 * 3600 // Default 7 days
        }

        switch unit {
        case "d": return number * 24 * 3600
        case "h": return number * 3600
        case "m": return number * 60
        default: return 7 * 24 * 3600
        }
    }
}
