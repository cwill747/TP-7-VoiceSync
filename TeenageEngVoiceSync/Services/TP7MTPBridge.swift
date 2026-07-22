//
//  TP7MTPBridge.swift
//  TeenageEngVoiceSync
//
//  Swift wrapper around the vendored libtp7mtp C API (see Vendor/TP7MTP).
//
//  The TP-7's MTP firmware does not tolerate rapid session open/close churn
//  (observed to crash the device out of MTP mode when each file transfer
//  opened and closed its own session). TP7MTPSession opens one session and
//  must be reused for every list/download/delete call, then closed once.
//  All calls are blocking libusb calls and must not run on the main thread.
//

import Foundation

enum TP7MTPError: LocalizedError {
    case device(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .device(let message): return message
        case .decodingFailed: return "Failed to decode MTP response"
        }
    }
}

struct TP7MTPDeviceInfo: Decodable {
    let manufacturer: String
    let model: String
    let serial: String
}

struct TP7MTPFileEntry: Decodable {
    let name: String
    /// Which on-device folder this file lives in ("recordings" or "memo").
    let folder: String
    let size: Int64
    let modTime: Int64
}

/// Boxes a Swift progress closure so it can be handed across the cgo
/// boundary as an opaque `void*` context pointer (see `tp7mtpProgressTrampoline`).
/// `nonisolated`: instances are created on whatever thread calls `download`
/// and read back from the download's own background thread inside
/// `tp7mtp_download_recording`'s blocking call - never touched from the main
/// actor.
private nonisolated final class ProgressBox {
    let callback: (Int64, Int64) -> Void
    nonisolated init(_ callback: @escaping (Int64, Int64) -> Void) {
        self.callback = callback
    }
}

/// The actual C function pointer passed to `tp7mtp_download_recording`.
/// Must be a capture-free, nonisolated function to bridge to
/// `tp7mtp_progress_cb`; the `context` parameter carries the `ProgressBox`
/// instead. Invoked from the download's background thread.
private nonisolated func tp7mtpProgressTrampoline(bytesSent: Int64, bytesTotal: Int64, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    box.callback(bytesSent, bytesTotal)
}

private nonisolated struct TP7MTPResponse: Decodable {
    let ok: Bool
    let error: String?
    let handle: Int64?
    let device: TP7MTPDeviceInfo?
    let files: [TP7MTPFileEntry]?
}

/// Holds one open MTP session. Must be closed exactly once via `close()`.
///
/// `@unchecked Sendable`: stored properties are immutable, and the shim
/// serializes every list/download/delete call on a session behind a mutex
/// (see `ioMu` in native/tp7mtp/shim.go), so concurrent calls from multiple
/// `Task.detached` closures are safe even though each call blocks on I/O.
nonisolated final class TP7MTPSession: @unchecked Sendable {
    let device: TP7MTPDeviceInfo
    private let handle: Int64

    private init(handle: Int64, device: TP7MTPDeviceInfo) {
        self.handle = handle
        self.device = device
    }

    /// Opens a session with the attached TP-7. Blocking; call off the main thread.
    static func open() -> Result<TP7MTPSession, TP7MTPError> {
        let json = call { tp7mtp_open() }
        return decode(json).flatMap { r in
            guard let handle = r.handle, let device = r.device else { return .failure(.decodingFailed) }
            return .success(TP7MTPSession(handle: handle, device: device))
        }
    }

    /// Closes the session. Blocking; call off the main thread. Safe to call at most once.
    func close() {
        tp7mtp_close(handle)
    }

    /// Lists *.wav files under /recordings and /memo on the device. Blocking; call off the main thread.
    func listRecordings() -> Result<[TP7MTPFileEntry], TP7MTPError> {
        let json = call { tp7mtp_list_recordings(handle) }
        return Self.decode(json).map { $0.files ?? [] }
    }

    /// Downloads a recording to `destination`. `folder` must be the value reported by
    /// `listRecordings()` for this file ("recordings" or "memo"). Blocking; call off the main thread.
    ///
    /// `onProgress`, if given, is invoked synchronously and repeatedly from
    /// within this call (never after it returns) with bytes sent/total for
    /// the file currently transferring.
    func download(filename: String, folder: String, to destination: URL, onProgress: ((Int64, Int64) -> Void)? = nil) -> Result<Void, TP7MTPError> {
        let box = onProgress.map(ProgressBox.init)
        defer { withExtendedLifetime(box) {} }
        let contextPtr = box.map { Unmanaged.passUnretained($0).toOpaque() }

        let json = folder.withCString { cFolder in
            filename.withCString { cFilename in
                destination.path.withCString { cDestPath in
                    call {
                        tp7mtp_download_recording(
                            handle,
                            UnsafeMutablePointer(mutating: cFolder),
                            UnsafeMutablePointer(mutating: cFilename),
                            UnsafeMutablePointer(mutating: cDestPath),
                            box != nil ? tp7mtpProgressTrampoline : nil,
                            contextPtr
                        )
                    }
                }
            }
        }
        return Self.decode(json).map { _ in () }
    }

    /// Deletes a recording from the device. `folder` must be "recordings" or "memo".
    /// Blocking; call off the main thread.
    func deleteRecording(filename: String, folder: String) -> Result<Void, TP7MTPError> {
        let json = folder.withCString { cFolder in
            filename.withCString { cFilename in
                call { tp7mtp_delete_recording(handle, UnsafeMutablePointer(mutating: cFolder), UnsafeMutablePointer(mutating: cFilename)) }
            }
        }
        return Self.decode(json).map { _ in () }
    }

    private func call(_ fn: () -> UnsafeMutablePointer<CChar>?) -> String? {
        Self.call(fn)
    }

    private static func call(_ fn: () -> UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = fn() else { return nil }
        defer { tp7mtp_free(ptr) }
        return String(cString: ptr)
    }

    private static func decode(_ json: String?) -> Result<TP7MTPResponse, TP7MTPError> {
        guard let json, let data = json.data(using: .utf8) else {
            return .failure(.decodingFailed)
        }
        guard let response = try? JSONDecoder().decode(TP7MTPResponse.self, from: data) else {
            return .failure(.decodingFailed)
        }
        guard response.ok else {
            return .failure(.device(response.error ?? "Unknown MTP error"))
        }
        return .success(response)
    }
}
