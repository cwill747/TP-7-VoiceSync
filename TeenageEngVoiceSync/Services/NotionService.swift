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
//   3. Call provisionDatabase(apiKey:databaseId:) — it adds any of the
//      properties below that are missing (Date, Filename, Duration,
//      Language, Size, Audio, File, Summary) and adopts whatever the database's
//      existing title column is called. The full transcript is written
//      into the page BODY (not a property), chunked to respect Notion's
//      2000-char-per-rich-text limit.
//

import Foundation

actor NotionService {

    /// Property names in the target database. Change these if your DB uses
    /// different column names. `title` must be the DB's title property.
    ///
    /// `provisionDatabase` resolves the real names to use for a given
    /// database (adapting to an existing title column, renaming around
    /// collisions) and the result is persisted via `store()`/`loadStored()`
    /// so `SyncService` uses the same mapping later.
    struct PropertyNames: Codable {
        var title = "Name"
        var date = "Date"
        var filename = "Filename"
        var duration = "Duration"
        var language = "Language"
        var size = "Size"
        var audio = "Audio"
        var file = "File"
        var summary = "Summary"

        static let `default` = PropertyNames()

        private static let storageKey = "notion.propertyNames"

        enum CodingKeys: String, CodingKey {
            case title, date, filename, duration, language, size, audio, file, summary
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Name"
            date = try values.decodeIfPresent(String.self, forKey: .date) ?? "Date"
            filename = try values.decodeIfPresent(String.self, forKey: .filename) ?? "Filename"
            duration = try values.decodeIfPresent(String.self, forKey: .duration) ?? "Duration"
            language = try values.decodeIfPresent(String.self, forKey: .language) ?? "Language"
            size = try values.decodeIfPresent(String.self, forKey: .size) ?? "Size"
            audio = try values.decodeIfPresent(String.self, forKey: .audio) ?? "Audio"
            file = try values.decodeIfPresent(String.self, forKey: .file) ?? "File"
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? "Summary"
        }

        static func loadStored() -> PropertyNames {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(PropertyNames.self, from: data) else {
                return .default
            }
            return decoded
        }

        func store() {
            store(in: .standard)
        }

        func store(in defaults: UserDefaults) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Result of `provisionDatabase`: the property names to actually use
    /// (which may differ from the requested defaults) plus any warnings
    /// about pre-existing columns that couldn't be reused.
    struct ProvisionResult {
        let props: PropertyNames
        let warnings: [String]
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

    /// Extracts a 32-char hex database/page ID from a pasted Notion "Copy link"
    /// URL (e.g. `https://app.notion.com/p/394a2d2be14680d89627d4547651f8f2?v=...`)
    /// or a raw ID (dashed or not). Falls back to a dash-stripped copy of the
    /// input if no 32-hex run is found, so plain valid IDs pass through unchanged.
    static func extractDatabaseId(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let hexRegex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{32}")
        func firstHexMatch(in string: String) -> String? {
            guard let hexRegex,
                  let match = hexRegex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                  let range = Range(match.range, in: string) else { return nil }
            return String(string[range])
        }

        // For a full Notion URL, prefer the ID from the path — the query string
        // also carries a 32-hex `v=` view ID that isn't the page/database ID.
        if let components = URLComponents(string: trimmed), let host = components.host, host.contains("notion") {
            if let id = firstHexMatch(in: components.path) {
                return id
            }
        }

        let dashless = trimmed.replacingOccurrences(of: "-", with: "")
        return firstHexMatch(in: dashless) ?? dashless
    }

    /// Ensures the target database has every property this app needs,
    /// creating whichever ones are missing. Adapts to the database's
    /// existing title column (Notion allows only one) and, if a required
    /// column name already exists with an incompatible type, creates an
    /// alternate "TP7 <Name>" column instead of touching the existing one.
    ///
    /// Never modifies or deletes existing properties/values — it only adds
    /// new columns via `PATCH /v1/databases/{id}`.
    static func provisionDatabase(
        apiKey: String,
        databaseId: String,
        desired: PropertyNames = .default
    ) async throws -> ProvisionResult {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }
        let cleanId = databaseId.replacingOccurrences(of: "-", with: "")

        var getRequest = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(cleanId)")!)
        getRequest.httpMethod = "GET"
        getRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        getRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: getRequest)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        guard http.statusCode == 200 else {
            throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existingProps = json["properties"] as? [String: [String: Any]] else {
            throw NotionError.invalidResponse
        }

        var resultProps = desired
        var warnings: [String] = []
        var toCreate: [String: Any] = [:]

        // Every Notion database has exactly one title property; it may not
        // be named "Name", so adopt whatever it's actually called.
        if let titleEntry = existingProps.first(where: { ($0.value["type"] as? String) == "title" }) {
            resultProps.title = titleEntry.key
        }

        // (keyPath, desired name, Notion property type, creation schema)
        let required: [(WritableKeyPath<PropertyNames, String>, String, String, [String: Any])] = [
            (\.date, desired.date, "date", ["date": [String: Any]()]),
            (\.filename, desired.filename, "rich_text", ["rich_text": [String: Any]()]),
            (\.duration, desired.duration, "rich_text", ["rich_text": [String: Any]()]),
            (\.language, desired.language, "rich_text", ["rich_text": [String: Any]()]),
            (\.size, desired.size, "rich_text", ["rich_text": [String: Any]()]),
            (\.audio, desired.audio, "url", ["url": [String: Any]()]),
            (\.file, desired.file, "rich_text", ["rich_text": [String: Any]()]),
            (\.summary, desired.summary, "rich_text", ["rich_text": [String: Any]()])
        ]

        for (keyPath, name, type, schema) in required {
            if let existing = existingProps[name] {
                let existingType = existing["type"] as? String
                if existingType == type {
                    continue  // Already the right shape, reuse it as-is.
                }
                let altName = "TP7 \(name)"
                warnings.append("\"\(name)\" already exists as \(existingType ?? "unknown") — using \"\(altName)\" instead.")
                resultProps[keyPath: keyPath] = altName
                if existingProps[altName] == nil {
                    toCreate[altName] = schema
                }
            } else {
                toCreate[name] = schema
            }
        }

        if !toCreate.isEmpty {
            var patchRequest = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(cleanId)")!)
            patchRequest.httpMethod = "PATCH"
            patchRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            patchRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            patchRequest.httpBody = try JSONSerialization.data(withJSONObject: ["properties": toCreate])

            let (patchData, patchResponse) = try await URLSession.shared.data(for: patchRequest)
            guard let patchHttp = patchResponse as? HTTPURLResponse else { throw NotionError.invalidResponse }
            guard (200...299).contains(patchHttp.statusCode) else {
                throw NotionError.apiError(statusCode: patchHttp.statusCode, message: Self.message(from: patchData))
            }
        }

        return ProvisionResult(props: resultProps, warnings: warnings)
    }

    /// Read-only check that the integration secret is valid and the database is
    /// shared with it. Unlike `provisionDatabase`, this never modifies the
    /// database — the setup wizard uses it for mid-flow feedback while deferring
    /// the column-adding provisioning to completion.
    static func validateDatabaseAccess(apiKey: String, databaseId: String) async throws {
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
    /// Creates a new transcription page and returns its Notion page ID (store it
    /// so the page can later be updated in place via `updateTranscriptionNote`).
    @discardableResult
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
        summary: String? = nil,
        overdubNotes: [OverdubNote]? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }

        let content = buildNoteContent(
            transcription: transcription, filename: filename, tpDeviceFilename: tpDeviceFilename,
            recordedAt: recordedAt, fileSize: fileSize, duration: duration, language: language,
            playURL: playURL, downloadURL: downloadURL, customTitle: customTitle,
            summary: summary, overdubNotes: overdubNotes
        )

        // Notion caps children at 100 blocks per create call.
        let firstBatch = Array(content.children.prefix(100))
        let overflow = Array(content.children.dropFirst(100))

        let payload: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": content.properties,
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
        return pageId
    }

    /// Updates an existing transcription page in place: rewrites its properties
    /// and fully replaces its body blocks. Used by re-delivery (e.g. after a
    /// retranscribe) so the transcript is refreshed without leaving a duplicate
    /// page behind. Notion has no "replace all children" call, so the existing
    /// body blocks are deleted (archived) and the new ones appended.
    func updateTranscriptionNote(
        pageId: String,
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
        summary: String? = nil,
        overdubNotes: [OverdubNote]? = nil
    ) async throws {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }
        guard !pageId.isEmpty else { throw NotionError.invalidResponse }

        let content = buildNoteContent(
            transcription: transcription, filename: filename, tpDeviceFilename: tpDeviceFilename,
            recordedAt: recordedAt, fileSize: fileSize, duration: duration, language: language,
            playURL: playURL, downloadURL: downloadURL, customTitle: customTitle,
            summary: summary, overdubNotes: overdubNotes
        )

        try await updatePageProperties(pageId: pageId, properties: content.properties)

        // Clear the old body, then re-append the freshly built blocks (batched
        // at Notion's 100-per-call cap).
        for blockId in try await fetchChildBlockIDs(pageId: pageId) {
            try await deleteBlock(blockId: blockId)
        }
        var remaining = content.children
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(100))
            remaining = Array(remaining.dropFirst(100))
            try await appendChildren(pageId: pageId, blocks: batch)
        }
    }

    /// Builds the property map and body blocks shared by create + update, so the
    /// two paths always produce identical page content.
    private func buildNoteContent(
        transcription: String,
        filename: String,
        tpDeviceFilename: String?,
        recordedAt: Date,
        fileSize: Int64,
        duration: TimeInterval?,
        language: String,
        playURL: String,
        downloadURL: String,
        customTitle: String?,
        summary: String?,
        overdubNotes: [OverdubNote]?
    ) -> (properties: [String: Any], children: [[String: Any]]) {
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
            props.language: richText(language),
            props.size: richText(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        ]
        // Notion's URL property only accepts http(s). A local file:// link
        // (when S3 backup is off) would 400 the whole request, so only set it
        // for real web URLs; the local path is surfaced in the body instead.
        if playURL.hasPrefix("http") {
            properties[props.audio] = ["url": playURL]
        }
        if !downloadURL.isEmpty {
            properties[props.file] = richText(downloadURL)
        }
        if let summary, !summary.isEmpty {
            properties[props.summary] = richText(summary)
        }

        // MARK: Page body (children blocks)
        var children: [[String: Any]] = []

        children.append(headingBlock("Transcript"))
        children.append(contentsOf: paragraphBlocks(transcription))

        if let overdubNotes, !overdubNotes.isEmpty {
            children.append(headingBlock("Overdubbed notes"))
            for note in overdubNotes.sorted(by: { $0.startTime < $1.startTime }) {
                children.append(calloutBlock("\(formatTimestamp(note.startTime)) — \(note.text)"))
            }
        }

        return (properties, children)
    }

    /// Queries all pages in the database, returning recording metadata for
    /// each page. Used during startup recovery to find recordings that exist
    /// in Notion but not in the local database.
    func queryAllPages() async throws -> [NotionRecordingInfo] {
        guard !apiKey.isEmpty, !databaseId.isEmpty else {
            throw NotionError.notConfigured
        }

        var results: [NotionRecordingInfo] = []
        var startCursor: String?
        let cleanId = databaseId.replacingOccurrences(of: "-", with: "")

        repeat {
            var payload: [String: Any] = ["page_size": 100]
            if let cursor = startCursor {
                payload["start_cursor"] = cursor
            }

            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(cleanId)/query")!)
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

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pages = json["results"] as? [[String: Any]] else {
                throw NotionError.invalidResponse
            }

            for page in pages {
                if let info = extractRecordingInfo(from: page) {
                    results.append(info)
                }
            }

            let hasMore = json["has_more"] as? Bool ?? false
            startCursor = hasMore ? (json["next_cursor"] as? String) : nil
        } while startCursor != nil

        return results
    }

    private func extractRecordingInfo(from page: [String: Any]) -> NotionRecordingInfo? {
        guard let properties = page["properties"] as? [String: [String: Any]] else { return nil }

        let filename = extractRichText(properties[props.filename])
        guard !filename.isEmpty else { return nil }

        let title = extractTitle(properties[props.title])
        let dateStr = extractDate(properties[props.date])
        let language = extractRichText(properties[props.language])
        let durationStr = extractRichText(properties[props.duration])
        let summary = extractRichText(properties[props.summary])

        var recordedAt: Date?
        if let dateStr {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            recordedAt = iso.date(from: dateStr)
        }

        // Extract transcript from page body would require a separate API call;
        // we get it via the blocks API only when needed.
        let pageId = page["id"] as? String ?? ""

        return NotionRecordingInfo(
            pageId: pageId,
            filename: filename,
            title: title,
            recordedAt: recordedAt,
            language: language,
            durationString: durationStr,
            summary: summary
        )
    }

    /// Fetches the transcript text from a Notion page's body blocks.
    func fetchPageTranscript(pageId: String) async throws -> String? {
        guard !pageId.isEmpty else { return nil }

        var allText: [String] = []
        var startCursor: String?
        var inTranscript = false

        repeat {
            var urlString = "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100"
            if let cursor = startCursor {
                urlString += "&start_cursor=\(cursor)"
            }

            var request = URLRequest(url: URL(string: urlString)!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NotionError.invalidResponse
            }
            // Throw rather than break: breaking would return the transcript
            // accumulated from earlier pages, so a transient 429/500 mid-pagination
            // would be silently persisted as a truncated-but-"complete" transcript.
            guard (200...299).contains(http.statusCode) else {
                throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["results"] as? [[String: Any]] else {
                throw NotionError.invalidResponse
            }

            for block in blocks {
                let type = block["type"] as? String ?? ""

                if type == "heading_2",
                   let heading = block["heading_2"] as? [String: Any],
                   let richTexts = heading["rich_text"] as? [[String: Any]],
                   let text = richTexts.first?["plain_text"] as? String {
                    if text == "Transcript" { inTranscript = true; continue }
                    if inTranscript { inTranscript = false }
                }

                if type == "divider" && inTranscript { inTranscript = false; continue }

                if inTranscript, type == "paragraph",
                   let para = block["paragraph"] as? [String: Any],
                   let richTexts = para["rich_text"] as? [[String: Any]] {
                    let paraText = richTexts.compactMap { $0["plain_text"] as? String }.joined()
                    if !paraText.isEmpty { allText.append(paraText) }
                }
            }

            let hasMore = json["has_more"] as? Bool ?? false
            startCursor = hasMore ? (json["next_cursor"] as? String) : nil
        } while startCursor != nil

        let joined = allText.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private func extractRichText(_ prop: [String: Any]?) -> String {
        guard let prop,
              let richTexts = prop["rich_text"] as? [[String: Any]] else { return "" }
        return richTexts.compactMap { $0["plain_text"] as? String }.joined()
    }

    private func extractTitle(_ prop: [String: Any]?) -> String? {
        guard let prop,
              let titleArray = prop["title"] as? [[String: Any]] else { return nil }
        let text = titleArray.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private func extractDate(_ prop: [String: Any]?) -> String? {
        guard let prop,
              let dateObj = prop["date"] as? [String: Any],
              let start = dateObj["start"] as? String else { return nil }
        return start
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

    /// PATCHes a page's properties (title/date/filename/etc.). Body blocks are
    /// updated separately — this call only touches the database properties.
    private func updatePageProperties(pageId: String, properties: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageId)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
        }
    }

    /// Returns the IDs of a page's direct child blocks (its body), paging through
    /// all results. Used to clear the body before rewriting it on update.
    private func fetchChildBlockIDs(pageId: String) async throws -> [String] {
        var ids: [String] = []
        var startCursor: String?

        repeat {
            var urlString = "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100"
            if let cursor = startCursor {
                urlString += "&start_cursor=\(cursor)"
            }
            var request = URLRequest(url: URL(string: urlString)!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                throw NotionError.apiError(statusCode: http.statusCode, message: Self.message(from: data))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            ids.append(contentsOf: results.compactMap { $0["id"] as? String })
            startCursor = (json?["has_more"] as? Bool == true) ? json?["next_cursor"] as? String : nil
        } while startCursor != nil

        return ids
    }

    /// Archives (deletes) a single block. Notion's `DELETE /v1/blocks/{id}` moves
    /// the block to trash rather than hard-deleting it.
    private func deleteBlock(blockId: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/blocks/\(blockId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

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
    ///
    /// Splits on blank lines first (e.g. the "Speaker N: ..." turns a diarized
    /// transcript produces) so a turn only gets hard-split by character count
    /// if it individually exceeds the limit, instead of fusing two speakers'
    /// text together mid-block.
    private func paragraphBlocks(_ text: String) -> [[String: Any]] {
        let chunks = text.components(separatedBy: "\n\n").flatMap { $0.chunked(into: 1900) }
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

    /// A single callout block whose text is split into multiple rich_text
    /// entries (each under Notion's 2000-char-per-rich-text limit) rather than
    /// truncated, so a long overdub note isn't silently cut short — mirrors
    /// how `paragraphBlocks` chunks rather than truncates.
    private func calloutBlock(_ text: String) -> [String: Any] {
        let chunks = text.chunked(into: 1900)
        return [
            "object": "block",
            "type": "callout",
            "callout": [
                "rich_text": chunks.map { ["type": "text", "text": ["content": $0]] },
                "icon": ["type": "emoji", "emoji": "💡"]
            ]
        ]
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
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

struct NotionRecordingInfo {
    let pageId: String
    let filename: String
    let title: String?
    let recordedAt: Date?
    let language: String?
    let durationString: String?
    let summary: String?
}

private extension String {
    /// Splits the string into chunks of at most `size` characters.
    nonisolated func chunked(into size: Int) -> [String] {
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
