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
    let size: Int64
    let modTime: Int64
}

private struct TP7MTPResponse: Decodable {
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
final class TP7MTPSession: @unchecked Sendable {
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

    /// Lists *.wav files under /recordings on the device. Blocking; call off the main thread.
    func listRecordings() -> Result<[TP7MTPFileEntry], TP7MTPError> {
        let json = call { tp7mtp_list_recordings(handle) }
        return Self.decode(json).map { $0.files ?? [] }
    }

    /// Downloads a recording to `destination`. Blocking; call off the main thread.
    func download(filename: String, to destination: URL) -> Result<Void, TP7MTPError> {
        let json = filename.withCString { cFilename in
            destination.path.withCString { cDestPath in
                call { tp7mtp_download_recording(handle, UnsafeMutablePointer(mutating: cFilename), UnsafeMutablePointer(mutating: cDestPath)) }
            }
        }
        return Self.decode(json).map { _ in () }
    }

    /// Deletes a recording from the device. Blocking; call off the main thread.
    func deleteRecording(filename: String) -> Result<Void, TP7MTPError> {
        let json = filename.withCString { cFilename in
            call { tp7mtp_delete_recording(handle, UnsafeMutablePointer(mutating: cFilename)) }
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
