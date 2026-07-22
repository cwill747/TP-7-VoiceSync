//
//  OnboardingTranscriptionView.swift
//  TeenageEngVoiceSync
//
//  Transcription provider setup for onboarding.
//

import SwiftUI

struct OnboardingTranscriptionView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var isConfigured: Bool

    @State private var showKey = false
    @State private var isVerifying = false
    @State private var verificationStatus: VerificationStatus?

    @State private var whisperKitDownloadState: WhisperKitDownloadState = .notDownloaded
    @State private var whisperKitDownloadProgress = 0.0
    @State private var whisperKitDownloadError: String?

    @State private var parakeetUnifiedDownloadState: WhisperKitDownloadState = .notDownloaded
    @State private var parakeetUnifiedDownloadProgress = 0.0
    @State private var parakeetUnifiedDownloadError: String?

    enum VerificationStatus {
        case success(String)
        case error(String)
    }

    enum WhisperKitDownloadState {
        case notDownloaded
        case downloading
        case ready
    }

    private var transcriptionProviderBinding: Binding<TranscriptionProviderKind> {
        Binding(
            get: { draft.transcriptionProvider },
            set: { newValue in
                draft.transcriptionProvider = newValue
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
                        .accessibilityHidden(true)

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

                if draft.transcriptionProvider == .elevenLabs {
                    elevenLabsSection
                }

                if draft.transcriptionProvider == .whisperKit {
                    whisperKitSection
                }

                if draft.transcriptionProvider == .parakeetUnified {
                    parakeetUnifiedSection
                }

                if isConfigured {
                    Toggle("Enable automatic transcription", isOn: $draft.transcriptionEnabled)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            refreshWhisperKitStatus()
            refreshParakeetUnifiedStatus()
            updateConfiguredState()
        }
    }

    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ElevenLabs API Key")
                .font(.headline)

            HStack {
                if showKey {
                    TextField("Enter your ElevenLabs API key", text: $draft.elevenLabsAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Enter your ElevenLabs API key", text: $draft.elevenLabsAPIKey)
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

            Link("Get an API key from ElevenLabs", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                .font(.caption)

            HStack {
                Button("Verify & Save") {
                    Task { await verifyAndSave() }
                }
                .buttonStyle(.bordered)
                .disabled(draft.elevenLabsAPIKey.isEmpty || isVerifying)

                if isVerifying {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if let status = verificationStatus {
                statusLabel(for: status)
            }

            Text("Your API key is saved securely to your Mac's Keychain when you finish setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var whisperKitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhisperKit Model")
                .font(.headline)

            Picker("Model", selection: $draft.whisperKitModel) {
                ForEach(WhisperKitService.availableModels) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .onChange(of: draft.whisperKitModel) { _, _ in
                refreshWhisperKitStatus()
                updateConfiguredState()
            }

            if let model = WhisperKitService.availableModels.first(where: { $0.id == draft.whisperKitModel }) {
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

            if draft.s3Enabled {
                Toggle("Backup audio to S3", isOn: $draft.backupAfterTranscription)
            }

            Text("Runs locally using WhisperKit. Download a model for offline use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var parakeetUnifiedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parakeet Unified Model")
                .font(.headline)

            HStack {
                Button("Download Model") {
                    downloadParakeetUnifiedModel()
                }
                .disabled(parakeetUnifiedDownloadState == .downloading)

                if parakeetUnifiedDownloadState == .downloading {
                    ProgressView(value: parakeetUnifiedDownloadProgress)
                        .frame(width: 120)
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
                    Label("Downloading model...", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                case .ready:
                    Label("Model downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            if draft.s3Enabled {
                Toggle("Backup audio to S3", isOn: $draft.backupAfterTranscription)
            }

            Text("Runs locally on the Apple Neural Engine with native punctuation and capitalization (English only). First transcription downloads the model if you skip this.")
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

    private func verifyAndSave() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            // Validate against the live API, but stage the key in the draft; it is
            // written to the Keychain only when onboarding completes.
            try await ElevenLabsTranscriptionService.validateAPIKey(draft.elevenLabsAPIKey)
            verificationStatus = .success("API key verified!")
            isConfigured = true
            draft.transcriptionEnabled = true

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
        if WhisperKitService.cachedModelPath(for: draft.whisperKitModel) != nil {
            whisperKitDownloadState = .ready
        } else {
            whisperKitDownloadState = .notDownloaded
        }
    }

    private func updateConfiguredState() {
        switch draft.transcriptionProvider {
        case .elevenLabs:
            isConfigured = !draft.elevenLabsAPIKey.isEmpty
        case .whisperKit:
            isConfigured = whisperKitDownloadState == .ready
        case .parakeet:
            isConfigured = true
        case .parakeetUnified:
            isConfigured = true
        }
    }

    private func downloadWhisperKitModel() {
        whisperKitDownloadError = nil
        whisperKitDownloadProgress = 0
        whisperKitDownloadState = .downloading

        Task {
            do {
                let modelURL = try await WhisperKitService.downloadModel(variant: draft.whisperKitModel) { progress in
                    Task { @MainActor in
                        whisperKitDownloadProgress = progress.fractionCompleted
                    }
                }
                WhisperKitService.storeDownloadedModel(path: modelURL, variant: draft.whisperKitModel)
                await MainActor.run {
                    whisperKitDownloadState = .ready
                    isConfigured = true
                    draft.transcriptionEnabled = true
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

    private func refreshParakeetUnifiedStatus() {
        parakeetUnifiedDownloadError = nil
        parakeetUnifiedDownloadState = ParakeetUnifiedService.cachedModelExists() ? .ready : .notDownloaded
    }

    private func downloadParakeetUnifiedModel() {
        parakeetUnifiedDownloadError = nil
        parakeetUnifiedDownloadProgress = 0
        parakeetUnifiedDownloadState = .downloading

        Task {
            do {
                try await ParakeetUnifiedService.downloadModel { status in
                    Task { @MainActor in
                        parakeetUnifiedDownloadProgress = status.fractionCompleted
                    }
                }
                await MainActor.run {
                    parakeetUnifiedDownloadState = .ready
                    isConfigured = true
                    draft.transcriptionEnabled = true
                }
            } catch {
                await MainActor.run {
                    parakeetUnifiedDownloadState = .notDownloaded
                    parakeetUnifiedDownloadError = error.localizedDescription
                    isConfigured = false
                }
            }
        }
    }
}

#Preview {
    OnboardingTranscriptionView(draft: OnboardingDraft(), isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
