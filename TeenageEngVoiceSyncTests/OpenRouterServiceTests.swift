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

    func testShortSummaryTranscriptDoesNotChunk() {
        let transcript = "Quick note about the build."

        XCTAssertFalse(OpenRouterService.shouldChunkSummary(transcription: transcript))
        XCTAssertEqual(OpenRouterService.chunkTranscription(transcript, targetSize: 100), [transcript])
    }

    func testLongSummaryTranscriptSplitsOnParagraphBoundary() {
        let first = String(repeating: "First paragraph sentence. ", count: 3)
        let second = String(repeating: "Second paragraph sentence. ", count: 3)
        let transcript = first + "\n\n" + second

        let chunks = OpenRouterService.chunkTranscription(transcript, targetSize: first.count + 4, overlap: 10)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasSuffix("\n\n"))
        XCTAssertTrue(chunks[1].hasPrefix("Second paragraph"))
        XCTAssertEqual(chunks.joined(), transcript)
    }

    func testLongSummaryTranscriptHardSplitsSingleParagraph() {
        let transcript = String(repeating: "abcdefghij", count: 4)

        let chunks = OpenRouterService.chunkTranscription(transcript, targetSize: 12, overlap: 3)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count == 12 })
        XCTAssertEqual(reconstructOverlappedChunks(chunks), transcript)
    }

    func testSummaryChunkOverlapOnlyAppliesToForcedSplits() {
        let paragraphTranscript = String(repeating: "first paragraph ", count: 3)
            + "\n\n"
            + String(repeating: "second paragraph ", count: 3)
        let paragraphChunks = OpenRouterService.chunkTranscription(
            paragraphTranscript,
            targetSize: 52,
            overlap: 8
        )

        XCTAssertEqual(paragraphChunks.joined(), paragraphTranscript)

        let forcedTranscript = String(repeating: "abcdefghij", count: 3)
        let forcedChunks = OpenRouterService.chunkTranscription(
            forcedTranscript,
            targetSize: 12,
            overlap: 4
        )

        XCTAssertGreaterThan(forcedChunks.count, 1)
        XCTAssertEqual(String(forcedChunks[0].suffix(4)), String(forcedChunks[1].prefix(4)))
        XCTAssertEqual(reconstructOverlappedChunks(forcedChunks), forcedTranscript)
    }

    func testLongFormattingTranscriptUsesNonOverlappingChunks() {
        let transcript = String(repeating: "abcdefghij", count: 700)

        XCTAssertFalse(OpenRouterService.shouldChunkFormatting(transcription: String(transcript.prefix(100))))
        XCTAssertTrue(OpenRouterService.shouldChunkFormatting(transcription: transcript + transcript))

        let chunks = OpenRouterService.formattingChunks(for: transcript)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, OpenRouterService.formatChunkTargetSize)
        XCTAssertEqual(chunks.joined(), transcript)
    }

    func testFormattingChunksPreferParagraphBoundary() {
        let first = String(repeating: "First chunk sentence. ", count: 160)
        let second = String(repeating: "Second chunk sentence. ", count: 100)
        let transcript = first + "\n\n" + second

        let chunks = OpenRouterService.chunkTranscription(
            transcript,
            targetSize: first.count + 8,
            overlap: 0
        )

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.joined(), transcript)
        XCTAssertTrue(chunks[0].hasSuffix("\n\n"))
        XCTAssertTrue(chunks[1].hasPrefix("Second chunk"))
    }

    func testMergeFormattedChunksTrimsAndSeparatesChunks() {
        let merged = OpenRouterService.mergeFormattedChunks([
            "\n First cleaned paragraph. \n",
            "  ",
            "Second cleaned paragraph.\n"
        ])

        XCTAssertEqual(merged, "First cleaned paragraph.\n\nSecond cleaned paragraph.")
    }

    func testMergeFormattedChunksRejoinsSeamsTheWayTheyWereSplit() {
        let paragraphSeam = OpenRouterService.mergeFormattedChunks(
            ["First cleaned paragraph.", "Second cleaned paragraph."],
            rawChunks: ["first raw paragraph\n\n", "second raw paragraph"]
        )
        XCTAssertEqual(paragraphSeam, "First cleaned paragraph.\n\nSecond cleaned paragraph.")

        let lineSeam = OpenRouterService.mergeFormattedChunks(
            ["First cleaned line.", "Second cleaned line."],
            rawChunks: ["first raw line\n", "second raw line"]
        )
        XCTAssertEqual(lineSeam, "First cleaned line.\nSecond cleaned line.")

        // A mid-paragraph sentence split must not become a paragraph break.
        let sentenceSeam = OpenRouterService.mergeFormattedChunks(
            ["One thought ends.", "Another begins."],
            rawChunks: ["one thought ends. ", "another begins"]
        )
        XCTAssertEqual(sentenceSeam, "One thought ends. Another begins.")
    }

    func testMergeFormattedChunksDoesNotSplitAWordAcrossAForcedSeam() {
        let merged = OpenRouterService.mergeFormattedChunks(
            ["I was consi", "dering the build."],
            rawChunks: ["i was consi", "dering the build"]
        )

        XCTAssertEqual(merged, "I was considering the build.")
    }

    func testChunkPlanDerivesThresholdsFromContextLength() {
        let large = OpenRouterService.chunkPlan(contextLength: 128_000)
        XCTAssertGreaterThan(large.summaryThreshold, OpenRouterService.summaryChunkThreshold)
        XCTAssertGreaterThan(large.formatThreshold, OpenRouterService.formatChunkThreshold)
        XCTAssertLessThan(large.summaryTargetSize, large.summaryThreshold)
        XCTAssertLessThan(large.formatTargetSize, large.formatThreshold)

        // A small local context has to chunk earlier than the static default.
        let small = OpenRouterService.chunkPlan(contextLength: 4_096)
        XCTAssertLessThan(small.summaryThreshold, OpenRouterService.summaryChunkThreshold)
        XCTAssertGreaterThanOrEqual(small.summaryThreshold, OpenRouterService.minimumChunkThreshold)

        // An endpoint that reports nothing keeps the static fallbacks.
        XCTAssertEqual(OpenRouterService.chunkPlan(contextLength: 0), OpenRouterService.fallbackChunkPlan)
    }

    func testNoteBatchesGroupNotesUnderTheBudget() {
        let notes = (0..<6).map { OpenRouterService.ChunkNote(index: $0, text: String(repeating: "x", count: 100)) }

        let batches = OpenRouterService.noteBatches(notes, budget: 250)

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }, notes)
        for batch in batches where batch.count > 1 {
            XCTAssertLessThanOrEqual(OpenRouterService.renderNotes(batch).count, 250)
        }
    }

    func testStripPreambleRemovesModelCommentaryButKeepsTranscriptContent() {
        XCTAssertEqual(
            OpenRouterService.stripPreamble("Here is the cleaned chunk:\nthe actual words"),
            "the actual words"
        )

        // A real heading or speaker label at the top of a chunk must survive.
        let heading = "Action items:\n- ship the build\n- email Dana"
        XCTAssertEqual(OpenRouterService.stripPreamble(heading), heading)

        let speakerTurn = "Alex:\nI will check the transcript cleanup"
        XCTAssertEqual(OpenRouterService.stripPreamble(speakerTurn), speakerTurn)
    }

    func testChunkedFormattingKeepsSpeakerInstructionsForLabelFreeChunks() {
        // A chunk taken from the middle of one long turn carries no label of its
        // own, but the transcript it came from does.
        let chunk = "and then we decided to ship it on friday after the build passed"

        XCTAssertFalse(OpenRouterService.containsSpeakerLabels(chunk))

        let prompt = OpenRouterService.formattingPromptBody(
            transcription: chunk,
            speakerLabelsPresent: true
        )

        XCTAssertTrue(prompt.contains("Preserve every speaker label exactly as written"))
    }

    func testRetryClassificationSeparatesTransientFromPermanentFailures() {
        XCTAssertTrue(OpenRouterService.isRetryable(OpenRouterError.apiError(statusCode: 429)))
        XCTAssertTrue(OpenRouterService.isRetryable(OpenRouterError.apiError(statusCode: 503)))
        XCTAssertTrue(OpenRouterService.isRetryable(OpenRouterError.transport("timed out")))
        XCTAssertTrue(OpenRouterService.isRetryable(OpenRouterError.responseTruncated))
        XCTAssertTrue(OpenRouterService.isRetryable(URLError(.timedOut)))

        XCTAssertFalse(OpenRouterService.isRetryable(OpenRouterError.invalidAPIKey))
        XCTAssertFalse(OpenRouterService.isRetryable(OpenRouterError.apiError(statusCode: 400)))
        XCTAssertFalse(OpenRouterService.isRetryable(OpenRouterError.parseError("bad json")))
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

    private func reconstructOverlappedChunks(_ chunks: [String]) -> String {
        guard var result = chunks.first else { return "" }

        for chunk in chunks.dropFirst() {
            let overlap = largestOverlapSuffixPrefix(result, chunk)
            result += chunk.dropFirst(overlap)
        }

        return result
    }

    private func largestOverlapSuffixPrefix(_ left: String, _ right: String) -> Int {
        let maxLength = min(left.count, right.count)
        guard maxLength > 0 else { return 0 }

        for length in stride(from: maxLength, through: 1, by: -1) {
            if left.suffix(length) == right.prefix(length) {
                return length
            }
        }
        return 0
    }
}
