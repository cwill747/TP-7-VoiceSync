//
//  ParakeetUnifiedService.swift
//  TeenageEngVoiceSync
//
//  On-device transcription via FluidAudio's Parakeet Unified model
//  (English, offline batch, CoreML / Apple Neural Engine).
//
//  Unlike `ParakeetService` (Parakeet TDT v2/v3), the Unified model emits
//  punctuation and capitalization natively, so recordings come out already
//  formatted without the LLM cleanup pass. The trade-offs: English only, and
//  the batch API returns plain text with no token timings — so this engine
//  cannot drive speaker diarization, multi-track per-speaker splitting, overdub
//  notes, or vocabulary boosting. Those stay on `ParakeetService`.
//
//  Because `SyncService.transcribeLocal` only special-cases `ParakeetService`,
//  selecting this provider automatically routes every recording through the
//  plain single-shot `transcribe(localPath:)` path below.
//

import Foundation
import FluidAudio
import os

actor ParakeetUnifiedService: TranscriptionProvider {
    static let providerName = "Parakeet Unified"

    enum ParakeetUnifiedServiceError: LocalizedError {
        case invalidURL
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid audio URL"
            case .emptyResult: return "Parakeet Unified returned no transcription"
            }
        }
    }

    private var manager: UnifiedAsrManager?

    init() {}

    // MARK: - Model download / cache

    /// Snapshot of an in-progress model download, for UI display.
    /// Mirrors `ParakeetService.DownloadStatus`.
    struct DownloadStatus: Sendable {
        let fractionCompleted: Double
        let phaseDescription: String
    }

    /// Whether the Parakeet Unified CoreML models are already cached on disk.
    /// Reconstructs the same cache location `UnifiedAsrManager.loadModels(to:)`
    /// uses and checks for the offline encoder bundle.
    static func cachedModelExists() -> Bool {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let encoder = base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8))
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    /// Downloads (and loads, then discards) the Parakeet Unified models, reporting progress.
    static func downloadModel(
        progressHandler: @escaping @Sendable (DownloadStatus) -> Void
    ) async throws {
        let manager = UnifiedAsrManager()
        try await manager.loadModels { progress in
            progressHandler(DownloadStatus(
                fractionCompleted: progress.fractionCompleted,
                phaseDescription: phaseDescription(for: progress.phase)
            ))
        }
        await manager.cleanup()
    }

    /// Maps a FluidAudio download phase to the label shown in the settings UI.
    private static func phaseDescription(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Listing files…"
        case .downloading(let completed, let total) where total > 0:
            return "Downloading files… (\(completed)/\(total))"
        case .downloading:
            return "Downloading…"
        case .compiling:
            return "Compiling model…"
        }
    }

    // MARK: - TranscriptionProvider

    func transcribe(localPath: String) async throws -> TranscriptionResult {
        let url = URL(fileURLWithPath: localPath)
        let samples = try AudioConverter().resampleAudioFile(url)

        let manager = try await loadManager()
        let rawText = try await manager.transcribe(samples)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ParakeetUnifiedServiceError.emptyResult
        }

        // Vocabulary *boosting* isn't available on this engine (no CTC/TDT
        // rescoring path), but dictionary trigger→replacement is a plain text
        // substitution that still applies.
        let finalText = await VocabularyStore.shared.applyDictionary(to: text)

        return TranscriptionResult(
            text: finalText,
            languageCode: "en",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil,
            speakerSegments: nil
        )
    }

    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult {
        guard let url = URL(string: cloudStorageURL) else {
            throw ParakeetUnifiedServiceError.invalidURL
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

    private func loadManager() async throws -> UnifiedAsrManager {
        if let manager { return manager }
        let manager = UnifiedAsrManager()
        try await manager.loadModels()
        self.manager = manager
        return manager
    }
}
