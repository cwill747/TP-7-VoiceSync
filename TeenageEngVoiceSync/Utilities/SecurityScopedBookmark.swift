import Foundation
import os

nonisolated enum SecurityScopedBookmark {

    private static let logger = Logger(subsystem: "com.tp7sync", category: "bookmark")

    @discardableResult
    static func save(url: URL, key: String) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: "\(key).bookmark")
            logger.info("Saved bookmark for \(key, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to save bookmark for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Saves a security-scoped bookmark and, only if that succeeds, records the
    /// folder path. Returns `false` (and stores nothing) when the bookmark can't
    /// be created, so callers never persist a path they can't reopen after relaunch.
    @discardableResult
    static func saveFolderSelection(url: URL, key: String) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard save(url: url, key: key) else { return false }
        UserDefaults.standard.set(url.path, forKey: key)
        return true
    }

    /// Creates security-scoped bookmark data for `url` without persisting anything.
    /// Returns `nil` when the bookmark can't be created. The setup wizard uses this to
    /// stage a folder choice in its draft and commit it only when onboarding completes.
    static func makeBookmarkData(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            logger.error("Failed to create staged bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Persists a pre-computed bookmark + path together. Counterpart to
    /// `makeBookmarkData(for:)`: the wizard stages `bookmarkData` during folder
    /// validation and commits it here only when the user finishes onboarding.
    static func persistFolderSelection(path: String, bookmarkData: Data, key: String, defaults: UserDefaults = .standard) {
        defaults.set(bookmarkData, forKey: "\(key).bookmark")
        defaults.set(path, forKey: key)
        logger.info("Persisted staged bookmark for \(key, privacy: .public)")
    }

    static func hasBookmark(key: String) -> Bool {
        UserDefaults.standard.data(forKey: "\(key).bookmark") != nil
    }

    static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "\(key).bookmark") else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.info("Bookmark stale for \(key, privacy: .public), re-saving")
                save(url: url, key: key)
            }

            return url
        } catch {
            logger.error("Failed to resolve bookmark for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: "\(key).bookmark")
    }
}
