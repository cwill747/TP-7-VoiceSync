//
//  EnhancementSettingsView.swift
//  TeenageEngVoiceSync
//
//  AI provider, title generation, and transcript cleanup settings.
//

import SwiftUI
import os

nonisolated struct EnhancementProviderState {
    enum Status: Equatable {
        case notTested
        case active
        case saved
        case testing
        case valid(Int)
        case error(String)
    }

    struct Configuration {
        var apiKey = ""
        var isAPIKeyStored = false
        var status: Status = .notTested
        var models: [OpenRouterModel] = []
        var isLoadingModels = false
        var modelLoadError: String?

        var hasUsableRemoteCredentials: Bool {
            isAPIKeyStored && !apiKey.isEmpty
        }
    }

    private(set) var configuredProvider: EnhancementProvider
    private var configurations: [EnhancementProvider: Configuration] = [:]

    init(configuredProvider: EnhancementProvider = .openRouter) {
        self.configuredProvider = configuredProvider
    }

    func configuration(for provider: EnhancementProvider) -> Configuration {
        configurations[provider] ?? Configuration()
    }

    mutating func update(
        _ provider: EnhancementProvider,
        _ update: (inout Configuration) -> Void
    ) {
        var configuration = configuration(for: provider)
        update(&configuration)
        configurations[provider] = configuration
    }

    mutating func configure(_ provider: EnhancementProvider) {
        configuredProvider = provider
    }
}

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

    @State private var showAPIKey = false
    @State private var isLoadingKey = true
    @State private var isSavingKey = false
    @State private var providerState = EnhancementProviderState()

    private let openRouterService = OpenRouterService()

    private var configuredProvider: EnhancementProvider {
        providerState.configuredProvider
    }

    private var configuredConfiguration: EnhancementProviderState.Configuration {
        providerState.configuration(for: configuredProvider)
    }

    private var configuredAPIKey: Binding<String> {
        Binding(
            get: { configuredConfiguration.apiKey },
            set: { newValue in
                providerState.update(configuredProvider) {
                    $0.apiKey = newValue
                    $0.isAPIKeyStored = false
                }
            }
        )
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
        !configuredConfiguration.apiKey.isEmpty || isConfiguredProviderLocalEndpoint
    }

    private var activeProviderHasCredentials: Bool {
        let activeConfiguration = providerState.configuration(for: provider)
        return activeConfiguration.hasUsableRemoteCredentials
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
            providerState.configure(provider)
            await loadAllProviderStatuses()
            await loadProviderKey(provider)
            if canUseAI {
                await loadModels(for: provider)
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
                        providerState.update(.custom) {
                            $0.modelLoadError = nil
                            $0.models = []
                            $0.status = $0.apiKey.isEmpty ? .notTested : .saved
                        }
                    }

                Text("Use an OpenAI-compatible chat API, for example http://127.0.0.1:8088/v1. Local endpoints do not require an API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if showAPIKey {
                    TextField("API Key", text: configuredAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API Key", text: configuredAPIKey)
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
                .disabled(isLoadingKey || isSavingKey || configuredConfiguration.apiKey.isEmpty || isConfiguredProviderLocalEndpoint)

                Button {
                    let targetProvider = configuredProvider
                    Task { await loadModels(for: targetProvider) }
                } label: {
                    Label("Test Connection", systemImage: "checkmark.circle")
                }
                .disabled(!configuredProviderCanTest || configuredConfiguration.isLoadingModels)

                if configuredConfiguration.isLoadingModels {
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

            if let modelLoadError = configuredConfiguration.modelLoadError {
                Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func providerStatusText(for rowProvider: EnhancementProvider) -> some View {
        switch providerState.configuration(for: rowProvider).status {
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
        switch providerState.configuration(for: rowProvider).status {
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
        let activeConfiguration = providerState.configuration(for: provider)
        if activeConfiguration.isLoadingModels {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading models...")
                    .foregroundStyle(.secondary)
            }
        } else if activeConfiguration.models.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: selection) {
                Text("Select a model").tag("")
                ForEach(activeConfiguration.models) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)

            if let model = activeConfiguration.models.first(where: { $0.id == selection.wrappedValue }) {
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
                providerState.update(provider) {
                    $0.apiKey = storedKey
                    $0.isAPIKeyStored = true
                    $0.status = .saved
                }
            }
        }
    }

    private func loadProviderKey(_ targetProvider: EnhancementProvider) async {
        isLoadingKey = true
        defer { isLoadingKey = false }
        let storedKey = (try? await KeychainService.shared.retrieve(for: targetProvider.keychainKey)) ?? ""
        providerState.update(targetProvider) {
            $0.apiKey = storedKey
            $0.isAPIKeyStored = !storedKey.isEmpty
        }
    }

    private func saveSelectedProviderKey() async {
        let targetProvider = configuredProvider
        let apiKey = configuredConfiguration.apiKey
        isSavingKey = true
        defer { isSavingKey = false }

        do {
            try await KeychainService.shared.save(apiKey, for: targetProvider.keychainKey)
            providerState.update(targetProvider) {
                $0.isAPIKeyStored = true
                $0.status = .saved
            }
        } catch {
            providerState.update(targetProvider) {
                $0.status = .error("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    private func loadModels(for targetProvider: EnhancementProvider) async {
        let configuration = providerState.configuration(for: targetProvider)
        let targetBaseURL = targetProvider == .custom ? apiBaseURL : targetProvider.defaultBaseURL
        let targetIsLocalEndpoint = isLocalEndpoint(targetProvider, baseURL: targetBaseURL)
        guard !configuration.apiKey.isEmpty || targetIsLocalEndpoint else { return }

        providerState.update(targetProvider) {
            $0.isLoadingModels = true
            $0.modelLoadError = nil
            $0.status = .testing
        }
        defer {
            providerState.update(targetProvider) { $0.isLoadingModels = false }
        }

        do {
            let models = try await openRouterService.fetchModels(
                apiKey: configuration.apiKey,
                provider: targetProvider,
                customBaseURL: targetBaseURL
            )
            providerState.update(targetProvider) {
                $0.models = models
                $0.modelLoadError = nil
                $0.status = .valid(models.count)
            }

            guard targetProvider == provider else { return }
            updateModelSelections(using: models)
        } catch {
            let message = modelLoadErrorMessage(for: error, provider: targetProvider, baseURL: targetBaseURL)
            providerState.update(targetProvider) {
                $0.models = []
                $0.modelLoadError = message
                $0.status = .error(message)
            }
            AppLogger.app.error("Failed to load enhancement models: \(String(describing: error), privacy: .public)")
        }
    }

    private func useProvider(_ newProvider: EnhancementProvider) {
        let previousProvider = provider
        providerRaw = newProvider.rawValue
        providerState.configure(newProvider)
        Task {
            // If the new slot is empty, carry over the previous provider's key so
            // LLM keeps working after a provider switch without requiring re-entry.
            let existingKey = (try? await KeychainService.shared.retrieve(for: newProvider.keychainKey)) ?? ""
            if existingKey.isEmpty, previousProvider != newProvider {
                let previousKey = (try? await KeychainService.shared.retrieve(for: previousProvider.keychainKey)) ?? ""
                if !previousKey.isEmpty {
                    try? await KeychainService.shared.save(previousKey, for: newProvider.keychainKey)
                    providerState.update(newProvider) {
                        $0.apiKey = previousKey
                        $0.isAPIKeyStored = true
                        $0.status = .saved
                    }
                }
            }
            await loadProviderKey(newProvider)
            if canUseAI {
                let cachedModels = providerState.configuration(for: newProvider).models
                if cachedModels.isEmpty {
                    await loadModels(for: newProvider)
                } else {
                    updateModelSelections(using: cachedModels)
                }
            }
        }
    }

    private func configureProvider(_ newProvider: EnhancementProvider) {
        providerState.configure(newProvider)
        Task { await loadProviderKey(newProvider) }
    }

    private func updateModelSelections(using models: [OpenRouterModel]) {
        let availableIDs = Set(models.map(\.id))
        let defaultModel = models.first(where: {
            $0.id.contains("gpt-4o-mini") || $0.id.contains("claude-3-haiku")
        }) ?? models.first

        if !availableIDs.contains(selectedLLMModel) {
            selectedLLMModel = defaultModel?.id ?? ""
        }
        if !availableIDs.contains(formatModel) {
            formatModel = defaultModel?.id ?? ""
        }
    }

    private func isLocalEndpoint(_ provider: EnhancementProvider, baseURL: String) -> Bool {
        guard provider == .custom,
              let host = URL(string: OpenRouterService.normalizeBaseURL(baseURL))?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || OpenRouterService.isPrivateIPv4(host)
    }

    private func modelLoadErrorMessage(
        for error: Error,
        provider: EnhancementProvider,
        baseURL: String
    ) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                let resolvedURL = provider == .custom
                    ? OpenRouterService.normalizeBaseURL(baseURL)
                    : provider.defaultBaseURL
                return "Could not reach \(resolvedURL). Check that the provider is reachable, then test again."
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
