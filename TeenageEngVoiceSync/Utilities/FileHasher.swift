//
//  FileHasher.swift
//  TeenageEngVoiceSync
//
//  SHA256 file hashing for deduplication.
//

import Foundation
import CryptoKit

enum FileHasher {
    /// Calculates SHA256 hash of a file at the given URL
    static func sha256(url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileHandle = try FileHandle(forReadingFrom: url)
                    defer { try? fileHandle.close() }

                    var hasher = SHA256()
                    let bufferSize = 64 * 1024 // 64KB chunks

                    while autoreleasepool(invoking: {
                        guard let data = try? fileHandle.read(upToCount: bufferSize),
                              !data.isEmpty else {
                            return false
                        }
                        hasher.update(data: data)
                        return true
                    }) {}

                    let digest = hasher.finalize()
                    let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: hashString)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Calculates SHA256 hash of data
    static func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
