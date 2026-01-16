//
//  LocalMarkdownService.swift
//  TeenageEngVoiceSync
//
//  Local markdown file storage for transcriptions.
//

import Foundation

actor LocalMarkdownService {

    /// Creates a markdown file for a transcription
    func createTranscriptionNote(
        transcription: String,
        filename: String,
        tpDeviceFilename: String? = nil,
        recordedAt: Date,
        fileSize: Int64,
        language: String,
        playURL: String,
        downloadURL: String,
        customTitle: String? = nil,
        summary: String? = nil
    ) async throws {
        // Get folder from UserDefaults
        let folderURL = try resolveFolder()

        // Generate title
        let title = customTitle ?? "TP-7 Recording - \(recordedAt.formatted(.dateTime.month(.wide).day().year()))"

        // Generate markdown content
        let content = generateMarkdownContent(
            title: title,
            transcription: transcription,
            filename: tpDeviceFilename ?? filename,
            recordedAt: recordedAt,
            fileSize: fileSize,
            language: language,
            playURL: playURL,
            downloadURL: downloadURL,
            summary: summary
        )

        // Generate safe filename
        let safeFilename = generateSafeFilename(title: title, recordedAt: recordedAt)
        let fileURL = folderURL.appendingPathComponent(safeFilename)

        // Write file
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw MarkdownError.writeError(error.localizedDescription)
        }
    }

    /// Generates markdown content for the transcription
    private func generateMarkdownContent(
        title: String,
        transcription: String,
        filename: String,
        recordedAt: Date,
        fileSize: Int64,
        language: String,
        playURL: String,
        downloadURL: String,
        summary: String?
    ) -> String {
        let dateStr = recordedAt.formatted(.dateTime.month(.wide).day().year().hour().minute())
        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)

        var parts: [String] = []

        // Title
        parts.append("# \(title)")
        parts.append("")

        // Transcription
        parts.append(transcription)
        parts.append("")
        parts.append("---")
        parts.append("")

        // Summary (if provided)
        if let summary = summary, !summary.isEmpty {
            parts.append("## Summary")
            parts.append("")
            parts.append(summary)
            parts.append("")
            parts.append("---")
            parts.append("")
        }

        // Details
        parts.append("## Details")
        parts.append("")
        parts.append("- **Date:** \(dateStr)")
        parts.append("- **TP-7 File:** \(filename)")
        parts.append("- **Size:** \(sizeStr)")
        parts.append("- **Language:** \(language)")
        parts.append("")

        // Handle file:// URLs differently from cloud URLs
        if playURL.hasPrefix("file://") {
            // Local file - show path
            if let localPath = URL(string: playURL)?.path {
                parts.append("**Audio File:** `\(localPath)`")
            }
        } else {
            // Cloud URLs - show play/download links
            parts.append("[Play Audio](\(playURL)) | [Download](\(downloadURL))")
        }
        parts.append("")

        return parts.joined(separator: "\n")
    }

    /// Generates a safe filename from the title
    /// Format: "Title - YYYY-MM-DD.md" (LLM title first, then date with dash separator)
    private func generateSafeFilename(title: String, recordedAt: Date) -> String {
        // Create date string for filename
        let dateStr = recordedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            .replacingOccurrences(of: "/", with: "-")

        // Clean the title for use as filename
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: ",", with: "")  // Remove commas
            .trimmingCharacters(in: .whitespaces)

        // Truncate if too long
        let maxTitleLength = 50
        let truncatedTitle = safeTitle.count > maxTitleLength
            ? String(safeTitle.prefix(maxTitleLength))
            : safeTitle

        // Format: "Title - YYYY-MM-DD.md"
        return "\(truncatedTitle) - \(dateStr).md"
    }

    /// Resolves the folder URL from stored path
    private func resolveFolder() throws -> URL {
        let folderPath = UserDefaults.standard.string(forKey: "markdown.folderPath") ?? ""
        guard !folderPath.isEmpty else {
            throw MarkdownError.folderNotConfigured
        }

        let url = URL(fileURLWithPath: folderPath)

        // Verify folder exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MarkdownError.folderAccessDenied
        }

        return url
    }
}

enum MarkdownError: LocalizedError {
    case folderNotConfigured
    case folderAccessDenied
    case writeError(String)

    var errorDescription: String? {
        switch self {
        case .folderNotConfigured:
            return "Markdown folder not configured"
        case .folderAccessDenied:
            return "Cannot access the configured folder"
        case .writeError(let message):
            return "Failed to write markdown file: \(message)"
        }
    }
}
