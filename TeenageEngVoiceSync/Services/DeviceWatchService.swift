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
    private(set) var isDownloading = false
    private(set) var downloadingCount = 0

    private var watchTask: Task<Void, Never>?
    private var session: TP7MTPSession?
    /// Keyed by "<folder>/<filename>" so identically-named files in /memo and
    /// /recordings are tracked independently.
    private var knownFilenames: Set<String> = []

    /// Teenage Engineering vendor ID (0x2367) and the TP-7's MTP product ID
    /// (0x0019). Used to wake the watch loop only when this exact device is
    /// attached/detached rather than on every USB event.
    private static let tp7VendorID = 0x2367
    private static let tp7ProductID = 0x0019

    private var usbMonitor: USBDeviceMonitor?
    /// Lets the USB monitor (running on its own queue) cut the watch loop's
    /// heartbeat sleep short so an attach/detach is handled immediately.
    private let wakeGate = WakeGate()

    // Callbacks
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: ((String) -> Void)?
    var onNewRecordings: (([DownloadedRecording], String) -> Void)?

    /// Start watching for TP-7 devices
    func startWatching() {
        guard watchTask == nil else { return }

        AppLogger.device.info("Starting device watch")

        // Wake the loop the instant a TP-7 is plugged in or unplugged, so we
        // don't have to poll the USB bus to notice. `wakeGate` is Sendable and
        // shared with the loop; capturing it (not `self`) keeps the callback
        // free of the non-Sendable service reference.
        let gate = wakeGate
        let monitor = USBDeviceMonitor(vendorID: Self.tp7VendorID, productID: Self.tp7ProductID) {
            gate.wake()
        }
        monitor.start()
        usbMonitor = monitor

        watchTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    /// Stop watching
    func stopWatching() {
        usbMonitor?.stop()
        usbMonitor = nil
        watchTask?.cancel()
        watchTask = nil
        wakeGate.wake()  // break the heartbeat sleep so the loop sees the cancel
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

            // A USB attach/detach wakes us instantly, so this sleep is a
            // fallback. Its length depends on what we're waiting for:
            //  - connected: short, to re-scan for new files the TP-7 can't
            //    push a notification for;
            //  - disconnected but the device is physically present: short, to
            //    retry the MTP connect (right after power-on the device can be
            //    enumerated but not yet ready for an MTP session, so the first
            //    open() attempt often fails);
            //  - disconnected and no device present: long — nothing to do until
            //    one is plugged in, and the USB event will wake us when it is.
            let interval: Duration
            if isConnected {
                interval = .seconds(15)
            } else if USBDeviceMonitor.isDevicePresent(vendorID: Self.tp7VendorID, productID: Self.tp7ProductID) {
                interval = .seconds(2)
            } else {
                interval = .seconds(300)
            }
            await interruptibleSleep(interval)
        }
    }

    /// Sleeps for `duration`, but returns early if `wakeGate.wake()` is called
    /// (a USB attach/detach event, or `stopWatching`). Returns immediately if a
    /// wake arrived since the last sleep, so an event that lands in the gap
    /// between sleeps is never lost.
    private func interruptibleSleep(_ duration: Duration) async {
        let sleep = Task<Void, Never> {
            do { try await Task.sleep(for: duration) } catch { }
        }
        guard wakeGate.beginSleep(sleep) else {
            sleep.cancel()  // a wake was already pending — skip this sleep
            return
        }
        await sleep.value
        wakeGate.endSleep()
    }

    /// Attempts to open a fresh session when no device is currently connected.
    private func tryConnect() async {
        let result = await Task.detached(priority: .utility) {
            TP7MTPSession.open()
        }.value

        guard case .success(let newSession) = result else {
            if case .failure(let error) = result {
                AppLogger.device.debug("Connect attempt failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

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
        isDownloading = true
        downloadingCount = newFiles.count
        defer {
            isDownloading = false
            downloadingCount = 0
        }

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

    /// Prefix applied to every /memo device filename (see `localFilename`) so
    /// they can't collide with /recordings names once they become the
    /// app-wide `Recording.filename` identity. Shared with `inferDeviceOrigin`,
    /// which reverses the mapping for recordings whose origin fields were lost.
    private static let memoFilenamePrefix = "memo-"

    /// Prefix applied to a /recordings device filename only in the rare case it
    /// would otherwise collide with the /memo mapping above (i.e. it already
    /// starts with `memoFilenamePrefix`, or with this prefix itself). Distinct
    /// from `memoFilenamePrefix` so escaped /recordings names can never overlap
    /// with genuine /memo names, however they're nested: `localFilename` only
    /// ever emits `memoFilenamePrefix + X` for /memo (for any X), and this
    /// prefix never starts with `memoFilenamePrefix`, so the two output spaces
    /// are disjoint by construction, not just for the common case.
    private static let recordingsEscapePrefix = "recordings-escaped-"

    /// The device-reported filename is only guaranteed unique *within* its own
    /// folder, not across /recordings and /memo (both can auto-number from
    /// "0001.wav"). This name becomes the local cache filename and, downstream,
    /// `Recording.filename` - the identity SyncService uses for the SwiftData
    /// uniqueness constraint, the S3 object key, and Notion/local-folder
    /// matching - so a cross-folder collision there would silently drop or
    /// overwrite one of the two recordings. Qualifying /memo names with a
    /// prefix makes that identity collision-free while leaving /recordings
    /// unqualified in the overwhelmingly common case (the only folder that
    /// existed before this feature), so already-synced recordings keep
    /// matching their existing S3/Notion state. The rare /recordings name that
    /// would otherwise collide (it already looks like a qualified/escaped
    /// name) gets its own, disjoint escape prefix instead of being left as-is.
    static func localFilename(forDeviceFilename safeName: String, folder: String) -> String {
        if folder == RecordingSource.memo.rawValue {
            return "\(memoFilenamePrefix)\(safeName)"
        }
        if safeName.hasPrefix(memoFilenamePrefix) || safeName.hasPrefix(recordingsEscapePrefix) {
            return "\(recordingsEscapePrefix)\(safeName)"
        }
        return safeName
    }

    /// Reverses `localFilename` for a persisted `Recording.filename` whose
    /// `sourceFolder`/`deviceFilename` were never captured. Recordings
    /// recovered from S3/Notion/local folder only ever persist `filename` -
    /// none of those stores know about device folders - but that name
    /// round-trips both the /memo prefix and the /recordings escape prefix
    /// unchanged, so origin can be recovered from here. Returns nil for a
    /// plain, unqualified name (an ordinary /recordings-origin, or
    /// pre-/memo-feature, recording).
    static func inferDeviceOrigin(fromPersistedFilename filename: String) -> (source: RecordingSource, deviceFilename: String)? {
        if filename.hasPrefix(memoFilenamePrefix) {
            return (.memo, String(filename.dropFirst(memoFilenamePrefix.count)))
        }
        if filename.hasPrefix(recordingsEscapePrefix) {
            return (.recordings, String(filename.dropFirst(recordingsEscapePrefix.count)))
        }
        return nil
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

/// Thread-safe coordinator that lets the USB monitor's callback (on its own
/// queue) wake the watch loop early. It also *latches* a wake that arrives while
/// the loop isn't sleeping, so an attach/detach event landing in the gap between
/// two sleeps is applied to the next sleep instead of being lost. The two
/// guarded fields make `@unchecked Sendable` sound.
final class WakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepTask: Task<Void, Never>?
    private var pendingWake = false

    /// Registers `task` as the active sleep. Returns `false` (and consumes the
    /// latch) if a wake is already pending, meaning the caller should not sleep.
    func beginSleep(_ task: Task<Void, Never>) -> Bool {
        lock.withLock {
            if pendingWake {
                pendingWake = false
                return false
            }
            sleepTask = task
            return true
        }
    }

    func endSleep() {
        lock.withLock { sleepTask = nil }
    }

    /// Wakes the current sleep (if any) and latches the event for the next
    /// `beginSleep`, so it can't be dropped between sleeps.
    func wake() {
        lock.withLock {
            pendingWake = true
            sleepTask?.cancel()
        }
    }
}
