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
        guard save(url: url, key: key) else { return false }
        UserDefaults.standard.set(url.path, forKey: key)
        return true
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
