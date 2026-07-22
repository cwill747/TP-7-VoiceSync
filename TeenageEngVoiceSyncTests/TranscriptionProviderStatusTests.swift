//
//  TranscriptionProviderStatusTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers TP-13: an unavailable transcription configuration (missing API key,
//  model not downloaded, mid-download) must be clearly distinguishable from
//  the fully active state, and from transcription simply being turned off.
//

import XCTest
@testable import TP_7_VoiceSync

final class TranscriptionProviderStatusTests: XCTestCase {

    func testElevenLabsWithoutKeyIsPausedNotActive() {
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .elevenLabs,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: true
        )

        XCTAssertEqual(status.readiness, .missingAPIKey)
        XCTAssertFalse(status.isEffectivelyActive)
        XCTAssertTrue(status.isBlocked)
        XCTAssertEqual(status.statusText, "Paused — API key required")
    }

    func testElevenLabsWithKeyIsActive() {
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .elevenLabs,
            preferenceEnabled: true,
            hasElevenLabsKey: true,
            localModelReady: true
        )

        XCTAssertEqual(status.readiness, .ready)
        XCTAssertTrue(status.isEffectivelyActive)
        XCTAssertFalse(status.isBlocked)
    }

    func testWhisperKitWithoutModelIsUnavailableNotActive() {
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .whisperKit,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: false
        )

        XCTAssertEqual(status.readiness, .modelNotDownloaded)
        XCTAssertFalse(status.isEffectivelyActive)
        XCTAssertTrue(status.isBlocked)
        XCTAssertEqual(status.statusText, "Unavailable — model not downloaded")
    }

    func testParakeetDuringModelDownloadIsUnavailableNotActive() {
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .parakeet,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: false,
            localModelDownloading: true
        )

        XCTAssertEqual(status.readiness, .downloadingModel)
        XCTAssertFalse(status.isEffectivelyActive)
        XCTAssertTrue(status.isBlocked)
        XCTAssertEqual(status.statusText, "Unavailable — downloading model")
    }

    func testParakeetUnifiedWithModelIsActive() {
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .parakeetUnified,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: true
        )

        XCTAssertEqual(status.readiness, .ready)
        XCTAssertTrue(status.isEffectivelyActive)
    }

    func testDisabledPreferenceIsNeverBlockedOrActive() {
        // Configured (API key present) but the user has the master toggle off.
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .elevenLabs,
            preferenceEnabled: false,
            hasElevenLabsKey: true,
            localModelReady: true
        )

        XCTAssertTrue(status.isDisabled)
        XCTAssertFalse(status.isEffectivelyActive)
        XCTAssertFalse(status.isBlocked)
        XCTAssertEqual(status.statusText, "Transcription off")
    }

    func testDisabledPreferenceWithMissingKeyIsStillJustDisabled() {
        // Enabled=false should never surface as "blocked" even if the
        // underlying config is also incomplete — disabled takes priority.
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .elevenLabs,
            preferenceEnabled: false,
            hasElevenLabsKey: false,
            localModelReady: true
        )

        XCTAssertFalse(status.isBlocked)
        XCTAssertEqual(status.statusText, "Transcription off")
    }
}
