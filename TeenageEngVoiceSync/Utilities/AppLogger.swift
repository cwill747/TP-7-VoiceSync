//
//  AppLogger.swift
//  TeenageEngVoiceSync
//
//  Centralized logging with privacy-safe defaults.
//

import Foundation
import os

enum AppLogger {
    // Use a constant here to avoid actor isolation issues in Swift 6 mode (e.g. Bundle.main access).
    nonisolated static let subsystem = "TeenageEngVoiceSync"

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let device = Logger(subsystem: subsystem, category: "device")
    nonisolated static let sync = Logger(subsystem: subsystem, category: "sync")
    nonisolated static let keychain = Logger(subsystem: subsystem, category: "keychain")
    nonisolated static let notes = Logger(subsystem: subsystem, category: "notes")
    nonisolated static let network = Logger(subsystem: subsystem, category: "network")
}

