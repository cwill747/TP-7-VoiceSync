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
import os

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

    static let diarizationEnabledKey = "parakeet.diarizationEnabled"

    /// Fixed speaker-database ID used for the user's own enrolled voice, so
    /// `formatDiarizedTranscript` can recognize it and label it by name
    /// instead of "Speaker N".
    private static let enrolledSpeakerId = "enrolled_user"

    /// The user's own voice profile, enrolled from a sample recording so
    /// diarization can label their segments by name. Persisted as JSON
    /// (a 256-float embedding, ~1KB) alongside the other Parakeet settings.
    struct EnrolledSpeakerProfile: Codable {
        var name: String
        var embedding: [Float]

        private static let storageKey = "parakeet.enrolledSpeaker"

        static func loadStored() -> EnrolledSpeakerProfile? {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(EnrolledSpeakerProfile.self, from: data) else {
                return nil
            }
            return decoded
        }

        func store() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }

        static func clearStored() {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Enrolls the user's voice from a sample recording so future diarization
    /// runs label their segments as `name` instead of "Speaker N".
    ///
    /// `localPath` should ideally be a recording where the user is the only
    /// speaker — this extracts a single embedding assuming the whole clip is
    /// one voice, matching FluidAudio's documented enrollment workflow.
    static func enrollSpeaker(from localPath: String, name: String) async throws {
        let url = URL(fileURLWithPath: localPath)
        let samples = try AudioConverter().resampleAudioFile(url)

        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager(config: .default)
        diarizer.initialize(models: models)

        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        EnrolledSpeakerProfile(name: name, embedding: embedding).store()
    }

    static func clearEnrolledSpeaker() {
        EnrolledSpeakerProfile.clearStored()
    }

    private let variant: ParakeetModelVariant
    private let diarizationEnabled: Bool
    private var manager: AsrManager?
    private var diarizer: DiarizerManager?

    init(modelVersion: String = ParakeetModelVariant.v2.rawValue, diarizationEnabled: Bool = false) {
        self.variant = ParakeetModelVariant(rawValue: modelVersion) ?? .v2
        self.diarizationEnabled = diarizationEnabled
    }

    /// Whether the CoreML models for this variant are already cached on disk.
    static func cachedModelExists(for variant: ParakeetModelVariant) -> Bool {
        let directory = AsrModels.defaultCacheDirectory(for: variant.asrVersion)
        return AsrModels.modelsExist(at: directory, version: variant.asrVersion)
    }

    /// Whether the speaker diarization models (segmentation + embedding) are already cached on disk.
    ///
    /// Walks the diarizer's model directory rather than reconstructing FluidAudio's internal
    /// repo-path layout, so this stays correct if that layout changes.
    static func diarizerModelExists() -> Bool {
        let root = DiarizerModels.defaultModelsDirectory()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        var foundSegmentation = false
        var foundEmbedding = false
        for case let fileURL as URL in enumerator {
            switch fileURL.lastPathComponent {
            case ModelNames.Diarizer.segmentationFile: foundSegmentation = true
            case ModelNames.Diarizer.embeddingFile: foundEmbedding = true
            default: break
            }
            if foundSegmentation && foundEmbedding { return true }
        }
        return false
    }

    /// Maps a FluidAudio download phase to the label shown in the settings UI.
    /// Shared by `downloadDiarizerModel` and `downloadModel` since both report
    /// progress through the same `DownloadUtils.DownloadPhase` type.
    private static func phaseDescription(for phase: DownloadUtils.DownloadPhase) -> String {
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

    /// Downloads (but does not load) the speaker diarization models, reporting progress.
    static func downloadDiarizerModel(
        progressHandler: @escaping @Sendable (DownloadStatus) -> Void
    ) async throws {
        _ = try await DiarizerModels.download { progress in
            progressHandler(DownloadStatus(
                fractionCompleted: progress.fractionCompleted,
                phaseDescription: phaseDescription(for: progress.phase)
            ))
        }
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
            progressHandler(DownloadStatus(
                fractionCompleted: progress.fractionCompleted,
                phaseDescription: phaseDescription(for: progress.phase)
            ))
        }
    }

    // MARK: - TranscriptionProvider

    func transcribe(localPath: String) async throws -> TranscriptionResult {
        let manager = try await loadManager()

        let url = URL(fileURLWithPath: localPath)
        var decoderState = TdtDecoderState.make()
        // v2 is English-only regardless, so this hint only actually affects v3's
        // joint decoder. Only apply it there when the caller wants v2 anyway —
        // hinting v3 (the multilingual model) toward English would bias it away
        // from the non-English languages it exists to support.
        let language: Language? = variant == .v2 ? .english : nil

        let result: ASRResult
        var decodedSamples: [Float]?
        if diarizationEnabled {
            // Diarization needs the fully-decoded samples anyway, so decode once
            // here and feed the same buffer to both ASR and the diarizer instead
            // of letting FluidAudio decode the file again internally.
            let samples = try AudioConverter().resampleAudioFile(url)
            decodedSamples = samples
            result = try await manager.transcribe(samples, decoderState: &decoderState, language: language)
        } else {
            // Transcribe straight from the file URL. FluidAudio runs the source
            // through AudioConverter internally (handling the TP-7's 24-bit WAV,
            // resampling to the 16 kHz mono Float32 tensors Parakeet expects, and
            // disk-backing very large files), which the docs recommend over
            // decoding samples by hand.
            result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ParakeetServiceError.emptyResult
        }

        var finalText = text
        if diarizationEnabled, let decodedSamples {
            do {
                if let diarized = try await diarizedText(samples: decodedSamples, tokenTimings: result.tokenTimings) {
                    finalText = diarized
                }
            } catch {
                AppLogger.app.error("Diarization failed, falling back to flat transcript: \(String(describing: error), privacy: .public)")
            }
        }

        return TranscriptionResult(
            text: finalText,
            // Parakeet v3 is multilingual but does not surface a reliable
            // per-utterance language code; keep it neutral. Swap for the
            // detected language if a future FluidAudio release exposes it.
            languageCode: variant == .v2 ? "en" : "auto",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil
        )
    }

    /// Word span aggregated from sub-word `TokenTiming`s. FluidAudio 0.15.4 (the
    /// pinned version here) exposes the boundary-detection primitives
    /// (`isWordBoundary`/`stripWordBoundaryPrefix`) publicly but not its internal
    /// `buildWordTimings` aggregator, so this reimplements just the aggregation
    /// step on top of those public helpers.
    private struct WordSpan {
        let word: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    private static func buildWordSpans(from tokenTimings: [TokenTiming]) -> [WordSpan] {
        var spans: [WordSpan] = []
        var currentWord = ""
        var wordStart: TimeInterval = 0
        var wordEnd: TimeInterval = 0
        var hasPendingWord = false

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            spans.append(WordSpan(word: trimmed, startTime: wordStart, endTime: wordEnd))
        }

        for timing in tokenTimings {
            let token = timing.token
            guard !token.isEmpty, token != "<blank>", token != "<pad>" else { continue }

            let boundary = isWordBoundary(token)
            if boundary && hasPendingWord {
                flush()
                currentWord = ""
            }
            // Only anchor the start time on the token that begins a new word.
            // If a boundary-only token strips to empty text (e.g. a bare "▁"),
            // this keeps its timestamp as the word's start without treating the
            // following continuation token as the start of yet another word.
            if !hasPendingWord || boundary {
                wordStart = timing.startTime
                hasPendingWord = true
            }
            currentWord += stripWordBoundaryPrefix(token)
            wordEnd = timing.endTime
        }
        flush()
        return spans
    }

    /// Runs speaker diarization on pre-decoded `samples` and merges it with the ASR
    /// word timings, producing a "Speaker N: ..." labeled transcript. Falls back to
    /// nil (flat text) if there are no token timings or diarization finds no segments.
    private func diarizedText(samples: [Float], tokenTimings: [TokenTiming]?) async throws -> String? {
        guard let tokenTimings, !tokenTimings.isEmpty else { return nil }

        let diarizer = try await loadDiarizer()
        let diarizationResult = try diarizer.performCompleteDiarization(samples)

        let words = Self.buildWordSpans(from: tokenTimings)
        return Self.formatDiarizedTranscript(words: words, segments: diarizationResult.segments)
    }

    /// Groups ASR words into "Speaker N: ..." paragraphs using diarization segments,
    /// assigning each word to whichever segment contains its time midpoint (falling
    /// back to the nearest segment boundary). Speaker numbers are assigned in the
    /// order they first speak.
    ///
    /// `words` and `segments` are both processed in time order, so segment lookup
    /// advances a single pointer forward instead of rescanning all segments per word.
    private static func formatDiarizedTranscript(words: [WordSpan], segments: [TimedSpeakerSegment]) -> String? {
        guard !words.isEmpty, !segments.isEmpty else { return nil }

        let sortedSegments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var segmentIndex = 0

        func speakerId(atMidpoint midpoint: Double) -> String {
            while segmentIndex + 1 < sortedSegments.count,
                  Double(sortedSegments[segmentIndex + 1].startTimeSeconds) <= midpoint {
                segmentIndex += 1
            }
            let current = sortedSegments[segmentIndex]
            if midpoint < Double(current.startTimeSeconds) {
                // Before the first segment starts; nothing earlier to compare against.
                return current.speakerId
            }
            if midpoint <= Double(current.endTimeSeconds) {
                return current.speakerId
            }
            // In the gap after `current` (the while loop above already ruled out
            // any later segment starting at or before `midpoint`): pick whichever
            // segment boundary is closer.
            guard segmentIndex + 1 < sortedSegments.count else { return current.speakerId }
            let next = sortedSegments[segmentIndex + 1]
            let distanceToCurrent = midpoint - Double(current.endTimeSeconds)
            let distanceToNext = Double(next.startTimeSeconds) - midpoint
            return distanceToNext < distanceToCurrent ? next.speakerId : current.speakerId
        }

        let enrolledName = EnrolledSpeakerProfile.loadStored()?.name

        var speakerLabels: [String: String] = [:]
        var anonymousSpeakerCount = 0
        var paragraphs: [String] = []
        var currentSpeakerId: String?
        var currentWords: [String] = []

        func flush() {
            guard let speakerId = currentSpeakerId, !currentWords.isEmpty else { return }
            let label = speakerLabels[speakerId] ?? {
                let name: String
                if speakerId == enrolledSpeakerId, let enrolledName {
                    name = enrolledName
                } else {
                    anonymousSpeakerCount += 1
                    name = "Speaker \(anonymousSpeakerCount)"
                }
                speakerLabels[speakerId] = name
                return name
            }()
            paragraphs.append("\(label): \(currentWords.joined(separator: " "))")
        }

        for word in words {
            let midpoint = (word.startTime + word.endTime) / 2
            let resolvedSpeakerId = speakerId(atMidpoint: midpoint)

            if resolvedSpeakerId != currentSpeakerId {
                flush()
                currentWords = []
                currentSpeakerId = resolvedSpeakerId
            }
            currentWords.append(word.word)
        }
        flush()

        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
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

    private func loadDiarizer() async throws -> DiarizerManager {
        if let diarizer { return diarizer }

        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager(config: .default)
        diarizer.initialize(models: models)

        if let profile = EnrolledSpeakerProfile.loadStored() {
            let knownSpeaker = Speaker(
                id: Self.enrolledSpeakerId,
                name: profile.name,
                currentEmbedding: profile.embedding,
                isPermanent: true
            )
            diarizer.initializeKnownSpeakers([knownSpeaker])
        }

        self.diarizer = diarizer
        return diarizer
    }
}
