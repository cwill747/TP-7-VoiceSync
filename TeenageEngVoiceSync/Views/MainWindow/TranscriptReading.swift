//
//  TranscriptReading.swift
//  TeenageEngVoiceSync
//
//  Pure layout/search helpers for presenting long transcripts as readable,
//  navigable content (TP-10). Kept free of SwiftUI view state so they can be
//  unit-tested against multi-page fixtures.
//

import SwiftUI

// MARK: - Layout

enum TranscriptLayout {
    /// Comfortable maximum line length for body text on wide windows. Beyond
    /// this the eye struggles to track from the end of one line to the start of
    /// the next, so we cap width and let the surrounding layout stay responsive.
    static let maxReadingWidth: CGFloat = 680

    /// Splits transcript text into visible paragraphs.
    ///
    /// Blank-line separated blocks are treated as paragraphs. When a transcript
    /// has no blank lines but does use single newlines, those single breaks are
    /// promoted to paragraph boundaries so existing structure renders visibly
    /// instead of collapsing into one wall of text.
    static func paragraphs(from text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.contains("\n\n") ? "\n\n" : "\n"
        return normalized
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Search

enum TranscriptSearch {
    /// Character-offset ranges of every case- and diacritic-insensitive match of
    /// `query` within `text`. Offsets are into `text`'s `Character` view so they
    /// map cleanly onto `AttributedString` character indices.
    static func matchRanges(of query: String, in text: String) -> [Range<Int>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex
              ) {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            let upper = text.distance(from: text.startIndex, to: found.upperBound)
            ranges.append(lower..<upper)
            // Guard against zero-width matches so the loop always advances.
            searchStart = found.upperBound > found.lowerBound
                ? found.upperBound
                : text.index(after: found.lowerBound)
        }
        return ranges
    }

    /// Number of matches of `query` in `text`.
    static func matchCount(of query: String, in text: String) -> Int {
        matchRanges(of: query, in: text).count
    }

    /// `text` rendered as an `AttributedString` with every match of `query`
    /// highlighted. When `activeMatch` names a local match index, that one gets a
    /// stronger emphasis so the user can see which occurrence is focused.
    static func highlighted(
        _ text: String,
        query: String,
        activeMatch: Int? = nil
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let ranges = matchRanges(of: query, in: text)
        guard !ranges.isEmpty else { return attributed }

        for (index, range) in ranges.enumerated() {
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: range.upperBound)
            let isActive = index == activeMatch
            attributed[lower..<upper].backgroundColor = isActive
                ? Color.orange.opacity(0.85)
                : Color.yellow.opacity(0.4)
            if isActive {
                attributed[lower..<upper].foregroundColor = .black
            }
        }
        return attributed
    }
}

// MARK: - Match navigation

/// Ordered, per-block view of the matches for a search query across a displayed
/// transcript. Computed purely from the block texts so the same logic drives
/// both plain and diarized rendering, and so it can be tested directly.
struct TranscriptMatchMap {
    /// Number of matches contained in each block, in display order.
    let perBlock: [Int]
    /// Total matches across all blocks.
    let total: Int

    init(blocks: [String], query: String) {
        perBlock = blocks.map { TranscriptSearch.matchCount(of: query, in: $0) }
        total = perBlock.reduce(0, +)
    }

    /// The block index and the match index *within that block* for a given
    /// global match, or `nil` when the global index is out of range.
    func location(of globalMatch: Int) -> (block: Int, localMatch: Int)? {
        guard globalMatch >= 0, globalMatch < total else { return nil }
        var remaining = globalMatch
        for (blockIndex, count) in perBlock.enumerated() {
            if remaining < count {
                return (blockIndex, remaining)
            }
            remaining -= count
        }
        return nil
    }
}
