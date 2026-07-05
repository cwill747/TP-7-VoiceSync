//
//  ParakeetService.swift
//  TeenageEngVoiceSync
//
//  On-device transcription via FluidAudio (Parakeet TDT, CoreML / Apple Neural Engine).
//
//  Drop-in replacement for WhisperKitService that conforms to the existing
//  `TranscriptionProvider` protocol. Requires the FluidAudio Swift package:
//      https://github.com/FluidInference/FluidAudio  (>= 0.12.4)
//
//  Models auto-download from Hugging Face on first use and are cached locally
//  under ~/.cache/fluidaudio, so no API key or network is needed after that.
//

import Foundation
import FluidAudio

/// Parakeet model variants exposed by FluidAudio.
/// v3 = multilingual (25 European langs + JA/ZH). v2 = English-only, highest recall.
enum ParakeetModelVariant: String, CaseIterable, Identifiable {
    case v3
    case v2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v3: return "Parakeet TDT v3 (multilingual)"
        case .v2: return "Parakeet TDT v2 (English, highest recall)"
        }
    }

    /// Maps to FluidAudio's `AsrModelVersion`.
    var asrVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .v2: return .v2
        }
    }
}

actor ParakeetService: TranscriptionProvider {
    static let providerName = "Parakeet"

    static let modelKey = "parakeet.model"

    enum ParakeetServiceError: LocalizedError {
        case invalidURL
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid audio URL"
            case .emptyResult: return "Parakeet returned no transcription"
            }
        }
    }

    private let variant: ParakeetModelVariant
    private var manager: AsrManager?

    init(modelVersion: String = ParakeetModelVariant.v3.rawValue) {
        self.variant = ParakeetModelVariant(rawValue: modelVersion) ?? .v3
    }

    /// Whether the CoreML models for this variant are already cached on disk.
    static func cachedModelExists(for variant: ParakeetModelVariant) -> Bool {
        let directory = AsrModels.defaultCacheDirectory(for: variant.asrVersion)
        return AsrModels.modelsExist(at: directory, version: variant.asrVersion)
    }

    /// Snapshot of an in-progress model download, for UI display.
    struct DownloadStatus: Sendable {
        let fractionCompleted: Double
        let phaseDescription: String
    }

    /// Downloads (but does not load) the CoreML models for this variant, reporting progress.
    ///
    /// Cancellable: cancelling the enclosing `Task` propagates into FluidAudio's
    /// `URLSession`-based transfers (Swift's async URLSession APIs observe task
    /// cancellation and abort the in-flight request), surfacing as `CancellationError`.
    static func downloadModel(
        variant: ParakeetModelVariant,
        progressHandler: @escaping @Sendable (DownloadStatus) -> Void
    ) async throws {
        _ = try await AsrModels.download(version: variant.asrVersion) { progress in
            let phaseDescription: String
            switch progress.phase {
            case .listing:
                phaseDescription = "Listing files…"
            case .downloading(let completed, let total) where total > 0:
                phaseDescription = "Downloading files… (\(completed)/\(total))"
            case .downloading:
                phaseDescription = "Downloading…"
            case .compiling:
                phaseDescription = "Compiling model…"
            }
            progressHandler(DownloadStatus(fractionCompleted: progress.fractionCompleted, phaseDescription: phaseDescription))
        }
    }

    // MARK: - TranscriptionProvider

    func transcribe(localPath: String) async throws -> TranscriptionResult {
        let manager = try await loadManager()

        // Transcribe straight from the file URL. FluidAudio runs the source
        // through AudioConverter internally (handling the TP-7's 24-bit WAV,
        // resampling to the 16 kHz mono Float32 tensors Parakeet expects), which
        // the docs recommend over decoding samples by hand.
        let url = URL(fileURLWithPath: localPath)
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(url, decoderState: &decoderState)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ParakeetServiceError.emptyResult
        }

        return TranscriptionResult(
            text: text,
            // Parakeet v3 is multilingual but does not surface a reliable
            // per-utterance language code; keep it neutral. Swap for the
            // detected language if a future FluidAudio release exposes it.
            languageCode: variant == .v2 ? "en" : "auto",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil
        )
    }

    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult {
        guard let url = URL(string: cloudStorageURL) else {
            throw ParakeetServiceError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "wav" : url.pathExtension)
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        return try await transcribe(localPath: tempURL.path)
    }

    // MARK: - Model loading (once per actor instance)

    private func loadManager() async throws -> AsrManager {
        if let manager { return manager }

        let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }
}
