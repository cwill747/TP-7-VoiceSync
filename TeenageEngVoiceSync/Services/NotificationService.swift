//
//  NotificationService.swift
//  TeenageEngVoiceSync
//
//  macOS UserNotifications wrapper.
//

import Foundation
import os
import UserNotifications

actor NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// Request notification permissions
    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Send a notification
    func send(title: String, body: String, identifier: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            AppLogger.app.error("Failed to send notification: \(String(describing: error), privacy: .public)")
        }
    }

    /// Notify device connected
    func deviceConnected(_ serial: String) async {
        await send(
            title: "TP-7 Connected",
            body: "Device \(serial) is ready to sync",
            identifier: "device-connected"
        )
    }

    /// Notify device disconnected
    func deviceDisconnected(_ serial: String) async {
        await send(
            title: "TP-7 Disconnected",
            body: "Device \(serial) was disconnected",
            identifier: "device-disconnected"
        )
    }

    /// Notify sync started
    func syncStarted(count: Int) async {
        await send(
            title: "Sync Started",
            body: "Uploading \(count) recording\(count == 1 ? "" : "s")...",
            identifier: "sync-started"
        )
    }

    /// Notify sync complete
    func syncComplete(count: Int) async {
        await send(
            title: "Sync Complete",
            body: "Successfully synced \(count) recording\(count == 1 ? "" : "s")",
            identifier: "sync-complete"
        )
    }

    /// Notify sync error
    func syncError(_ message: String) async {
        await send(
            title: "Sync Error",
            body: message,
            identifier: "sync-error"
        )
    }

    /// Notify transcription complete with preview
    func transcriptionComplete(preview: String) async {
        let truncated = preview.count > 100 ? String(preview.prefix(100)) + "..." : preview
        await send(
            title: "Transcription Complete",
            body: truncated,
            identifier: "transcription-complete"
        )
    }

    /// Notify transcription error
    func transcriptionError(_ message: String, filename: String) async {
        await send(
            title: "Transcription Failed",
            body: "\(filename): \(message)",
            identifier: "transcription-error"
        )
    }

    /// Notify storage error (S3 or local)
    func storageError(_ message: String) async {
        await send(
            title: "Storage Error",
            body: message,
            identifier: "storage-error"
        )
    }

    /// Notify note creation error
    func noteError(_ message: String) async {
        await send(
            title: "Note Creation Failed",
            body: message,
            identifier: "note-error"
        )
    }
}
