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
    private let baseURL = "https://openrouter.ai/api/v1"
    private let session: URLSession

    /// Default prompt template for title and summary generation
    static let defaultPrompt = """
        Analyze this voice recording transcription and provide:
        1. A concise, descriptive title (maximum 60 characters) that captures the main topic or theme
        2. A brief summary (1-2 sentences) of the key points

        Respond in this exact JSON format:
        {"title": "Your title here", "summary": "Your summary here"}
        """

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Fetches available models from OpenRouter API
    func fetchModels(apiKey: String) async throws -> [OpenRouterModel] {
        guard !apiKey.isEmpty else {
            throw OpenRouterError.invalidAPIKey
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)

        return modelsResponse.data.map { model in
            OpenRouterModel(
                id: model.id,
                name: model.name,
                description: model.description ?? "",
                contextLength: model.contextLength,
                promptPrice: model.pricing.prompt,
                completionPrice: model.pricing.completion
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
        guard !apiKey.isEmpty else {
            throw OpenRouterError.invalidAPIKey
        }

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
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        return try parseLLMResponse(content)
    }

    private func parseLLMResponse(_ content: String) throws -> LLMResult {
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

    private func extractManually(from content: String) throws -> LLMResult {
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
    let name: String
    let description: String?
    let contextLength: Int
    let pricing: ModelPricing

    enum CodingKeys: String, CodingKey {
        case id, name, description, pricing
        case contextLength = "context_length"
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
