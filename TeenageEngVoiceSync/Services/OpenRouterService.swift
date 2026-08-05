//
//  OpenRouterService.swift
//  TeenageEngVoiceSync
//
//  OpenRouter API integration for LLM-powered title generation.
//

import Foundation
import os

/// Result from LLM title/summary generation
nonisolated struct LLMResult: Sendable {
    let title: String
    let summary: String
}

/// Toggleable additions to the transcript cleanup prompt. Each one appends an
/// extra instruction rather than replacing the base prompt, so they compose
/// with both the default and a user's custom cleanup prompt.
nonisolated struct TranscriptFormatOptions: Sendable, Equatable {
    var removeFillerWords = false
    var removeFalseStarts = false
    var splitParagraphs = false
    var bulletPoints = false

    var instructions: [String] {
        var result: [String] = []
        if removeFillerWords {
            result.append(#"Remove filler words and verbal tics ("um", "uh", "like", "you know", "I mean") that don't carry meaning."#)
        }
        if removeFalseStarts {
            result.append("Remove false starts, stutters, and repeated words or phrases where the speaker corrected themselves mid-sentence.")
        }
        if splitParagraphs {
            result.append("Break the text into clear paragraphs whenever the topic or idea shifts, even within a single continuous recording.")
        }
        if bulletPoints {
            result.append("Where the speaker lists items, steps, or action points, format them as a bullet list instead of a run-on sentence.")
        }
        return result
    }
}

/// Model information from OpenRouter API
nonisolated struct OpenRouterModel: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let contextLength: Int
    let promptPrice: String
    let completionPrice: String
}

nonisolated enum EnhancementProvider: String, CaseIterable, Identifiable {
    case openRouter
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom Provider"
        }
    }

    var systemImage: String {
        switch self {
        case .openRouter: return "brain"
        case .custom: return "server.rack"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return OpenRouterService.defaultBaseURL
        case .custom: return ""
        }
    }

    var keychainKey: KeychainService.Key {
        switch self {
        case .openRouter: return .openRouterAPIKey
        case .custom: return .customAIAPIKey
        }
    }

    var dashboardURL: URL? {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .custom: return nil
        }
    }
}

