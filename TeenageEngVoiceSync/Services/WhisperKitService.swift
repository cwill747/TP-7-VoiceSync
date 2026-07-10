//
//  WhisperKitService.swift
//  TeenageEngVoiceSync
//
//  On-device transcription via WhisperKit.
//

import Foundation
@preconcurrency import WhisperKit

struct WhisperKitModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let sizeMB: Int
    let speed: String
    let quality: String

    var detailLabel: String {
        "\(sizeMB) MB · \(speed) · \(quality)"
    }
}

actor WhisperKitService: TranscriptionProvider {
    static let providerName = "WhisperKit"

    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let modelPathKey = "whisperkit.modelPath"
    static let modelPathVariantKey = "whisperkit.modelPathVariant"

    static let availableModels: [WhisperKitModelInfo] = [
        WhisperKitModelInfo(id: "tiny", name: "Tiny", sizeMB: 75, speed: "Fastest", quality: "Basic"),
        WhisperKitModelInfo(id: "base", name: "Base", sizeMB: 150, speed: "Fast", quality: "Good"),
        WhisperKitModelInfo(id: "small", name: "Small", sizeMB: 500, speed: "Medium", quality: "Better"),
        WhisperKitModelInfo(id: "medium", name: "Medium", sizeMB: 1500, speed: "Slow", quality: "Great"),
        WhisperKitModelInfo(id: "distil-large-v3", name: "Distil Large v3", sizeMB: 1500, speed: "Fast", quality: "Excellent"),
        WhisperKitModelInfo(id: "large-v3", name: "Large v3", sizeMB: 3000, speed: "Slow", quality: "Best")
    ]

    enum WhisperKitServiceError: LocalizedError {
        case emptyResult
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .emptyResult:
                return "WhisperKit returned no transcription results"
            case .invalidURL:
                return "Invalid audio URL"
            }
        }
    }

    private let modelID: String
    private var pipe: WhisperKit?

    init(modelID: String) {
        self.modelID = modelID
    }

    static func cachedModelPath(for variant: String) -> String? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: modelPathVariantKey) == variant,
              let path = defaults.string(forKey: modelPathKey),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    static func storeDownloadedModel(path: URL, variant: String) {
        let defaults = UserDefaults.standard
        defaults.set(path.path, forKey: modelPathKey)
        defaults.set(variant, forKey: modelPathVariantKey)
    }

    static func downloadModel(
        variant: String,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: variant,
            from: modelRepo,
            progressCallback: progress
        )
    }

    func transcribe(localPath: String) async throws -> TranscriptionResult {
        beginWork()
        defer { armIdleUnload() }
        let pipe = try await loadPipe()
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            wordTimestamps: true
        )

        let results = try await pipe.transcribe(audioPath: localPath, decodeOptions: options)
        guard let result = results.first else {
            throw WhisperKitServiceError.emptyResult
        }

        let words = result.allWords.map { word in
            TranscriptionWord(
                text: word.word,
                start: Double(word.start),
                end: Double(word.end),
                type: nil,
                logprob: Double(word.probability)
            )
        }

        return TranscriptionResult(
            text: result.text,
            languageCode: result.language,
            languageProbability: nil,
            transcriptionId: nil,
            words: words.isEmpty ? nil : words
        )
    }

    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult {
        guard let url = URL(string: cloudStorageURL) else {
            throw WhisperKitServiceError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "audio" : url.pathExtension)
        try data.write(to: tempURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try await transcribe(localPath: tempURL.path)
    }

    private func loadPipe() async throws -> WhisperKit {
        if let pipe {
            return pipe
        }

        let config: WhisperKitConfig
        if let cachedPath = Self.cachedModelPath(for: modelID) {
            config = WhisperKitConfig(modelFolder: cachedPath, load: true, download: false)
        } else {
            config = WhisperKitConfig(model: modelID, load: true, download: true)
        }

        let pipe = try await WhisperKit(config)
        if let modelFolder = pipe.modelFolder {
            Self.storeDownloadedModel(path: modelFolder, variant: modelID)
        }
        self.pipe = pipe
        return pipe
    }

    // MARK: - Idle model unloading

    /// See `ParakeetService.modelIdleTimeout`. WhisperKit models are the largest
    /// (tiny 75 MB … large-v3 3 GB); releasing them after a quiet period is the
    /// single biggest memory saving for a background app that transcribes in
    /// short bursts. The next transcription lazily reloads via `loadPipe()`.
    private static let modelIdleTimeout: Duration = .seconds(180)
    private var idleUnloadTask: Task<Void, Never>?

    private func beginWork() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func armIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.modelIdleTimeout)
            guard !Task.isCancelled else { return }
            await self?.unloadModels()
        }
    }

    func unloadModels() async {
        guard let pipe else { return }
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        await pipe.unloadModels()
        self.pipe = nil
    }
}
