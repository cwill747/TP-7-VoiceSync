//
//  TranscriptionService.swift
//  TeenageEngVoiceSync
//
//  ElevenLabs speech-to-text API client.
//

import Foundation

actor TranscriptionService {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    private let modelID: String
    private let session: URLSession

    /// Available transcription models
    static let availableModels: [(id: String, name: String)] = [
        ("scribe_v1", "Scribe v1")
    ]

    init(apiKey: String, modelID: String = "scribe_v1") {
        self.apiKey = apiKey
        self.modelID = modelID

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // Transcription can take time
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Validate an ElevenLabs API key by making a test request to the user endpoint
    static func validateAPIKey(_ apiKey: String) async throws {
        guard !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw TranscriptionError.apiError(
                statusCode: httpResponse.statusCode,
                message: "Invalid API key"
            )
        }
    }

    /// Transcribe audio from a cloud storage URL (e.g., S3 presigned URL)
    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult {
        let url = baseURL.appendingPathComponent("speech-to-text")

        // Create multipart form data
        let boundary = UUID().uuidString
        var body = Data()

        // Add model_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(modelID)\r\n".data(using: .utf8)!)

        // Add cloud_storage_url field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"cloud_storage_url\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(cloudStorageURL)\r\n".data(using: .utf8)!)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Execute request
        let (data, response) = try await session.data(for: request)

        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        // Parse response
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TranscriptionResult.self, from: data)
    }
}

struct TranscriptionResult: Codable, Sendable {
    let text: String
    let languageCode: String
    let languageProbability: Double?
    let transcriptionId: String?
    let words: [TranscriptionWord]?
}

struct TranscriptionWord: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let type: String?
    let logprob: Double?
}

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from transcription service"
        case .apiError(let statusCode, let message):
            return "Transcription API error (\(statusCode)): \(message)"
        case .noAPIKey:
            return "ElevenLabs API key not configured"
        }
    }
}
