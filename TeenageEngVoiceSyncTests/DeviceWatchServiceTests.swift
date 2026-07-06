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

    /// The exact scenario the escape prefix exists for: a /recordings file
    /// whose raw device name already looks like a qualified /memo name would,
    /// without escaping, map to the identical local filename as the real
    /// /memo file it collides with.
    func testRecordingsFilenameThatLooksLikeMemoIsEscaped() {
        let recordingsName = DeviceWatchService.localFilename(forDeviceFilename: "memo-0001.wav", folder: "recordings")
        let memoName = DeviceWatchService.localFilename(forDeviceFilename: "0001.wav", folder: "memo")
        XCTAssertNotEqual(recordingsName, memoName)
        XCTAssertEqual(recordingsName, "recordings-escaped-memo-0001.wav")
    }

    /// A /recordings file already named with the escape prefix itself must
    /// also be escaped, or it would collide with a genuine escaped name.
    func testRecordingsFilenameThatLooksLikeEscapedIsEscapedAgain() {
        let name = DeviceWatchService.localFilename(forDeviceFilename: "recordings-escaped-foo.wav", folder: "recordings")
        XCTAssertEqual(name, "recordings-escaped-recordings-escaped-foo.wav")
    }

    // MARK: - inferDeviceOrigin

    func testInferDeviceOriginRecognizesQualifiedMemoFilename() {
        let inferred = DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: "memo-0001.wav")
        XCTAssertEqual(inferred?.source, .memo)
        XCTAssertEqual(inferred?.deviceFilename, "0001.wav")
    }

    func testInferDeviceOriginRecognizesEscapedRecordingsFilename() {
        let inferred = DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: "recordings-escaped-memo-0001.wav")
        XCTAssertEqual(inferred?.source, .recordings)
        XCTAssertEqual(inferred?.deviceFilename, "memo-0001.wav")
    }

    func testInferDeviceOriginNilForUnqualifiedFilename() {
        XCTAssertNil(DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: "0001.wav"))
    }

    func testInferDeviceOriginRoundTripsLocalFilename() {
        // The whole point of the prefixes: whatever localFilename produces,
        // inferDeviceOrigin must be able to reverse - for both folders, and
        // for the escaped edge case.
        for (deviceFilename, folder) in [("0007.wav", "memo"), ("0007.wav", "recordings"), ("memo-0007.wav", "recordings")] {
            let qualified = DeviceWatchService.localFilename(forDeviceFilename: deviceFilename, folder: folder)
            if folder == "recordings" && qualified == deviceFilename {
                // Unescaped common case: no origin to infer, by design.
                XCTAssertNil(DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: qualified))
                continue
            }
            let inferred = DeviceWatchService.inferDeviceOrigin(fromPersistedFilename: qualified)
            XCTAssertEqual(inferred?.source.rawValue, folder)
            XCTAssertEqual(inferred?.deviceFilename, deviceFilename)
        }
    }
}
