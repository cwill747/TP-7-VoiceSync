//
//  OnboardingTranscriptionView.swift
//  TeenageEngVoiceSync
//
//  Transcription provider setup for onboarding.
//

import SwiftUI

struct OnboardingTranscriptionView: View {
    @Binding var isConfigured: Bool

    @AppStorage("transcription.provider") private var transcriptionProviderRaw = TranscriptionProviderKind.elevenLabs.rawValue
    @AppStorage("transcription.enabled") private var transcriptionEnabled = false
    @AppStorage("whisperkit.model") private var whisperKitModel = "base"
    @AppStorage("s3.backupAfterTranscription") private var whisperKitBackupToS3 = true
    @AppStorage("s3.enabled") private var s3Enabled = false

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isVerifying = false
    @State private var verificationStatus: VerificationStatus?
    @State private var isLoading = true

    @State private var whisperKitDownloadState: WhisperKitDownloadState = .notDownloaded
    @State private var whisperKitDownloadProgress = 0.0
    @State private var whisperKitDownloadError: String?

    enum VerificationStatus {
        case success(String)
        case error(String)
    }

    enum WhisperKitDownloadState {
        case notDownloaded
        case downloading
        case ready
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
                updateConfiguredState()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)

                    Text("Transcription Setup")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Choose a transcription provider for your recordings. You can change this later in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Provider selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provider")
                        .font(.headline)

                    Picker("Provider", selection: transcriptionProviderBinding) {
                        ForEach(TranscriptionProviderKind.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if transcriptionProvider == .elevenLabs {
                    elevenLabsSection
                }

                if transcriptionProvider == .whisperKit {
                    whisperKitSection
                }

                if isConfigured {
                    Toggle("Enable automatic transcription", isOn: $transcriptionEnabled)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            ensureDefaults()
            await loadExistingKey()
            refreshWhisperKitStatus()
            updateConfiguredState()
        }
    }

    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ElevenLabs API Key")
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

            Text("Your API key is stored securely in your Mac's Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var whisperKitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhisperKit Model")
                .font(.headline)

            Picker("Model", selection: $whisperKitModel) {
                ForEach(WhisperKitService.availableModels) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .onChange(of: whisperKitModel) { _, _ in
                refreshWhisperKitStatus()
                updateConfiguredState()
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
            }

            Text("Runs locally using WhisperKit. Download a model for offline use.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func ensureDefaults() {
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

    private func loadExistingKey() async {
        isLoading = true
        defer { isLoading = false }

        do {
            if let existingKey = try await KeychainService.shared.retrieve(for: .elevenLabsAPIKey),
               !existingKey.isEmpty {
                apiKey = existingKey
            }
        } catch {
            // Key not found, that's fine
        }
    }

    private func verifyAndSave() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            try await ElevenLabsTranscriptionService.validateAPIKey(apiKey)
            try await KeychainService.shared.save(apiKey, for: .elevenLabsAPIKey)
            verificationStatus = .success("API key verified and saved!")
            isConfigured = true
            transcriptionEnabled = true

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

    private func refreshWhisperKitStatus() {
        whisperKitDownloadError = nil
        if WhisperKitService.cachedModelPath(for: whisperKitModel) != nil {
            whisperKitDownloadState = .ready
        } else {
            whisperKitDownloadState = .notDownloaded
        }
    }

    private func updateConfiguredState() {
        switch transcriptionProvider {
        case .elevenLabs:
            isConfigured = !apiKey.isEmpty
        case .whisperKit:
            isConfigured = whisperKitDownloadState == .ready
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
                    isConfigured = true
                    transcriptionEnabled = true
                }
            } catch {
                await MainActor.run {
                    whisperKitDownloadState = .notDownloaded
                    whisperKitDownloadError = error.localizedDescription
                    isConfigured = false
                }
            }
        }
    }
}

#Preview {
    OnboardingTranscriptionView(isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
