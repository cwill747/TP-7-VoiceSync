//
//  KeychainServiceKeyTests.swift
//  TeenageEngVoiceSyncTests
//
//  KeychainService.Key.rawValue is the Keychain account identifier for a
//  stored credential — changing one silently orphans whatever secret a user
//  already saved under the old value. These pin the current identifiers so
//  such a change is a deliberate, visible diff rather than an accident.
//

import XCTest
@testable import TP_7_VoiceSync

final class KeychainServiceKeyTests: XCTestCase {
    func testAllCasesHaveUniqueRawValues() {
        let rawValues = KeychainService.Key.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "Key raw values must be unique to avoid Keychain collisions")
    }

    func testExpectedCasesArePresent() {
        XCTAssertEqual(KeychainService.Key.allCases.count, 6)
    }

    func testRawValuesArePinned() {
        XCTAssertEqual(KeychainService.Key.elevenLabsAPIKey.rawValue, "com.tp7sync.elevenlabs.apikey")
        XCTAssertEqual(KeychainService.Key.awsAccessKeyId.rawValue, "com.tp7sync.aws.accesskeyid")
        XCTAssertEqual(KeychainService.Key.awsSecretAccessKey.rawValue, "com.tp7sync.aws.secretaccesskey")
        XCTAssertEqual(KeychainService.Key.openRouterAPIKey.rawValue, "com.tp7sync.openrouter.apikey")
        XCTAssertEqual(KeychainService.Key.customAIAPIKey.rawValue, "com.tp7sync.customai.apikey")
        XCTAssertEqual(KeychainService.Key.notionAPIKey.rawValue, "com.tp7sync.notion.apikey")
    }

    func testAllRawValuesShareTheAppNamespace() {
        for key in KeychainService.Key.allCases {
            XCTAssertTrue(key.rawValue.hasPrefix("com.tp7sync."), "\(key) should stay in the com.tp7sync. namespace")
        }
    }
}
