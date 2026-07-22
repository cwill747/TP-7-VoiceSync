//
//  TranscriptionProviderStatusTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers TP-13: a genuinely blocked transcription configuration (missing
//  API key) must be clearly distinguishable from the fully active state and
//  from transcription simply being turned off. Local engines (WhisperKit/
//  Parakeet/ParakeetUnified) download their model on demand on first use, so
//  a missing/downloading model is informational only — it must NOT read as
//  blocked or disable dependent features (see PR #65 review).
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

    func testWhisperKitWithoutModelIsStillActiveViaAutoDownload() {
        // WhisperKit falls back to `WhisperKitConfig(download: true)` when no
        // model is cached, so it will still transcribe (just slower on the
        // first recording) — it must not be treated as blocked.
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .whisperKit,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: false
        )

        XCTAssertEqual(status.readiness, .modelNotDownloaded)
        XCTAssertTrue(status.isEffectivelyActive)
        XCTAssertFalse(status.isBlocked)
        XCTAssertEqual(status.statusText, "WhisperKit active — model downloads on first use")
    }

    func testParakeetDuringModelDownloadIsStillActive() {
        // A user-initiated download in progress doesn't block transcription
        // either — ParakeetService.loadAsrModels() downloads on demand too.
        let status = TranscriptionProviderStatus.evaluate(
            providerKind: .parakeet,
            preferenceEnabled: true,
            hasElevenLabsKey: false,
            localModelReady: false,
            localModelDownloading: true
        )

        XCTAssertEqual(status.readiness, .downloadingModel)
        XCTAssertTrue(status.isEffectivelyActive)
        XCTAssertFalse(status.isBlocked)
        XCTAssertEqual(status.statusText, "Parakeet active — downloading model")
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

    func testOnlyMissingAPIKeyIsEverBlocking() {
        let allReadinessCases: [TranscriptionReadiness] = [.ready, .missingAPIKey, .modelNotDownloaded, .downloadingModel]
        for readiness in allReadinessCases {
            let status = TranscriptionProviderStatus(providerKind: .whisperKit, preferenceEnabled: true, readiness: readiness)
            XCTAssertEqual(status.isBlocked, readiness == .missingAPIKey, "readiness \(readiness) should only block when missingAPIKey")
        }
    }
}
