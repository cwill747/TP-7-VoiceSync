//
//  APIKeysSettingsView.swift
//  TeenageEngVoiceSync
//
//  Unified API keys management view.
//

import SwiftUI
import os

struct APIKeysSettingsView: View {
    // AWS credentials
    @State private var awsAccessKeyId = ""
    @State private var awsSecretAccessKey = ""
    @State private var showAWSSecret = false
    @State private var isVerifyingAWS = false
    @State private var awsStatus: VerificationStatus?

    // ElevenLabs credentials
    @State private var elevenLabsAPIKey = ""
    @State private var showElevenLabsKey = false
    @State private var isVerifyingElevenLabs = false
    @State private var elevenLabsStatus: VerificationStatus?

    // Loading state
    @State private var isLoading = true

    enum VerificationStatus {
        case success(String)
        case error(String)
    }

    var body: some View {
        Form {
            // MARK: - AWS Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Access Key ID", text: $awsAccessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .disabled(isLoading)

                    HStack {
                        if showAWSSecret {
                            TextField("Secret Access Key", text: $awsSecretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Secret Access Key", text: $awsSecretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showAWSSecret.toggle()
                        } label: {
                            Image(systemName: showAWSSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(isLoading)

                    Text("Used to upload recordings to your S3 bucket (AWS S3 or Backblaze B2)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Save") {
                            Task { await saveAWSCredentials() }
                        }
                        .disabled(awsAccessKeyId.isEmpty || awsSecretAccessKey.isEmpty)

                        Button("Verify") {
                            Task { await verifyAWSCredentials() }
                        }
                        .disabled(awsAccessKeyId.isEmpty || awsSecretAccessKey.isEmpty || isVerifyingAWS)

                        if isVerifyingAWS {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if let status = awsStatus {
                        statusLabel(for: status)
                    }
                }
            } header: {
                Label("S3 Storage", systemImage: "cloud")
            }

            // MARK: - ElevenLabs Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if showElevenLabsKey {
                            TextField("API Key", text: $elevenLabsAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $elevenLabsAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showElevenLabsKey.toggle()
                        } label: {
                            Image(systemName: showElevenLabsKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(isLoading)

                    Text("Used for speech-to-text transcription of your recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Link("Open ElevenLabs Dashboard", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                        .font(.caption)

                    HStack {
                        Button("Save") {
                            Task { await saveElevenLabsKey() }
                        }
                        .disabled(elevenLabsAPIKey.isEmpty)

                        Button("Verify") {
                            Task { await verifyElevenLabsKey() }
                        }
                        .disabled(elevenLabsAPIKey.isEmpty || isVerifyingElevenLabs)

                        if isVerifyingElevenLabs {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if let status = elevenLabsStatus {
                        statusLabel(for: status)
                    }
                }
            } header: {
                Label("ElevenLabs", systemImage: "waveform")
            }

            Section {
                Text("All API keys are stored securely in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await loadAllCredentials()
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

    // MARK: - Load Credentials

    private func loadAllCredentials() async {
        isLoading = true
        defer { isLoading = false }

        do {
            awsAccessKeyId = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
            awsSecretAccessKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""
            elevenLabsAPIKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey) ?? ""
        } catch {
            AppLogger.app.error("Failed to load credentials: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Save & Verify AWS

    private func saveAWSCredentials() async {
        do {
            try await KeychainService.shared.save(awsAccessKeyId, for: .awsAccessKeyId)
            try await KeychainService.shared.save(awsSecretAccessKey, for: .awsSecretAccessKey)
            awsStatus = .success("Saved")
            clearStatus(for: .aws)
        } catch {
            awsStatus = .error("Failed to save: \(error.localizedDescription)")
        }
    }

    private func verifyAWSCredentials() async {
        isVerifyingAWS = true
        defer { isVerifyingAWS = false }

        let bucket = UserDefaults.standard.string(forKey: "s3.bucket") ?? ""
        let provider = S3Provider(rawValue: UserDefaults.standard.string(forKey: "s3.provider") ?? "") ?? .aws
        let region = UserDefaults.standard.string(forKey: "s3.region") ?? provider.defaultRegion
        let prefix = UserDefaults.standard.string(forKey: "s3.prefix") ?? "recordings/"

        guard !bucket.isEmpty else {
            awsStatus = .error("Configure S3 bucket in S3 Storage tab first")
            return
        }

        let service = S3Service(
            bucket: bucket,
            region: region,
            prefix: prefix,
            accessKeyId: awsAccessKeyId,
            secretAccessKey: awsSecretAccessKey,
            provider: provider
        )

        do {
            try await service.validateBucket()
            awsStatus = .success("Connection successful")
            clearStatus(for: .aws)
        } catch {
            awsStatus = .error("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Save & Verify ElevenLabs

    private func saveElevenLabsKey() async {
        do {
            try await KeychainService.shared.save(elevenLabsAPIKey, for: .elevenLabsAPIKey)
            elevenLabsStatus = .success("Saved")
            clearStatus(for: .elevenLabs)
        } catch {
            elevenLabsStatus = .error("Failed to save: \(error.localizedDescription)")
        }
    }

    private func verifyElevenLabsKey() async {
        isVerifyingElevenLabs = true
        defer { isVerifyingElevenLabs = false }

        do {
            try await ElevenLabsTranscriptionService.validateAPIKey(elevenLabsAPIKey)
            elevenLabsStatus = .success("API key is valid")
            clearStatus(for: .elevenLabs)
        } catch {
            elevenLabsStatus = .error("Invalid API key: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private enum StatusType {
        case aws, elevenLabs
    }

    private func clearStatus(for type: StatusType) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                switch type {
                case .aws:
                    awsStatus = nil
                case .elevenLabs:
                    elevenLabsStatus = nil
                }
            }
        }
    }
}

#Preview {
    APIKeysSettingsView()
}
