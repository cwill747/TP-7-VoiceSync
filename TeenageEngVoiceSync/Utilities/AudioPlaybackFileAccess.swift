import Foundation

nonisolated struct AudioPlaybackSource: Equatable {
    let url: URL
    let requiresConfiguredFolderScope: Bool

    /// Prefers an existing app-managed cache file. External local copies are
    /// returned from their stored path without probing them because the probe
    /// itself may require opening their security-scoped folder first.
    static func select(
        localPath: String,
        localCopyPath: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AudioPlaybackSource? {
        if !localPath.isEmpty, fileExists(localPath) {
            return AudioPlaybackSource(
                url: URL(fileURLWithPath: localPath),
                requiresConfiguredFolderScope: false
            )
        }
        if let localCopyPath, !localCopyPath.isEmpty {
            return AudioPlaybackSource(
                url: URL(fileURLWithPath: localCopyPath),
                requiresConfiguredFolderScope: true
            )
        }
        return nil
    }
}

/// Keeps a configured local-audio folder's security scope open for as long as
/// AVFoundation may need to read a recording from it.
nonisolated final class AudioPlaybackFileAccess {
    enum AccessError: LocalizedError {
        case folderAccessDenied

        var errorDescription: String? {
            switch self {
            case .folderAccessDenied:
                return "VoiceSync no longer has permission to read the local audio folder. Choose the folder again in Settings."
            }
        }
    }

    private static let bookmarkKey = "localaudio.folderPath"

    private let configuredFolder: () -> URL?
    private let resolveBookmark: () -> URL?
    private let startAccessing: (URL) -> Bool
    private let stopAccessing: (URL) -> Void
    private var scopedFolderURL: URL?

    init(
        configuredFolder: @escaping () -> URL? = {
            guard let path = UserDefaults.standard.string(forKey: bookmarkKey), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        },
        resolveBookmark: @escaping () -> URL? = {
            SecurityScopedBookmark.resolve(key: bookmarkKey)
        },
        startAccessing: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.configuredFolder = configuredFolder
        self.resolveBookmark = resolveBookmark
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    /// Releases any previous scope, then acquires the configured folder scope
    /// for a file known to come from `Recording.localCopyPath`. App-managed
    /// device-cache files never require this scope, even if a broadly selected
    /// external folder happens to contain the cache directory.
    func acquire(for fileURL: URL, requiresConfiguredFolderScope: Bool) throws {
        release()

        guard requiresConfiguredFolderScope else { return }

        guard let configuredFolder = configuredFolder(),
              Self.contains(fileURL, in: configuredFolder),
              let folderURL = resolveBookmark(),
              startAccessing(folderURL) else {
            throw AccessError.folderAccessDenied
        }
        scopedFolderURL = folderURL
    }

    func release() {
        guard let scopedFolderURL else { return }
        stopAccessing(scopedFolderURL)
        self.scopedFolderURL = nil
    }

    deinit {
        release()
    }

    private static func contains(_ fileURL: URL, in folderURL: URL) -> Bool {
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        return fileComponents.count > folderComponents.count
            && fileComponents.starts(with: folderComponents)
    }
}
