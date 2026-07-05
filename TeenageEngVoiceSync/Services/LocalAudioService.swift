//
//  LocalAudioService.swift
//  TeenageEngVoiceSync
//
//  Local audio file storage service.
//

import Foundation

actor LocalAudioService {

    enum LocalAudioError: LocalizedError {
        case folderNotConfigured
        case folderAccessDenied
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .folderNotConfigured:
                return "Local audio folder not configured"
            case .folderAccessDenied:
                return "Cannot access the configured audio folder"
            case .copyFailed(let message):
                return "Failed to copy audio file: \(message)"
            }
        }
    }

    /// Copies an audio file to the configured local folder
    /// - Parameter sourceURL: The source file URL (e.g., on TP-7 device)
    /// - Returns: The destination URL in the local folder
    func copyToLocalFolder(sourceURL: URL) async throws -> URL {
        let (folderURL, scoped) = try resolveFolder()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        let destinationURL = folderURL.appendingPathComponent(sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw LocalAudioError.copyFailed(error.localizedDescription)
        }

        return destinationURL
    }

    /// Checks if local audio folder is configured
    static var isConfigured: Bool {
        let folderPath = UserDefaults.standard.string(forKey: "localaudio.folderPath") ?? ""
        return !folderPath.isEmpty
    }

    /// Resolves the folder URL from stored bookmark (preferred) or plain path
    private func resolveFolder() throws -> (URL, Bool) {
        if let url = SecurityScopedBookmark.resolve(key: "localaudio.folderPath") {
            guard url.startAccessingSecurityScopedResource() else {
                throw LocalAudioError.folderAccessDenied
            }
            return (url, true)
        }

        let folderPath = UserDefaults.standard.string(forKey: "localaudio.folderPath") ?? ""
        guard !folderPath.isEmpty else {
            throw LocalAudioError.folderNotConfigured
        }

        let url = URL(fileURLWithPath: folderPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalAudioError.folderAccessDenied
        }

        return (url, false)
    }
}
