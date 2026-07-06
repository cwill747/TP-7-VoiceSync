//
//  SyncServiceLinkExpiryTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class SyncServiceLinkExpiryTests: XCTestCase {
    func testParsesDaysHoursMinutes() {
        XCTAssertEqual(SyncService.parseLinkExpiry("2d"), 2 * 24 * 3600)
        XCTAssertEqual(SyncService.parseLinkExpiry("3h"), 3 * 3600)
        XCTAssertEqual(SyncService.parseLinkExpiry("45m"), 45 * 60)
    }

    func testGarbageInputFallsBackToSevenDays() {
        let sevenDays: TimeInterval = 7 * 24 * 3600
        XCTAssertEqual(SyncService.parseLinkExpiry("garbage"), sevenDays)
        XCTAssertEqual(SyncService.parseLinkExpiry(""), sevenDays)
        XCTAssertEqual(SyncService.parseLinkExpiry("d"), sevenDays)
    }

    func testUnknownUnitFallsBackToSevenDays() {
        // Numeric value parses fine, but "x" isn't a recognized unit.
        XCTAssertEqual(SyncService.parseLinkExpiry("5x"), 7 * 24 * 3600)
    }

    func testClampsBelowMinimum() {
        XCTAssertEqual(SyncService.parseLinkExpiry("0d"), 60)
        XCTAssertEqual(SyncService.parseLinkExpiry("0m"), 60)
    }

    func testClampsAboveSigV4Maximum() {
        XCTAssertEqual(SyncService.parseLinkExpiry("100d"), 604_800)
        XCTAssertEqual(SyncService.parseLinkExpiry("999h"), 604_800)
    }
}
