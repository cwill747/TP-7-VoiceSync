//
//  OpenRouterServiceTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class OpenRouterServiceTests: XCTestCase {
    func testResolvedBaseURLUsesIPv4ForLocalhost() throws {
        let suiteName = "OpenRouterServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost:8088/v1/", forKey: OpenRouterService.baseURLKey)

        XCTAssertEqual(
            OpenRouterService.resolvedBaseURL(defaults: defaults),
            "http://127.0.0.1:8088/v1"
        )
    }

    func testLocalCompletionsAllowLongRunningInference() throws {
        let suiteName = "OpenRouterServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://127.0.0.1:8088/v1", forKey: OpenRouterService.baseURLKey)

        XCTAssertEqual(
            OpenRouterService.completionTimeout(defaults: defaults),
            OpenRouterService.localCompletionTimeout
        )
        XCTAssertEqual(OpenRouterService.localCompletionTimeout, 3600)
    }

    func testPrivateLanCompletionsAllowLongRunningInference() throws {
        let suiteName = "OpenRouterServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://192.168.100.44:8088/v1", forKey: OpenRouterService.baseURLKey)

        XCTAssertEqual(
            OpenRouterService.completionTimeout(defaults: defaults),
            OpenRouterService.localCompletionTimeout
        )
    }

    func testRemoteCompletionsKeepABoundedTimeout() throws {
        let suiteName = "OpenRouterServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            OpenRouterService.completionTimeout(defaults: defaults),
            OpenRouterService.remoteCompletionTimeout
        )
    }

    func testDecodesLlamaServerModelsResponse() throws {
        let response = """
        {
          "object": "list",
          "data": [{
            "id": "lmstudio-community/Llama-3.2-1B-Instruct-GGUF",
            "object": "model",
            "created": 1783540905,
            "owned_by": "llamacpp",
            "meta": { "n_ctx": 131072 }
          }]
        }
        """

        let models = try OpenRouterService.decodeModels(from: Data(response.utf8))

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "lmstudio-community/Llama-3.2-1B-Instruct-GGUF")
        XCTAssertEqual(models[0].name, models[0].id)
        XCTAssertEqual(models[0].contextLength, 131072)
        XCTAssertEqual(models[0].promptPrice, "0")
        XCTAssertEqual(models[0].completionPrice, "0")
    }

    func testDecodesOpenRouterModelsResponse() throws {
        let response = """
        {
          "data": [{
            "id": "openai/gpt-test",
            "name": "GPT Test",
            "description": "Test model",
            "context_length": 8192,
            "pricing": { "prompt": "0.1", "completion": "0.2" }
          }]
        }
        """

        let models = try OpenRouterService.decodeModels(from: Data(response.utf8))

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "GPT Test")
        XCTAssertEqual(models[0].contextLength, 8192)
        XCTAssertEqual(models[0].promptPrice, "0.1")
        XCTAssertEqual(models[0].completionPrice, "0.2")
    }

    func testSpeakerLabeledTranscriptAddsSpeakerPreservationInstructions() {
        let transcript = """
        Speaker 1: we should ship this tomorrow

        Speaker 2: yes after the build passes
        """

        let prompt = OpenRouterService.formattingPromptBody(transcription: transcript)

        XCTAssertTrue(prompt.contains("Preserve every speaker label exactly as written"))
        XCTAssertTrue(prompt.contains("Do NOT merge speaker turns"))
        XCTAssertTrue(prompt.contains("Clean only the spoken text after each speaker label"))
    }

    func testNamedSpeakerTranscriptAddsSpeakerPreservationInstructions() {
        let transcript = """
        Cameron: can you review the notion sync

        Alex: i will check the transcript cleanup
        """

        XCTAssertTrue(OpenRouterService.containsSpeakerLabels(transcript))
    }

    func testPlainTranscriptDoesNotAddSpeakerPreservationInstructions() {
        let transcript = "we should ship this tomorrow after the build passes"

        let prompt = OpenRouterService.formattingPromptBody(transcription: transcript)

        XCTAssertFalse(OpenRouterService.containsSpeakerLabels(transcript))
        XCTAssertFalse(prompt.contains("Preserve every speaker label exactly as written"))
    }

    func testCustomPromptStillGetsSpeakerPreservationInstructions() {
        let transcript = """
        SPEAKER_00: this is the first turn
        SPEAKER_01: this is the second turn
        """

        let prompt = OpenRouterService.formattingPromptBody(
            transcription: transcript,
            customPrompt: "Only fix punctuation."
        )

        XCTAssertTrue(prompt.hasPrefix("Only fix punctuation."))
        XCTAssertTrue(prompt.contains("Preserve every speaker label exactly as written"))
    }

    func testNonSpeakerColonLineDoesNotCountAsSpeakerTranscript() {
        let transcript = """
        Action items: review the build output and update the branch
        Notes: this should still be treated as ordinary prose
        """

        XCTAssertFalse(OpenRouterService.containsSpeakerLabels(transcript))
    }
}
