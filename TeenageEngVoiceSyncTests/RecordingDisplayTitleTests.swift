//
//  RecordingDisplayTitleTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the human-readable title hierarchy (TP-9): generated title ->
//  date/time fallback, with the raw filename never used as the primary label.
//

import XCTest
@testable import TP_7_VoiceSync

final class RecordingDisplayTitleTests: XCTestCase {
    private func makeRecording(
        filename: String = "0001.wav",
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Recording {
        Recording(
            filename: filename,
            localPath: "/tmp/\(filename)",
            fileSize: 1234,
            recordedAt: recordedAt
        )
    }

    func testGeneratedTitleIsPrimaryLabel() {
        let recording = makeRecording()
        recording.llmTitle = "Weekly planning sync"

        XCTAssertTrue(recording.hasGeneratedTitle)
        XCTAssertEqual(recording.generatedTitle, "Weekly planning sync")
        XCTAssertEqual(recording.displayTitle, "Weekly planning sync")
    }

    func testGeneratedTitleIsTrimmed() {
        let recording = makeRecording()
        recording.llmTitle = "  Trimmed title \n"

        XCTAssertEqual(recording.displayTitle, "Trimmed title")
    }

    func testMissingTitleFallsBackToDateTimeNotFilename() {
        let recording = makeRecording(filename: "0001.wav")
        recording.llmTitle = nil

        XCTAssertFalse(recording.hasGeneratedTitle)
        XCTAssertNil(recording.generatedTitle)
        XCTAssertEqual(recording.displayTitle, recording.fallbackTitle)
        XCTAssertNotEqual(recording.displayTitle, recording.filename)
        // The raw filename must never leak into the primary label.
        XCTAssertFalse(recording.displayTitle.contains(".wav"))
    }

    func testWhitespaceOnlyTitleFallsBack() {
        let recording = makeRecording()
        recording.llmTitle = "   \n\t"

        XCTAssertFalse(recording.hasGeneratedTitle)
        XCTAssertEqual(recording.displayTitle, recording.fallbackTitle)
    }

    func testFallbackTitleIsStableForSameRecordedAt() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeRecording(filename: "0001.wav", recordedAt: date)
        let b = makeRecording(filename: "memo-0002.wav", recordedAt: date)

        // Same recorded time -> same stable fallback, independent of filename.
        XCTAssertEqual(a.fallbackTitle, b.fallbackTitle)
        XCTAssertFalse(a.fallbackTitle.isEmpty)
    }

    func testFilenameRemainsDiscoverable() {
        // Even when the display title is the fallback, the original filename is
        // still stored on the model (surfaced in the detail view).
        let recording = makeRecording(filename: "memo-0007.wav")
        recording.llmTitle = nil

        XCTAssertEqual(recording.filename, "memo-0007.wav")
    }
}
