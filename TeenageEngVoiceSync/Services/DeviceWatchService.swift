//
//  DeviceWatchService.swift
//  TeenageEngVoiceSync
//
//  Watches for a TP-7 over MTP (via the vendored libtp7mtp backend) and
//  downloads new recordings from both the /recordings and /memo device
//  folders to a local cache directory.
//
//  A single MTP session is held open for the entire time the device is
//  connected, and reused for every list/download/delete call - the TP-7's
//  MTP firmware does not tolerate a fresh session being opened and closed
//  per file transfer.
//

import Foundation
import os
import Observation

/// A device file freshly downloaded to the local cache, tagged with the
/// on-device folder it came from.
struct DownloadedRecording {
    let url: URL
    let source: RecordingSource
    /// The literal on-device filename (before local disambiguation - see
    /// `DeviceWatchService.localFilename`), needed for MTP delete calls.
    let deviceFilename: String
}

@Observable
final class DeviceWatchService {
    private(set) var isConnected = false
    private(set) var currentDeviceSerial: String?
    private(set) var recordingsPath: String?

    private var watchTask: Task<Void, Never>?
    private var session: TP7MTPSession?
    /// Keyed by "<folder>/<filename>" so identically-named files in /memo and
    /// /recordings are tracked independently.
    private var knownFilenames: Set<String> = []

    // Callbacks
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: ((String) -> Void)?
    var onNewRecordings: (([DownloadedRecording], String) -> Void)?

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
        recordingsPath = "/recordings, /memo"
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

        let newFiles = files.filter { !knownFilenames.contains(Self.trackingKey(for: $0)) }
        guard !newFiles.isEmpty else { return true }

        var downloaded: [DownloadedRecording] = []

        for file in newFiles {
            let key = Self.trackingKey(for: file)
            guard let source = RecordingSource(rawValue: file.folder) else {
                AppLogger.device.error("Skipping recording with unknown folder \(file.folder, privacy: .public)")
                continue
            }
            guard let destination = Self.cacheDestination(for: file.name, folder: file.folder, serial: serial) else { continue }

            if FileManager.default.fileExists(atPath: destination.path) {
                knownFilenames.insert(key)
                downloaded.append(DownloadedRecording(url: destination, source: source, deviceFilename: file.name))
                continue
            }

            let downloadResult = await Task.detached(priority: .utility) {
                session.download(filename: file.name, folder: file.folder, to: destination)
            }.value

            switch downloadResult {
            case .success:
                knownFilenames.insert(key)
                downloaded.append(DownloadedRecording(url: destination, source: source, deviceFilename: file.name))
            case .failure(let error):
                // Do not mark as known: a transient MTP failure here should be
                // retried on the next poll cycle rather than skipped forever.
                AppLogger.device.error("Failed to download \(file.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !downloaded.isEmpty {
            onNewRecordings?(downloaded, serial)
        }

        return true
    }

    private static func trackingKey(for file: TP7MTPFileEntry) -> String {
        "\(file.folder)/\(file.name)"
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
    /// `folder` must be "recordings" or "memo". Blocking; call off the main
    /// thread. No-op if no device is connected.
    func deleteFromDevice(filename: String, folder: String) async -> Result<Void, TP7MTPError> {
        guard let session else {
            return .failure(.device("No device connected"))
        }
        return await Task.detached(priority: .utility) {
            session.deleteRecording(filename: filename, folder: folder)
        }.value
    }

    /// Prefix applied to /memo device filenames (see `localFilename`) so they
    /// can't collide with /recordings names once they become the app-wide
    /// `Recording.filename` identity. Shared with `inferMemoOrigin`, which
    /// reverses the mapping for recordings whose origin fields were lost.
    private static let memoFilenamePrefix = "memo-"

    /// The device-reported filename is only guaranteed unique *within* its own
    /// folder, not across /recordings and /memo (both can auto-number from
    /// "0001.wav"). This name becomes the local cache filename and, downstream,
    /// `Recording.filename` - the identity SyncService uses for the SwiftData
    /// uniqueness constraint, the S3 object key, and Notion/local-folder
    /// matching - so a cross-folder collision there would silently drop or
    /// overwrite one of the two recordings. Qualifying /memo names with a
    /// prefix makes that identity collision-free while leaving /recordings
    /// (the only folder that existed before this feature) untouched, so
    /// already-synced recordings keep matching their existing S3/Notion state.
    static func localFilename(forDeviceFilename safeName: String, folder: String) -> String {
        folder == RecordingSource.memo.rawValue ? "\(memoFilenamePrefix)\(safeName)" : safeName
    }

    /// Reverses `localFilename` for a persisted `Recording.filename` whose
    /// `sourceFolder`/`deviceFilename` were never captured. Recordings
    /// recovered from S3/Notion/local folder only ever persist `filename` -
    /// none of those stores know about device folders - but that name
    /// round-trips the /memo prefix unchanged, so it can be recovered from
    /// here. Returns nil when the name doesn't carry the prefix (a
    /// /recordings-origin, or pre-/memo-feature, recording).
    static func inferMemoOrigin(fromPersistedFilename filename: String) -> (source: RecordingSource, deviceFilename: String)? {
        guard filename.hasPrefix(memoFilenamePrefix) else { return nil }
        return (.memo, String(filename.dropFirst(memoFilenamePrefix.count)))
    }

    private static func cacheDestination(for filename: String, folder: String, serial: String) -> URL? {
        // Defense in depth: never trust the device-reported name as a path.
        // Only its last path component is used, so a malicious "../../foo.wav"
        // can't write outside the cache directory.
        let safeName = (filename as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            AppLogger.device.error("Rejecting recording with unsafe filename \(filename, privacy: .private)")
            return nil
        }

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        // Also nested by folder for on-disk organization, in addition to the
        // filename qualification above.
        let dir = appSupport
            .appendingPathComponent("TP-7 VoiceSync", isDirectory: true)
            .appendingPathComponent("DeviceDownloads", isDirectory: true)
            .appendingPathComponent(serial, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent(Self.localFilename(forDeviceFilename: safeName, folder: folder))
    }
}
