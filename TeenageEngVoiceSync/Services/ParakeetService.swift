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
nonisolated enum ParakeetModelVariant: String, CaseIterable, Identifiable {
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

/// A known speaker's profile, extracted from a `Person` model before crossing actor boundaries.
struct KnownPersonProfile: Sendable {
    let personId: String
    let name: String
    let embedding: [Float]
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

    /// Legacy single-profile storage, kept for one-time migration to the SwiftData Person model.
    struct EnrolledSpeakerProfile: Codable {
        var name: String
        var embedding: [Float]

        static let storageKey = "parakeet.enrolledSpeaker"

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

    /// Extracts a speaker embedding from a local audio file without full diarization.
    /// Used both for initial enrollment and for the People screen's "Add sample" flow.
    static func extractEmbedding(from localPath: String) async throws -> [Float] {
        let url = URL(fileURLWithPath: localPath)
        let samples = try AudioConverter().resampleAudioFile(url)

        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager(config: .default)
        diarizer.initialize(models: models)

        return try diarizer.extractSpeakerEmbedding(from: samples)
    }

    // Retained for legacy single-profile enrollment via Settings (redirects to People flow now).
    static func enrollSpeaker(from localPath: String, name: String) async throws {
        let embedding = try await extractEmbedding(from: localPath)
        EnrolledSpeakerProfile(name: name, embedding: embedding).store()
    }

    static func clearEnrolledSpeaker() {
        EnrolledSpeakerProfile.clearStored()
    }

    private let variant: ParakeetModelVariant
    private let diarizationEnabled: Bool
    private var manager: AsrManager?
    private var diarizer: DiarizerManager?
    /// Populated by SyncService before transcription runs.
    private var knownPersonProfiles: [KnownPersonProfile] = []

    init(
        modelVersion: String = ParakeetModelVariant.v2.rawValue,
        diarizationEnabled: Bool = false,
        knownPersonProfiles: [KnownPersonProfile] = []
    ) {
        self.variant = ParakeetModelVariant(rawValue: modelVersion) ?? .v2
        self.diarizationEnabled = diarizationEnabled
        self.knownPersonProfiles = knownPersonProfiles
    }

    /// Update the known speaker roster. Resets the cached diarizer so the next
    /// transcription picks up the new profiles.
    func updateKnownSpeakers(_ profiles: [KnownPersonProfile]) {
        knownPersonProfiles = profiles
        diarizer = nil  // force re-init with the new roster
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
    /// `URLSession`-based transfers, surfacing as `CancellationError`.
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
        try await transcribe(localPath: localPath, forceSingleSpeaker: false)
    }

    /// - Parameter forceSingleSpeaker: Skips diarization entirely, regardless of
    ///   the diarization setting. Used for TP-7 recordings from the /memo
    ///   folder, which only ever captures the primary user's own voice, so any
    ///   "speaker" diarization might detect there would be a misattribution,
    ///   not a real second speaker. /recordings has no such guarantee.
    func transcribe(localPath: String, forceSingleSpeaker: Bool) async throws -> TranscriptionResult {
        let manager = try await loadManager()
        let runDiarization = diarizationEnabled && !forceSingleSpeaker

        let url = URL(fileURLWithPath: localPath)
        var decoderState = TdtDecoderState.make()
        let language: Language? = variant == .v2 ? .english : nil

        let result: ASRResult
        var decodedSamples: [Float]?
        if runDiarization {
            let samples = try AudioConverter().resampleAudioFile(url)
            decodedSamples = samples
            result = try await manager.transcribe(samples, decoderState: &decoderState, language: language)
        } else {
            result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ParakeetServiceError.emptyResult
        }

        var finalText = text
        var speakerSegments: [StoredSpeakerSegment]?
        if runDiarization, let decodedSamples {
            do {
                let diarized = try await diarizedOutput(
                    samples: decodedSamples,
                    tokenTimings: result.tokenTimings
                )
                if let diarized {
                    finalText = diarized.text
                    speakerSegments = diarized.segments
                }
            } catch {
                AppLogger.app.error("Diarization failed, falling back to flat transcript: \(String(describing: error), privacy: .public)")
            }
        }

        return TranscriptionResult(
            text: finalText,
            languageCode: variant == .v2 ? "en" : "auto",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil,
            speakerSegments: speakerSegments
        )
    }

    /// Transcribes N single-speaker track files split from a TP-7 multi-track
    /// /recordings WAV (see `MultiTrackAudio.extractTracks`).
    ///
    /// The tracks can mean one of two things, distinguished here acoustically:
    /// - Distinct speakers on separate channels (an interview/meeting) — each
    ///   track is a clean isolated source, so speaker separation is exact rather
    ///   than acoustic. Rendered as a diarized transcript: same
    ///   `(text, speakerSegments)` shape the diarizer produces, so Notion/Notes
    ///   rendering and the speaker-editing UI work unchanged.
    /// - The same person overdubbing themselves (the TP-7 files overdubs under
    ///   /recordings, not /memo) — track 0 is the base take and tracks 1+ are
    ///   overdub layers over the same timeline. Rendered as a base transcript +
    ///   `OverdubNote`s, matching the /memo overdub shape, since labelling one
    ///   speaker's own overdub as "Speaker 2" would be a misattribution.
    func transcribeMultiTrack(trackPaths: [String]) async throws -> TranscriptionResult {
        let manager = try await loadManager()
        let language: Language? = variant == .v2 ? .english : nil

        var perTrackText: [String] = []
        var perTrackWords: [[WordSpan]] = []
        var perTrackEmbeddings: [[Float]] = []

        for path in trackPaths {
            var decoderState = TdtDecoderState.make()
            let result = try await manager.transcribe(URL(fileURLWithPath: path), decoderState: &decoderState, language: language)
            perTrackText.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            perTrackWords.append(Self.buildWordSpans(from: result.tokenTimings ?? []))
            perTrackEmbeddings.append((try? await Self.extractEmbedding(from: path)) ?? [])
        }

        // Same person on every track → it's a self-overdub, not a multi-speaker
        // capture. Fall back to the diarized-speakers rendering below whenever
        // that can't be confirmed (missing embeddings, a track that doesn't
        // match), which is the safe default for a genuine multi-speaker file.
        if allTracksSameSpeaker(perTrackEmbeddings) {
            return Self.overdubResult(perTrackText: perTrackText, perTrackWords: perTrackWords, languageCode: variant == .v2 ? "en" : "auto")
        }

        let labels = Self.resolveTrackLabels(embeddings: perTrackEmbeddings, knownPersonProfiles: knownPersonProfiles)

        struct TimedParagraph {
            let startTime: TimeInterval
            let paragraph: String
            let segment: StoredSpeakerSegment
        }

        var timedParagraphs: [TimedParagraph] = []
        for (index, words) in perTrackWords.enumerated() {
            let turns = Self.buildTurns(from: words)
            guard !turns.isEmpty else { continue }

            let (label, personId) = labels[index]
            // `rawSpeakerId` doubles as the display fallback when nothing is
            // assigned (see `DiarizedTranscriptView`'s `assignedPersonName ??
            // rawSpeakerId`) — use the generated label itself rather than the
            // internal "track-N" index so an anonymous "Speaker N" survives
            // into the speaker-editing UI and re-persisted transcript instead
            // of regressing to a raw track identifier.
            let rawSpeakerId = label
            let embedding = perTrackEmbeddings[index]

            for turn in turns {
                let segment = StoredSpeakerSegment(
                    startTime: turn.startTime,
                    endTime: turn.endTime,
                    rawSpeakerId: rawSpeakerId,
                    text: turn.text,
                    embedding: embedding,
                    assignedPersonName: label.hasPrefix("Speaker ") ? nil : label,
                    assignedPersonId: personId
                )
                timedParagraphs.append(TimedParagraph(
                    startTime: turn.startTime,
                    paragraph: "\(label): \(turn.text)",
                    segment: segment
                ))
            }
        }

        guard !timedParagraphs.isEmpty else {
            throw ParakeetServiceError.emptyResult
        }

        // Interleave every track's turns by absolute start time so the
        // rendered transcript reads as a single back-and-forth conversation.
        timedParagraphs.sort { $0.startTime < $1.startTime }

        return TranscriptionResult(
            text: timedParagraphs.map(\.paragraph).joined(separator: "\n\n"),
            languageCode: variant == .v2 ? "en" : "auto",
            languageProbability: nil,
            transcriptionId: nil,
            words: nil,
            speakerSegments: timedParagraphs.map(\.segment)
        )
    }

    /// Cosine-similarity floor for treating two tracks as the same voice. A
    /// self-overdub is the same person recorded on the same mic seconds apart,
    /// so its cross-track similarity sits well above this; two different people
    /// sit below it. Set conservatively (above the natural gap, below the
    /// known-person match threshold of 0.75) so a genuine multi-speaker capture
    /// is never collapsed into a single speaker's overdub.
    private static let sameSpeakerOverdubThreshold: Float = 0.7

    /// True when every track's embedding matches track 0's above
    /// `sameSpeakerOverdubThreshold` — i.e. one person overdubbing themselves.
    /// Requires 2+ tracks and a usable embedding for each; any empty embedding
    /// (extraction failed) or below-threshold track returns false so we fall
    /// back to the safe multi-speaker rendering.
    private func allTracksSameSpeaker(_ embeddings: [[Float]]) -> Bool {
        guard embeddings.count > 1, let base = embeddings.first, !base.isEmpty else { return false }
        for embedding in embeddings.dropFirst() {
            guard !embedding.isEmpty,
                  cosineSimilarity(base, embedding) >= Self.sameSpeakerOverdubThreshold else { return false }
        }
        return true
    }

    /// Builds a base-transcript + overdub-notes result from already-transcribed
    /// tracks: track 0 is the base take, tracks 1+ become `OverdubNote`s placed
    /// on the shared timeline by their first word's start time. Mirrors the
    /// /memo overdub rendering so the two paths produce identical output.
    private static func overdubResult(perTrackText: [String], perTrackWords: [[WordSpan]], languageCode: String) -> TranscriptionResult {
        var notes: [OverdubNote] = []
        for index in perTrackText.indices where index > 0 {
            let text = perTrackText[index]
            guard !text.isEmpty else { continue }
            let startTime = perTrackWords[index].first?.startTime ?? 0
            notes.append(OverdubNote(trackIndex: index, startTime: startTime, text: text))
        }
        var result = TranscriptionResult(
            text: perTrackText.first ?? "",
            languageCode: languageCode,
            languageProbability: nil,
            transcriptionId: nil,
            words: nil,
            speakerSegments: nil
        )
        result.overdubNotes = notes.isEmpty ? nil : notes
        return result
    }

    /// A labeled speech turn: a run of a track's words uninterrupted by a
    /// pause longer than `turnGapThreshold`.
    private struct TrackTurn {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Pause length that splits a track's words into separate turns — mirrors
    /// the paragraph breaks a diarizer's segment boundaries would produce.
    private static let turnGapThreshold: TimeInterval = 1.0

    private static func buildTurns(from words: [WordSpan]) -> [TrackTurn] {
        guard let first = words.first else { return [] }

        var turns: [TrackTurn] = []
        var currentWords = [first.word]
        var currentStart = first.startTime
        var currentEnd = first.endTime

        for word in words.dropFirst() {
            if word.startTime - currentEnd > turnGapThreshold {
                turns.append(TrackTurn(text: currentWords.joined(separator: " "), startTime: currentStart, endTime: currentEnd))
                currentWords = []
                currentStart = word.startTime
            }
            currentWords.append(word.word)
            currentEnd = word.endTime
        }
        turns.append(TrackTurn(text: currentWords.joined(separator: " "), startTime: currentStart, endTime: currentEnd))
        return turns
    }

    /// Resolves each track's speaker label the same way `buildDiarizedOutput`
    /// resolves a diarizer segment: cosine match against known persons above
    /// the 0.75 threshold, else an anonymous "Speaker N" (numbered in track order).
    private static func resolveTrackLabels(
        embeddings: [[Float]],
        knownPersonProfiles: [KnownPersonProfile]
    ) -> [(label: String, personId: String?)] {
        var anonymousCount = 0
        return embeddings.map { embedding -> (label: String, personId: String?) in
            if !knownPersonProfiles.isEmpty, !embedding.isEmpty {
                var best: (profile: KnownPersonProfile, similarity: Float)?
                for profile in knownPersonProfiles where profile.embedding.count == embedding.count {
                    let sim = cosineSimilarity(profile.embedding, embedding)
                    if sim > 0.75, best == nil || sim > best!.similarity {
                        best = (profile, sim)
                    }
                }
                if let match = best {
                    return (match.profile.name, match.profile.personId)
                }
            }
            anonymousCount += 1
            return ("Speaker \(anonymousCount)", nil)
        }
    }

    /// Word span aggregated from sub-word `TokenTiming`s. FluidAudio 0.15.4 exposes the
    /// boundary-detection primitives publicly but not its internal `buildWordTimings`
    /// aggregator, so this reimplements just the aggregation step on top of those helpers.
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

    private struct DiarizedOutput {
        let text: String
        let segments: [StoredSpeakerSegment]
    }

    /// Runs speaker diarization and merges it with ASR word timings.
    /// Returns both the labeled transcript text and per-segment data for storage.
    private func diarizedOutput(samples: [Float], tokenTimings: [TokenTiming]?) async throws -> DiarizedOutput? {
        guard let tokenTimings, !tokenTimings.isEmpty else { return nil }

        let diarizer = try await loadDiarizer()
        let diarizationResult = try diarizer.performCompleteDiarization(samples)

        let words = Self.buildWordSpans(from: tokenTimings)
        return Self.buildDiarizedOutput(
            words: words,
            segments: diarizationResult.segments,
            knownPersonProfiles: knownPersonProfiles
        )
    }

    /// Groups ASR words into labeled paragraphs using diarization segments.
    /// Returns both a rendered transcript string and `StoredSpeakerSegment` records
    /// (one per speaker turn) that include embeddings for later correction.
    private static func buildDiarizedOutput(
        words: [WordSpan],
        segments: [TimedSpeakerSegment],
        knownPersonProfiles: [KnownPersonProfile]
    ) -> DiarizedOutput? {
        guard !words.isEmpty, !segments.isEmpty else { return nil }

        let sortedSegments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var segmentIndex = 0

        func segmentAtMidpoint(_ midpoint: Double) -> TimedSpeakerSegment {
            while segmentIndex + 1 < sortedSegments.count,
                  Double(sortedSegments[segmentIndex + 1].startTimeSeconds) <= midpoint {
                segmentIndex += 1
            }
            let current = sortedSegments[segmentIndex]
            if midpoint < Double(current.startTimeSeconds) { return current }
            if midpoint <= Double(current.endTimeSeconds) { return current }
            guard segmentIndex + 1 < sortedSegments.count else { return current }
            let next = sortedSegments[segmentIndex + 1]
            let distanceToCurrent = midpoint - Double(current.endTimeSeconds)
            let distanceToNext = Double(next.startTimeSeconds) - midpoint
            return distanceToNext < distanceToCurrent ? next : current
        }

        // Map each diarizer speakerId → resolved display name and known person ID
        var speakerLabels: [String: String] = [:]
        var speakerPersonIds: [String: String] = [:]
        var anonymousSpeakerCount = 0

        func resolveLabel(for rawSpeakerId: String, embedding: [Float]) -> (label: String, personId: String?) {
            if let cached = speakerLabels[rawSpeakerId] {
                return (cached, speakerPersonIds[rawSpeakerId])
            }
            // Try to match against known persons by cosine similarity
            if !knownPersonProfiles.isEmpty, !embedding.isEmpty {
                var best: (profile: KnownPersonProfile, similarity: Float)?
                for profile in knownPersonProfiles where profile.embedding.count == embedding.count {
                    let sim = cosineSimilarity(profile.embedding, embedding)
                    if sim > 0.75, best == nil || sim > best!.similarity {
                        best = (profile, sim)
                    }
                }
                if let match = best {
                    speakerLabels[rawSpeakerId] = match.profile.name
                    speakerPersonIds[rawSpeakerId] = match.profile.personId
                    return (match.profile.name, match.profile.personId)
                }
            }
            // No match — assign an anonymous label
            anonymousSpeakerCount += 1
            let label = "Speaker \(anonymousSpeakerCount)"
            speakerLabels[rawSpeakerId] = label
            return (label, nil)
        }

        var storedSegments: [StoredSpeakerSegment] = []
        var paragraphs: [String] = []
        var currentRawSpeakerId: String?
        var currentDiarizerSegment: TimedSpeakerSegment?
        var currentWords: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0

        func flush() {
            guard let rawId = currentRawSpeakerId, !currentWords.isEmpty,
                  let diarizerSeg = currentDiarizerSegment else { return }

            let embedding = diarizerSeg.embedding
            let (label, personId) = resolveLabel(for: rawId, embedding: Array(embedding))
            let text = currentWords.joined(separator: " ")
            paragraphs.append("\(label): \(text)")

            storedSegments.append(StoredSpeakerSegment(
                startTime: currentStart,
                endTime: currentEnd,
                rawSpeakerId: rawId,
                text: text,
                embedding: Array(embedding),
                assignedPersonName: label.hasPrefix("Speaker ") ? nil : label,
                assignedPersonId: personId
            ))
        }

        for word in words {
            let midpoint = (word.startTime + word.endTime) / 2
            let diarizerSeg = segmentAtMidpoint(midpoint)

            if diarizerSeg.speakerId != currentRawSpeakerId {
                flush()
                currentWords = []
                currentRawSpeakerId = diarizerSeg.speakerId
                currentDiarizerSegment = diarizerSeg
                currentStart = word.startTime
            }
            currentWords.append(word.word)
            currentEnd = word.endTime
        }
        flush()

        guard !paragraphs.isEmpty else { return nil }
        return DiarizedOutput(
            text: paragraphs.joined(separator: "\n\n"),
            segments: storedSegments
        )
    }

    /// Transcribes one overdub track from a split /memo recording (track 0 = base,
    /// handled by the normal `transcribe` path). No diarization — an overdub layer is
    /// the same speaker as the base track — but ASR word timings are still needed to
    /// place the note on the base memo's timeline, since every track shares that
    /// timeline (all tracks in the source file are the same length).
    func transcribeOverdubTrack(localPath: String) async throws -> (text: String, startTime: TimeInterval) {
        let manager = try await loadManager()
        let url = URL(fileURLWithPath: localPath)
        var decoderState = TdtDecoderState.make()
        let language: Language? = variant == .v2 ? .english : nil

        let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", 0) }

        let startTime = result.tokenTimings.flatMap { Self.buildWordSpans(from: $0).first?.startTime } ?? 0
        return (text, startTime)
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

        // Register all known persons so the diarizer can match their voices.
        let speakers = knownPersonProfiles.compactMap { profile -> Speaker? in
            guard !profile.embedding.isEmpty else { return nil }
            return Speaker(
                id: profile.personId,
                name: profile.name,
                currentEmbedding: profile.embedding,
                isPermanent: true
            )
        }
        if !speakers.isEmpty {
            diarizer.initializeKnownSpeakers(speakers)
        }

        self.diarizer = diarizer
        return diarizer
    }
}

// MARK: - Cosine similarity helper

private nonisolated func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    let denom = normA.squareRoot() * normB.squareRoot()
    return denom > 0 ? dot / denom : 0
}
