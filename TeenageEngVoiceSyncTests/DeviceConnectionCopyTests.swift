//
//  DeviceConnectionCopyTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class DeviceConnectionCopyTests: XCTestCase {
    func testSettingsHelpDescribesDirectMTPConnectionAndUSBPrompt() {
        let help = DeviceConnectionCopy.settingsHelp

        XCTAssertTrue(help.contains("MTP mode"))
        XCTAssertTrue(help.contains("Do you want to connect the USB accessory to this Mac?"))
        XCTAssertTrue(help.contains("Choose Allow"))
        XCTAssertFalse(help.localizedCaseInsensitiveContains("FieldKit"))
    }

    func testOnboardingDescribesDirectMTPConnectionWithoutFieldKit() {
        let description = DeviceConnectionCopy.onboardingDescription

        XCTAssertTrue(description.contains("MTP mode"))
        XCTAssertTrue(description.contains("allow the USB accessory to connect"))
        XCTAssertFalse(description.localizedCaseInsensitiveContains("FieldKit"))
    }
}
