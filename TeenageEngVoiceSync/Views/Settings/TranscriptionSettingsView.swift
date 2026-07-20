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
    // OpenAI-compatible API base URL. Empty = OpenRouter default; set to e.g.
    // http://127.0.0.1:8088/v1 for a local llama-server / LM Studio / Ollama.
    @AppStorage(OpenRouterService.baseURLKey) private var apiBaseURL = ""

    // LLM transcript cleanup settings (separate model choice from titling)
    @AppStorage("openrouter.formatEnabled") private var formatEnabled = false
    @AppStorage("openrouter.formatModel") private var formatModel = ""
    @AppStorage("openrouter.format.removeFillerWords") private var removeFillerWords = false
    @AppStorage("openrouter.format.removeFalseStarts") private var removeFalseStarts = false
    @AppStorage("openrouter.format.splitParagraphs") private var splitParagraphs = false
    @AppStorage("openrouter.format.bulletPoints") private var bulletPoints = false

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
    @State private var parakeetUnifiedDownloadState: ModelDownloadState = .notDownloaded
    @State private var parakeetUnifiedDownloadProgress = 0.0
    @State private var parakeetUnifiedDownloadError: String?
    @State private var parakeetUnifiedDownloadPhaseText: String?
    @State private var parakeetUnifiedDownloadTask: Task<Void, Never>?
    @State private var availableLLMModels: [OpenRouterModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var isTestingNote = false
    @State private var testNoteStatus: TestStatus?
    @State private var markdownInputPath = ""
    @State private var selectedMarkdownFolderURL: URL?
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
                // Persist before rebuilding services. The app can be quit while
                // that asynchronous reload is still running.
                UserDefaults.standard.synchronize()
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
        case .parakeetUnified:
            return true
        }
    }

    private var transcriptionActive: Bool {
        transcriptionEnabled && canTranscribe
    }

    /// The effective base URL, falling back to OpenRouter when unset.
    private var resolvedBaseURL: String {
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? OpenRouterService.defaultBaseURL : raw
    }

    /// A local endpoint (llama-server etc.) needs no API key.
    private var isLocalEndpoint: Bool {
        OpenRouterService.isLocalEndpoint()
    }

    /// AI steps can run when a key is configured or the endpoint is local.
    private var canUseAI: Bool {
        hasOpenRouterKey || isLocalEndpoint
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

                        Label("Manage who's speaking in the People section of the main window.", systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if transcriptionProvider == .parakeetUnified {
                    HStack {
                        Button("Download Model") {
                            downloadParakeetUnifiedModel()
                        }
                        .disabled(parakeetUnifiedDownloadState == .downloading)

                        if parakeetUnifiedDownloadState == .downloading {
                            ProgressView(value: parakeetUnifiedDownloadProgress)
                                .frame(width: 120)

                            Button("Cancel") {
                                cancelParakeetUnifiedDownload()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if let errorMessage = parakeetUnifiedDownloadError {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        switch parakeetUnifiedDownloadState {
                        case .notDownloaded:
                            Label("Model not downloaded yet", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .downloading:
                            Label(parakeetUnifiedDownloadPhaseText ?? "Downloading model...", systemImage: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        case .ready:
                            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    Text("Runs locally on the Apple Neural Engine and adds punctuation and capitalization natively, so you can turn off AI cleanup below. English only; no speaker diarization, multi-track splitting, or vocabulary boosting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            .onChange(of: markdownInputPath) { _, newValue in
                                if selectedMarkdownFolderURL?.path != newValue {
                                    selectedMarkdownFolderURL = nil
                                }
                                markdownValidationStatus = nil
                            }
                            .onAppear {
                                if !markdownFolderPath.isEmpty {
                                    markdownInputPath = markdownFolderPath
                                }
                            }

                        Button("Choose…") {
                            chooseMarkdownFolder()
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

                    TextField("Database ID (paste the DB URL or the 32-char hex ID)", text: $notionDatabaseId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLoadingNotionKey)
                        .onChange(of: notionDatabaseId) { _, newValue in
                            let extracted = NotionService.extractDatabaseId(from: newValue)
                            if extracted != newValue {
                                notionDatabaseId = extracted
                            }
                        }

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

            // MARK: - AI Provider
            Section("AI Provider") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(OpenRouterService.defaultBaseURL, text: $apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: apiBaseURL) { _, _ in
                                modelLoadError = nil
                            }
                            .onSubmit { Task { await loadModels() } }
                        if !apiBaseURL.isEmpty {
                            Button("Reset") { apiBaseURL = "" }
                                .buttonStyle(.borderless)
                        }
                        Button {
                            Task { await loadModels() }
                        } label: {
                            Label("Refresh Models", systemImage: "arrow.clockwise")
                        }
                        .disabled(!canUseAI || isLoadingModels)
                    }

                    if isLocalEndpoint {
                        Label("Local endpoint — no API key required", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if hasOpenRouterKey {
                        Label("API key configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Configure an API key in the API Keys tab", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    if let modelLoadError {
                        Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Text("Any OpenAI-compatible chat API. Leave blank for OpenRouter, or point at a local server you run yourself — e.g. llama-server at http://127.0.0.1:8088/v1 (start it with: llama-server --model <model.gguf> --port 8088). Local endpoints need no API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - LLM Title Generation
            Section("LLM Title Generation") {
                Toggle("Enable AI-powered titles", isOn: $llmEnabled)
                    .disabled(!canUseAI)
                    .help("Generate intelligent titles for Apple Notes using AI")

                if !canUseAI {
                    Label("Configure an API key in API Keys tab, or set a local endpoint above", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if isLoadingModels {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading models...")
                            .foregroundStyle(.secondary)
                    }
                } else if let modelLoadError {
                    Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if availableLLMModels.isEmpty && canUseAI {
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

                Text("Generates intelligent titles and summaries for your Apple Notes using AI. Configure the prompt in the Advanced tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - AI Transcript Cleanup
            Section("AI Transcript Cleanup") {
                Toggle("Clean up transcripts with AI", isOn: $formatEnabled)
                    .disabled(!canUseAI)
                    .help("Add punctuation and fix likely transcription errors before saving")

                if !canUseAI {
                    Label("Configure an API key in API Keys tab, or set a local endpoint above", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if isLoadingModels {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading models...")
                            .foregroundStyle(.secondary)
                    }
                } else if let modelLoadError {
                    Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if availableLLMModels.isEmpty && canUseAI {
                    Text("Click 'Refresh Models' above to load available models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !availableLLMModels.isEmpty {
                    Picker("Model", selection: $formatModel) {
                        Text("Select a model").tag("")
                        ForEach(availableLLMModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!formatEnabled)

                    if let model = availableLLMModels.first(where: { $0.id == formatModel }) {
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

                Text("Rewrites the transcript with proper punctuation and paragraphs, correcting only words very likely misheard by the transcription engine. Notes and Notion pages use the cleaned text. Configure the prompt in the Advanced tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Cut filler words (\u{201c}um\u{201d}, \u{201c}uh\u{201d}, \u{201c}like\u{201d})", isOn: $removeFillerWords)
                    .disabled(!formatEnabled)
                Toggle("Remove false starts and repeated words", isOn: $removeFalseStarts)
                    .disabled(!formatEnabled)
                Toggle("Split into paragraphs by topic", isOn: $splitParagraphs)
                    .disabled(!formatEnabled)
                Toggle("Format lists as bullet points", isOn: $bulletPoints)
                    .disabled(!formatEnabled)
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
            refreshParakeetUnifiedStatus()
            refreshDiarizerStatus()
            if canUseAI {
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

    private func refreshParakeetUnifiedStatus() {
        parakeetUnifiedDownloadError = nil
        parakeetUnifiedDownloadState = ParakeetUnifiedService.cachedModelExists() ? .ready : .notDownloaded
    }

    private func downloadParakeetUnifiedModel() {
        parakeetUnifiedDownloadError = nil
        parakeetUnifiedDownloadProgress = 0
        parakeetUnifiedDownloadPhaseText = "Listing files…"
        parakeetUnifiedDownloadState = .downloading

        parakeetUnifiedDownloadTask = Task {
            do {
                try await ParakeetUnifiedService.downloadModel { status in
                    Task { @MainActor in
                        parakeetUnifiedDownloadProgress = status.fractionCompleted
                        parakeetUnifiedDownloadPhaseText = status.phaseDescription
                    }
                }
                await MainActor.run {
                    parakeetUnifiedDownloadState = .ready
                    parakeetUnifiedDownloadPhaseText = nil
                    appState.reloadServices()
                }
            } catch is CancellationError {
                await MainActor.run {
                    parakeetUnifiedDownloadState = .notDownloaded
                    parakeetUnifiedDownloadPhaseText = nil
                }
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    await MainActor.run {
                        parakeetUnifiedDownloadState = .notDownloaded
                        parakeetUnifiedDownloadPhaseText = nil
                    }
                    return
                }
                await MainActor.run {
                    parakeetUnifiedDownloadState = .notDownloaded
                    parakeetUnifiedDownloadError = error.localizedDescription
                    parakeetUnifiedDownloadPhaseText = nil
                }
            }
        }
    }

    private func cancelParakeetUnifiedDownload() {
        parakeetUnifiedDownloadTask?.cancel()
    }

    private func refreshDiarizerStatus() {
        diarizerDownloadError = nil
        diarizerDownloadState = ParakeetService.diarizerModelExists() ? .ready : .notDownloaded
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
        guard canUseAI else { return }

        isLoadingModels = true
        modelLoadError = nil
        defer { isLoadingModels = false }

        do {
            let apiKey = (try? await KeychainService.shared.retrieve(for: .openRouterAPIKey)) ?? ""
            availableLLMModels = try await openRouterService.fetchModels(apiKey: apiKey)
            modelLoadError = nil

            // Stored OpenRouter selections are invalid after switching to a
            // local server. Replace missing selections so SwiftUI's Picker and
            // subsequent completion requests always use an available model.
            let availableIDs = Set(availableLLMModels.map(\.id))
            let defaultModel = availableLLMModels.first(where: {
                $0.id.contains("gpt-4o-mini") || $0.id.contains("claude-3-haiku")
            }) ?? availableLLMModels.first

            if !availableIDs.contains(selectedLLMModel) {
                selectedLLMModel = defaultModel?.id ?? ""
            }
            if !availableIDs.contains(formatModel) {
                formatModel = defaultModel?.id ?? ""
            }
        } catch {
            availableLLMModels = []
            modelLoadError = modelLoadErrorMessage(for: error)
            AppLogger.app.error("Failed to load OpenRouter models: \(String(describing: error), privacy: .public)")
        }
    }

    private func modelLoadErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                return "Could not reach \(resolvedBaseURL). Check that the AI server is running and reachable, then refresh models."
            default:
                break
            }
        }

        return "Failed to load models: \(error.localizedDescription)"
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

    private func chooseMarkdownFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        let startPath = markdownInputPath.isEmpty ? markdownFolderPath : markdownInputPath
        if !startPath.isEmpty {
            let expanded = NSString(string: startPath).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedMarkdownFolderURL = url
        markdownInputPath = url.path
        validateMarkdownFolder()
    }

    private func validateMarkdownFolder() {
        markdownValidationStatus = nil

        let path = markdownInputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = NSString(string: path).expandingTildeInPath

        let folderURL: URL
        if let selectedMarkdownFolderURL, selectedMarkdownFolderURL.path == expandedPath {
            folderURL = selectedMarkdownFolderURL
        } else {
            folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        }
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

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
        let testFile = folderURL.appendingPathComponent(".tp7-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
        } catch {
            markdownValidationStatus = .error("Cannot write to folder")
            return
        }

        // Save the path and security-scoped bookmark together. Bail out if the
        // bookmark can't be created rather than persisting a folder we can't reopen.
        guard SecurityScopedBookmark.saveFolderSelection(url: folderURL, key: "markdown.folderPath") else {
            markdownValidationStatus = .error("Couldn't get lasting access to this folder. Use Choose… to grant access.")
            return
        }

        // Update the @AppStorage binding so the "Current:" label refreshes now (a
        // direct UserDefaults write to a dotted key is not observed by @AppStorage).
        markdownFolderPath = folderURL.path
        markdownValidationStatus = .success
    }
}

#Preview {
    TranscriptionSettingsView()
}
