//
//  DeviceWatchServiceTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the /memo vs /recordings filename disambiguation: the TP-7
//  auto-numbers recordings independently per folder, so both can report the
//  same device filename (e.g. "0001.wav"). That name flows downstream into
//  Recording.filename, which SyncService treats as a unique, app-wide
//  identity (SwiftData uniqueness, S3 key, Notion/local-folder matching), so
//  a cross-folder collision there would silently drop or overwrite one of
//  the two recordings.
//

import XCTest
@testable import TP_7_VoiceSync

final class DeviceWatchServiceTests: XCTestCase {
    func testMemoFilenameIsQualified() {
        XCTAssertEqual(
            DeviceWatchService.localFilename(forDeviceFilename: "0001.wav", folder: "memo"),
            "memo-0001.wav"
        )
    }

    func testRecordingsFilenameIsUnqualified() {
        // /recordings is the only folder that existed before the /memo split,
        // so it must keep producing exactly the device's filename - changing it
        // would orphan already-synced recordings' S3/Notion state.
        XCTAssertEqual(
            DeviceWatchService.localFilename(forDeviceFilename: "0001.wav", folder: "recordings"),
            "0001.wav"
        )
    }

    func testIdenticalDeviceNamesResolveToDistinctLocalFilenames() {
        let recordingsName = DeviceWatchService.localFilename(forDeviceFilename: "0001.wav", folder: "recordings")
        let memoName = DeviceWatchService.localFilename(forDeviceFilename: "0001.wav", folder: "memo")
        XCTAssertNotEqual(recordingsName, memoName)
    }
}
