//
//  OfflineModePendingWorkTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the pure "deferred remote work" predicates that drive offline mode:
//  which stages a recording still owes (needsS3Upload / remainingRemoteSteps)
//  and whether it's waiting on connectivity (hasPendingRemoteWork). These are
//  derived from the recording's fields + settings, with no schema/state, so
//  they can be exercised without the full pipeline.
//

import XCTest
import SwiftData
@testable import TP_7_VoiceSync

final class OfflineModePendingWorkTests: XCTestCase {
    /// The settings keys these predicates read; cleared before and after each test
    /// so cases don't leak into one another.
    private let keys = [
        "s3.enabled", "s3.bucket", "s3.backupAfterTranscription",
        "localaudio.enabled", "localaudio.folderPath",
        "openrouter.baseURL",
        "transcription.provider", "openrouter.enabled", "openrouter.model",
        "openrouter.formatEnabled", "openrouter.formatModel",
        "notion.enabled", "notion.databaseId",
        "markdown.enabled", "applenotes.enabled",
    ]

    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    private func clearKeys() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @MainActor
    private func makeRecording(status: TranscriptionStatus = .completed) throws -> Recording {
        let schema = Schema([Recording.self, Device.self, Person.self, VoiceSample.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let recording = Recording(filename: "REC001.wav", localPath: "/tmp/REC001.wav", fileSize: 1234, recordedAt: Date())
        recording.transcriptionStatus = status
        recording.transcriptionText = status == .completed ? "hello world" : nil
        context.insert(recording)
        return recording
    }

    // MARK: - needsS3Upload

    @MainActor
    func testCloudProviderNeedsS3WhenEnabledAndNotUploaded() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set("elevenLabs", forKey: "transcription.provider")

        let recording = try makeRecording()
        XCTAssertTrue(SyncService.needsS3Upload(recording))
    }

    @MainActor
    func testNoS3WhenAlreadyUploaded() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set("elevenLabs", forKey: "transcription.provider")

        let recording = try makeRecording()
        recording.s3Key = "recordings/REC001.wav"
        XCTAssertFalse(SyncService.needsS3Upload(recording))
    }

    @MainActor
    func testNoS3WhenS3Disabled() throws {
        UserDefaults.standard.set(false, forKey: "s3.enabled")
        let recording = try makeRecording()
        XCTAssertFalse(SyncService.needsS3Upload(recording))
    }

    @MainActor
    func testLocalStorageDoesNotPrecludeS3() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set(true, forKey: "localaudio.enabled")
        UserDefaults.standard.set("/tmp/audio", forKey: "localaudio.folderPath")

