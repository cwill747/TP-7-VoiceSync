//
//  OnboardingOpenRouterView.swift
//  TeenageEngVoiceSync
//
//  OpenRouter setup for AI-powered titles (optional).
//

import SwiftUI

struct OnboardingOpenRouterView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var decision: IntegrationDecision

    @State private var showKey = false
    @State private var isVerifying = false
    @State private var verificationStatus: VerificationStatus?
    /// True once a verify has failed in this session. Hides the Enable/Disable
    /// toggle so a kept-existing decision can't be waved back to enabled
    /// without another successful verify — see `existingConfigurationToggle`.
    @State private var hasFailedTest = false
    /// True once a verify has succeeded in this session. Keeps the fresh Enable
    /// toggle visible (so the user can flip it back on) even after they've
    /// turned it off, without reintroducing `existingConfigurationToggle`.
    @State private var hasVerifiedKey = false

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
                    .accessibilityHidden(true)

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
                        TextField("Enter your OpenRouter API key", text: $draft.openRouterAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Enter your OpenRouter API key", text: $draft.openRouterAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(showKey ? "Hide API key" : "Show API key"))
                }
                .disabled(draft.isSeeding)

                Link("Get an API key from OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.caption)

                Text("OpenRouter provides access to multiple AI models (GPT-4, Claude, etc.) through a single API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Existing configuration control (re-run only). Hidden once the key
            // is actively reconfigured this session — the Enable toggle below
            // takes over at that point instead of showing two overlapping controls.
            if draft.openRouterWasConfiguredAtSeed && !hasVerifiedKey && !hasFailedTest {
                existingConfigurationToggle
            }

            // Verify button and status
            VStack(spacing: 10) {
                HStack {
                    Button("Verify & Save") {
                        Task { await verifyAndSave() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(draft.openRouterAPIKey.isEmpty || isVerifying)

                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let status = verificationStatus {
                    statusLabel(for: status)
                }
            }

            // Enable toggle — keeps `decision` (not just the draft flag) in
            // sync, since OnboardingView.goToNextStep() re-derives
            // draft.openRouterEnabled from decision.isEnabled on Continue and
            // would otherwise silently re-enable a key the user just turned off.
            // Stays visible after being turned off (gated on `hasVerifiedKey`,
            // not `decision`) so the user can flip it back on.
            if hasVerifiedKey {
                Toggle("Enable AI-powered titles", isOn: Binding(
                    get: { draft.openRouterEnabled },
                    set: { newValue in
                        draft.openRouterEnabled = newValue
                        decision = newValue ? .configuredNow : .disabled
                    }
                ))
            }

            // Info text
            Text("Your API key is saved securely to your Mac's Keychain when you finish setup. You can select your preferred model in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var existingConfigurationToggle: some View {
        Toggle(isOn: Binding(
            get: { decision.isEnabled },
            set: { newValue in
                decision = newValue ? .keptExisting : .disabled
                draft.openRouterEnabled = newValue
            }
        )) {
            Text(decision.isEnabled ? "AI-powered titles are already configured — keep enabled" : "AI-powered titles are disabled")
                .font(.caption)
        }
        .toggleStyle(.switch)
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

    private func verifyAndSave() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let models = try await openRouterService.fetchModels(apiKey: draft.openRouterAPIKey)
            if models.isEmpty {
                verificationStatus = .error("No models returned - key may be invalid")
                hasFailedTest = true
                hasVerifiedKey = false
                decision = .disabled
                draft.openRouterEnabled = false
                return
            }

            // Stage the verified key + enabled flag in the draft; persisted on completion.
            verificationStatus = .success("Valid! \(models.count) models available")
            hasFailedTest = false
            hasVerifiedKey = true
            decision = .configuredNow
            draft.openRouterEnabled = true

            // Clear success message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    verificationStatus = nil
                }
            }
        } catch {
            verificationStatus = .error("Verification failed: \(error.localizedDescription)")
            hasFailedTest = true
            hasVerifiedKey = false
            // A failed (re)verify must not leave a kept-existing decision that
            // still reads as enabled — the key just tested may be an edited,
            // unvalidated value, and a kept `.isEnabled` decision would let
            // `apply()` commit it as a working OpenRouter key.
            decision = .disabled
            draft.openRouterEnabled = false
        }
    }
}

#Preview {
    OnboardingOpenRouterView(draft: OnboardingDraft(), decision: .constant(.notConfigured))
        .frame(width: 600, height: 440)
}
