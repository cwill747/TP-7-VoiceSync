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

    /// Number of recordings with deferred remote work (upload/summary/notion/note)
    /// still pending — surfaced in the UI as "N waiting".
    private(set) var pendingRemoteCount = 0

    /// Tracks connectivity + the manual "Work Offline" override. Public so the UI
    /// can read/toggle it and forward its state.
    let reachability = ReachabilityService()

    /// True when we're offline (network down or user forced offline).
    var isOffline: Bool { !reachability.isOnline }

    /// Guards `reconcilePendingWork()` against overlapping runs (e.g. a launch
    /// pass racing a reconnect pass).
    private var isReconciling = false

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

    /// A not-yet-processed cache file's device origin, keyed by its local path.
    /// Populated when a device download is queued (the debouncer only tracks
    /// paths); consumed and removed once `createRecording` runs. Internal (not
    /// private) so tests can seed it directly, mirroring `createRecording`'s
    /// own access level.
    var pendingRecordingOrigins: [String: PendingRecordingOrigin] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.deviceWatch = DeviceWatchService()
        self.debouncer = Debouncer(delay: 2.0)
        self.notificationService = NotificationService.shared

        setupCallbacks()

        // When connectivity returns (or the user turns off Work Offline), finish
        // any deferred remote work.
        reachability.onBecameOnline = { [weak self] in
            Task { @MainActor in
                await self?.reconcilePendingWork()
            }
        }
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

        deviceWatch.onNewRecordings = { [weak self] downloads, serial in
            Task { @MainActor in
                await self?.handleNewRecordings(downloads: downloads, serial: serial)
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

        // Start connectivity monitoring before recovery so the Work Offline
        // override (forceOffline, persisted in UserDefaults) is respected.
        reachability.start()

        // Recover recordings from remote sources before starting device watch.
        // Skip when the user has forced offline mode — they explicitly asked
        // for no network activity.
        if reachability.isOnline {
            await recoverFromRemoteSources()
        }

        await refreshPendingCount()
        if reachability.isOnline {
            await reconcilePendingWork()
        }

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

    // MARK: - Startup Recovery

    /// Scans all configured remote/local sources for recordings not present in
    /// the local database and re-creates their entries. This handles the case
    /// where local SwiftData state was lost (app reinstall, container reset, etc).
    private func recoverFromRemoteSources() async {
        AppLogger.sync.info("Starting recovery scan from remote sources")

        let existingFilenames = fetchAllKnownFilenames()
        var recovered = 0

        // 1. S3 — richest source of truth for audio files
        if let s3 = s3Service {
            do {
                let objects = try await s3.listObjects()
                let wavObjects = objects.filter { $0.filename.hasSuffix(".wav") || $0.filename.hasSuffix(".WAV") }
                AppLogger.sync.info("S3: found \(wavObjects.count) audio files, \(existingFilenames.count) already tracked")

                for obj in wavObjects where !existingFilenames.contains(obj.filename) {
                    let recording = Recording(
                        filename: obj.filename,
                        localPath: "",
                        fileSize: obj.size,
                        recordedAt: obj.lastModified
                    )
                    recording.s3Key = obj.key
                    recording.s3UploadedAt = obj.lastModified
                    inferRecoveredDeviceOrigin(for: recording)
                    modelContext.insert(recording)
                    recovered += 1
                }

                if recovered > 0 {
                    try? modelContext.save()
                    AppLogger.sync.info("S3: recovered \(recovered) recordings")
                }
            } catch {
                AppLogger.sync.error("S3 recovery scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Local audio folder — scan for WAV files
        let useLocalStorage = UserDefaults.standard.bool(forKey: "localaudio.enabled")
        if useLocalStorage, LocalAudioService.isConfigured {
            let localRecovered = await recoverFromLocalAudioFolder(existingFilenames: existingFilenames)
            recovered += localRecovered
        }

        // 3. Notion — may have transcriptions for recordings we already found
        //    from S3 or local, plus any recordings only in Notion.
        let notionEnabled = UserDefaults.standard.bool(forKey: "notion.enabled")
        let databaseId = UserDefaults.standard.string(forKey: "notion.databaseId") ?? ""
        if notionEnabled && !databaseId.isEmpty {
            let notionRecovered = await recoverFromNotion(databaseId: databaseId)
            recovered += notionRecovered
        }

        if recovered > 0 {
            AppLogger.sync.info("Recovery complete: \(recovered) recordings restored from remote sources")
        } else {
            AppLogger.sync.info("Recovery scan complete: all sources in sync")
        }
    }

    /// Backfills `sourceFolder`/`deviceFilename` on a recording recovered from
    /// a remote source (S3/local folder/Notion). None of those stores persist
    /// those fields — only `filename` — so without this, a recovered /memo
    /// recording would look identical to a /recordings one: `deleteRecording`
    /// would then send its device-delete call to the wrong folder, and
    /// `forceSingleSpeaker` would wrongly run full diarization on retranscribe.
    /// No-op when `filename` doesn't carry a recognized qualification, or
    /// sourceFolder is already known. Internal (not private) so tests can call
    /// it directly, mirroring `createRecording`'s own access level.
    func inferRecoveredDeviceOrigin(for recording: Recording) {
        guard recording.sourceFolder == nil,
              let inferred = DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: recording.filename) else { return }
        recording.sourceFolder = inferred.source
        recording.deviceFilename = inferred.deviceFilename
    }

    private func fetchAllKnownFilenames() -> Set<String> {
        let descriptor = FetchDescriptor<Recording>()
        guard let recordings = try? modelContext.fetch(descriptor) else { return [] }
        return Set(recordings.map(\.filename))
    }

    private func recoverFromLocalAudioFolder(existingFilenames: Set<String>) async -> Int {
        let folderPath: URL?
        if let url = SecurityScopedBookmark.resolve(key: "localaudio.folderPath") {
            guard url.startAccessingSecurityScopedResource() else { return 0 }
            folderPath = url
        } else {
            let path = UserDefaults.standard.string(forKey: "localaudio.folderPath") ?? ""
            folderPath = path.isEmpty ? nil : URL(fileURLWithPath: path)
        }

        guard let folder = folderPath else { return 0 }
        defer {
            if SecurityScopedBookmark.resolve(key: "localaudio.folderPath") != nil {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return 0
        }

        // Refresh known filenames (S3 recovery may have added some)
        let currentFilenames = fetchAllKnownFilenames()

        let audioFiles = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "wav" || ext == "mp3" || ext == "m4a"
        }

        AppLogger.sync.info("Local folder: found \(audioFiles.count) audio files")

        var recovered = 0
        for file in audioFiles {
            let filename = file.lastPathComponent
            guard !currentFilenames.contains(filename) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let size = attrs?[.size] as? Int64 ?? 0
            let modDate = attrs?[.modificationDate] as? Date ?? Date()

            // Store the archived file only as `localCopyPath`, not `localPath`.
            // `deleteRecording` unconditionally removes `localPath` (the disposable
            // device cache), so pointing it at the user's local-storage archive
            // would delete their file when they delete a recovered recording.
            let recording = Recording(
                filename: filename,
                localPath: "",
                fileSize: size,
                recordedAt: modDate
            )
            recording.localCopyPath = file.path

            if let metadata = try? await WAVParser.parse(url: file) {
                recording.duration = metadata.duration
                recording.sampleRate = metadata.sampleRate
                recording.trackCount = metadata.trackCount
            }

            inferRecoveredDeviceOrigin(for: recording)
            modelContext.insert(recording)
            recovered += 1
        }

        if recovered > 0 {
            try? modelContext.save()
            AppLogger.sync.info("Local folder: recovered \(recovered) recordings")
        }

        return recovered
    }

    private func recoverFromNotion(databaseId: String) async -> Int {
        guard let apiKey = try? await KeychainService.shared.retrieve(for: .notionAPIKey),
              !apiKey.isEmpty else { return 0 }

        let service = NotionService(apiKey: apiKey, databaseId: databaseId, props: .loadStored())

        do {
            let pages = try await service.queryAllPages()
            AppLogger.sync.info("Notion: found \(pages.count) pages")

            // Mutable so filenames inserted earlier in this loop are seen by later
            // iterations — the Notion DB can contain multiple pages with the same
            // filename (e.g. a retranscribe creates a second page), and a stale
            // pre-loop snapshot would let every duplicate insert its own active row.
            var seenFilenames = fetchAllKnownFilenames()
            var recovered = 0

            for page in pages {
                guard !seenFilenames.contains(page.filename) else {
                    // Recording already exists — enrich with Notion metadata if missing
                    await enrichExistingRecording(filename: page.filename, from: page, databaseId: databaseId, service: service)
                    continue
                }

                // A Notion-only recovery only makes sense if the page actually has
                // transcript text to restore — the audio itself is gone. Fetch it
                // first; if there's none (or the fetch failed/was truncated), skip
                // the insert so a later device/S3 sync of the real file isn't
                // permanently blocked by a filename-tracked placeholder that has
                // neither transcript nor audio.
                guard let transcript = try? await service.fetchPageTranscript(pageId: page.pageId),
                      !transcript.isEmpty else {
                    continue
                }

                let recording = Recording(
                    filename: page.filename,
                    localPath: "",
                    fileSize: 0,
                    recordedAt: page.recordedAt ?? Date()
                )
                recording.notionPageCreatedAt = Date()
                recording.notionPageId = page.pageId.isEmpty ? nil : page.pageId
                recording.notionDatabaseId = page.pageId.isEmpty ? nil : databaseId
                recording.transcriptionText = transcript
                recording.transcriptionStatus = .completed
                recording.transcribedAt = Date()

                if let title = page.title {
                    recording.llmTitle = title
                }
                if let summary = page.summary, !summary.isEmpty {
                    recording.llmSummary = summary
                }
                if let lang = page.language, !lang.isEmpty {
                    recording.transcriptionLanguage = lang
                }

                inferRecoveredDeviceOrigin(for: recording)
                modelContext.insert(recording)
                seenFilenames.insert(page.filename)
                recovered += 1
            }

            if recovered > 0 {
                try? modelContext.save()
                AppLogger.sync.info("Notion: recovered \(recovered) recordings")
            }

            return recovered
        } catch {
            AppLogger.sync.error("Notion recovery scan failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Fills in gaps on an existing Recording with data from Notion (e.g. if
    /// S3 recovery created the entry but it has no transcription yet).
    private func enrichExistingRecording(filename: String, from page: NotionRecordingInfo, databaseId: String, service: NotionService) async {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt == nil })
        guard let recording = try? modelContext.fetch(descriptor).first else { return }

        var changed = false

        if recording.sourceFolder == nil {
            inferRecoveredDeviceOrigin(for: recording)
            if recording.sourceFolder != nil {
                changed = true
            }
        }

        if recording.transcriptionText == nil || recording.transcriptionText?.isEmpty == true {
            if let transcript = try? await service.fetchPageTranscript(pageId: page.pageId), !transcript.isEmpty {
                recording.transcriptionText = transcript
                recording.transcriptionStatus = .completed
                recording.transcribedAt = Date()
                changed = true
            }
        }

        if recording.llmTitle == nil, let title = page.title {
            recording.llmTitle = title
            changed = true
        }

        if recording.llmSummary == nil, let summary = page.summary, !summary.isEmpty {
            recording.llmSummary = summary
            changed = true
        }

        if recording.notionPageCreatedAt == nil {
            recording.notionPageCreatedAt = Date()
            changed = true
        }

        // Backfill the page ID so a later retranscribe updates this existing page
        // in place instead of creating a duplicate (pre-existing pages predate the
        // notionPageId field).
        if recording.notionPageId == nil, !page.pageId.isEmpty {
            recording.notionPageId = page.pageId
            recording.notionDatabaseId = databaseId
            changed = true
        }

        // Notion holds the true recording date; S3/local recovery only had the
        // object/file modification time. Prefer the Notion date so recovered rows
        // sort and display by when they were actually recorded.
        if let recordedAt = page.recordedAt, recording.recordedAt != recordedAt {
            recording.recordedAt = recordedAt
            changed = true
        }

        if changed {
            recording.updatedAt = Date()
            try? modelContext.save()
            AppLogger.sync.debug("Enriched recording \(filename, privacy: .private) with Notion data")
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

    /// Whether the recording has audio we can (re)transcribe from: an S3 object,
    /// an existing local copy, or an on-disk device cache file.
    nonisolated static func hasAudioSource(_ recording: Recording) -> Bool {
        if recording.s3Key != nil { return true }
        let fm = FileManager.default
        if let copy = recording.localCopyPath, fm.fileExists(atPath: copy) { return true }
        if !recording.localPath.isEmpty, fm.fileExists(atPath: recording.localPath) { return true }
        return false
    }

    private func hasAudioSource(_ recording: Recording) -> Bool {
        Self.hasAudioSource(recording)
    }

    /// Retranscribe a recording
    func retranscribe(_ recording: Recording) async {
        guard let transcriber = transcriptionProvider else {
            return
        }

        // Don't wipe a recovered transcript: a Notion-only recovery has no audio
        // source (empty localPath, no s3Key/localCopyPath), so retranscription
        // would only fail and hide the restored transcript behind the failure UI.
        guard hasAudioSource(recording) else {
            AppLogger.sync.info("Skipping retranscribe for \(recording.filename, privacy: .private): no audio source")
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
            case .whisperKit, .parakeet:
                guard let audio = await resolveLocalAudioPath(for: recording) else {
                    throw SyncTranscriptionError.noAudioSource
                }
                defer { audio.cleanup?() }
                result = try await transcribeLocal(transcriber, path: audio.path, recording: recording)
            }

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()
            // Always overwrite (including nil) so a flat retranscription clears
            // any diarization blob from a previous Parakeet run.
            if let segs = result.speakerSegments, !segs.isEmpty {
                recording.speakerSegmentsData = try? JSONEncoder().encode(segs)
            } else {
                recording.speakerSegmentsData = nil
            }
            if let notes = result.overdubNotes, !notes.isEmpty {
                recording.overdubNotesData = try? JSONEncoder().encode(notes)
            } else {
                recording.overdubNotesData = nil
            }

            // Reset note + summary tracking so retranscription regenerates them
            // from the new transcript. notionPageId is deliberately kept so the
            // existing Notion page is updated in place rather than duplicated.
            recording.appleNoteCreatedAt = nil
            recording.notionPageCreatedAt = nil
            recording.llmProcessedAt = nil

            // Regenerate summary/notes via deliverRemote so the Work Offline
            // guard is honoured; reconciliation finishes deferred steps later.
            await deliverRemote(recording, transcription: result)

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
            // Rows with no sourceFolder are either pre-/memo-split recordings, or
            // recovered rows inferRecoveredDeviceOrigin couldn't identify as
            // /memo — both cases are /recordings, or not on the device at all
            // (in which case the device call below just fails harmlessly).
            let folder = (recording.sourceFolder ?? .recordings).rawValue
            // `deviceFilename` holds the literal on-device name; `filename` may be
            // locally qualified (e.g. "memo-0001.wav") to keep the app-wide identity
            // collision-free with /recordings, so it isn't safe to send to the device.
            let deviceFilename = recording.deviceFilename ?? recording.filename
            switch await deviceWatch.deleteFromDevice(filename: deviceFilename, folder: folder) {
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

        await refreshPendingCount()
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

    private func handleNewRecordings(downloads: [DownloadedRecording], serial: String) async {
        // Debug: Count total recordings in database
        let countDescriptor = FetchDescriptor<Recording>()
        let totalCount = (try? modelContext.fetch(countDescriptor).count) ?? 0
        AppLogger.sync.debug("Database has \(totalCount, privacy: .public) total recordings")

        for download in downloads {
            let url = download.url
            let filename = url.lastPathComponent

            // Check if already in database (excluding soft-deleted recordings)
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt == nil })
            if let existing = try? modelContext.fetch(descriptor).first {
                // Skip only if it already has audio. An audio-less recovered row
                // (e.g. Notion-only) must NOT be skipped: let the device file flow
                // through so createRecording can attach its audio — otherwise the
                // recording stays unplayable/untranscribable forever.
                if Self.hasAudioSource(existing) {
                    AppLogger.sync.debug("Skipping already tracked recording \(filename, privacy: .private)")
                    continue
                }
                AppLogger.sync.info("Attaching device audio to recovered recording \(filename, privacy: .private)")
            } else {
                // Not tracked at all — but skip if it exists as a soft-deleted row
                let deletedDescriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt != nil })
                if let deleted = try? modelContext.fetch(deletedDescriptor).first {
                    AppLogger.sync.debug("Skipping soft-deleted recording \(filename, privacy: .private) (deletedAt=\(String(describing: deleted.deletedAt), privacy: .public))")
                    continue // Skip soft-deleted recordings too
                }
                AppLogger.sync.info("New recording detected: \(filename, privacy: .private)")
            }

            // Add to debouncer
            pendingRecordingOrigins[url.path] = PendingRecordingOrigin(source: download.source, deviceFilename: download.deviceFilename)
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
                // Create recording record (or adopt an audio-less recovered row)
                let recording = try await createRecording(from: url)

                if recording.transcriptionStatus == .completed {
                    // Adopted an already-transcribed recovered row: persist the
                    // audio only — don't re-transcribe or recreate the Notion page.
                    await attachDeviceAudio(to: recording)
                } else {
                    await processRecording(recording)
                }
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

    func createRecording(from url: URL) async throws -> Recording {
        let filename = url.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let modDate = attributes[.modificationDate] as? Date ?? Date()

        // Adopt an existing audio-less recovered row (e.g. Notion-only) with the
        // same filename instead of inserting a duplicate — this attaches the real
        // device audio to the row that already holds the recovered transcript.
        let existingDescriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.filename == filename && $0.deletedAt == nil })
        let existing = try? modelContext.fetch(existingDescriptor).first
        let isAdoption = existing != nil && !Self.hasAudioSource(existing!)

        let recording = existing ?? Recording(
            filename: filename,
            localPath: url.path,
            fileSize: fileSize,
            recordedAt: modDate
        )

        if isAdoption {
            recording.localPath = url.path
            recording.fileSize = fileSize
            // Keep the recovered recordedAt (from Notion) — it's more accurate
            // than the device file's modification time.
        }

        // Parse WAV metadata
        if let metadata = try? await WAVParser.parse(url: url) {
            recording.duration = metadata.duration
            recording.sampleRate = metadata.sampleRate
            recording.trackCount = metadata.trackCount
        }

        // Calculate hash
        recording.fileHash = try await FileHasher.sha256(url: url)

        // Set device serial
        recording.deviceSerial = deviceWatch.currentDeviceSerial
        if let origin = pendingRecordingOrigins.removeValue(forKey: url.path) {
            recording.sourceFolder = origin.source
            recording.deviceFilename = origin.deviceFilename
        }
        recording.updatedAt = Date()

        if !isAdoption {
            modelContext.insert(recording)
        }
        try modelContext.save()

        // Update device recordings count (only for genuinely new recordings)
        if !isAdoption, let serial = recording.deviceSerial {
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
                recording.speakerSegmentsData = existing.speakerSegmentsData
                recording.overdubNotesData = existing.overdubNotesData
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
            // Local ASR (Parakeet/WhisperKit) works offline: transcribe now, then
            // store + deliver. storeRecording defers S3 when offline; deliverRemote
            // is a no-op when offline and gets retried by reconciliation later.
            let transcriptionResult = await transcribeRecording(recording, provider: provider)
            _ = await storeRecording(recording, allowS3Upload: backupToS3)

            if let transcriptionResult {
                await deliverRemote(recording, transcription: transcriptionResult)
                if reachability.isOnline, UserDefaults.standard.bool(forKey: "notify.onSync") {
                    await notificationService.transcriptionComplete(preview: transcriptionResult.text)
                }
            }
        } else {
            // Cloud transcription (or storage-first) needs the network. When
            // offline, preserve a local copy first (if configured) so the
            // archival file is written regardless, then defer the rest until
            // reconciliation brings us back online.
            if !reachability.isOnline {
                _ = await storeRecording(recording, allowS3Upload: false)
                recording.transcriptionStatus = (transcriptionProvider != nil) ? .pending : .none
                recording.updatedAt = Date()
                try? modelContext.save()
                AppLogger.sync.info("Offline: deferring cloud processing for \(recording.filename, privacy: .private)")
                await refreshPendingCount()
                return
            }

            let allowS3Upload = !isLocalProvider || backupToS3
            let storageOk = await storeRecording(recording, allowS3Upload: allowS3Upload)
            guard storageOk else { return }

            let transcriptionResult = await transcribeRecording(recording, provider: provider)
            if let transcriptionResult {
                await deliverRemote(recording, transcription: transcriptionResult)
                if UserDefaults.standard.bool(forKey: "notify.onSync") {
                    await notificationService.transcriptionComplete(preview: transcriptionResult.text)
                }
            }
        }

        await refreshPendingCount()
    }

    /// Persists the audio for a recovered row we just attached a device file to,
    /// without re-transcribing (the transcript was already restored from Notion).
    private func attachDeviceAudio(to recording: Recording) async {
        let provider = transcriptionProviderKind ?? .elevenLabs
        let isLocalProvider = provider == .whisperKit || provider == .parakeet
        let backupToS3 = UserDefaults.standard.bool(forKey: "s3.backupAfterTranscription")
        let allowS3Upload = !isLocalProvider || backupToS3
        _ = await storeRecording(recording, allowS3Upload: allowS3Upload)
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
        } else if allowS3Upload, s3Service != nil {
            // Offline: defer the upload (not a failure) so the local phase
            // continues. Reconciliation uploads it once we're back online.
            guard reachability.isOnline else {
                AppLogger.sync.info("Offline: deferring S3 upload for \(recording.filename, privacy: .private)")
                return true
            }
            await uploadToS3IfPossible(recording)
            // Deferred backup uploads shouldn't block the pipeline; only a
            // failure of a *required* upload (no local copy) is fatal here.
            return recording.s3Key != nil || recording.localCopyPath != nil
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

    /// Uploads a recording's local audio to S3 if it hasn't been uploaded yet and
    /// a source file exists on disk. Used by both the live pipeline and
    /// reconciliation, so it must be idempotent.
    private func uploadToS3IfPossible(_ recording: Recording) async {
        guard recording.s3Key == nil, let s3 = s3Service else { return }
        guard FileManager.default.fileExists(atPath: recording.localPath) else {
            AppLogger.sync.debug("Deferred S3 upload skipped: no local audio for \(recording.filename, privacy: .private)")
            return
        }
        do {
            let result = try await s3.upload(fileURL: URL(fileURLWithPath: recording.localPath))
            recording.s3Key = result.s3Key
            recording.s3UploadedAt = result.uploadedAt
            recording.updatedAt = Date()
            try? modelContext.save()
            AppLogger.sync.info("Uploaded to S3: \(recording.filename, privacy: .private)")
        } catch {
            lastError = error.localizedDescription
            await notificationService.storageError("S3 upload failed: \(error.localizedDescription)")
        }
    }

    /// Resolves an on-disk audio path for local transcription providers, plus a
    /// `cleanup` closure the caller must run when done (deletes a temp download
    /// and/or releases security-scoped access — no-op when neither applies).
    ///
    /// Prefers the in-container device cache, which is always readable, over the
    /// user's configured local-audio copy: that copy can live outside the app
    /// sandbox (e.g. a synced cloud folder), and opening it without holding the
    /// folder's security-scoped bookmark fails with `AVAudioFile` error -54. When
    /// only the external copy exists we start that bookmark for the read. Falls
    /// back to downloading the S3 object to a temp file (what makes recordings
    /// restored by startup recovery, with an `s3Key` but no local audio,
    /// transcribable).
    private func resolveLocalAudioPath(for recording: Recording) async -> (path: String, cleanup: (() -> Void)?)? {
        let fm = FileManager.default

        // In-container device cache first — readable without any bookmark.
        if !recording.localPath.isEmpty, fm.fileExists(atPath: recording.localPath) {
            return (recording.localPath, nil)
        }

        if let copy = recording.localCopyPath, fm.fileExists(atPath: copy) {
            // The copy may be outside the sandbox; hold the local-audio folder's
            // security-scoped bookmark for the duration of the read so the open
            // doesn't fail with error -54.
            if let folder = SecurityScopedBookmark.resolve(key: "localaudio.folderPath"),
               folder.startAccessingSecurityScopedResource() {
                return (copy, { folder.stopAccessingSecurityScopedResource() })
            }
            return (copy, nil)
        }

        guard let s3Key = recording.s3Key, let s3 = s3Service else { return nil }
        let ext = (recording.filename as NSString).pathExtension
        let tmp = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "wav" : ext)
        do {
            try await s3.download(s3Key: s3Key, to: tmp)
            AppLogger.sync.info("Downloaded S3 audio for transcription: \(recording.filename, privacy: .private)")
            return (tmp.path, { try? FileManager.default.removeItem(at: tmp) })
        } catch {
            AppLogger.sync.error("Failed to download S3 audio for \(recording.filename, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether diarization must be skipped for this recording regardless of the
    /// diarization setting. True only for the TP-7's /memo folder, which only
    /// ever captures the primary user's own voice — any "speaker" diarization
    /// might detect there would be a misattribution, not a real second
    /// speaker. /recordings has no such guarantee (it can capture interviews,
    /// meetings, etc.), so diarization still runs there as normal.
    nonisolated static func forceSingleSpeaker(for recording: Recording) -> Bool {
        recording.sourceFolder == .memo
    }

    /// Whether a recording is an overdubbed /memo (multiple tracks captured while
    /// the primary user recorded over their own base memo) rather than a plain
    /// single-track memo or a /recordings multi-speaker capture.
    nonisolated static func hasMemoOverdubTracks(for recording: Recording) -> Bool {
        recording.trackCount > 1 && recording.sourceFolder == .memo
    }

    /// Recordings recovered from S3/Notion never had `WAVParser` run against them
    /// (no local audio existed yet at recovery time), so `trackCount` is stuck at
    /// the model default of 1. Only re-parses when it looks unset, so a normal
    /// device-ingested recording (already correct from `createRecording`) doesn't
    /// pay for a redundant parse on every transcription.
    private func refreshTrackCountIfNeeded(for recording: Recording, path: String) async {
        guard recording.trackCount <= 1,
              let metadata = try? await WAVParser.parse(url: URL(fileURLWithPath: path)) else { return }
        recording.trackCount = metadata.trackCount
    }

    /// Runs a local (WhisperKit/Parakeet) transcription.
    private func transcribeLocal(_ transcriber: any TranscriptionProvider, path: String, recording: Recording) async throws -> TranscriptionResult {
        guard let parakeet = transcriber as? ParakeetService else {
            return try await transcriber.transcribe(localPath: path)
        }

        // Rows recovered from S3/Notion have no local audio at recovery time, so
        // `trackCount` is stuck at the model default of 1 until now — the first
        // point a real file is on disk. Re-derive it so a recovered multi-track
        // memo/recording doesn't silently fall through to the flat single-track
        // path below.
        await refreshTrackCountIfNeeded(for: recording, path: path)

        // A TP-7 /recordings file with 2+ tracks captures distinct speakers on
        // separate channels — split and transcribe each independently instead
        // of handing a naive downmix (which would sum the speakers together)
        // to the transcriber.
        if recording.trackCount > 1, recording.sourceFolder == .recordings {
            return try await transcribeMultiTrackRecording(parakeet, path: path, recording: recording)
        }

        // A TP-7 /memo file with 2+ tracks is an overdub: track 0 is the base
        // memo, tracks 1+ are a second pass over the same recording captured
        // as `OverdubNote`s rather than merged into the transcript.
        if Self.hasMemoOverdubTracks(for: recording) {
            return try await transcribeMemoOverdub(parakeet, sourcePath: path)
        }

        return try await parakeet.transcribe(localPath: path, forceSingleSpeaker: Self.forceSingleSpeaker(for: recording))
    }

    /// Splits a multi-track /recordings WAV into its per-speaker tracks and
    /// transcribes each independently. `extractTracks` drops all-silent track
    /// slots (the TP-7 pads unused tracks with silence), so a file that's really
    /// single-track once silence is removed transcribes as one diarized track
    /// instead of a phantom multi-speaker/overdub split. Writes the corrected
    /// (non-silent) track count back onto the recording so the UI and future
    /// routing stop treating the padded slots as real tracks.
    private func transcribeMultiTrackRecording(_ parakeet: ParakeetService, path: String, recording: Recording) async throws -> TranscriptionResult {
        let tracks = try MultiTrackAudio.extractTracks(from: URL(fileURLWithPath: path))
        defer {
            for track in tracks where track.path != path {
                try? FileManager.default.removeItem(at: track)
            }
        }

        if recording.trackCount != tracks.count {
            recording.trackCount = tracks.count
            recording.updatedAt = Date()
            try? modelContext.save()
        }

        // Only genuinely multi-track audio goes through per-track transcription;
        // a single surviving track (incl. a 2-or-fewer-channel file that
        // extractTracks returns unchanged) is a normal single-track recording.
        guard tracks.count > 1 else {
            return try await parakeet.transcribe(localPath: tracks.first?.path ?? path, forceSingleSpeaker: false)
        }
        return try await parakeet.transcribeMultiTrack(trackPaths: tracks.map(\.path))
    }

    /// Splits an overdubbed /memo recording (`trackCount > 1`) into its base track
    /// (track 0 — rendered as the normal single-speaker transcript) and overdub
    /// tracks (1+ — captured as `OverdubNote`s rather than merged into the transcript,
    /// since they're a second pass over the same recording, not new speech in line).
    private func transcribeMemoOverdub(_ parakeet: ParakeetService, sourcePath: String) async throws -> TranscriptionResult {
        let trackURLs = try MultiTrackAudio.extractTracks(from: URL(fileURLWithPath: sourcePath))
        defer {
            for url in trackURLs where url.path != sourcePath {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var result = try await parakeet.transcribe(localPath: trackURLs[0].path, forceSingleSpeaker: true)

        var notes: [OverdubNote] = []
        for (index, trackURL) in trackURLs.enumerated() where index > 0 {
            let overdub = try await parakeet.transcribeOverdubTrack(localPath: trackURL.path)
            guard !overdub.text.isEmpty else { continue }
            notes.append(OverdubNote(trackIndex: index, startTime: overdub.startTime, text: overdub.text))
        }
        result.overdubNotes = notes.isEmpty ? nil : notes
        return result
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
            case .whisperKit, .parakeet:
                guard let audio = await resolveLocalAudioPath(for: recording) else {
                    throw SyncTranscriptionError.noAudioSource
                }
                defer { audio.cleanup?() }
                result = try await transcribeLocal(transcriber, path: audio.path, recording: recording)
                AppLogger.sync.debug("Transcribed locally with \(provider.shortName)")
            }

            AppLogger.sync.info("Transcription complete for \(recording.filename, privacy: .private) (language=\(result.languageCode, privacy: .public), chars=\(result.text.count, privacy: .public))")

            recording.transcriptionText = result.text
            recording.transcriptionLanguage = result.languageCode
            recording.transcriptionStatus = .completed
            recording.transcribedAt = Date()
            recording.updatedAt = Date()
            if let segs = result.speakerSegments, !segs.isEmpty {
                recording.speakerSegmentsData = try? JSONEncoder().encode(segs)
            } else {
                recording.speakerSegmentsData = nil
            }
            if let notes = result.overdubNotes, !notes.isEmpty {
                recording.overdubNotesData = try? JSONEncoder().encode(notes)
            } else {
                recording.overdubNotesData = nil
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

    /// Delivers a recording's transcript to Notion. Creates a page on first
    /// delivery; on later calls it updates the existing page in place when its
    /// ID is known. `forceUpdate` lets an explicit edit (e.g. a speaker
    /// reassignment) refresh an already-delivered page; without it, an
    /// already-delivered recording is skipped so reconciliation doesn't re-push.
    private func createNotionPage(for recording: Recording, transcription: TranscriptionResult, forceUpdate: Bool = false) async {
        if recording.notionPageCreatedAt != nil {
            guard forceUpdate, recording.notionPageId != nil else { return }
        }
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
            let expiry = Self.parseLinkExpiry(UserDefaults.standard.string(forKey: "applenotes.linkExpiry") ?? "7d")
            playURLString = (try? s3.generatePresignedURL(s3Key: s3Key, expiry: expiry).absoluteString) ?? ""
            downloadURLString = (try? s3.generateDownloadURL(s3Key: s3Key, filename: recording.filename, expiry: expiry).absoluteString) ?? ""
        } else if let localCopyPath = recording.localCopyPath {
            let u = URL(fileURLWithPath: localCopyPath).absoluteString
            playURLString = u; downloadURLString = u
        }

        // A page ID is only valid within the database it was created in. If the
        // configured database has changed since, ignore the stored ID and create
        // a fresh page in the current database instead of PATCHing the old one.
        let existingPageId = (recording.notionDatabaseId == databaseId) ? recording.notionPageId : nil

        let service = NotionService(apiKey: apiKey, databaseId: databaseId, props: .loadStored())
        do {
            // Update the existing page in place when we know its ID (e.g. after a
            // retranscribe, which resets notionPageCreatedAt to re-trigger delivery
            // but keeps the page ID), otherwise create a fresh page and record its
            // ID for next time.
            if let pageId = existingPageId {
                try await service.updateTranscriptionNote(
                    pageId: pageId,
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
                    summary: recording.llmSummary,
                    overdubNotes: transcription.overdubNotes
                )
                AppLogger.notes.info("Updated Notion page in place for \(recording.filename, privacy: .private)")
            } else {
                let pageId = try await service.createTranscriptionNote(
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
                    summary: recording.llmSummary,
                    overdubNotes: transcription.overdubNotes
                )
                recording.notionPageId = pageId.isEmpty ? nil : pageId
                recording.notionDatabaseId = pageId.isEmpty ? nil : databaseId
                AppLogger.notes.info("Created Notion page for \(recording.filename, privacy: .private)")
            }
            recording.notionPageCreatedAt = Date()
            recording.updatedAt = Date()
            try? modelContext.save()
        } catch {
            AppLogger.notes.error("Notion delivery failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Notion: \(error.localizedDescription)"
        }
    }

    /// Re-pushes a recording's current transcript to its existing Notion page
    /// after an in-app edit (e.g. reassigning a speaker, or assigning the same
    /// speaker to two tracks). Updates the page in place — no new page, and no
    /// LLM summary/title regeneration, since only the transcript body changed.
    /// When offline, clears the delivered marker so reconciliation refreshes the
    /// page (still in place, via the retained page ID) once back online.
    func refreshNotionForEditedTranscript(_ recording: Recording) async {
        // Only refresh a page that lives in the currently configured database —
        // a stored page ID from a different database can't be updated in place.
        let databaseId = UserDefaults.standard.string(forKey: "notion.databaseId") ?? ""
        guard UserDefaults.standard.bool(forKey: "notion.enabled"),
              recording.notionPageId != nil,
              recording.notionDatabaseId == databaseId,
              recording.transcriptionStatus == .completed,
              let text = recording.transcriptionText else { return }

        var overdubNotes: [OverdubNote]?
        if let data = recording.overdubNotesData {
            overdubNotes = try? JSONDecoder().decode([OverdubNote].self, from: data)
        }
        let transcription = TranscriptionResult(
            text: text,
            languageCode: recording.transcriptionLanguage ?? "en",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil,
            speakerSegments: nil,
            overdubNotes: overdubNotes
        )

        guard reachability.isOnline else {
            recording.notionPageCreatedAt = nil
            recording.updatedAt = Date()
            try? modelContext.save()
            await refreshPendingCount()
            AppLogger.notes.info("Offline: deferring Notion refresh for edited \(recording.filename, privacy: .private)")
            return
        }

        await createNotionPage(for: recording, transcription: transcription, forceUpdate: true)
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
            let expiry = Self.parseLinkExpiry(expiryString)
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

        // LLM title/summary are generated by generateAndStoreSummary earlier in
        // the delivery phase; reuse whatever was stored on the recording.
        let customTitle = recording.llmTitle
        let summary = recording.llmSummary

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
                    summary: summary,
                    overdubNotes: transcription.overdubNotes
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
                    summary: summary,
                    overdubNotes: transcription.overdubNotes
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

    /// Generates and persists the LLM title/summary if enabled and not already
    /// done. Idempotent — safe to call from both the live pipeline and
    /// reconciliation. Both the Notion and note steps read the stored values.
    private func generateAndStoreSummary(for recording: Recording, text: String) async {
        guard recording.llmProcessedAt == nil else { return }
        guard UserDefaults.standard.bool(forKey: "openrouter.enabled") else { return }

        guard let result = await generateLLMTitle(for: text) else { return }
        recording.llmTitle = result.title
        recording.llmSummary = result.summary
        recording.llmProcessedAt = Date()
        recording.updatedAt = Date()
        try? modelContext.save()
        AppLogger.notes.debug("Stored LLM title: \(result.title, privacy: .private)")
    }

    /// Runs the network-dependent delivery stages (S3 upload, LLM summary, Notion
    /// page, note creation) for a transcribed recording. Each stage is guarded by
    /// its own idempotency check, so this is safe to re-run. A no-op when offline —
    /// reconciliation retries it once connectivity returns.
    private func deliverRemote(_ recording: Recording, transcription: TranscriptionResult) async {
        guard reachability.isOnline else {
            AppLogger.sync.debug("Offline: deferring remote delivery for \(recording.filename, privacy: .private)")
            return
        }

        if Self.needsS3Upload(recording) {
            await uploadToS3IfPossible(recording)
            guard !Self.needsS3Upload(recording) else {
                AppLogger.sync.info("Deferring remote delivery until required S3 upload completes for \(recording.filename, privacy: .private)")
                await refreshPendingCount()
                return
            }
        }
        await generateAndStoreSummary(for: recording, text: transcription.text)
        await createNotionPage(for: recording, transcription: transcription)
        await createAppleNote(for: recording, transcription: transcription)
        await refreshPendingCount()
    }

    /// Completes deferred remote work across all recordings: resumes transcription
    /// for items captured offline, then finishes delivery for anything transcribed
    /// but not yet fully uploaded. Triggered at launch, on offline→online, and via
    /// a manual "Retry now".
    func reconcilePendingWork() async {
        guard reachability.isOnline, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.deletedAt == nil })
        guard let recordings = try? modelContext.fetch(descriptor) else { return }

        AppLogger.sync.info("Reconciling deferred remote work across \(recordings.count, privacy: .public) recordings")

        for recording in recordings {
            guard reachability.isOnline else { break }

            if recording.transcriptionStatus == .pending {
                guard transcriptionProvider != nil else { continue }
                // Cloud providers transcribe from S3; make sure the audio is
                // uploaded first when that's the storage path.
                if Self.needsS3Upload(recording) {
                    await uploadToS3IfPossible(recording)
                }
                let provider = transcriptionProviderKind ?? .elevenLabs
                if let result = await transcribeRecording(recording, provider: provider) {
                    await deliverRemote(recording, transcription: result)
                }
                continue
            }

            if recording.transcriptionStatus == .completed,
               !Self.remainingRemoteSteps(for: recording).isEmpty,
               let text = recording.transcriptionText {
                var overdubNotes: [OverdubNote]?
                if let data = recording.overdubNotesData {
                    overdubNotes = try? JSONDecoder().decode([OverdubNote].self, from: data)
                }
                let transcription = TranscriptionResult(
                    text: text,
                    languageCode: recording.transcriptionLanguage ?? "en",
                    languageProbability: nil,
                    transcriptionId: nil,
                    words: nil,
                    speakerSegments: nil,
                    overdubNotes: overdubNotes
                )
                await deliverRemote(recording, transcription: transcription)
            }
        }

        await refreshPendingCount()
    }

    /// Recomputes `pendingRemoteCount` from the database.
    func refreshPendingCount() async {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.deletedAt == nil })
        let all = (try? modelContext.fetch(descriptor)) ?? []
        pendingRemoteCount = all.filter { Self.hasPendingRemoteWork($0) }.count
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
        let expiry = Self.parseLinkExpiry(expiryString)

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

        var overdubNotes: [OverdubNote]?
        if let data = recording.overdubNotesData {
            overdubNotes = try? JSONDecoder().decode([OverdubNote].self, from: data)
        }

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
            summary: summary,
            overdubNotes: overdubNotes
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

    nonisolated static func parseLinkExpiry(_ string: String) -> TimeInterval {
        let value = string.dropLast()
        let unit = string.last

        guard let number = Double(value) else {
            return 7 * 24 * 3600 // Default 7 days
        }

        var expiry: TimeInterval
        switch unit {
        case "d": expiry = number * 24 * 3600
        case "h": expiry = number * 3600
        case "m": expiry = number * 60
        default: expiry = 7 * 24 * 3600
        }

        // Clamp to SigV4 presigned URL limits: min 60s, max 7 days (604800s)
        return min(max(expiry, 60), 604800)
    }
}

// MARK: - Deferred remote-work predicates
//
// Single source of truth (used by both reconciliation and the UI) for what
// network-dependent work a recording still owes. Pure functions over the
// recording's fields + current settings, so no schema/state is required.
extension SyncService {
    enum RemoteStep: Equatable {
        case s3       // audio upload
        case summary  // LLM title/summary
        case notion   // Notion page
        case note     // Markdown / Apple note
    }

    /// Whether a recording still needs its audio uploaded to S3, mirroring the
    /// conditions in `storeRecording`: local-folder storage precludes S3; for
    /// local ASR providers S3 is opt-in via the backup flag; cloud providers
    /// always need it.
    nonisolated static func needsS3Upload(_ recording: Recording) -> Bool {
        guard recording.s3Key == nil else { return false }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "s3.enabled"),
              !(defaults.string(forKey: "s3.bucket") ?? "").isEmpty else { return false }
        if defaults.bool(forKey: "localaudio.enabled"), LocalAudioService.isConfigured {
            return false
        }
        let providerRaw = defaults.string(forKey: "transcription.provider") ?? TranscriptionProviderKind.elevenLabs.rawValue
        let provider = TranscriptionProviderKind(rawValue: providerRaw) ?? .elevenLabs
        let isLocalProvider = provider == .whisperKit || provider == .parakeet
        return isLocalProvider ? defaults.bool(forKey: "s3.backupAfterTranscription") : true
    }

    /// The post-transcription remote steps a recording still owes, given current
    /// settings. Only meaningful for a recording whose transcript exists.
    nonisolated static func remainingRemoteSteps(for recording: Recording) -> [RemoteStep] {
        let defaults = UserDefaults.standard
        var steps: [RemoteStep] = []

        if needsS3Upload(recording) { steps.append(.s3) }

        let openRouterModel = defaults.string(forKey: "openrouter.model") ?? ""
        if defaults.bool(forKey: "openrouter.enabled"), !openRouterModel.isEmpty,
           recording.llmProcessedAt == nil {
            steps.append(.summary)
        }

        let notionEnabled = defaults.bool(forKey: "notion.enabled")
        let databaseId = defaults.string(forKey: "notion.databaseId") ?? ""
        if notionEnabled, !databaseId.isEmpty, recording.notionPageCreatedAt == nil {
            steps.append(.notion)
        }

        let notesEnabled = defaults.bool(forKey: "markdown.enabled") || defaults.bool(forKey: "applenotes.enabled")
        // createAppleNote requires an s3Key or a persisted local copy to build
        // the audio URL; without one it returns immediately and the step can
        // never be satisfied.
        let hasAudioForNote = recording.s3Key != nil || recording.localCopyPath != nil
        if notesEnabled, hasAudioForNote, recording.appleNoteCreatedAt == nil {
            steps.append(.note)
        }

        return steps
    }

    /// True when a recording has deferred remote work — either it still needs
    /// transcription (captured offline) or its transcript exists but has
    /// unfinished remote steps. Drives the "N waiting" count and the per-row badge.
    nonisolated static func hasPendingRemoteWork(_ recording: Recording) -> Bool {
        guard recording.deletedAt == nil else { return false }
        switch recording.transcriptionStatus {
        case .pending:
            return true
        case .completed:
            return !remainingRemoteSteps(for: recording).isEmpty
        default:
            return false
        }
    }
}

private enum SyncTranscriptionError: LocalizedError {
    case noAudioSource

    var errorDescription: String? {
        "No audio available to transcribe — the recording has no local file or S3 copy."
    }
}

/// A queued device download's origin, recorded before it reaches `createRecording`.
struct PendingRecordingOrigin: Equatable {
    let source: RecordingSource
    let deviceFilename: String
}
