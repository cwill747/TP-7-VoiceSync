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

actor OpenRouterService {
    /// UserDefaults key holding the OpenAI-compatible API base URL. Empty means
    /// use the OpenRouter default; set it to e.g. `http://127.0.0.1:8088/v1` to
    /// point at a local llama-server / LM Studio / Ollama instance.
    static let baseURLKey = "openrouter.baseURL"
    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    static let remoteCompletionTimeout: TimeInterval = 300
    static let localCompletionTimeout: TimeInterval = 3600

    /// Resolves the configured base URL, falling back to OpenRouter and trimming
    /// a trailing slash so path joins stay well-formed.
    nonisolated static func resolvedBaseURL(defaults: UserDefaults = .standard) -> String {
        let raw = (defaults.string(forKey: baseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? defaultBaseURL : raw
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base

        // URLSession may resolve localhost to IPv6 first. llama-server commonly
        // listens only on IPv4, which makes an otherwise healthy local endpoint
        // fail with a refused ::1 connection.
        guard var components = URLComponents(string: trimmed),
              components.host?.lowercased() == "localhost" else {
            return trimmed
        }
        components.host = "127.0.0.1"
        return components.string ?? trimmed
    }

    /// True when the endpoint is on the local machine or private LAN — such
    /// servers need no API key and can run while the app is otherwise offline.
    nonisolated static func isLocalEndpoint(defaults: UserDefaults = .standard) -> Bool {
        guard let host = URL(string: resolvedBaseURL(defaults: defaults))?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || isPrivateIPv4(host)
    }

    nonisolated private static func isPrivateIPv4(_ host: String) -> Bool {
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
        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
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

        // Use custom prompt if provided and non-empty, otherwise use default
        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : Self.defaultPrompt
        let prompt = """
        \(promptTemplate)

        Transcription:
        \(transcription)
        """

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
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
            temperature: 0.3
        )

        request.httpBody = try JSONEncoder().encode(requestBody)

        AppLogger.network.info("OpenRouter request (model=\(model, privacy: .public))")
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

        guard let content = completionResponse.choices.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.noContent
        }

        // Parse the JSON response from the LLM
        return try Self.parseLLMResponse(content)
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

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
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
            temperature: 0.2
        )

        request.httpBody = try JSONEncoder().encode(requestBody)

        AppLogger.network.info("OpenRouter format request (model=\(model, privacy: .public))")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw OpenRouterError.invalidAPIKey
            }
            AppLogger.network.error("OpenRouter format API error (status=\(httpResponse.statusCode, privacy: .public))")
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode)
        }

        let completionResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let content = completionResponse.choices.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.noContent
        }

        return Self.stripPreamble(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func formattingPromptBody(
        transcription: String,
        customPrompt: String? = nil,
        options: TranscriptFormatOptions = TranscriptFormatOptions()
    ) -> String {
        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : Self.defaultFormattingPrompt
        var extraInstructions = options.instructions
        if containsSpeakerLabels(transcription) {
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
    static func stripPreamble(_ text: String) -> String {
        guard let newlineIndex = text.firstIndex(of: "\n") else { return text }
        let firstLine = text[text.startIndex..<newlineIndex]
            .trimmingCharacters(in: .whitespaces)
        // Only treat short intro sentences ending in a colon as preamble, so we
        // don't accidentally drop real transcript content.
        guard firstLine.hasSuffix(":"), firstLine.count <= 80 else { return text }
        let remainder = text[text.index(after: newlineIndex)...]
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }

    init(model: String, messages: [ChatMessage], temperature: Double, maxTokens: Int? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
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
        }
    }
}