actor OpenRouterService {
    static let providerKey = "enhancement.provider"
    /// UserDefaults key holding the OpenAI-compatible API base URL. Empty means
    /// use the OpenRouter default; set it to e.g. `http://127.0.0.1:8088/v1` to
    /// point at a local llama-server / LM Studio / Ollama instance.
    static let baseURLKey = "openrouter.baseURL"
    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    static let remoteCompletionTimeout: TimeInterval = 300
    static let localCompletionTimeout: TimeInterval = 3600
    /// Fallback chunk thresholds, used when the selected model's context window
    /// is unknown. When it is known, `chunkPlan(contextLength:)` derives the
    /// thresholds from it instead.
    static let summaryChunkThreshold = 12_000
    static let summaryChunkTargetSize = 8_000
    static let summaryChunkOverlap = 500
    static let formatChunkThreshold = 12_000
    static let formatChunkTargetSize = 6_000
    /// Rough characters-per-token ratio for English prose, used to turn a
    /// model's token context window into a transcript character budget.
    static let charactersPerToken = 4
    /// Share of the context window a single-shot summary request may occupy.
    static let summaryContextUtilization = 0.6
    /// Cleanup echoes the transcript back, so input and output both have to fit.
    static let formatContextUtilization = 0.35
    /// Floor for a derived threshold, so a small or misreported context window
    /// can't produce single-sentence chunks.
    static let minimumChunkThreshold = 2_000
    /// Chunk requests are independent, so a few run concurrently to keep a long
    /// transcript from serializing the whole sync pipeline. Local endpoints
    /// usually serve a single model instance, so they stay sequential.
    static let maxConcurrentChunkRequests = 3
    /// Attempts per chunk request before that chunk is treated as failed.
    static let chunkRequestAttempts = 3
    static let chunkRetryDelay: TimeInterval = 2

    /// Resolves the configured base URL, falling back to OpenRouter and trimming
    /// a trailing slash so path joins stay well-formed.
    nonisolated static func resolvedBaseURL(defaults: UserDefaults = .standard) -> String {
        let provider = activeProvider(defaults: defaults)
        let raw = provider == .custom
            ? (defaults.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : provider.defaultBaseURL
        let base = raw.isEmpty ? provider.defaultBaseURL : raw
        return normalizeBaseURL(base)
    }

    nonisolated static func activeProvider(defaults: UserDefaults = .standard) -> EnhancementProvider {
        if let raw = defaults.string(forKey: providerKey),
           let provider = EnhancementProvider(rawValue: raw) {
            return provider
        }

        let legacyBaseURL = (defaults.string(forKey: baseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyBaseURL.isEmpty ? .openRouter : .custom
    }

    nonisolated static func activeKeychainKey(defaults: UserDefaults = .standard) -> KeychainService.Key {
        activeProvider(defaults: defaults).keychainKey
    }

    // Trims a trailing slash and rewrites localhost to 127.0.0.1 to avoid IPv6
    // resolution races with llama-server and similar local servers.
    nonisolated static func normalizeBaseURL(_ url: String) -> String {
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard var components = URLComponents(string: trimmed),
              components.host?.lowercased() == "localhost" else {
            return trimmed
        }
        components.host = "127.0.0.1"
        return components.string ?? trimmed
    }

    nonisolated static func isLocalEndpoint(defaults: UserDefaults = .standard) -> Bool {
        guard let host = URL(string: resolvedBaseURL(defaults: defaults))?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || isPrivateIPv4(host)
    }

    nonisolated static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              parts.dropFirst(2).allSatisfy({ Int($0) != nil }) else {
            return false
        }

        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    nonisolated static func completionTimeout(defaults: UserDefaults = .standard) -> TimeInterval {
        isLocalEndpoint(defaults: defaults) ? localCompletionTimeout : remoteCompletionTimeout
    }

    private var baseURL: String { Self.resolvedBaseURL() }
    private let session: URLSession
    /// Context window per model id, populated lazily from `/models`. A cached 0
    /// means "asked, not reported" so we don't refetch on every recording.
    private var modelContextLengths: [String: Int] = [:]
    private var modelContextLookupFailed = false

    /// Default prompt template for title and summary generation
    static let defaultPrompt = """
        Analyze this voice recording transcription and provide:
        1. A concise, descriptive title (maximum 60 characters) that captures the main topic or theme
        2. A brief summary (1-2 sentences) of the key points

        Respond in this exact JSON format:
        {"title": "Your title here", "summary": "Your summary here"}
        """

    /// Default prompt template for cleaning up a raw transcription. Intentionally
    /// conservative: punctuation and capitalization only, plus corrections limited
    /// to words that were very likely misheard by the speech-to-text engine.
    static let defaultFormattingPrompt = """
        You are a transcription formatter. Reformat the following speech-to-text \
        transcription to improve readability WITHOUT changing its meaning or wording.

        Rules:
        - Add correct punctuation, capitalization, and paragraph breaks.
        - Fix ONLY obvious transcription errors — words that were very likely misheard \
        by the speech-to-text engine (for example homophones or clearly garbled words). \
        When in doubt, leave the original word unchanged.
        - Do NOT paraphrase, summarize, add, remove, or reorder content.
        - Do NOT add commentary, headings, or explanations.
        - Preserve the speaker's original vocabulary, tone, and filler words unless they \
        are clearly transcription noise.

        Return ONLY the corrected transcription text, with no preamble or quotation marks.
        """

    static let speakerFormattingInstructions = [
        "Preserve every speaker label exactly as written, including the colon (for example, \"Speaker 1:\" or \"Alex:\").",
        "Do NOT merge speaker turns, reorder turns, rename speakers, or move words from one speaker to another.",
        "Clean only the spoken text after each speaker label. If you split a speaker's turn into paragraphs or bullets, keep that content under the same speaker label."
    ]

    static let chunkSummaryPrompt = """
        Summarize this portion of a voice recording transcript as compact notes.

        Rules:
        - Capture important topics, decisions, action items, names, dates, and open questions.
        - Preserve speaker labels or names when they matter.
        - Do not invent context from outside this chunk.
        - Return concise bullet points only.
        """

    static let mergeNotesPrompt = """
        Merge these notes, taken from consecutive portions of one voice recording
        transcript, into a single set of compact notes.

        Rules:
        - Keep important topics, decisions, action items, names, dates, and open questions.
        - Consecutive portions can overlap; state a repeated item once.
        - Do not invent anything that isn't in the notes.
        - Return concise bullet points only.
        """

    /// Cap on note-folding passes before the reduce step runs on whatever it has.
    static let maxNoteReduceRounds = 4

    init() {
        let config = URLSessionConfiguration.default
        // Formatting a long transcript can generate a lot of tokens, so allow
        // more headroom than short title/summary requests need.
        config.timeoutIntervalForRequest = Self.remoteCompletionTimeout
        config.timeoutIntervalForResource = Self.localCompletionTimeout
        self.session = URLSession(configuration: config)
    }

    /// Fetches available models from OpenRouter API
    func fetchModels(apiKey: String) async throws -> [OpenRouterModel] {
        try await fetchModels(apiKey: apiKey, baseURL: baseURL)
    }

    func fetchModels(apiKey: String, provider: EnhancementProvider, customBaseURL: String) async throws -> [OpenRouterModel] {
        let rawBaseURL = provider == .custom
            ? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : provider.defaultBaseURL
        let resolvedURL = Self.normalizeBaseURL(rawBaseURL.isEmpty ? provider.defaultBaseURL : rawBaseURL)
        return try await fetchModels(apiKey: apiKey, baseURL: resolvedURL)
    }

    private func fetchModels(apiKey: String, baseURL: String) async throws -> [OpenRouterModel] {
        guard !baseURL.isEmpty else {
            throw OpenRouterError.parseError("No base URL configured for this provider")
        }
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBaseURL)/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw OpenRouterError.invalidAPIKey
            }
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode)
        }

        return try Self.decodeModels(from: data)
    }

    /// Decodes both OpenRouter's model schema and the smaller OpenAI-compatible
    /// schema returned by llama-server.
    nonisolated static func decodeModels(from data: Data) throws -> [OpenRouterModel] {
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)

        return modelsResponse.data.map { model in
            OpenRouterModel(
                id: model.id,
                name: model.name ?? model.id,
                description: model.description ?? "",
                contextLength: model.contextLength ?? model.meta?.contextLength ?? 0,
                promptPrice: model.pricing?.prompt ?? "0",
                completionPrice: model.pricing?.completion ?? "0"
            )
        }.sorted { $0.name < $1.name }
    }

    /// Generates a title and summary for the given transcription
    /// - Parameters:
    ///   - transcription: The transcription text to analyze
    ///   - model: The model ID to use for generation
    ///   - apiKey: The OpenRouter API key
    ///   - customPrompt: Optional custom prompt template (uses defaultPrompt if nil or empty)
    func generateTitleAndSummary(
        transcription: String,
        model: String,
        apiKey: String,
        customPrompt: String? = nil
    ) async throws -> LLMResult {
        guard !transcription.isEmpty else {
            throw OpenRouterError.emptyTranscription
        }

        let plan = await chunkPlan(model: model, apiKey: apiKey)
        if transcription.count > plan.summaryThreshold {
            return try await generateChunkedTitleAndSummary(
                transcription: transcription,
                model: model,
                apiKey: apiKey,
                customPrompt: customPrompt,
                plan: plan
            )
        }

        // Use custom prompt if provided and non-empty, otherwise use default
        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : Self.defaultPrompt
        let prompt = """
        \(promptTemplate)

        Transcription:
        \(transcription)
        """

        AppLogger.network.info("OpenRouter request (model=\(model, privacy: .public))")
        let content = try await chatCompletion(prompt: prompt, model: model, apiKey: apiKey, temperature: 0.3)

        // Parse the JSON response from the LLM
        return try Self.parseLLMResponse(content)
    }

    private func generateChunkedTitleAndSummary(
        transcription: String,
        model: String,
        apiKey: String,
        customPrompt: String?,
        plan: ChunkPlan
    ) async throws -> LLMResult {
        let chunks = Self.chunkTranscription(
            transcription,
            targetSize: plan.summaryTargetSize,
            overlap: Self.summaryChunkOverlap
        )
        AppLogger.network.info("Chunking title/summary request into \(chunks.count, privacy: .public) chunks (model=\(model, privacy: .public))")

        let prompts = chunks.enumerated().map { index, chunk in
            """
            \(Self.chunkSummaryPrompt)

            Chunk \(index + 1) of \(chunks.count):
            \(chunk)
            """
        }

        // Notes are lossy intermediates, so one flaky chunk shouldn't cost the
        // whole summary: failed chunks are dropped and the reduce step runs on
        // whatever came back. Only a total failure propagates.
        let results = try await chunkCompletions(
            prompts: prompts,
            model: model,
            apiKey: apiKey,
            temperature: 0.2,
            tolerateFailures: true
        )

        var notes: [ChunkNote] = []
        for (index, content) in results.enumerated() {
            guard let content else { continue }
            let text = Self.stripPreamble(content.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { continue }
            notes.append(ChunkNote(index: index, text: text))
        }

        let missing = chunks.count - notes.count
        if missing > 0 {
            AppLogger.network.error("\(missing, privacy: .public) of \(chunks.count, privacy: .public) summary chunks produced no notes; summarizing from the rest")
        }

        return try await reduceChunkNotes(
            notes,
            model: model,
            apiKey: apiKey,
            customPrompt: customPrompt,
            plan: plan
        )
    }

    /// Folds chunk notes into one title and summary. When the notes themselves
    /// outgrow a single request they are merged in batches first, so the reduce
    /// step can't re-exceed the context window chunking exists to respect.
    private func reduceChunkNotes(
        _ notes: [ChunkNote],
        model: String,
        apiKey: String,
        customPrompt: String?,
        plan: ChunkPlan
    ) async throws -> LLMResult {
        guard !notes.isEmpty else { throw OpenRouterError.noContent }

        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : Self.defaultPrompt
        // Leave room for the prompt template and the model's own answer.
        let notesBudget = max(Self.minimumChunkThreshold, plan.summaryThreshold - promptTemplate.count - 512)

        var current = notes
        var round = 0
        while Self.renderNotes(current).count > notesBudget, current.count > 1, round < Self.maxNoteReduceRounds {
            round += 1
            let batches = Self.noteBatches(current, budget: notesBudget)
            // Batching that can't merge anything would loop without shrinking.
            guard batches.count < current.count else { break }
            AppLogger.network.info("Reducing \(current.count, privacy: .public) chunk notes to \(batches.count, privacy: .public) (round \(round, privacy: .public))")
            current = try await foldNoteBatches(batches, model: model, apiKey: apiKey)
        }

        let prompt = """
        \(promptTemplate)

        The original transcript was summarized in chunks. Use the chunk notes below to produce one title and one summary for the full recording.
        Consecutive chunks can overlap, so treat a repeated topic, decision, or action item as one item and mention it once.

        Chunk notes:
        \(Self.clamp(Self.renderNotes(current), to: notesBudget))
        """

        let content = try await chatCompletion(prompt: prompt, model: model, apiKey: apiKey, temperature: 0.3)
        return try Self.parseLLMResponse(content)
    }

    /// Merges each batch of notes into a single note. A batch that fails to
    /// merge keeps its original notes rather than dropping that section.
    private func foldNoteBatches(
        _ batches: [[ChunkNote]],
        model: String,
        apiKey: String
    ) async throws -> [ChunkNote] {
        let prompts = batches.map { batch in
            """
            \(Self.mergeNotesPrompt)

            Notes:
            \(Self.renderNotes(batch))
            """
        }

        let results = try await chunkCompletions(
            prompts: prompts,
            model: model,
            apiKey: apiKey,
            temperature: 0.2,
            tolerateFailures: true
        )

        var folded: [ChunkNote] = []
        for (offset, batch) in batches.enumerated() {
            let merged = results[offset]
                .map { Self.stripPreamble($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? ""
            guard !merged.isEmpty, let first = batch.first else {
                folded.append(contentsOf: batch)
                continue
            }
            folded.append(ChunkNote(index: first.index, text: merged))
        }

        return folded
    }

    /// Groups notes into batches that each render under `budget` characters.
    static func noteBatches(_ notes: [ChunkNote], budget: Int) -> [[ChunkNote]] {
        var batches: [[ChunkNote]] = []
        var current: [ChunkNote] = []
        var size = 0

        for note in notes {
            // Rough allowance for the "Chunk N:" header and the blank-line join.
            let cost = note.text.count + 16
            if !current.isEmpty, size + cost > budget {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(note)
            size += cost
        }

        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func renderNotes(_ notes: [ChunkNote]) -> String {
        notes.map { "Chunk \($0.index + 1):\n\($0.text)" }.joined(separator: "\n\n")
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    /// Runs chunk prompts with bounded concurrency and per-request retries.
    /// With `tolerateFailures`, a chunk that never succeeds yields nil and only
    /// a total failure throws; otherwise the first failure throws.
    private func chunkCompletions(
        prompts: [String],
        model: String,
        apiKey: String,
        temperature: Double,
        tolerateFailures: Bool
    ) async throws -> [String?] {
        guard !prompts.isEmpty else { return [] }

        var results = [String?](repeating: nil, count: prompts.count)
        var firstFailure: OpenRouterError?
        let limit = Self.isLocalEndpoint() ? 1 : Self.maxConcurrentChunkRequests

        for batchStart in stride(from: 0, to: prompts.count, by: limit) {
            let batch = batchStart..<min(batchStart + limit, prompts.count)
            let completions = await withTaskGroup(of: ChunkCompletion.self) { group -> [ChunkCompletion] in
                for index in batch {
                    let prompt = prompts[index]
                    group.addTask { [self] in
                        do {
                            let content = try await chunkCompletion(
                                prompt: prompt,
                                model: model,
                                apiKey: apiKey,
                                temperature: temperature
                            )
                            return ChunkCompletion(index: index, content: content, failure: nil)
                        } catch {
                            return ChunkCompletion(index: index, content: nil, failure: Self.normalized(error))
                        }
                    }
                }

                var collected: [ChunkCompletion] = []
                for await completion in group { collected.append(completion) }
                return collected
            }

            for completion in completions {
                results[completion.index] = completion.content
                guard let failure = completion.failure else { continue }
                AppLogger.network.error("Chunk \(completion.index + 1, privacy: .public) failed: \(failure.localizedDescription, privacy: .public)")
                if firstFailure == nil { firstFailure = failure }
            }

            if !tolerateFailures, let firstFailure { throw firstFailure }
        }

        if let firstFailure, results.allSatisfy({ $0 == nil }) { throw firstFailure }
        return results
    }

    /// One chunk request, retried on transient failures so a single 429 or
    /// dropped connection doesn't discard the work done for the other chunks.
    private func chunkCompletion(
        prompt: String,
        model: String,
        apiKey: String,
        temperature: Double
    ) async throws -> String {
        for attempt in 1...Self.chunkRequestAttempts {
            do {
                return try await chatCompletion(
                    prompt: prompt,
                    model: model,
                    apiKey: apiKey,
                    temperature: temperature
                )
            } catch {
                guard Self.isRetryable(error), attempt < Self.chunkRequestAttempts else { throw error }
                let delay = Self.chunkRetryDelay * Double(attempt)
                AppLogger.network.info("Retrying chunk request in \(delay, privacy: .public)s (attempt \(attempt + 1, privacy: .public))")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw OpenRouterError.noContent
    }

    nonisolated static func isRetryable(_ error: Error) -> Bool {
        guard let openRouterError = error as? OpenRouterError else {
            return error is URLError
        }

        switch openRouterError {
        case .apiError(let statusCode):
            return statusCode == 408 || statusCode == 429 || statusCode >= 500
        case .noContent, .invalidResponse, .transport:
            return true
        case .invalidAPIKey, .emptyTranscription, .parseError:
            return false
        }
    }

    nonisolated static func normalized(_ error: Error) -> OpenRouterError {
        (error as? OpenRouterError) ?? .transport(error.localizedDescription)
    }

    private func chatCompletion(
        prompt: String,
        model: String,
        apiKey: String,
        temperature: Double
    ) async throws -> String {
        guard let chatURL = URL(string: "\(baseURL)/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = Self.completionTimeout()
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TP-7-VoiceSync", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("TP-7 Voice Sync", forHTTPHeaderField: "X-Title")

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: temperature
        )

        request.httpBody = try JSONEncoder().encode(requestBody)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw OpenRouterError.invalidAPIKey
            }
            AppLogger.network.error("OpenRouter API error (status=\(httpResponse.statusCode, privacy: .public))")
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode)
        }

        let completionResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let choice = completionResponse.choices.first else {
            throw OpenRouterError.noContent
        }

        // A response cut off by the provider's token limit is silently partial,
        // so say so rather than storing half a summary as if it were complete.
        if choice.finishReason == "length" {
            AppLogger.network.error("Response truncated by the token limit (model=\(model, privacy: .public))")
        }

        guard !choice.message.content.isEmpty else {
            throw OpenRouterError.noContent
        }

        return choice.message.content
    }

    /// Chunking sizes for one model. Derived from the model's context window
    /// when the provider reports one, and from the static fallbacks when it
    /// doesn't.
    struct ChunkPlan: Sendable, Equatable {
        let summaryThreshold: Int
        let summaryTargetSize: Int
        let formatThreshold: Int
        let formatTargetSize: Int
    }

    struct ChunkNote: Sendable, Equatable {
        let index: Int
        let text: String
    }

    private struct ChunkCompletion: Sendable {
        let index: Int
        let content: String?
        let failure: OpenRouterError?
    }

    static let fallbackChunkPlan = ChunkPlan(
        summaryThreshold: summaryChunkThreshold,
        summaryTargetSize: summaryChunkTargetSize,
        formatThreshold: formatChunkThreshold,
        formatTargetSize: formatChunkTargetSize
    )

    static func chunkPlan(contextLength: Int) -> ChunkPlan {
        guard contextLength > 0 else { return fallbackChunkPlan }

        let budget = Double(contextLength * charactersPerToken)
        let summaryThreshold = max(minimumChunkThreshold, Int(budget * summaryContextUtilization))
        let formatThreshold = max(minimumChunkThreshold, Int(budget * formatContextUtilization))

        return ChunkPlan(
            summaryThreshold: summaryThreshold,
            summaryTargetSize: max(1, summaryThreshold * 2 / 3),
            formatThreshold: formatThreshold,
            formatTargetSize: max(1, formatThreshold / 2)
        )
    }

    private func chunkPlan(model: String, apiKey: String) async -> ChunkPlan {
        Self.chunkPlan(contextLength: await contextLength(for: model, apiKey: apiKey))
    }

    /// Looks up the model's context window, caching the whole model list on the
    /// first miss. A cached 0 means "asked, not reported", so an endpoint that
    /// omits context lengths isn't refetched for every recording.
    private func contextLength(for model: String, apiKey: String) async -> Int {
        if let cached = modelContextLengths[model] { return cached }

        if !modelContextLookupFailed {
            do {
                for entry in try await fetchModels(apiKey: apiKey) {
                    modelContextLengths[entry.id] = entry.contextLength
                }
            } catch {
                modelContextLookupFailed = true
                AppLogger.network.debug("Model context lookup failed; using fallback chunk sizes: \(error.localizedDescription, privacy: .public)")
            }
        }

        let resolved = modelContextLengths[model] ?? 0
        modelContextLengths[model] = resolved
        return resolved
    }

    static func shouldChunkSummary(transcription: String) -> Bool {
        transcription.count > summaryChunkThreshold
    }

    static func chunkTranscription(
        _ transcription: String,
        targetSize: Int = summaryChunkTargetSize,
        overlap: Int = summaryChunkOverlap
    ) -> [String] {
        guard transcription.count > targetSize, targetSize > 0 else {
            return transcription.isEmpty ? [] : [transcription]
        }

        var chunks: [String] = []
        var start = transcription.startIndex

        while start < transcription.endIndex {
            guard let targetEnd = transcription.index(start, offsetBy: targetSize, limitedBy: transcription.endIndex) else {
                chunks.append(String(transcription[start..<transcription.endIndex]))
                break
            }

            if targetEnd == transcription.endIndex {
                chunks.append(String(transcription[start..<transcription.endIndex]))
                break
            }

            let segment = String(transcription[start..<targetEnd])
            if let boundaryOffset = bestSummaryChunkBoundary(in: segment, targetSize: targetSize),
               boundaryOffset > 0 {
                let boundary = transcription.index(start, offsetBy: boundaryOffset)
                chunks.append(String(transcription[start..<boundary]))
                start = boundary
            } else {
                chunks.append(String(transcription[start..<targetEnd]))
                let chunkLength = transcription.distance(from: start, to: targetEnd)
                let appliedOverlap = min(max(overlap, 0), max(chunkLength - 1, 0))
                start = transcription.index(targetEnd, offsetBy: -appliedOverlap)
            }
        }

        return chunks.filter { !$0.isEmpty }
    }

    private static func bestSummaryChunkBoundary(in segment: String, targetSize: Int) -> Int? {
        let minimumUsefulOffset = max(targetSize / 2, 1)
        for separator in ["\n\n", "\n", ". ", "? ", "! "] {
            if let range = segment.range(of: separator, options: .backwards) {
                let offset = segment.distance(from: segment.startIndex, to: range.upperBound)
                if offset >= minimumUsefulOffset {
                    return offset
                }
            }
        }
        return nil
    }

    /// Cleans up a raw transcription: adds punctuation and capitalization and
    /// corrects only high-confidence transcription errors, returning the
    /// reformatted plain text. Uses a separate model choice from titling.
    /// - Parameters:
    ///   - transcription: The raw transcription text to reformat
    ///   - model: The model ID to use for formatting
    ///   - apiKey: The OpenRouter API key
    ///   - customPrompt: Optional custom prompt (uses defaultFormattingPrompt if nil or empty)
    func formatTranscription(
        transcription: String,
        model: String,
        apiKey: String,
        customPrompt: String? = nil,
        options: TranscriptFormatOptions = TranscriptFormatOptions()
    ) async throws -> String {
        guard !transcription.isEmpty else {
            throw OpenRouterError.emptyTranscription
        }

        let plan = await chunkPlan(model: model, apiKey: apiKey)
        if transcription.count > plan.formatThreshold {
            return try await formatTranscriptionInChunks(
                transcription: transcription,
                model: model,
                apiKey: apiKey,
                customPrompt: customPrompt,
                options: options,
                plan: plan
            )
        }

        let promptBody = Self.formattingPromptBody(
            transcription: transcription,
            customPrompt: customPrompt,
            options: options
        )
        let prompt = """
        \(promptBody)

        Transcription:
        \(transcription)
        """

        AppLogger.network.info("OpenRouter format request (model=\(model, privacy: .public))")
        let content = try await chatCompletion(prompt: prompt, model: model, apiKey: apiKey, temperature: 0.2)

        return Self.stripPreamble(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func formatTranscriptionInChunks(
        transcription: String,
        model: String,
        apiKey: String,
        customPrompt: String?,
        options: TranscriptFormatOptions,
        plan: ChunkPlan
    ) async throws -> String {
        let chunks = Self.chunkTranscription(transcription, targetSize: plan.formatTargetSize, overlap: 0)
        AppLogger.network.info("Chunking format request into \(chunks.count, privacy: .public) chunks (model=\(model, privacy: .public))")

        // Speaker labels are detected once over the whole transcript: a chunk
        // that lands inside one long uninterrupted turn carries no label of its
        // own but still has to be told to preserve the one it inherits.
        let promptBody = Self.formattingPromptBody(
            transcription: transcription,
            customPrompt: customPrompt,
            options: options,
            speakerLabelsPresent: Self.containsSpeakerLabels(transcription)
        )

        let prompts = chunks.enumerated().map { index, chunk in
            """
            \(promptBody)

            This is chunk \(index + 1) of \(chunks.count) from one transcript.
            Clean only this chunk. Do not add chunk labels, headings, summaries, or transition text.
            The chunk may start or end mid-sentence; leave its boundaries where they are.

            Transcription:
            \(chunk)
            """
        }

        // Cleanup has to be complete — a dropped chunk would publish a transcript
        // with a hole in it — so any chunk that can't be cleaned fails the whole
        // request and reconciliation retries it later.
        let results = try await chunkCompletions(
            prompts: prompts,
            model: model,
            apiKey: apiKey,
            temperature: 0.2,
            tolerateFailures: false
        )

        let formattedChunks = results.enumerated().map { index, content -> String in
            let cleaned = content
                .map { Self.stripPreamble($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? ""
            guard cleaned.isEmpty else { return cleaned }
            // Never drop a section: if cleanup produced nothing usable, keep the
            // raw text for that chunk.
            AppLogger.network.error("Format chunk \(index + 1, privacy: .public) came back empty; keeping the raw text")
            return chunks[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Self.mergeFormattedChunks(formattedChunks, rawChunks: chunks)
    }

    static func shouldChunkFormatting(transcription: String) -> Bool {
        transcription.count > formatChunkThreshold
    }

    static func formattingChunks(for transcription: String) -> [String] {
        chunkTranscription(transcription, targetSize: formatChunkTargetSize, overlap: 0)
    }

    /// Rejoins cleaned chunks using the separator that produced each seam, so a
    /// split made mid-sentence doesn't gain a paragraph break and one made
    /// mid-word doesn't gain whitespace. Without `rawChunks` the seams are
    /// unknown and every chunk is treated as its own paragraph.
    static func mergeFormattedChunks(_ chunks: [String], rawChunks: [String] = []) -> String {
        var merged = ""

        for (index, chunk) in chunks.enumerated() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if merged.isEmpty {
                merged = trimmed
            } else {
                merged += seamJoiner(afterChunkAt: index - 1, in: rawChunks) + trimmed
            }
        }

        return merged
    }

    /// The whitespace that was consumed when the raw transcript was split after
    /// chunk `index`, recovered from that chunk's own trailing characters.
    private static func seamJoiner(afterChunkAt index: Int, in rawChunks: [String]) -> String {
        guard rawChunks.indices.contains(index) else { return "\n\n" }

        let raw = rawChunks[index]
        if raw.hasSuffix("\n\n") { return "\n\n" }
        if raw.hasSuffix("\n") { return "\n" }
        // A sentence boundary ends with the separator's trailing space; a forced
        // mid-word split ends with the word itself and must rejoin seamlessly.
        return raw.last == " " ? " " : ""
    }

    static func formattingPromptBody(
        transcription: String,
        customPrompt: String? = nil,
        options: TranscriptFormatOptions = TranscriptFormatOptions(),
        speakerLabelsPresent: Bool? = nil
    ) -> String {
        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : Self.defaultFormattingPrompt
        var extraInstructions = options.instructions
        if speakerLabelsPresent ?? containsSpeakerLabels(transcription) {
            extraInstructions.append(contentsOf: speakerFormattingInstructions)
        }

        guard !extraInstructions.isEmpty else { return promptTemplate }
        return promptTemplate
            + "\n\nAdditional formatting instructions:\n"
            + extraInstructions.map { "- \($0)" }.joined(separator: "\n")
    }

    static func containsSpeakerLabels(_ transcription: String) -> Bool {
        let lines = transcription.components(separatedBy: .newlines)
        var labels = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let label = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let remainder = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !remainder.isEmpty, label.count <= 60 else { continue }
            guard label.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} _.'-]*$"#, options: .regularExpression) != nil else { continue }

            if label.range(of: #"(?i)^speaker[\s_-]*[[:alnum:]]+$"#, options: .regularExpression) != nil {
                return true
            }
            let normalizedLabel = label.lowercased()
            let ordinaryHeadings: Set<String> = [
                "action item", "action items", "agenda", "date", "duration",
                "file", "filename", "language", "note", "notes", "summary",
                "title", "transcript", "transcription"
            ]
            guard !ordinaryHeadings.contains(normalizedLabel) else { continue }

            labels.insert(normalizedLabel)
            if labels.count >= 2 { return true }
        }

        return false
    }

    /// Some models ignore the "no preamble" instruction and prefix the output
    /// with a line like "Here is the reformatted transcription:". Strip a single
    /// leading intro line that ends in a colon (optionally followed by a blank
    /// line) before returning the cleaned text.
    ///
    /// The line also has to read as meta-commentary. This runs on every chunk of
    /// a long transcript, so a real heading ("Action items:") or a speaker label
    /// ("Alex:") at the top of a chunk has to survive.
    static func stripPreamble(_ text: String) -> String {
        guard let newlineIndex = text.firstIndex(of: "\n") else { return text }
        let firstLine = text[text.startIndex..<newlineIndex]
            .trimmingCharacters(in: .whitespaces)
        guard firstLine.hasSuffix(":"), firstLine.count <= 80, isPreambleLine(firstLine) else { return text }
        let remainder = text[text.index(after: newlineIndex)...]
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let preamblePattern =
        #"(?i)^(sure|okay|ok|certainly|of course|as requested|here\b|below\b|output\b|result\b|(the )?(following|cleaned|formatted|reformatted|corrected|revised)\b)"#

    static func isPreambleLine(_ line: String) -> Bool {
        line.range(of: preamblePattern, options: .regularExpression) != nil
    }

    static func parseLLMResponse(_ content: String) throws -> LLMResult {
        // Try to find JSON in the response (LLM might include extra text)
        var jsonString = content

        // Look for JSON object boundaries
        if let startIndex = content.firstIndex(of: "{"),
           let endIndex = content.lastIndex(of: "}") {
            jsonString = String(content[startIndex...endIndex])
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OpenRouterError.parseError("Could not encode response as data")
        }

        do {
            let parsed = try JSONDecoder().decode(LLMResponseJSON.self, from: jsonData)
            return LLMResult(
                title: String(parsed.title.prefix(60)),
                summary: parsed.summary
            )
        } catch {
            AppLogger.network.debug("OpenRouter JSON parse error: \(String(describing: error), privacy: .public)")
            // If JSON parsing fails, try to extract manually
            return try extractManually(from: content)
        }
    }

    private static func extractManually(from content: String) throws -> LLMResult {
        // Fallback: try to extract title and summary from plain text
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var title = "Voice Recording"
        var summary = ""

        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.contains("title") {
                // Extract after colon or quotes
                if let colonIndex = line.firstIndex(of: ":") {
                    title = String(line[line.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            } else if lowercased.contains("summary") {
                if let colonIndex = line.firstIndex(of: ":") {
                    summary = String(line[line.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }

        if title == "Voice Recording" && summary.isEmpty {
            throw OpenRouterError.parseError("Could not extract title and summary from response")
        }

        return LLMResult(
            title: String(title.prefix(60)),
            summary: summary
        )
    }
}

// MARK: - API Request/Response Types

private nonisolated struct ModelsResponse: Codable {
    let data: [ModelData]
}

private nonisolated struct ModelData: Codable {
    let id: String
    let name: String?
    let description: String?
    let contextLength: Int?
    let pricing: ModelPricing?
    let meta: ModelMeta?

    enum CodingKeys: String, CodingKey {
        case id, name, description, pricing, meta
        case contextLength = "context_length"
    }
}

private nonisolated struct ModelMeta: Codable {
    let contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case contextLength = "n_ctx"
    }
}

private nonisolated struct ModelPricing: Codable {
    let prompt: String
    let completion: String
}

private nonisolated struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private nonisolated struct ChatMessage: Codable {
    let role: String
    let content: String
}

private nonisolated struct ChatCompletionResponse: Codable {
    let choices: [Choice]
}

private nonisolated struct Choice: Codable {
    let message: ResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private nonisolated struct ResponseMessage: Codable {
    let content: String
}

private nonisolated struct LLMResponseJSON: Codable {
    let title: String
    let summary: String
}

// MARK: - Errors

nonisolated enum OpenRouterError: LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case noContent
    case emptyTranscription
    case parseError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid or missing API key"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let statusCode):
            return "API error (status code: \(statusCode))"
        case .noContent:
            return "No content in response"
        case .emptyTranscription:
            return "Transcription is empty"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .transport(let message):
            return "Network error: \(message)"
        }
    }
}
