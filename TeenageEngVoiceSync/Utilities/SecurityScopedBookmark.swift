import Foundation
import os

enum SecurityScopedBookmark {

    private static let logger = Logger(subsystem: "com.tp7sync", category: "bookmark")

    static func save(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: "\(key).bookmark")
            logger.info("Saved bookmark for \(key, privacy: .public)")
        } catch {
            logger.error("Failed to save bookmark for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
