//
//  LocalGGUFService.swift
//  TeenageEngVoiceSync
//
//  Local transcript enhancement via llama.cpp's OpenAI-compatible llama-server.
//

import Foundation

nonisolated enum AIEnhancementBackend: String, CaseIterable, Identifiable {
    case openRouter
    case localGGUF

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .localGGUF: return "Local GGUF"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> AIEnhancementBackend {
        AIEnhancementBackend(rawValue: defaults.string(forKey: "aiEnhancement.backend") ?? "") ?? .openRouter
    }
}

actor LocalGGUFService {
    static let serverPathKey = "localgguf.serverPath"
    static let modelPathKey = "localgguf.modelPath"
    static let portKey = "localgguf.port"
    static let contextTokensKey = "localgguf.contextTokens"

    private var process: Process?
    private var runningConfiguration: RuntimeConfiguration?
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    nonisolated static func isConfigured(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.string(forKey: serverPathKey) ?? "").isEmpty
            && !(defaults.string(forKey: modelPathKey) ?? "").isEmpty
    }

    func generateTitleAndSummary(transcription: String, customPrompt: String? = nil) async throws -> LLMResult {
        guard !transcription.isEmpty else { throw LocalGGUFError.emptyTranscription }

        let promptTemplate = (customPrompt?.isEmpty == false) ? customPrompt! : OpenRouterService.defaultPrompt
        let prompt = """
        \(promptTemplate)

        Transcription:
        \(transcription)
        """
        let content = try await chatCompletion(prompt: prompt, temperature: 0.3, maxTokens: 512)
        return try OpenRouterService.parseLLMResponse(content)
    }

    func formatTranscription(
        transcription: String,
        customPrompt: String? = nil,
        options: TranscriptFormatOptions = TranscriptFormatOptions()
    ) async throws -> String {
        guard !transcription.isEmpty else { throw LocalGGUFError.emptyTranscription }

        let promptBody = OpenRouterService.formattingPromptBody(
            transcription: transcription,
            customPrompt: customPrompt,
            options: options
        )
        let prompt = """
        \(promptBody)

        Transcription:
        \(transcription)
        """
        let content = try await chatCompletion(prompt: prompt, temperature: 0.2, maxTokens: 4096)
        return OpenRouterService.stripPreamble(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func chatCompletion(prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        let configuration = try RuntimeConfiguration.current()
        try await ensureServer(configuration)

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LocalChatCompletionRequest(
                model: "local-gguf",
                messages: [LocalChatMessage(role: "user", content: prompt)],
                temperature: temperature,
                maxTokens: maxTokens,
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalGGUFError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LocalGGUFError.apiError(statusCode: httpResponse.statusCode)
        }

        let completion = try JSONDecoder().decode(LocalChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content, !content.isEmpty else {
            throw LocalGGUFError.noContent
        }
        return content
    }

    private func ensureServer(_ configuration: RuntimeConfiguration) async throws {
        if let process, process.isRunning, runningConfiguration == configuration,
           await isHealthy(baseURL: configuration.baseURL) {
            return
        }

        stopServer()
        try startServer(configuration)
        try await waitUntilHealthy(configuration)
    }

    private func startServer(_ configuration: RuntimeConfiguration) throws {
        let process = Process()
        process.executableURL = configuration.serverURL
        process.arguments = [
            "--model", configuration.modelURL.path,
            "--host", "127.0.0.1",
            "--port", "\(configuration.port)",
            "--ctx-size", "\(configuration.contextTokens)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LocalGGUFError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.runningConfiguration = configuration
    }

    private func waitUntilHealthy(_ configuration: RuntimeConfiguration) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if process?.isRunning == false {
                throw LocalGGUFError.serverExited
            }
            if await isHealthy(baseURL: configuration.baseURL) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LocalGGUFError.startupTimedOut
    }

    private func isHealthy(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func stopServer() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        self.runningConfiguration = nil
    }
}

private struct RuntimeConfiguration: Equatable {
    let serverURL: URL
    let modelURL: URL
    let port: Int
    let contextTokens: Int

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    static func current(defaults: UserDefaults = .standard) throws -> RuntimeConfiguration {
        guard let serverURL = bookmarkedURL(key: LocalGGUFService.serverPathKey),
              FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            throw LocalGGUFError.missingServer
        }
        guard let modelURL = bookmarkedURL(key: LocalGGUFService.modelPathKey),
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalGGUFError.missingModel
        }

        let storedPort = defaults.integer(forKey: LocalGGUFService.portKey)
        let port = storedPort == 0 ? 8088 : storedPort
        let storedContext = defaults.integer(forKey: LocalGGUFService.contextTokensKey)
        let contextTokens = storedContext == 0 ? 8192 : max(1024, storedContext)

        return RuntimeConfiguration(
            serverURL: serverURL,
            modelURL: modelURL,
            port: port,
            contextTokens: contextTokens
        )
    }

    private static func bookmarkedURL(key: String) -> URL? {
        if let url = SecurityScopedBookmark.resolve(key: key) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }

        let path = UserDefaults.standard.string(forKey: key) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
}

private nonisolated struct LocalChatCompletionRequest: Codable {
    let model: String
    let messages: [LocalChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}

private nonisolated struct LocalChatMessage: Codable {
    let role: String
    let content: String
}

private nonisolated struct LocalChatCompletionResponse: Codable {
    let choices: [LocalChoice]
}

private nonisolated struct LocalChoice: Codable {
    let message: LocalResponseMessage
}

private nonisolated struct LocalResponseMessage: Codable {
    let content: String
}

nonisolated enum LocalGGUFError: LocalizedError {
    case missingServer
    case missingModel
    case launchFailed(String)
    case startupTimedOut
    case serverExited
    case invalidResponse
    case apiError(statusCode: Int)
    case noContent
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .missingServer:
            return "llama-server executable is not configured or is not executable"
        case .missingModel:
            return "GGUF model file is not configured or no longer exists"
        case .launchFailed(let message):
            return "Failed to launch llama-server: \(message)"
        case .startupTimedOut:
            return "Timed out waiting for llama-server to become ready"
        case .serverExited:
            return "llama-server exited before it was ready"
        case .invalidResponse:
            return "Invalid response from local llama-server"
        case .apiError(let statusCode):
            return "Local llama-server API error (status code: \(statusCode))"
        case .noContent:
            return "No content in local llama-server response"
        case .emptyTranscription:
            return "Transcription is empty"
        }
    }
}

private extension FileHandle {
    static var nullDevice: FileHandle? {
        FileHandle(forWritingAtPath: "/dev/null")
    }
}
