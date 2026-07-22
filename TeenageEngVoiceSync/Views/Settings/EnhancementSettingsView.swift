//
//  EnhancementSettingsView.swift
//  TeenageEngVoiceSync
//
//  AI provider, title generation, and transcript cleanup settings.
//

import SwiftUI
import os

struct EnhancementSettingsView: View {
    @AppStorage(OpenRouterService.providerKey) private var providerRaw = EnhancementProvider.openRouter.rawValue
    @AppStorage(OpenRouterService.baseURLKey) private var apiBaseURL = ""
    @AppStorage("openrouter.enabled") private var llmEnabled = false
    @AppStorage("openrouter.model") private var selectedLLMModel = ""
    @AppStorage("openrouter.formatEnabled") private var formatEnabled = false
    @AppStorage("openrouter.formatModel") private var formatModel = ""
    @AppStorage("openrouter.format.removeFillerWords") private var removeFillerWords = false
    @AppStorage("openrouter.format.removeFalseStarts") private var removeFalseStarts = false
    @AppStorage("openrouter.format.splitParagraphs") private var splitParagraphs = false
    @AppStorage("openrouter.format.bulletPoints") private var bulletPoints = false

    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var isLoadingKey = true
    @State private var isSavingKey = false
    @State private var configuredProvider: EnhancementProvider = .openRouter
    @State private var providerStatuses: [EnhancementProvider: ProviderStatus] = [:]
    @State private var availableLLMModels: [OpenRouterModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    private let openRouterService = OpenRouterService()

    private enum ProviderStatus: Equatable {
        case notTested
        case active
        case saved
        case testing
        case valid(Int)
        case error(String)
    }

    private var provider: EnhancementProvider {
        EnhancementProvider(rawValue: providerRaw) ?? .openRouter
    }

    private var resolvedBaseURL: String {
        OpenRouterService.resolvedBaseURL()
    }

    private var isLocalEndpoint: Bool {
        OpenRouterService.isLocalEndpoint()
    }

    private var isConfiguredProviderLocalEndpoint: Bool {
        guard configuredProvider == .custom,
              let host = URL(string: configuredBaseURL)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || OpenRouterService.isPrivateIPv4(host)
    }

    private var configuredBaseURL: String {
        if configuredProvider == .openRouter {
            return OpenRouterService.defaultBaseURL
        }
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? configuredProvider.defaultBaseURL : raw
        return OpenRouterService.normalizeBaseURL(base)
    }

    private var configuredProviderCanTest: Bool {
        !apiKey.isEmpty || isConfiguredProviderLocalEndpoint
    }

    private var activeProviderHasCredentials: Bool {
        if provider == configuredProvider {
            return !apiKey.isEmpty
        }

        switch providerStatuses[provider] {
        case .saved, .valid:
            return true
        default:
            return false
        }
    }

    private var canUseAI: Bool {
        activeProviderHasCredentials || isLocalEndpoint
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ForEach(EnhancementProvider.allCases) { provider in
                        providerRow(provider)
                    }
                }
            } header: {
                Label("Providers", systemImage: "sparkles")
            } footer: {
                Text("Choose the active OpenAI-compatible provider used for titles, summaries, and transcript cleanup.")
            }

