//
//  OnboardingOpenRouterView.swift
//  TeenageEngVoiceSync
//
//  OpenRouter setup for AI-powered titles (optional).
//

import SwiftUI

struct OnboardingOpenRouterView: View {
    @Binding var isConfigured: Bool

    @AppStorage("openrouter.enabled") private var llmEnabled = false

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isVerifying = false
    @State private var verificationStatus: VerificationStatus?
    @State private var isLoading = true

    private let openRouterService = OpenRouterService()

    enum VerificationStatus {
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("OpenRouter AI Titles")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Optional: Use AI to generate intelligent titles and summaries for your Apple Notes based on the transcription content.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // API Key input
            VStack(alignment: .leading, spacing: 10) {
                Text("API Key")
                    .font(.headline)

                HStack {
                    if showKey {
                        TextField("Enter your OpenRouter API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Enter your OpenRouter API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(isLoading)

                Link("Get an API key from OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.caption)

                Text("OpenRouter provides access to multiple AI models (GPT-4, Claude, etc.) through a single API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Verify button and status
            VStack(spacing: 10) {
                HStack {
                    Button("Verify & Save") {
                        Task { await verifyAndSave() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(apiKey.isEmpty || isVerifying)

                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let status = verificationStatus {
                    statusLabel(for: status)
                }
            }

            // Enable toggle
            if isConfigured {
                Toggle("Enable AI-powered titles", isOn: $llmEnabled)
            }

            // Info text
            Text("Your API key is stored securely in your Mac's Keychain. You can select your preferred model in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadExistingKey()
        }
    }

    @ViewBuilder
    private func statusLabel(for status: VerificationStatus) -> some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func loadExistingKey() async {
        isLoading = true
        defer { isLoading = false }

        do {
            if let existingKey = try await KeychainService.shared.retrieve(for: OpenRouterService.activeKeychainKey()),
               !existingKey.isEmpty {
                apiKey = existingKey
                isConfigured = true
            }
        } catch {
            // Key not found, that's fine
        }
    }

    private func verifyAndSave() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let models = try await openRouterService.fetchModels(apiKey: apiKey)
            if models.isEmpty {
                verificationStatus = .error("No models returned - key may be invalid")
                return
            }

            try await KeychainService.shared.save(apiKey, for: OpenRouterService.activeKeychainKey())
            verificationStatus = .success("Valid! \(models.count) models available")
            isConfigured = true
            llmEnabled = true

            // Clear success message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    verificationStatus = nil
                }
            }
        } catch {
            verificationStatus = .error("Verification failed: \(error.localizedDescription)")
            isConfigured = false
        }
    }
}

#Preview {
    OnboardingOpenRouterView(isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
