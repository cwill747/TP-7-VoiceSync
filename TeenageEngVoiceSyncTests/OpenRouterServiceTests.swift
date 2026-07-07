//
//  OpenRouterServiceTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class OpenRouterServiceTests: XCTestCase {
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
