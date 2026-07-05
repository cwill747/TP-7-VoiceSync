//
//  KeychainService.swift
//  TeenageEngVoiceSync
//
//  Secure credential storage using macOS Keychain.
//

import Foundation
import os
import Security

actor KeychainService {
    static let shared = KeychainService()

    enum Key: String, CaseIterable {
        case elevenLabsAPIKey = "com.tp7sync.elevenlabs.apikey"
        case awsAccessKeyId = "com.tp7sync.aws.accesskeyid"
        case awsSecretAccessKey = "com.tp7sync.aws.secretaccesskey"
        case openRouterAPIKey = "com.tp7sync.openrouter.apikey"
        case notionAPIKey = "com.tp7sync.notion.apikey"
    }

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case retrieveFailed(OSStatus)
        case deleteFailed(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Failed to save to Keychain: \(status)"
            case .retrieveFailed(let status):
                return "Failed to retrieve from Keychain: \(status)"
            case .deleteFailed(let status):
                return "Failed to delete from Keychain: \(status)"
            case .encodingFailed:
                return "Failed to encode value"
            }
        }
    }

    private static let service = "TeenageEngVoiceSync"
    private static let account = "credentials"

    private init() {}

    func save(_ value: String, for key: Key) throws {
        var blob = try readBlob()
        blob[key.rawValue] = value
        try writeBlob(blob)
        AppLogger.keychain.info("Saved key \(key.rawValue, privacy: .public)")
    }

    func retrieve(for key: Key) throws -> String? {
        let blob = try readBlob()
        return blob[key.rawValue]
    }

    func delete(for key: Key) throws {
        var blob = try readBlob()
        blob.removeValue(forKey: key.rawValue)
        try writeBlob(blob)
    }

    func hasValue(for key: Key) throws -> Bool {
        guard let value = try retrieve(for: key) else { return false }
        return !value.isEmpty
    }

    // MARK: - Private

    private func readBlob() throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return [:]
        }

        guard status == errSecSuccess else {
            AppLogger.keychain.error("Blob read failed: \(status, privacy: .public)")
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data,
              let blob = try? JSONDecoder().decode([String: String].self, from: data) else {
            AppLogger.keychain.error("Blob decode failed")
            return [:]
        }

        return blob
    }

    private func writeBlob(_ blob: [String: String]) throws {
        guard let data = try? JSONEncoder().encode(blob) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
            return
        }

        throw KeychainError.saveFailed(updateStatus)
    }
}
