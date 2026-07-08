//
//  SecurityScopedBookmarkTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class SecurityScopedBookmarkTests: XCTestCase {
    private let key = "test.folderPath"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: "\(key).bookmark")
        super.tearDown()
    }

    func testSaveFolderSelectionPersistsPathAndBookmarkTogether() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp7-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let savedBookmark = SecurityScopedBookmark.saveFolderSelection(url: folder, key: key)

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), folder.path)
        XCTAssertTrue(savedBookmark)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "\(key).bookmark"))
    }
}
