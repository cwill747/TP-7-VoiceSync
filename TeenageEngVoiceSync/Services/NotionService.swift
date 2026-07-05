//
//  NotionService.swift
//  TeenageEngVoiceSync
//
//  Notion integration: creates a page in a Notion database for each transcription,
//  mirroring AppleNotesService so it can be wired into the same sync pipeline.
//
//  Setup:
//   1. Create an internal integration at https://www.notion.so/my-integrations
//      and copy its "Internal Integration Secret" (starts with `ntn_` or `secret_`).
//   2. Share your target database with that integration (••• → Connections).
//   3. The database must contain these properties (types matter, names are
//      configurable below via NotionService.PropertyNames):
//        - Name       (title)      -> page title
//        - Date       (date)       -> recordedAt, so views can sort by date
//        - Filename   (rich text)  -> TP-7 device filename
//        - Duration   (rich text)  -> mm:ss
//        - Language   (rich text)  -> detected language
//        - Audio      (url)        -> playback/download link (S3 or file://)
//        - Summary    (rich text)  -> optional LLM summary
//      The full transcript is written into the page BODY (not a property),
//      chunked to respect Notion's 2000-char-per-rich-text limit.
//

import Foundation

actor NotionService {

    /// Property names in the target database. Change these if your DB uses
    /// different column names. `title` must be the DB's title property.
    struct PropertyNames {
        var title = "Name"
        var date = "Date"
        var filename = "Filename"
        var duration = "Duration"
        var language = "Language"
        var audio = "Audio"
        var summary = "Summary"

        static let `default` = PropertyNames()
    }

    enum NotionError: LocalizedError {
        case notConfigured
        case invalidResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Notion API key or database ID not configured"
            case .invalidResponse:
                return "Invalid response from Notion"
            case .apiError(let statusCode, let message):
                return "Notion API error (\(statusCode)): \(message)"
            }
        }
    }

    private let apiKey: String
    private let databaseId: String
    private let props: PropertyNames
    private let notionVersion = "2022-06-28"
    private let session: URLSession

    init(apiKey: String, databaseId: String, props: PropertyNames = .default) {
        self.apiKey = apiKey
        self.databaseId = databaseId
        self.props = props

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    /// Lightweight validation: fetch the database to confirm token + ID + access.
    static func validate(apiKey: String, databaseId: String) async throws {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }
        let cleanId = databaseId.replacingOccurrences(of: "-", with: "")
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(cleanId)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        guard http.statusCode == 200 else {
            throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
        }
    }

    /// Creates a Notion page for a transcription. Signature parallels
    /// AppleNotesService.createTranscriptionNote for symmetric wiring.
    func createTranscriptionNote(
        transcription: String,
        filename: String,
        tpDeviceFilename: String? = nil,
        recordedAt: Date,
        fileSize: Int64,
        duration: TimeInterval? = nil,
        language: String,
        playURL: String,
        downloadURL: String,
        customTitle: String? = nil,
        summary: String? = nil
    ) async throws {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }

        let title = customTitle
            ?? "TP-7 Recording - \(recordedAt.formatted(.dateTime.month(.wide).day().year()))"
        let tpFilename = tpDeviceFilename ?? filename
        let durationStr = formatDuration(duration)

        // ISO-8601 date (Notion accepts full timestamps for date properties).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let dateString = iso.string(from: recordedAt)

        // MARK: Properties
        var properties: [String: Any] = [
            props.title: [
                "title": [["text": ["content": String(title.prefix(2000))]]]
            ],
            props.date: [
                "date": ["start": dateString]
            ],
            props.filename: richText(tpFilename),
            props.duration: richText(durationStr),
            props.language: richText(language)
        ]
        // Notion's URL property only accepts http(s). A local file:// link
        // (when S3 backup is off) would 400 the whole request, so only set it
        // for real web URLs; the local path is surfaced in the body instead.
        if playURL.hasPrefix("http") {
            properties[props.audio] = ["url": playURL]
        }
        if let summary, !summary.isEmpty {
            properties[props.summary] = richText(summary)
        }

        // MARK: Page body (children blocks)
        var children: [[String: Any]] = []

        if let summary, !summary.isEmpty {
            children.append(headingBlock("Summary"))
            children.append(contentsOf: paragraphBlocks(summary))
            children.append(dividerBlock())
        }

        children.append(headingBlock("Transcript"))
        children.append(contentsOf: paragraphBlocks(transcription))

        children.append(dividerBlock())
        children.append(headingBlock("Details"))
        var details = "TP-7 File: \(tpFilename)\n"
            + "Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))\n"
            + "Language: \(language)"
        // For local-only recordings, include the path as text (bookmark blocks
        // also require http(s)).
        if !downloadURL.isEmpty, !downloadURL.hasPrefix("http") {
            details += "\nLocal file: \(downloadURL)"
        }
        children.append(contentsOf: paragraphBlocks(details))
        if downloadURL.hasPrefix("http") {
            children.append(bookmarkBlock(downloadURL))
        }

        // Notion caps children at 100 blocks per create call.
        let firstBatch = Array(children.prefix(100))
        let overflow = Array(children.dropFirst(100))

        let payload: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": properties,
            "children": firstBatch
        ]

        let pageId = try await createPage(payload)

        // Append any overflow blocks in batches of 100.
        var remaining = overflow
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(100))
            remaining = Array(remaining.dropFirst(100))
            try await appendChildren(pageId: pageId, blocks: batch)
        }
    }

    // MARK: - Networking

    private func createPage(_ payload: [String: Any]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["id"] as? String) ?? ""
    }

    private func appendChildren(pageId: String, blocks: [[String: Any]]) async throws {
        guard !pageId.isEmpty else { return }
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
        }
    }

    // MARK: - Block / property builders

    private func richText(_ content: String) -> [String: Any] {
        ["rich_text": [["text": ["content": String(content.prefix(2000))]]]]
    }

    /// Splits arbitrary-length text into paragraph blocks under Notion's
    /// 2000-char-per-rich-text limit (uses 1900 for safety).
    private func paragraphBlocks(_ text: String) -> [[String: Any]] {
        let chunks = text.chunked(into: 1900)
        return chunks.map { chunk in
            [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": chunk]]]
                ]
            ]
        }
    }

    private func headingBlock(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func dividerBlock() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [:]]
    }

    private func bookmarkBlock(_ url: String) -> [String: Any] {
        ["object": "block", "type": "bookmark", "bookmark": ["url": url]]
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

private extension String {
    /// Splits the string into chunks of at most `size` characters.
    func chunked(into size: Int) -> [String] {
        guard !isEmpty else { return [""] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
