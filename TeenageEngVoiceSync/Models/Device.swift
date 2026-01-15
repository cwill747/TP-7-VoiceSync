//
//  Device.swift
//  TeenageEngVoiceSync
//
//  SwiftData model for TP-7 devices.
//

import SwiftData
import Foundation

@Model
final class Device {
    @Attribute(.unique) var serial: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var recordingsCount: Int

    init(serial: String) {
        self.serial = serial
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
        self.recordingsCount = 0
    }

    func markSeen() {
        lastSeenAt = Date()
    }

    func incrementRecordings() {
        recordingsCount += 1
    }
}
