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

    private init() {}

    func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            AppLogger.keychain.error("Save failed: encoding error for key \(key.rawValue, privacy: .public)")
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync"
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            AppLogger.keychain.info("Updated key \(key.rawValue, privacy: .public)")
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
            AppLogger.keychain.info("Added key \(key.rawValue, privacy: .public)")
            return
        }

        throw KeychainError.saveFailed(updateStatus)
    }

    func retrieve(for key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            AppLogger.keychain.error("Retrieve failed for \(key.rawValue, privacy: .public): status \(status, privacy: .public)")
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    func delete(for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync"
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func hasValue(for key: Key) throws -> Bool {
        guard let value = try retrieve(for: key) else { return false }
        return !value.isEmpty
    }
}
