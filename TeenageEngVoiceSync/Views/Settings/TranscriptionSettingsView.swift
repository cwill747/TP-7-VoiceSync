//
//  TranscriptionSettingsView.swift
//  TeenageEngVoiceSync
//
//  Combined transcription, Apple Notes, and LLM settings.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState

    // Transcription settings
    @AppStorage("transcription.enabled") private var transcriptionEnabled = false
    @AppStorage("transcription.provider") private var transcriptionProviderRaw = TranscriptionProviderKind.elevenLabs.rawValue
    @AppStorage("elevenlabs.model") private var elevenLabsModel = "scribe_v1"
    @AppStorage("whisperkit.model") private var whisperKitModel = "base"
    @AppStorage("parakeet.model") private var parakeetModel = ParakeetModelVariant.v2.rawValue
    @AppStorage("parakeet.diarizationEnabled") private var parakeetDiarizationEnabled = false
    @AppStorage("s3.backupAfterTranscription") private var whisperKitBackupToS3 = true
    @AppStorage("s3.enabled") private var s3Enabled = false

    // Apple Notes settings
    @AppStorage("applenotes.enabled") private var notesEnabled = false
    @AppStorage("applenotes.folder") private var notesFolder = "TP-7 Transcripts"
    @AppStorage("applenotes.linkExpiry") private var linkExpiry = "7d"

    // Local Markdown settings
    @AppStorage("markdown.enabled") private var markdownEnabled = false
    @AppStorage("markdown.folderPath") private var markdownFolderPath = ""

    // Notion settings
    @AppStorage("notion.enabled") private var notionEnabled = false
    @AppStorage("notion.databaseId") private var notionDatabaseId = ""

    // LLM settings
    @AppStorage("openrouter.enabled") private var llmEnabled = false
    @AppStorage("openrouter.model") private var selectedLLMModel = ""

    // State
    @State private var hasElevenLabsKey = false
    @State private var hasOpenRouterKey = false
    @State private var whisperKitDownloadState: ModelDownloadState = .notDownloaded
    @State private var whisperKitDownloadProgress = 0.0
    @State private var whisperKitDownloadError: String?
    @State private var parakeetDownloadState: ModelDownloadState = .notDownloaded
    @State private var parakeetDownloadProgress = 0.0
    @State private var parakeetDownloadError: String?
    @State private var parakeetDownloadPhaseText: String?
    @State private var parakeetDownloadTask: Task<Void, Never>?
    @State private var diarizerDownloadState: ModelDownloadState = .notDownloaded
    @State private var diarizerDownloadProgress = 0.0
    @State private var diarizerDownloadError: String?
    @State private var diarizerDownloadPhaseText: String?
    @State private var diarizerDownloadTask: Task<Void, Never>?
    @State private var enrolledSpeakerName: String?
    @State private var enrollmentNameInput = ""
    @State private var isEnrolling = false
    @State private var enrollmentError: String?
    @State private var availableLLMModels: [OpenRouterModel] = []
    @State private var isLoadingModels = false
    @State private var isTestingNote = false
    @State private var testNoteStatus: TestStatus?
    @State private var markdownInputPath = ""
    @State private var markdownValidationStatus: ValidationStatus?
    @State private var notionAPIKey = ""
    @State private var showNotionKey = false
    @State private var notionStatus: String?
    @State private var notionWarnings: [String] = []
    @State private var isValidatingNotion = false
    @State private var isLoadingNotionKey = true

    enum ValidationStatus {
        case success
        case error(String)
    }

    enum ModelDownloadState {
        case notDownloaded
        case downloading
        case ready
    }

    private let openRouterService = OpenRouterService()

    enum TestStatus {
        case success
        case error(String)
    }

    private var transcriptionProvider: TranscriptionProviderKind {
        TranscriptionProviderKind(rawValue: transcriptionProviderRaw) ?? .elevenLabs
    }

    private var transcriptionProviderBinding: Binding<TranscriptionProviderKind> {
        Binding(
            get: { transcriptionProvider },
            set: { newValue in
                transcriptionProviderRaw = newValue.rawValue
                refreshWhisperKitStatus()
                appState.reloadServices()
            }
        )
    }

    private var canTranscribe: Bool {
        switch transcriptionProvider {
        case .elevenLabs:
            return hasElevenLabsKey
        case .whisperKit:
            return true
        case .parakeet:
            return true
        }
    }

    private var transcriptionActive: Bool {
        transcriptionEnabled && canTranscribe
    }

    var body: some View {
        Form {
            // MARK: - Transcription Settings
            Section("Transcription") {
                Picker("Provider", selection: transcriptionProviderBinding) {
                    ForEach(TranscriptionProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Enable automatic transcription", isOn: $transcriptionEnabled)
                    .disabled(transcriptionProvider == .elevenLabs && !hasElevenLabsKey)
                    .onChange(of: transcriptionEnabled) { _, newValue in
                        if !newValue {
                            // Disable dependent features when transcription is disabled
                            notesEnabled = false
                        }
                        appState.reloadServices()
                    }

                if transcriptionProvider == .elevenLabs {
                    if !hasElevenLabsKey {
                        Label("Configure ElevenLabs API key in API Keys tab", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else {
                        Label("ElevenLabs API key configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    Picker("Model", selection: $elevenLabsModel) {
                        ForEach(ElevenLabsTranscriptionService.availableModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .disabled(!transcriptionEnabled || !hasElevenLabsKey)
                    .onChange(of: elevenLabsModel) { _, _ in
                        appState.reloadServices()
                    }

                    Text("Uses ElevenLabs speech-to-text to transcribe your voice recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if transcriptionProvider == .whisperKit {
                    Picker("Model", selection: $whisperKitModel) {
                        ForEach(WhisperKitService.availableModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .disabled(whisperKitDownloadState == .downloading)
                    .onChange(of: whisperKitModel) { _, _ in
                        refreshWhisperKitStatus()
                        appState.reloadServices()
                    }

                    if let model = WhisperKitService.availableModels.first(where: { $0.id == whisperKitModel }) {
                        Text(model.detailLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Download Model") {
                            downloadWhisperKitModel()
                        }
                        .disabled(whisperKitDownloadState == .downloading)

                        if whisperKitDownloadState == .downloading {
                            ProgressView(value: whisperKitDownloadProgress)
                                .frame(width: 120)
                        }
                    }

                    if let errorMessage = whisperKitDownloadError {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        switch whisperKitDownloadState {
                        case .notDownloaded:
                            Label("Model not downloaded yet", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .downloading:
                            Label("Downloading model...", systemImage: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .ready:
                            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    if s3Enabled {
                        Toggle("Backup audio to S3", isOn: $whisperKitBackupToS3)
                            .onChange(of: whisperKitBackupToS3) { _, _ in
                                appState.reloadServices()
                            }
                    } else {
                        Label("Enable S3 storage to back up audio", systemImage: "cloud")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Text("Runs locally using WhisperKit. Download a model for offline use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if transcriptionProvider == .parakeet {
                    Picker("Model", selection: $parakeetModel) {
                        ForEach(ParakeetModelVariant.allCases) { variant in
                            Text(variant.displayName).tag(variant.rawValue)
                        }
                    }
                    .disabled(parakeetDownloadState == .downloading)
                    .onChange(of: parakeetModel) { _, _ in
                        refreshParakeetStatus()
                        appState.reloadServices()
                    }

                    HStack {
                        Button("Download Model") {
                            downloadParakeetModel()
                        }
                        .disabled(parakeetDownloadState == .downloading)

                        if parakeetDownloadState == .downloading {
                            ProgressView(value: parakeetDownloadProgress)
                                .frame(width: 120)

                            Button("Cancel") {
                                cancelParakeetDownload()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if let errorMessage = parakeetDownloadError {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        switch parakeetDownloadState {
                        case .notDownloaded:
                            Label("Model not downloaded yet", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .downloading:
                            Label(parakeetDownloadPhaseText ?? "Downloading model...", systemImage: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .ready:
                            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    Text("Runs locally on the Apple Neural Engine. First transcription downloads the model if you skip this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Speaker diarization", isOn: $parakeetDiarizationEnabled)
                        .disabled(diarizerDownloadState == .downloading)
                        .onChange(of: parakeetDiarizationEnabled) { _, _ in
                            appState.reloadServices()
                        }

                    if parakeetDiarizationEnabled {
                        HStack {
                            Button("Download Diarization Model") {
                                downloadDiarizerModel()
                            }
                            .disabled(diarizerDownloadState == .downloading)

                            if diarizerDownloadState == .downloading {
                                ProgressView(value: diarizerDownloadProgress)
                                    .frame(width: 120)

                                Button("Cancel") {
                                    diarizerDownloadTask?.cancel()
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if let errorMessage = diarizerDownloadError {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        } else {
                            switch diarizerDownloadState {
                            case .notDownloaded:
                                Label("Diarization model not downloaded yet", systemImage: "icloud.and.arrow.down")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            case .downloading:
                                Label(diarizerDownloadPhaseText ?? "Downloading model...", systemImage: "arrow.down.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            case .ready:
                                Label("Diarization model downloaded", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }

                        Text("Labels each paragraph \"Speaker 1\", \"Speaker 2\", etc. based on who's talking. Adds a one-time model download and extra processing time per recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        if let enrolledSpeakerName {
                            Label("Your voice is enrolled as \"\(enrolledSpeakerName)\"", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)

                            Button("Remove") {
                                ParakeetService.clearEnrolledSpeaker()
                                self.enrolledSpeakerName = nil
                                enrollmentNameInput = ""
                            }
                            .buttonStyle(.borderless)
                        } else {
                            TextField("Your name (e.g. Cameron)", text: $enrollmentNameInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isEnrolling)

                            HStack {
                                Button("Choose Sample Recording…") {
                                    enrollFromSampleRecording()
                                }
                                .disabled(isEnrolling || enrollmentNameInput.trimmingCharacters(in: .whitespaces).isEmpty || diarizerDownloadState != .ready)

                                if isEnrolling {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }

                            if diarizerDownloadState != .ready {
                                Text("Download the diarization model above first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let enrollmentError {
                                Label(enrollmentError, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }

                            Text("Pick a recording where you're the only speaker (a solo voice memo works well). Your voice will be labeled by name instead of \"Speaker N\" from then on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // MARK: - Apple Notes Integration
            Section("Apple Notes Integration") {
                Toggle("Save transcriptions to Apple Notes", isOn: $notesEnabled)
                    .disabled(!transcriptionActive)
                    .onChange(of: notesEnabled) { _, newValue in
                        if newValue {
                            // Disable markdown when Apple Notes is enabled
                            markdownEnabled = false
                        }
                    }

                if !transcriptionActive {
                    Text("Enable transcription above to use Apple Notes integration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if notesEnabled {
                    TextField("Notes Folder", text: $notesFolder)
                        .textFieldStyle(.roundedBorder)

                    Picker("Link expiry", selection: $linkExpiry) {
                        Text("1 day").tag("1d")
                        Text("7 days").tag("7d")
                        Text("30 days").tag("30d")
                        Text("90 days").tag("90d")
                    }

                    HStack {
                        Button("Test Note Creation") {
                            testNoteCreation()
                        }
                        .disabled(isTestingNote)

                        if isTestingNote {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if let status = testNoteStatus {
                        switch status {
                        case .success:
                            Label("Test note created! Check your Notes app.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }

                Text("Creates notes in the Apple Notes app with transcription and audio links")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Local Markdown Notes
            Section("Local Markdown Notes") {
                Toggle("Save transcriptions as markdown files", isOn: $markdownEnabled)
                    .disabled(!transcriptionActive)
                    .onChange(of: markdownEnabled) { _, newValue in
                        if newValue {
                            // Disable Apple Notes when markdown is enabled
                            notesEnabled = false
                        }
                    }

                if markdownEnabled {
                    HStack {
                        TextField("e.g. ~/Downloads/TP7-Notes", text: $markdownInputPath)
                            .textFieldStyle(.roundedBorder)
                            .onAppear {
                                if !markdownFolderPath.isEmpty {
                                    markdownInputPath = markdownFolderPath
                                }
                            }

                        Button("Validate") {
                            validateMarkdownFolder()
                        }
                        .disabled(markdownInputPath.isEmpty)
                    }

                    if let status = markdownValidationStatus {
                        switch status {
                        case .success:
                            Label("Folder is valid and accessible", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    if !markdownFolderPath.isEmpty {
                        Text("Current: \(markdownFolderPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Creates .md files that work with any text editor or note-taking app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Notion Integration
            Section("Notion Integration") {
                Toggle("Send transcriptions to Notion", isOn: $notionEnabled)
                    .disabled(!transcriptionActive || isLoadingNotionKey)

                if !transcriptionActive {
                    Text("Enable transcription above to use Notion integration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if notionEnabled {
                    HStack {
                        if showNotionKey {
                            TextField("Integration Secret (ntn_… or secret_…)", text: $notionAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Integration Secret (ntn_… or secret_…)", text: $notionAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button { showNotionKey.toggle() } label: {
                            Image(systemName: showNotionKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(isLoadingNotionKey)

                    TextField("Database ID (32-char hex from the DB URL)", text: $notionDatabaseId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLoadingNotionKey)

                    HStack {
                        Button(isValidatingNotion ? "Connecting…" : "Save & Connect") {
                            Task { await saveAndValidateNotion() }
                        }
                        .disabled(isLoadingNotionKey || isValidatingNotion || notionAPIKey.isEmpty || notionDatabaseId.isEmpty)

                        if let notionStatus {
                            Text(notionStatus)
                                .font(.caption)
                                .foregroundStyle(notionStatus == "Connected" ? .green : .red)
                        }
                    }

                    if !notionWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(notionWarnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Text("Create an integration at notion.so/my-integrations, then share your database with it via ••• → Connections. Any missing properties are added automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Creates a page per recording in your Notion database, alongside Apple Notes or Markdown if enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Notes Status
            Section {
                if !notesEnabled && !markdownEnabled && !notionEnabled && transcriptionActive {
                    Label("Enable Apple Notes, Markdown, or Notion to save transcriptions", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    if notesEnabled {
                        Label("Transcriptions will be saved to Apple Notes", systemImage: "note.text")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    } else if markdownEnabled {
                        Label("Transcriptions will be saved as markdown files", systemImage: "doc.text")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    if notionEnabled {
                        Label("Transcriptions will be synced to Notion", systemImage: "note.text")
                            .foregroundStyle(.purple)
                            .font(.caption)
                    }
                }
            }

            // MARK: - LLM Title Generation
            Section("LLM Title Generation") {
                Toggle("Enable AI-powered titles", isOn: $llmEnabled)
                    .disabled(!hasOpenRouterKey)
                    .help("Generate intelligent titles for Apple Notes using AI")

                if !hasOpenRouterKey {
                    Label("Configure OpenRouter API key in API Keys tab", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("OpenRouter API key configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                if isLoadingModels {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading models...")
                            .foregroundStyle(.secondary)
                    }
                } else if availableLLMModels.isEmpty && hasOpenRouterKey {
                    Text("Click 'Refresh Models' to load available models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !availableLLMModels.isEmpty {
                    Picker("Model", selection: $selectedLLMModel) {
                        Text("Select a model").tag("")
                        ForEach(availableLLMModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!llmEnabled)

                    if let model = availableLLMModels.first(where: { $0.id == selectedLLMModel }) {
                        VStack(alignment: .leading, spacing: 4) {
                            if !model.description.isEmpty {
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text("Context: \(model.contextLength.formatted()) tokens")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Button("Refresh Models") {
                    Task { await loadModels() }
                }
                .buttonStyle(.borderless)
                .disabled(!hasOpenRouterKey || isLoadingModels)

                Text("Generates intelligent titles and summaries for your Apple Notes using AI. Configure the prompt in the Advanced tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            ensureTranscriptionDefaults()
            await checkAPIKeys()
            await loadNotionSettings()
            refreshWhisperKitStatus()
            refreshParakeetStatus()
            refreshDiarizerStatus()
            if hasOpenRouterKey {
                await loadModels()
            }
        }
    }

    // MARK: - Helper Methods

    private func checkAPIKeys() async {
        do {
            let elevenLabsKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey)
            hasElevenLabsKey = elevenLabsKey != nil && !elevenLabsKey!.isEmpty

            let openRouterKey = try await KeychainService.shared.retrieve(for: .openRouterAPIKey)
            hasOpenRouterKey = openRouterKey != nil && !openRouterKey!.isEmpty
        } catch {
            hasElevenLabsKey = false
            hasOpenRouterKey = false
        }
    }

    private func ensureTranscriptionDefaults() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "transcription.provider") == nil {
            defaults.set(TranscriptionProviderKind.elevenLabs.rawValue, forKey: "transcription.provider")
        }
        if defaults.string(forKey: "whisperkit.model") == nil {
            defaults.set("base", forKey: "whisperkit.model")
        }
        if defaults.object(forKey: "s3.backupAfterTranscription") == nil {
            defaults.set(true, forKey: "s3.backupAfterTranscription")
        }
        if defaults.object(forKey: "transcription.enabled") == nil {
            let legacyEnabled = defaults.bool(forKey: "elevenlabs.enabled")
            defaults.set(legacyEnabled, forKey: "transcription.enabled")
        }
    }

    private func refreshWhisperKitStatus() {
        whisperKitDownloadError = nil
        if WhisperKitService.cachedModelPath(for: whisperKitModel) != nil {
            whisperKitDownloadState = .ready
        } else {
            whisperKitDownloadState = .notDownloaded
        }
    }

    private func refreshParakeetStatus() {
        parakeetDownloadError = nil
        let variant = ParakeetModelVariant(rawValue: parakeetModel) ?? .v2
        parakeetDownloadState = ParakeetService.cachedModelExists(for: variant) ? .ready : .notDownloaded
    }

    private func downloadParakeetModel() {
        parakeetDownloadError = nil
        parakeetDownloadProgress = 0
        parakeetDownloadPhaseText = "Listing files…"
        parakeetDownloadState = .downloading

        let variant = ParakeetModelVariant(rawValue: parakeetModel) ?? .v2
        parakeetDownloadTask = Task {
            do {
                try await ParakeetService.downloadModel(variant: variant) { status in
                    Task { @MainActor in
                        parakeetDownloadProgress = status.fractionCompleted
                        parakeetDownloadPhaseText = status.phaseDescription
                    }
                }
                await MainActor.run {
                    parakeetDownloadState = .ready
                    parakeetDownloadPhaseText = nil
                    appState.reloadServices()
                }
            } catch is CancellationError {
                await MainActor.run {
                    parakeetDownloadState = .notDownloaded
                    parakeetDownloadPhaseText = nil
                }
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    await MainActor.run {
                        parakeetDownloadState = .notDownloaded
                        parakeetDownloadPhaseText = nil
                    }
                    return
                }
                await MainActor.run {
                    parakeetDownloadState = .notDownloaded
                    parakeetDownloadError = error.localizedDescription
                    parakeetDownloadPhaseText = nil
                }
            }
        }
    }

    private func cancelParakeetDownload() {
        parakeetDownloadTask?.cancel()
    }

    private func refreshDiarizerStatus() {
        diarizerDownloadError = nil
        diarizerDownloadState = ParakeetService.diarizerModelExists() ? .ready : .notDownloaded
        enrolledSpeakerName = ParakeetService.EnrolledSpeakerProfile.loadStored()?.name
    }

    private func enrollFromSampleRecording() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Enroll"
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let name = enrollmentNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        enrollmentError = nil
        isEnrolling = true

        Task {
            do {
                try await ParakeetService.enrollSpeaker(from: url.path, name: name)
                await MainActor.run {
                    enrolledSpeakerName = name
                    isEnrolling = false
                }
            } catch {
                await MainActor.run {
                    enrollmentError = error.localizedDescription
                    isEnrolling = false
                }
            }
        }
    }

    private func downloadDiarizerModel() {
        diarizerDownloadError = nil
        diarizerDownloadProgress = 0
        diarizerDownloadPhaseText = "Listing files…"
        diarizerDownloadState = .downloading

        diarizerDownloadTask = Task {
            do {
                try await ParakeetService.downloadDiarizerModel { status in
                    Task { @MainActor in
                        diarizerDownloadProgress = status.fractionCompleted
                        diarizerDownloadPhaseText = status.phaseDescription
                    }
                }
                await MainActor.run {
                    diarizerDownloadState = .ready
                    diarizerDownloadPhaseText = nil
                    appState.reloadServices()
                }
            } catch is CancellationError {
                await MainActor.run {
                    diarizerDownloadState = .notDownloaded
                    diarizerDownloadPhaseText = nil
                }
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    await MainActor.run {
                        diarizerDownloadState = .notDownloaded
                        diarizerDownloadPhaseText = nil
                    }
                    return
                }
                await MainActor.run {
                    diarizerDownloadState = .notDownloaded
                    diarizerDownloadError = error.localizedDescription
                    diarizerDownloadPhaseText = nil
                }
            }
        }
    }

    private func downloadWhisperKitModel() {
        whisperKitDownloadError = nil
        whisperKitDownloadProgress = 0
        whisperKitDownloadState = .downloading

        Task {
            do {
                let modelURL = try await WhisperKitService.downloadModel(variant: whisperKitModel) { progress in
                    Task { @MainActor in
                        whisperKitDownloadProgress = progress.fractionCompleted
                    }
                }
                WhisperKitService.storeDownloadedModel(path: modelURL, variant: whisperKitModel)
                await MainActor.run {
                    whisperKitDownloadState = .ready
                    appState.reloadServices()
                }
            } catch {
                await MainActor.run {
                    whisperKitDownloadState = .notDownloaded
                    whisperKitDownloadError = error.localizedDescription
                }
            }
        }
    }

    private func loadModels() async {
        guard hasOpenRouterKey else { return }

        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            let apiKey = try await KeychainService.shared.retrieve(for: .openRouterAPIKey) ?? ""
            availableLLMModels = try await openRouterService.fetchModels(apiKey: apiKey)

            // If no model selected yet, try to select a reasonable default
            if selectedLLMModel.isEmpty, let defaultModel = availableLLMModels.first(where: {
                $0.id.contains("gpt-4o-mini") || $0.id.contains("claude-3-haiku")
            }) {
                selectedLLMModel = defaultModel.id
            }
        } catch {
            AppLogger.app.error("Failed to load OpenRouter models: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadNotionSettings() async {
        notionAPIKey = (try? await KeychainService.shared.retrieve(for: .notionAPIKey)) ?? ""
        isLoadingNotionKey = false
    }

    private func saveAndValidateNotion() async {
        isValidatingNotion = true
        notionStatus = nil
        notionWarnings = []
        do {
            try await KeychainService.shared.save(notionAPIKey, for: .notionAPIKey)
            let result = try await NotionService.provisionDatabase(apiKey: notionAPIKey, databaseId: notionDatabaseId)
            result.props.store()
            notionStatus = "Connected"
            notionWarnings = result.warnings
        } catch {
            notionStatus = "Failed: \(error.localizedDescription)"
        }
        isValidatingNotion = false
    }

    private func testNoteCreation() {
        isTestingNote = true
        testNoteStatus = nil

        Task {
            let service = AppleNotesService()
            do {
                try await service.createNote(
                    title: "Test Note - \(Date().formatted())",
                    body: "<p>This is a test note from TP-7 VoiceSync.</p><p>If you can see this, Apple Notes integration is working correctly!</p>",
                    folder: notesFolder
                )
                await MainActor.run {
                    testNoteStatus = .success
                    isTestingNote = false
                }
            } catch {
                await MainActor.run {
                    testNoteStatus = .error("Failed: \(error.localizedDescription)")
                    isTestingNote = false
                }
            }
        }
    }

    private func validateMarkdownFolder() {
        markdownValidationStatus = nil

        let path = markdownInputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Check if folder exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            markdownValidationStatus = .error("Folder does not exist")
            return
        }

        guard isDirectory.boolValue else {
            markdownValidationStatus = .error("Path is not a folder")
            return
        }

        // Try to write a test file
        let testFile = URL(fileURLWithPath: expandedPath).appendingPathComponent(".tp7-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
        } catch {
            markdownValidationStatus = .error("Cannot write to folder")
            return
        }

        // Success - save the path
        markdownFolderPath = expandedPath
        markdownValidationStatus = .success
    }
}

#Preview {
    TranscriptionSettingsView()
}
