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
    private var transcriptionService: TranscriptionService?
    private let openRouterService = OpenRouterService()

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

        // Request notification permission
        _ = try? await notificationService.requestPermission()

        // Load credentials and create services
        await loadServices()
        AppLogger.sync.info("Services loaded (s3=\(self.s3Service != nil), transcription=\(self.transcriptionService != nil))")

        let shouldWatch = UserDefaults.standard.bool(forKey: deviceWatchEnabledKey)
        await updateDeviceWatch(enabled: shouldWatch)
    }

    func stop() {
        deviceWatch.stopWatching()
        Task {
            await debouncer.stopProcessing()
        }
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
        guard let s3Key = recording.s3Key,
              let transcriber = transcriptionService,
              let s3 = s3Service else {
            return
        }

        recording.transcriptionStatus = .processing

        do {
            let presignedURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: 3600)
            let result = try await transcriber.transcribe(cloudStorageURL: presignedURL.absoluteString)

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()

            // Reset note tracking to allow new note creation after retranscription
            recording.appleNoteCreatedAt = nil

            // Create Apple Note
            await createAppleNote(for: recording, transcription: result)

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

        // 1. Try device deletion (if connected and file exists)
        if deviceWatch.isConnected,
           FileManager.default.fileExists(atPath: recording.localPath) {
            do {
                try FileManager.default.removeItem(atPath: recording.localPath)
                AppLogger.sync.info("Removed recording from device: \(recording.filename, privacy: .private)")
            } catch {
                AppLogger.sync.info("Could not delete from device (may be read-only): \(String(describing: error), privacy: .public)")
                // Continue - not a fatal error
            }
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
            // Load S3 credentials
            let bucket = UserDefaults.standard.string(forKey: "s3.bucket") ?? ""
            let region = UserDefaults.standard.string(forKey: "s3.region") ?? "us-east-1"
            let prefix = UserDefaults.standard.string(forKey: "s3.prefix") ?? "recordings/"

            if !bucket.isEmpty {
                let accessKey = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
                let secretKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""

                if !accessKey.isEmpty && !secretKey.isEmpty {
                    s3Service = S3Service(
                        bucket: bucket,
                        region: region,
                        prefix: prefix,
                        accessKeyId: accessKey,
                        secretAccessKey: secretKey
                    )
                }
            }

            // Load ElevenLabs credentials
            if UserDefaults.standard.bool(forKey: "elevenlabs.enabled") {
                let apiKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey) ?? ""
                let modelID = UserDefaults.standard.string(forKey: "elevenlabs.model") ?? "scribe_v1"
                if !apiKey.isEmpty {
                    transcriptionService = TranscriptionService(apiKey: apiKey, modelID: modelID)
                }
            }
        } catch {
            lastError = "Failed to load credentials: \(error.localizedDescription)"
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
        // Skip if already uploaded
        guard recording.s3Key == nil else { return }

        // Check for duplicate by hash
        if let hash = recording.fileHash {
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate {
                $0.fileHash == hash && $0.s3Key != nil
            })
            if let existing = try? modelContext.fetch(descriptor).first,
               existing.id != recording.id {
                // Duplicate found, copy S3 info
                recording.s3Key = existing.s3Key
                recording.s3UploadedAt = existing.s3UploadedAt
                recording.transcriptionText = existing.transcriptionText
                recording.transcriptionLanguage = existing.transcriptionLanguage
                recording.transcriptionStatus = existing.transcriptionStatus
                recording.transcribedAt = existing.transcribedAt
                recording.updatedAt = Date()
                try? modelContext.save()
                return
            }
        }

        // Upload to S3
        guard let s3 = s3Service else {
            lastError = "S3 not configured"
            return
        }

        do {
            let url = URL(fileURLWithPath: recording.localPath)
            let result = try await s3.upload(fileURL: url)

            recording.s3Key = result.s3Key
            recording.s3UploadedAt = result.uploadedAt
            recording.updatedAt = Date()
            try? modelContext.save()

            // Transcribe
            await transcribeRecording(recording)
        } catch {
            lastError = error.localizedDescription
            if UserDefaults.standard.bool(forKey: "notify.onSync") {
                await notificationService.syncError(error.localizedDescription)
            }
        }
    }

    private func transcribeRecording(_ recording: Recording) async {
        guard let transcriber = transcriptionService,
              let s3 = s3Service,
              let s3Key = recording.s3Key else {
            AppLogger.sync.debug("Skipping transcription (missing configuration)")
            return
        }

        recording.transcriptionStatus = .processing
        AppLogger.sync.info("Starting transcription for \(recording.filename, privacy: .private)")

        do {
            let presignedURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: 3600)

            let result = try await transcriber.transcribe(cloudStorageURL: presignedURL.absoluteString)
            AppLogger.sync.info("Transcription complete for \(recording.filename, privacy: .private) (language=\(result.languageCode, privacy: .public), chars=\(result.text.count, privacy: .public))")

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()
            try? modelContext.save()

            // Create Apple Note
            await createAppleNote(for: recording, transcription: result)

            // Notify
            if UserDefaults.standard.bool(forKey: "notify.onSync") {
                await notificationService.transcriptionComplete(preview: result.text)
            }
        } catch {
            AppLogger.sync.error("Transcription failed for \(recording.filename, privacy: .private): \(String(describing: error), privacy: .public)")
            recording.transcriptionStatus = .failed
            recording.updatedAt = Date()
            try? modelContext.save()
            lastError = error.localizedDescription
        }
    }

    private func createAppleNote(for recording: Recording, transcription: TranscriptionResult) async {
        AppLogger.notes.debug("createAppleNote called for \(recording.filename, privacy: .private)")

        // Prevent duplicate note creation
        guard recording.appleNoteCreatedAt == nil else {
            AppLogger.notes.debug("Skipping note creation (already created)")
            return
        }

        guard UserDefaults.standard.bool(forKey: "applenotes.enabled") else {
            AppLogger.notes.debug("Skipping note creation (disabled in settings)")
            return
        }

        guard let s3 = s3Service else {
            AppLogger.notes.info("Skipping note creation (S3 not configured)")
            return
        }

        guard let s3Key = recording.s3Key else {
            AppLogger.notes.info("Skipping note creation (missing S3 key)")
            return
        }

        let folder = UserDefaults.standard.string(forKey: "applenotes.folder") ?? "TP-7 Transcripts"
        let expiryString = UserDefaults.standard.string(forKey: "applenotes.linkExpiry") ?? "7d"
        let expiry = parseLinkExpiry(expiryString)
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
            let playURL = try s3.generatePresignedURL(s3Key: s3Key, expiry: expiry)
            let downloadURL = try s3.generateDownloadURL(s3Key: s3Key, filename: recording.filename, expiry: expiry)

            let notesService = AppleNotesService()
            try await notesService.createTranscriptionNote(
                transcription: transcription.text,
                filename: recording.filename,
                tpDeviceFilename: recording.filename,
                recordedAt: recording.recordedAt,
                fileSize: recording.fileSize,
                language: transcription.languageCode,
                playURL: playURL.absoluteString,
                downloadURL: downloadURL.absoluteString,
                folder: folder,
                customTitle: customTitle,
                summary: summary
            )

            // Mark that Apple Note was created to prevent duplicates
            recording.appleNoteCreatedAt = Date()
            recording.updatedAt = Date()
            try? modelContext.save()

            AppLogger.notes.info("Successfully created note for \(recording.filename, privacy: .private)")
        } catch {
            AppLogger.notes.error("Failed to create note for \(recording.filename, privacy: .private): \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to create Apple Note: \(error.localizedDescription)"
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
