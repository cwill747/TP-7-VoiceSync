//
//  ShortRecordingSkipTests.swift
//  TeenageEngVoiceSyncTests
//
//  TP-21: recordings under the minimum duration are almost always accidental
//  button presses, so they should never be sent for transcription/summary.
//

import XCTest
import SwiftData
@testable import TP_7_VoiceSync

final class ShortRecordingSkipTests: XCTestCase {
    private func makeRecording(duration: TimeInterval?) -> Recording {
        let recording = Recording(filename: "REC001.wav", localPath: "/tmp/REC001.wav", fileSize: 1234, recordedAt: Date())
        recording.duration = duration
        return recording
    }

    func testZeroSecondRecordingIsTooShort() {
        XCTAssertTrue(SyncService.isTooShortToTranscribe(makeRecording(duration: 0)))
    }

    func testOneSecondRecordingIsTooShort() {
        XCTAssertTrue(SyncService.isTooShortToTranscribe(makeRecording(duration: 1)))
    }

    func testJustUnderMinimumIsTooShort() {
        let duration = SyncService.minimumDurationForTranscription - 0.01
        XCTAssertTrue(SyncService.isTooShortToTranscribe(makeRecording(duration: duration)))
    }

    func testAtMinimumIsNotTooShort() {
        XCTAssertFalse(SyncService.isTooShortToTranscribe(makeRecording(duration: SyncService.minimumDurationForTranscription)))
    }

    func testNormalLengthRecordingIsNotTooShort() {
        XCTAssertFalse(SyncService.isTooShortToTranscribe(makeRecording(duration: 45)))
    }

    func testUnknownDurationIsNotTooShort() {
        // Duration is only populated after WAV parsing succeeds; treat unknown
        // as "don't skip" so a parse failure can't silently drop a real memo.
        XCTAssertFalse(SyncService.isTooShortToTranscribe(makeRecording(duration: nil)))
    }
}
