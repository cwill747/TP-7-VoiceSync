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

    private var didMigrate = false

    private init() {}

    // Migrate from the single-JSON-blob keychain item used in an earlier build.
    private func migrateFromBlobIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecAttrAccount as String: "credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let blob = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }

        for key in Key.allCases {
            if let value = blob[key.rawValue] {
                try? save(value, for: key)
            }
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecAttrAccount as String: "credentials"
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        AppLogger.keychain.info("Migrated credentials from JSON blob to per-key storage")
    }

    func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            AppLogger.keychain.error("Save failed: encoding error for key \(key.rawValue, privacy: .public)")
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecUseDataProtectionKeychain as String: true
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
        migrateFromBlobIfNeeded()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return try migrateFromLegacyKeychainIfNeeded(for: key)
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

    // Migrate a per-key item from the legacy file-based keychain (saved before this
    // app adopted the data-protection keychain) into the data-protection keychain.
    private func migrateFromLegacyKeychainIfNeeded(for key: Key) throws -> String? {
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        try save(value, for: key)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync"
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        AppLogger.keychain.info("Migrated key \(key.rawValue, privacy: .public) to data-protection keychain")

        return value
    }

    func delete(for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync",
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }

        // Best-effort cleanup of an unmigrated legacy copy so hasValue/delete behave
        // identically regardless of whether this key was ever read (and thus migrated).
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: "TeenageEngVoiceSync"
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    func hasValue(for key: Key) throws -> Bool {
        guard let value = try retrieve(for: key) else { return false }
        return !value.isEmpty
    }
}
