import Foundation
import FluidAudio

/// Persists custom vocabulary terms and dictionary replacement entries to Application Support.
final class VocabularyStore: @unchecked Sendable {
    static let shared = VocabularyStore()
    static let boostingEnabledDefaultsKey = "vocabulary.boostingEnabled"

    static var isBoostingEnabled: Bool {
        if UserDefaults.standard.object(forKey: boostingEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: boostingEnabledDefaultsKey)
    }

    // MARK: - Types

    struct BoostTerm: Codable, Hashable, Sendable {
        let text: String
        let weight: Float?
        let aliases: [String]

        init(text: String, weight: Float?, aliases: [String] = []) {
            self.text = text
            self.weight = weight
            self.aliases = aliases
        }

        private enum CodingKeys: String, CodingKey {
            case text, weight, aliases
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            weight = try c.decodeIfPresent(Float.self, forKey: .weight)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(weight, forKey: .weight)
            if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
        }
    }

    struct DictionaryEntry: Codable, Identifiable, Sendable {
        let id: UUID
        let triggers: [String]
        let replacement: String

        init(id: UUID = UUID(), triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers
            self.replacement = replacement
        }
    }

    // MARK: - Boost term persistence

    private struct BoostConfig: Codable {
        let alpha: Float?
        let minCtcScore: Float?
        let minSimilarity: Float?
        let minCombinedConfidence: Float?
        let minTermLength: Int?
        let terms: [BoostTerm]
    }

    private enum Defaults {
        static let alpha: Float = 2.8
        static let minCtcScore: Float = -2.2
        static let minSimilarity: Float = 0.72
        static let minCombinedConfidence: Float = 0.64
        static let minTermLength: Int = 3
        static let maxTerms: Int = 256
    }

    private let boostFileName = "voicesync_custom_vocabulary.json"
    private let appSupportFolder = "VoiceSync"
    private let dictionaryDefaultsKey = "vocabulary.dictionaryEntries"

    private init() {}

    // MARK: - Boost terms

    func boostFileURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw URLError(.fileDoesNotExist)
        }
        let dir = base.appendingPathComponent(appSupportFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(boostFileName)
    }

    func loadBoostTerms() throws -> [BoostTerm] {
        let url = try boostFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(BoostConfig.self, from: data)
        return Self.normalizeTerms(config.terms, max: Defaults.maxTerms)
    }

    func saveBoostTerms(_ terms: [BoostTerm]) throws {
        let normalized = Self.normalizeTerms(terms, max: Defaults.maxTerms)
        let config = BoostConfig(
            alpha: Defaults.alpha,
            minCtcScore: Defaults.minCtcScore,
            minSimilarity: Defaults.minSimilarity,
            minCombinedConfidence: Defaults.minCombinedConfidence,
            minTermLength: Defaults.minTermLength,
            terms: normalized
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let url = try boostFileURL()
        try data.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .vocabularyDidChange, object: nil)
    }

    // MARK: - Dictionary entries (trigger→replacement)

    func loadDictionaryEntries() -> [DictionaryEntry] {
        guard let data = UserDefaults.standard.data(forKey: dictionaryDefaultsKey),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func saveDictionaryEntries(_ entries: [DictionaryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: dictionaryDefaultsKey)
        }
        NotificationCenter.default.post(name: .vocabularyDidChange, object: nil)
    }

    // MARK: - Text post-processing

    /// Applies dictionary trigger→replacement pairs to a transcript.
    func applyDictionary(to text: String) -> String {
        let entries = loadDictionaryEntries()
        guard !entries.isEmpty else { return text }
        var result = text
        for entry in entries {
            let replacement = entry.replacement
            for trigger in entry.triggers where !trigger.isEmpty {
                result = result.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b",
                    with: replacement,
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }
        return result
    }

    // MARK: - FluidAudio vocabulary context

    func buildVocabularyContext() throws -> CustomVocabularyContext? {
        var merged: [String: BoostTerm] = [:]

        func upsert(_ term: BoostTerm) {
            let key = term.text.lowercased()
            if let existing = merged[key] {
                let combinedAliases = Array(Set(existing.aliases + term.aliases)).sorted()
                let w = max(existing.weight ?? 0, term.weight ?? 0)
                merged[key] = BoostTerm(
                    text: existing.text,
                    weight: w > 0 ? w : nil,
                    aliases: combinedAliases
                )
            } else {
                merged[key] = term
            }
        }

        for term in (try? loadBoostTerms()) ?? [] {
            upsert(term)
        }
        for entry in loadDictionaryEntries() {
            upsert(BoostTerm(text: entry.replacement, weight: 8.0, aliases: entry.triggers))
        }

        guard !merged.isEmpty else { return nil }

        let terms = merged.values.sorted {
            $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
        }.prefix(Defaults.maxTerms).map { term in
            CustomVocabularyTerm(
                text: term.text,
                weight: term.weight,
                aliases: term.aliases.isEmpty ? nil : term.aliases
            )
        }

        return CustomVocabularyContext(
            terms: terms,
            alpha: Defaults.alpha,
            minCtcScore: Defaults.minCtcScore,
            minSimilarity: Defaults.minSimilarity,
            minCombinedConfidence: Defaults.minCombinedConfidence,
            minTermLength: Defaults.minTermLength
        )
    }

    // MARK: - Helpers

    private static func normalizeTerms(_ terms: [BoostTerm], max maxCount: Int) -> [BoostTerm] {
        var seen: Set<String> = []
        var result: [BoostTerm] = []
        for term in terms {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let aliases = term.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(text) != .orderedSame }
            result.append(BoostTerm(text: text, weight: term.weight, aliases: Array(Set(aliases)).sorted()))
            if result.count >= maxCount { break }
        }
        return result
    }
}

extension Notification.Name {
    static let vocabularyDidChange = Notification.Name("VoiceSyncVocabularyDidChange")
}
