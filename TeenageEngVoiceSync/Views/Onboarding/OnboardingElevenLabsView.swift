//
//  OnboardingElevenLabsView.swift
//  TeenageEngVoiceSync
//
//  ElevenLabs API key setup for transcription (core feature).
//

import SwiftUI

struct OnboardingElevenLabsView: View {
    @Binding var isConfigured: Bool

    @AppStorage("elevenlabs.enabled") private var transcriptionEnabled = false

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isVerifying = false
    @State private var verificationStatus: VerificationStatus?
    @State private var isLoading = true

    enum VerificationStatus {
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("ElevenLabs Transcription")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This is the core feature of TP-7 VoiceSync. An ElevenLabs API key is required to transcribe your recordings.")
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
                        TextField("Enter your ElevenLabs API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Enter your ElevenLabs API key", text: $apiKey)
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

                Link("Get an API key from ElevenLabs", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                    .font(.caption)
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
                Toggle("Enable automatic transcription", isOn: $transcriptionEnabled)
            }

            // Info text
            Text("Your API key is stored securely in your Mac's Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            if let existingKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey),
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
            try await TranscriptionService.validateAPIKey(apiKey)
            try await KeychainService.shared.save(apiKey, for: .elevenLabsAPIKey)
            verificationStatus = .success("API key verified and saved!")
            isConfigured = true
            transcriptionEnabled = true

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
    OnboardingElevenLabsView(isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
