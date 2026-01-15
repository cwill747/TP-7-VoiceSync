//
//  AppleNotesService.swift
//  TeenageEngVoiceSync
//
//  Apple Notes integration via AppleScript.
//

import Foundation

actor AppleNotesService {
    /// Creates a new note in Apple Notes
    func createNote(title: String, body: String, folder: String) async throws {
        let escapedTitle = escapeForAppleScript(title)
        let escapedBody = escapeForAppleScript(body)
        let escapedFolder = escapeForAppleScript(folder)

        let script = """
        tell application "Notes"
            set folderName to "\(escapedFolder)"
            set noteTitle to "\(escapedTitle)"
            set noteBody to "\(escapedBody)"

            -- Get or create the folder
            set targetAccount to first account

            try
                set targetFolder to folder folderName of targetAccount
            on error
                -- Folder doesn't exist, create it
                set targetFolder to make new folder at targetAccount with properties {name:folderName}
            end try

            -- Create the note
            make new note at targetFolder with properties {name:noteTitle, body:noteBody}
        end tell
        """

        try await executeAppleScript(script)
    }

    /// Creates a note with transcription details
    func createTranscriptionNote(
        transcription: String,
        filename: String,
        tpDeviceFilename: String? = nil,
        recordedAt: Date,
        fileSize: Int64,
        language: String,
        playURL: String,
        downloadURL: String,
        folder: String,
        customTitle: String? = nil,
        summary: String? = nil
    ) async throws {
        // Use custom title if provided, otherwise fall back to date-based title
        let title = customTitle ?? "TP-7 Recording - \(recordedAt.formatted(.dateTime.month(.wide).day().year()))"

        let dateStr = recordedAt.formatted(.dateTime.month(.wide).day().year().hour().minute())
        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        let tpFilename = tpDeviceFilename ?? filename

        // Build body with optional summary
        var bodyParts: [String] = []

        // Main transcription
        bodyParts.append("<p>\(escapeHTML(transcription))</p>")
        bodyParts.append("<hr>")

        // Summary section (if provided)
        if let summary = summary, !summary.isEmpty {
            bodyParts.append("<p><b>Summary</b></p>")
            bodyParts.append("<p>\(escapeHTML(summary))</p>")
            bodyParts.append("<hr>")
        }

        // Details section with TP-7 filename prominently displayed
        bodyParts.append("<p><b>Details</b></p>")
        bodyParts.append("""
        <p>Date: \(dateStr)<br>
        TP-7 File: \(tpFilename)<br>
        Size: \(sizeStr)<br>
        Language: \(language)</p>
        """)

        bodyParts.append("<p><a href=\"\(playURL)\">Play Audio</a> · <a href=\"\(downloadURL)\">Download</a></p>")

        let body = bodyParts.joined(separator: "\n\n")

        try await createNote(title: title, body: body, folder: folder)
    }

    private func executeAppleScript(_ source: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: AppleNotesError.scriptCreationFailed)
                    return
                }

                var error: NSDictionary?
                script.executeAndReturnError(&error)

                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    continuation.resume(throwing: AppleNotesError.executionFailed(message))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum AppleNotesError: LocalizedError {
    case scriptCreationFailed
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript"
        case .executionFailed(let message):
            return "AppleScript execution failed: \(message)"
        }
    }
}