            Section("Title Generation") {
                Toggle("Generate AI titles and summaries", isOn: $llmEnabled)
                    .disabled(!canUseAI)

                modelPicker(selection: $selectedLLMModel, enabled: llmEnabled, emptyMessage: "Test the provider connection to load models.")

                Text("Generates titles and summaries for saved notes. Configure the prompt in the Advanced tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript Cleanup") {
                Toggle("Clean up transcripts with AI", isOn: $formatEnabled)
                    .disabled(!canUseAI)

                modelPicker(selection: $formatModel, enabled: formatEnabled, emptyMessage: "Test the provider connection above to load models.")

                Text("Rewrites transcripts for punctuation, paragraphs, and likely speech-to-text mistakes before saving notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Cut filler words (\"um\", \"uh\", \"like\")", isOn: $removeFillerWords)
                    .disabled(!formatEnabled)
                Toggle("Remove false starts and repeated words", isOn: $removeFalseStarts)
                    .disabled(!formatEnabled)
                Toggle("Split into paragraphs by topic", isOn: $splitParagraphs)
                    .disabled(!formatEnabled)
                Toggle("Format lists as bullet points", isOn: $bulletPoints)
                    .disabled(!formatEnabled)
            }

            Section {
                Text("Provider API keys are stored securely in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            configuredProvider = provider
            await loadAllProviderStatuses()
            await loadConfiguredProviderKey()
            if canUseAI {
                await loadModels()
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ rowProvider: EnhancementProvider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: rowProvider.systemImage)
                    .frame(width: 28)
                    .foregroundStyle(rowProvider == provider ? .teal : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(rowProvider.displayName)
                            .font(.headline)
                        if rowProvider == provider {
                            Text("Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)
                        }
                    }
                    providerStatusText(for: rowProvider)
                }

                Spacer()

                Button("Configure") {
                    configureProvider(rowProvider)
                }

                Button("Use") {
                    useProvider(rowProvider)
                }
                .disabled(rowProvider == provider)
            }

            if configuredProvider == rowProvider {
                Divider()
                providerConfigurationControls
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(rowProvider == provider ? Color.teal : Color.clear, lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private var providerConfigurationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if configuredProvider == .custom {
                TextField("Base URL", text: $apiBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiBaseURL) { _, _ in
                        modelLoadError = nil
                        availableLLMModels = []
                    }

                Text("Use an OpenAI-compatible chat API, for example http://127.0.0.1:8088/v1. Local endpoints do not require an API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if showAPIKey {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(showAPIKey ? "Hide API key" : "Show API key"))
            }
            .disabled(isLoadingKey || isConfiguredProviderLocalEndpoint)

            if let dashboardURL = configuredProvider.dashboardURL {
                Link("Open \(configuredProvider.displayName) Dashboard", destination: dashboardURL)
                    .font(.caption)
            }

            HStack {
                Button(isSavingKey ? "Saving..." : "Save") {
                    Task { await saveSelectedProviderKey() }
                }
                .disabled(isLoadingKey || isSavingKey || apiKey.isEmpty || isConfiguredProviderLocalEndpoint)

                Button {
                    Task { await loadModels() }
                } label: {
                    Label("Test Connection", systemImage: "checkmark.circle")
                }
                .disabled(!configuredProviderCanTest || isLoadingModels)

                if isLoadingModels {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            providerStatusLabel(for: configuredProvider)

            if isConfiguredProviderLocalEndpoint {
                Label("Local endpoint - no API key required", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            if let modelLoadError {
                Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func providerStatusText(for rowProvider: EnhancementProvider) -> some View {
        switch providerStatuses[rowProvider] ?? .notTested {
        case .active:
            Text("Ready")
                .font(.caption)
                .foregroundStyle(.green)
        case .saved:
            Text("API key saved")
                .font(.caption)
                .foregroundStyle(.green)
        case .testing:
            Text("Testing connection...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .valid(let count):
            Text("\(count) models available")
                .font(.caption)
                .foregroundStyle(.green)
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        case .notTested:
            Text("Connection not tested")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func providerStatusLabel(for rowProvider: EnhancementProvider) -> some View {
        switch providerStatuses[rowProvider] ?? .notTested {
        case .active, .saved:
            Label("API key saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .testing:
            Label("Testing connection...", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .valid(let count):
            Label("Connection successful - \(count) models available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .notTested:
            Label("Connection not tested", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func modelPicker(selection: Binding<String>, enabled: Bool, emptyMessage: String) -> some View {
        if isLoadingModels {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading models...")
                    .foregroundStyle(.secondary)
            }
        } else if availableLLMModels.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: selection) {
                Text("Select a model").tag("")
                ForEach(availableLLMModels) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)

            if let model = availableLLMModels.first(where: { $0.id == selection.wrappedValue }) {
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
    }

    private func loadAllProviderStatuses() async {
        for provider in EnhancementProvider.allCases {
            let storedKey = (try? await KeychainService.shared.retrieve(for: provider.keychainKey)) ?? ""
            if !storedKey.isEmpty {
                providerStatuses[provider] = .saved
            }
        }
    }

    private func loadConfiguredProviderKey() async {
        isLoadingKey = true
        defer { isLoadingKey = false }
        apiKey = (try? await KeychainService.shared.retrieve(for: configuredProvider.keychainKey)) ?? ""
    }

    private func saveSelectedProviderKey() async {
        isSavingKey = true
        defer { isSavingKey = false }

        do {
            try await KeychainService.shared.save(apiKey, for: configuredProvider.keychainKey)
            providerStatuses[configuredProvider] = .saved
        } catch {
            providerStatuses[configuredProvider] = .error("Failed to save: \(error.localizedDescription)")
        }
    }

    private func loadModels() async {
        guard !apiKey.isEmpty || isConfiguredProviderLocalEndpoint else { return }

        isLoadingModels = true
        modelLoadError = nil
        providerStatuses[configuredProvider] = .testing
        defer { isLoadingModels = false }

        do {
            availableLLMModels = try await openRouterService.fetchModels(
                apiKey: apiKey,
                provider: configuredProvider,
                customBaseURL: apiBaseURL
            )
            modelLoadError = nil
            providerStatuses[configuredProvider] = .valid(availableLLMModels.count)

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
            let message = modelLoadErrorMessage(for: error)
            modelLoadError = message
            providerStatuses[configuredProvider] = .error(message)
            AppLogger.app.error("Failed to load enhancement models: \(String(describing: error), privacy: .public)")
        }
    }

    private func useProvider(_ newProvider: EnhancementProvider) {
        let previousProvider = provider
        providerRaw = newProvider.rawValue
        configuredProvider = newProvider
        apiKey = ""
        modelLoadError = nil
        availableLLMModels = []
        Task {
            // If the new slot is empty, carry over the previous provider's key so
            // LLM keeps working after a provider switch without requiring re-entry.
            let existingKey = (try? await KeychainService.shared.retrieve(for: newProvider.keychainKey)) ?? ""
            if existingKey.isEmpty, previousProvider != newProvider {
                let previousKey = (try? await KeychainService.shared.retrieve(for: previousProvider.keychainKey)) ?? ""
                if !previousKey.isEmpty {
                    try? await KeychainService.shared.save(previousKey, for: newProvider.keychainKey)
                    providerStatuses[newProvider] = .saved
                }
            }
            await loadConfiguredProviderKey()
            if canUseAI {
                await loadModels()
            }
        }
    }

    private func configureProvider(_ newProvider: EnhancementProvider) {
        configuredProvider = newProvider
        apiKey = ""
        modelLoadError = nil
        availableLLMModels = []
        Task { await loadConfiguredProviderKey() }
    }

    private func modelLoadErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                return "Could not reach \(configuredBaseURL). Check that the provider is reachable, then test again."
            default:
                break
            }
        }

        return "Failed to load models: \(error.localizedDescription)"
    }
}

#Preview {
    EnhancementSettingsView()
}