        let recording = try makeRecording()
        XCTAssertTrue(SyncService.needsS3Upload(recording), "S3 and local storage run independently, so enabling local storage no longer skips S3")
    }

    @MainActor
    func testLocalProviderUploadsWhenS3IsADestination() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set("parakeet", forKey: "transcription.provider")

        let recording = try makeRecording()
        XCTAssertTrue(SyncService.needsS3Upload(recording), "S3 is a destination triggered by Send to Destinations, not a local-ASR backup side effect")
    }

    // MARK: - remainingRemoteSteps

    @MainActor
    func testRemainingStepsCollectsAllEnabledPending() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set("elevenLabs", forKey: "transcription.provider")
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set("openai/gpt-4o-mini", forKey: "openrouter.model")
        UserDefaults.standard.set(true, forKey: "notion.enabled")
        UserDefaults.standard.set("db-123", forKey: "notion.databaseId")
        UserDefaults.standard.set(true, forKey: "markdown.enabled")

        let recording = try makeRecording()
        recording.localCopyPath = "/tmp/REC001.wav"
        XCTAssertEqual(SyncService.remainingRemoteSteps(for: recording), [.s3, .summary, .notion, .note])
    }

    @MainActor
    func testRemainingStepsEmptyWhenAllDone() throws {
        UserDefaults.standard.set(true, forKey: "s3.enabled")
        UserDefaults.standard.set("my-bucket", forKey: "s3.bucket")
        UserDefaults.standard.set("elevenLabs", forKey: "transcription.provider")
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set(true, forKey: "notion.enabled")
        UserDefaults.standard.set("db-123", forKey: "notion.databaseId")
        UserDefaults.standard.set(true, forKey: "applenotes.enabled")

        let recording = try makeRecording()
        recording.s3Key = "recordings/REC001.wav"
        recording.llmProcessedAt = Date()
        recording.notionPageCreatedAt = Date()
        recording.appleNoteCreatedAt = Date()

        XCTAssertTrue(SyncService.remainingRemoteSteps(for: recording).isEmpty)
    }

    @MainActor
    func testNotionSkippedWithoutDatabaseId() throws {
        UserDefaults.standard.set(true, forKey: "notion.enabled")
        UserDefaults.standard.set("", forKey: "notion.databaseId")

        let recording = try makeRecording()
        XCTAssertFalse(SyncService.remainingRemoteSteps(for: recording).contains(.notion))
    }

    // MARK: - hasPendingRemoteWork

    @MainActor
    func testPendingTranscriptionIsWaiting() throws {
        let recording = try makeRecording(status: .pending)
        XCTAssertTrue(SyncService.hasPendingRemoteWork(recording))
    }

    @MainActor
    func testCompletedWithRemainingDestinationStepIsNotWaiting() throws {
        UserDefaults.standard.set(true, forKey: "notion.enabled")
        UserDefaults.standard.set("db-123", forKey: "notion.databaseId")

        let recording = try makeRecording(status: .completed)
        XCTAssertFalse(SyncService.hasPendingRemoteWork(recording))
    }

    @MainActor
    func testCompletedWithRemainingLLMStepIsWaiting() throws {
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set("openai/gpt-4o-mini", forKey: "openrouter.model")

        let recording = try makeRecording(status: .completed)
        XCTAssertTrue(SyncService.hasPendingRemoteWork(recording))
    }

    @MainActor
    func testTitleStepPresentWhenModelSet() throws {
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set("some-model", forKey: "openrouter.model")

        let recording = try makeRecording(status: .completed)

        XCTAssertTrue(SyncService.remainingRemoteSteps(for: recording).contains(.summary))
    }

    @MainActor
    func testFormatStepPresentWhenModelSet() throws {
        UserDefaults.standard.set(true, forKey: "openrouter.formatEnabled")
        UserDefaults.standard.set("some-model", forKey: "openrouter.formatModel")

        let recording = try makeRecording(status: .completed)

        XCTAssertTrue(SyncService.remainingRemoteSteps(for: recording).contains(.format))
    }

    @MainActor
    func testManualSendDoesNotRequireNetworkForLocalEndpoint() throws {
        // A local (127.0.0.1) OpenAI-compatible endpoint runs without network,
        // so an outstanding title step shouldn't gate manual send on connectivity.
        UserDefaults.standard.set("http://127.0.0.1:8088/v1", forKey: "openrouter.baseURL")
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set("some-model", forKey: "openrouter.model")

        let recording = try makeRecording(status: .completed)

        XCTAssertFalse(SyncService.needsNetworkForManualSend(recording))
    }

    @MainActor
    func testManualSendRequiresNetworkForRemoteEndpoint() throws {
        // The default (OpenRouter) endpoint is remote, so an outstanding title
        // step should require connectivity for a manual send.
        UserDefaults.standard.set(true, forKey: "openrouter.enabled")
        UserDefaults.standard.set("some-model", forKey: "openrouter.model")

        let recording = try makeRecording(status: .completed)

        XCTAssertTrue(SyncService.needsNetworkForManualSend(recording))
    }

    @MainActor
    func testCompletedWithNothingEnabledIsNotWaiting() throws {
        let recording = try makeRecording(status: .completed)
        XCTAssertFalse(SyncService.hasPendingRemoteWork(recording))
    }

    @MainActor
    func testNoneStatusIsNotWaiting() throws {
        let recording = try makeRecording(status: .none)
        XCTAssertFalse(SyncService.hasPendingRemoteWork(recording))
    }

    @MainActor
    func testDeletedIsNotWaiting() throws {
        UserDefaults.standard.set(true, forKey: "notion.enabled")
        UserDefaults.standard.set("db-123", forKey: "notion.databaseId")

        let recording = try makeRecording(status: .completed)
        recording.deletedAt = Date()
        XCTAssertFalse(SyncService.hasPendingRemoteWork(recording))
    }
}
