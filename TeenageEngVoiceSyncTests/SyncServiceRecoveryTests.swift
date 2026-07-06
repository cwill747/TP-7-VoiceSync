//
//  SyncServiceRecoveryTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the recovery/adoption dedup logic: a Recording row restored from a
//  remote source (e.g. Notion-only, no local audio) must be adopted by
//  createRecording rather than duplicated when the device file later shows
//  up, since Recording.filename is a unique SwiftData attribute.
//

import XCTest
import SwiftData
@testable import TP_7_VoiceSync

final class SyncServiceRecoveryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncServiceRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Recording.self, Device.self, Person.self, VoiceSample.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func writeDeviceFile(named filename: String) -> URL {
        let url = tempDirectory.appendingPathComponent(filename)
        try! makeWAVData(numSamples: 4410).write(to: url)
        return url
    }

    // MARK: - hasAudioSource

    func testHasAudioSourceTrueWhenS3KeySet() {
        let recording = Recording(filename: "a.wav", localPath: "", fileSize: 0, recordedAt: .now)
        recording.s3Key = "recordings/a.wav"
        XCTAssertTrue(SyncService.hasAudioSource(recording))
    }

    func testHasAudioSourceFalseWhenNoFilesAndNoS3Key() {
        let recording = Recording(filename: "b.wav", localPath: "", fileSize: 0, recordedAt: .now)
        XCTAssertFalse(SyncService.hasAudioSource(recording))
    }

    func testHasAudioSourceTrueWhenLocalCopyExists() throws {
        let url = writeDeviceFile(named: "c.wav")
        let recording = Recording(filename: "c.wav", localPath: "", fileSize: 0, recordedAt: .now)
        recording.localCopyPath = url.path
        XCTAssertTrue(SyncService.hasAudioSource(recording))
    }

    func testHasAudioSourceFalseWhenLocalCopyPathIsStale() {
        let recording = Recording(filename: "d.wav", localPath: "", fileSize: 0, recordedAt: .now)
        recording.localCopyPath = tempDirectory.appendingPathComponent("missing.wav").path
        XCTAssertFalse(SyncService.hasAudioSource(recording))
    }

    // MARK: - forceSingleSpeaker

    func testForceSingleSpeakerTrueForMemoFolder() {
        let recording = Recording(filename: "memo.wav", localPath: "", fileSize: 0, recordedAt: .now)
        recording.sourceFolder = .memo
        XCTAssertTrue(SyncService.forceSingleSpeaker(for: recording))
    }

    func testForceSingleSpeakerFalseForRecordingsFolder() {
        // /recordings can capture other speakers (interviews, meetings), so it
        // must go through normal diarization, unlike /memo.
        let recording = Recording(filename: "session.wav", localPath: "", fileSize: 0, recordedAt: .now)
        recording.sourceFolder = .recordings
        XCTAssertFalse(SyncService.forceSingleSpeaker(for: recording))
    }

    func testForceSingleSpeakerFalseWhenSourceUnknown() {
        // Recovered rows (S3/Notion/local-folder) have no device origin at all.
        let recording = Recording(filename: "recovered.wav", localPath: "", fileSize: 0, recordedAt: .now)
        XCTAssertFalse(SyncService.forceSingleSpeaker(for: recording))
    }

    // MARK: - createRecording adoption

    @MainActor
    func testCreateRecordingAdoptsAudiolessRecoveredRow() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        // Simulate a Notion-only recovered row: has a transcript but no audio.
        let recoveredDate = Date(timeIntervalSince1970: 1_700_000_000)
        let recovered = Recording(filename: "session01.wav", localPath: "", fileSize: 0, recordedAt: recoveredDate)
        recovered.transcriptionStatus = .completed
        recovered.transcriptionText = "hello from notion"
        context.insert(recovered)
        try context.save()

        let deviceFileURL = writeDeviceFile(named: "session01.wav")
        let result = try await sync.createRecording(from: deviceFileURL)

        // Adopted, not duplicated.
        let allRecordings = try context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(allRecordings.count, 1)

        XCTAssertEqual(result.filename, "session01.wav")
        XCTAssertEqual(result.localPath, deviceFileURL.path)
        XCTAssertEqual(result.transcriptionStatus, .completed)
        XCTAssertEqual(result.transcriptionText, "hello from notion")
        // The recovered recordedAt (from Notion) is kept, not the device file's mtime.
        XCTAssertEqual(result.recordedAt, recoveredDate)
        XCTAssertNotNil(result.fileHash)
    }

    @MainActor
    func testCreateRecordingInsertsNewRowWhenNoExistingRecord() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        let deviceFileURL = writeDeviceFile(named: "session02.wav")
        _ = try await sync.createRecording(from: deviceFileURL)

        let allRecordings = try context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(allRecordings.count, 1)
        XCTAssertEqual(allRecordings[0].filename, "session02.wav")
        XCTAssertEqual(allRecordings[0].sampleRate, 44100)
    }

    // MARK: - createRecording sourceFolder tagging

    @MainActor
    func testCreateRecordingTagsSourceFolderFromPendingDownload() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        // The local filename is already the disambiguated one DeviceWatchService
        // would have produced (see DeviceWatchServiceTests) - createRecording
        // itself just needs to tag the row with the origin it's told about.
        let deviceFileURL = writeDeviceFile(named: "memo-0001.wav")
        sync.pendingRecordingOrigins[deviceFileURL.path] = PendingRecordingOrigin(source: .memo, deviceFilename: "0001.wav")

        let result = try await sync.createRecording(from: deviceFileURL)

        XCTAssertEqual(result.sourceFolder, .memo)
        XCTAssertEqual(result.deviceFilename, "0001.wav")
        // Consumed, not left behind for a later unrelated call to pick up.
        XCTAssertNil(sync.pendingRecordingOrigins[deviceFileURL.path])
    }

    @MainActor
    func testCreateRecordingLeavesSourceFolderNilWithoutPendingEntry() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        let deviceFileURL = writeDeviceFile(named: "recovered.wav")
        let result = try await sync.createRecording(from: deviceFileURL)

        XCTAssertNil(result.sourceFolder)
        XCTAssertNil(result.deviceFilename)
    }

    /// The TP-7 auto-numbers recordings independently per folder, so /recordings
    /// and /memo can both report "0001.wav". DeviceWatchService disambiguates the
    /// /memo copy's local filename before it ever reaches createRecording (see
    /// DeviceWatchServiceTests) - this confirms createRecording then treats them
    /// as two distinct rows instead of one silently shadowing the other via the
    /// unique `filename` attribute.
    @MainActor
    func testCreateRecordingKeepsBothFoldersDistinctOnNameCollision() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        let recordingsFileURL = writeDeviceFile(named: "0001.wav")
        sync.pendingRecordingOrigins[recordingsFileURL.path] = PendingRecordingOrigin(source: .recordings, deviceFilename: "0001.wav")
        let recordingsResult = try await sync.createRecording(from: recordingsFileURL)

        let memoFileURL = writeDeviceFile(named: "memo-0001.wav")
        sync.pendingRecordingOrigins[memoFileURL.path] = PendingRecordingOrigin(source: .memo, deviceFilename: "0001.wav")
        let memoResult = try await sync.createRecording(from: memoFileURL)

        let allRecordings = try context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(allRecordings.count, 2)

        XCTAssertEqual(recordingsResult.sourceFolder, .recordings)
        XCTAssertEqual(recordingsResult.deviceFilename, "0001.wav")
        XCTAssertEqual(memoResult.sourceFolder, .memo)
        XCTAssertEqual(memoResult.deviceFilename, "0001.wav")
        // Both report the same literal on-device name, but distinct app identities.
        XCTAssertNotEqual(recordingsResult.filename, memoResult.filename)
    }

    @MainActor
    func testCreateRecordingSkipsAdoptionWhenExistingAlreadyHasAudio() async throws {
        let context = try makeContext()
        let sync = SyncService(modelContext: context)

        let existingAudioURL = writeDeviceFile(named: "already-has-audio.wav")
        let existing = Recording(filename: "session03.wav", localPath: existingAudioURL.path, fileSize: 123, recordedAt: .now)
        context.insert(existing)
        try context.save()

        let deviceFileURL = writeDeviceFile(named: "session03.wav")
        let result = try await sync.createRecording(from: deviceFileURL)

        // Not an adoption: the existing row already had audio, so this call
        // re-saves the same row (still one row) without overwriting its
        // original localPath — only a non-adoption's fileHash gets refreshed.
        let allRecordings = try context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(allRecordings.count, 1)
        XCTAssertEqual(result.localPath, existingAudioURL.path)
        XCTAssertNotNil(result.fileHash)
    }
}
