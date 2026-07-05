//
//  DeviceWatchService.swift
//  TeenageEngVoiceSync
//
//  Watches for a TP-7 over MTP (via the vendored libtp7mtp backend) and
//  downloads new recordings to a local cache directory.
//
//  A single MTP session is held open for the entire time the device is
//  connected, and reused for every list/download/delete call - the TP-7's
//  MTP firmware does not tolerate a fresh session being opened and closed
//  per file transfer.
//

import Foundation
import os
import Observation

@Observable
final class DeviceWatchService {
    private(set) var isConnected = false
    private(set) var currentDeviceSerial: String?
    private(set) var recordingsPath: String?

    private var watchTask: Task<Void, Never>?
    private var session: TP7MTPSession?
    private var knownFilenames: Set<String> = []

    // Callbacks
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: ((String) -> Void)?
    var onNewRecordings: (([URL], String) -> Void)?

    /// Start watching for TP-7 devices
    func startWatching() {
        guard watchTask == nil else { return }

        AppLogger.device.info("Starting device watch")

        watchTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    /// Stop watching
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        closeSession()
    }

    private func watchLoop() async {
        while !Task.isCancelled {
            if session == nil {
                await tryConnect()
            } else {
                await pollConnectedSession()
            }

            guard !Task.isCancelled else { break }
            let interval: Duration = isConnected ? .seconds(10) : .seconds(2)
            try? await Task.sleep(for: interval)
        }
    }

    /// Attempts to open a fresh session when no device is currently connected.
    private func tryConnect() async {
        let result = await Task.detached(priority: .utility) {
            TP7MTPSession.open()
        }.value

        guard case .success(let newSession) = result else { return }

        session = newSession
        isConnected = true
        currentDeviceSerial = newSession.device.serial
        recordingsPath = "/recordings"
        knownFilenames = []

        AppLogger.device.info("Device connected (serial=\(newSession.device.serial, privacy: .private))")
        onDeviceConnected?(newSession.device.serial)

        await scanRecordings()
    }

    /// Uses the existing open session to check for new recordings. If any
    /// call fails, treats it as a disconnect and closes the session so the
    /// next loop iteration attempts a fresh connect.
    private func pollConnectedSession() async {
        let stillHealthy = await scanRecordings()
        if !stillHealthy {
            handleDisconnected()
        }
    }

    /// Returns false if the session appears to be dead (device disconnected).
    @discardableResult
    private func scanRecordings() async -> Bool {
        guard let session else { return false }
        let serial = session.device.serial

        let listResult = await Task.detached(priority: .utility) {
            session.listRecordings()
        }.value

        guard case .success(let files) = listResult else { return false }

        let newFiles = files.filter { !knownFilenames.contains($0.name) }
        guard !newFiles.isEmpty else { return true }

        var downloadedURLs: [URL] = []

        for file in newFiles {
            knownFilenames.insert(file.name)

            guard let destination = Self.cacheDestination(for: file.name, serial: serial) else { continue }

            if FileManager.default.fileExists(atPath: destination.path) {
                downloadedURLs.append(destination)
                continue
            }

            let downloadResult = await Task.detached(priority: .utility) {
                session.download(filename: file.name, to: destination)
            }.value

            switch downloadResult {
            case .success:
                downloadedURLs.append(destination)
            case .failure(let error):
                AppLogger.device.error("Failed to download \(file.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !downloadedURLs.isEmpty {
            onNewRecordings?(downloadedURLs, serial)
        }

        return true
    }

    private func handleDisconnected() {
        guard let serial = currentDeviceSerial else {
            closeSession()
            return
        }
        AppLogger.device.info("Device disconnected (serial=\(serial, privacy: .private))")
        closeSession()
        onDeviceDisconnected?(serial)
    }

    private func closeSession() {
        let sessionToClose = session
        session = nil
        isConnected = false
        currentDeviceSerial = nil
        recordingsPath = nil
        knownFilenames = []

        guard let sessionToClose else { return }
        Task.detached(priority: .utility) {
            sessionToClose.close()
        }
    }

    /// Deletes a recording from the currently connected device over MTP.
    /// Blocking; call off the main thread. No-op if no device is connected.
    func deleteFromDevice(filename: String) async -> Result<Void, TP7MTPError> {
        guard let session else {
            return .failure(.device("No device connected"))
        }
        return await Task.detached(priority: .utility) {
            session.deleteRecording(filename: filename)
        }.value
    }

    private static func cacheDestination(for filename: String, serial: String) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("TP-7 VoiceSync", isDirectory: true)
            .appendingPathComponent("DeviceDownloads", isDirectory: true)
            .appendingPathComponent(serial, isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent(filename)
    }
}
