//
//  TranscriptionSettingsView.swift
//  TeenageEngVoiceSync
//
//  Combined transcription, Apple Notes, and LLM settings.
//

import SwiftUI
import os

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState

    // Transcription settings
    @AppStorage("elevenlabs.enabled") private var transcriptionEnabled = false
    @AppStorage("elevenlabs.model") private var transcriptionModel = "scribe_v1"

    // Apple Notes settings
    @AppStorage("applenotes.enabled") private var notesEnabled = false
    @AppStorage("applenotes.folder") private var notesFolder = "TP-7 Transcripts"
    @AppStorage("applenotes.linkExpiry") private var linkExpiry = "7d"

    // Local Markdown settings
    @AppStorage("markdown.enabled") private var markdownEnabled = false
    @AppStorage("markdown.folderPath") private var markdownFolderPath = ""

    // LLM settings
    @AppStorage("openrouter.enabled") private var llmEnabled = false
    @AppStorage("openrouter.model") private var selectedLLMModel = ""

    // State
    @State private var hasElevenLabsKey = false
    @State private var hasOpenRouterKey = false
    @State private var availableLLMModels: [OpenRouterModel] = []
    @State private var isLoadingModels = false
    @State private var isTestingNote = false
    @State private var testNoteStatus: TestStatus?
    @State private var markdownInputPath = ""
    @State private var markdownValidationStatus: ValidationStatus?

    enum ValidationStatus {
        case success
        case error(String)
    }

    private let openRouterService = OpenRouterService()

    enum TestStatus {
        case success
        case error(String)
    }

    var body: some View {
        Form {
            // MARK: - Transcription Settings
            Section("Transcription") {
                Toggle("Enable automatic transcription", isOn: $transcriptionEnabled)
                    .disabled(!hasElevenLabsKey)
                    .onChange(of: transcriptionEnabled) { _, newValue in
                        if !newValue {
                            // Disable dependent features when transcription is disabled
                            notesEnabled = false
                        }
                        appState.reloadServices()
                    }

                if !hasElevenLabsKey {
                    Label("Configure ElevenLabs API key in API Keys tab", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("ElevenLabs API key configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Picker("Model", selection: $transcriptionModel) {
                    ForEach(TranscriptionService.availableModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .disabled(!transcriptionEnabled)

                Text("Uses ElevenLabs speech-to-text to transcribe your voice recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Apple Notes Integration
            Section("Apple Notes Integration") {
                Toggle("Save transcriptions to Apple Notes", isOn: $notesEnabled)
                    .disabled(!transcriptionEnabled || !hasElevenLabsKey)
                    .onChange(of: notesEnabled) { _, newValue in
                        if newValue {
                            // Disable markdown when Apple Notes is enabled
                            markdownEnabled = false
                        }
                    }

                if !transcriptionEnabled {
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
                    .disabled(!transcriptionEnabled || !hasElevenLabsKey)
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

            // MARK: - Notes Status
            Section {
                if !notesEnabled && !markdownEnabled && transcriptionEnabled {
                    Label("Enable Apple Notes or Markdown to save transcriptions", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else if notesEnabled {
                    Label("Transcriptions will be saved to Apple Notes", systemImage: "note.text")
                        .foregroundStyle(.blue)
                        .font(.caption)
                } else if markdownEnabled {
                    Label("Transcriptions will be saved as markdown files", systemImage: "doc.text")
                        .foregroundStyle(.green)
                        .font(.caption)
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
            await checkAPIKeys()
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
