//
//  TranscriptReadingTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the pure layout/search helpers backing the readable, navigable
//  transcript view (TP-10), exercised against a multi-page fixture.
//

import XCTest
import SwiftUI
@testable import TP_7_VoiceSync

final class TranscriptReadingTests: XCTestCase {

    /// A multi-page transcript with blank-line paragraph boundaries and a marker
    /// term ("projections") scattered across paragraphs for search coverage.
    private static let multiPage: String = (1...10)
        .map { "Section \($0). The projections landed close to plan this period." }
        .joined(separator: "\n\n")

    // MARK: - Paragraph splitting

    func testParagraphsSplitOnBlankLines() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird."
        XCTAssertEqual(
            TranscriptLayout.paragraphs(from: text),
            ["First paragraph.", "Second paragraph.", "Third."]
        )
    }

    func testSingleNewlinesPromotedWhenNoBlankLines() {
        // Without blank lines, single newlines become visible paragraph breaks.
        let text = "Line one.\nLine two.\nLine three."
        XCTAssertEqual(
            TranscriptLayout.paragraphs(from: text),
            ["Line one.", "Line two.", "Line three."]
        )
    }

    func testBlankLinesPreserveIntraParagraphNewlines() {
        // With blank-line separators present, single newlines stay inside a block.
        let text = "Line one.\nstill one.\n\nSecond block."
        XCTAssertEqual(
            TranscriptLayout.paragraphs(from: text),
            ["Line one.\nstill one.", "Second block."]
        )
    }

    func testParagraphsNormalizeCRLFAndTrimWhitespace() {
        let text = "  Alpha  \r\n\r\n  Beta  "
        XCTAssertEqual(TranscriptLayout.paragraphs(from: text), ["Alpha", "Beta"])
    }

    func testEmptyAndWhitespaceProduceNoParagraphs() {
        XCTAssertTrue(TranscriptLayout.paragraphs(from: "").isEmpty)
        XCTAssertTrue(TranscriptLayout.paragraphs(from: "   \n\n  \n ").isEmpty)
    }

    func testMultiPageFixtureSplitsIntoTenParagraphs() {
        XCTAssertEqual(TranscriptLayout.paragraphs(from: Self.multiPage).count, 10)
    }

    // MARK: - Match ranges

    func testMatchRangesFindsAllOccurrences() {
        let ranges = TranscriptSearch.matchRanges(of: "projections", in: Self.multiPage)
        XCTAssertEqual(ranges.count, 10)
    }

    func testMatchRangesAreCaseInsensitive() {
        XCTAssertEqual(
            TranscriptSearch.matchCount(of: "PROJECTIONS", in: Self.multiPage),
            10
        )
    }

    func testMatchRangesAreDiacriticInsensitive() {
        let text = "café Café CAFE cafe"
        XCTAssertEqual(TranscriptSearch.matchCount(of: "cafe", in: text), 4)
    }

    func testMatchRangeOffsetsMapToOriginalText() {
        let text = "one two one two one"
        let ranges = TranscriptSearch.matchRanges(of: "one", in: text)
        XCTAssertEqual(ranges.count, 3)
        for range in ranges {
            let start = text.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.index(text.startIndex, offsetBy: range.upperBound)
            XCTAssertEqual(String(text[start..<end]).lowercased(), "one")
        }
    }

    func testEmptyQueryYieldsNoMatches() {
        XCTAssertTrue(TranscriptSearch.matchRanges(of: "", in: Self.multiPage).isEmpty)
        XCTAssertTrue(TranscriptSearch.matchRanges(of: "   ", in: Self.multiPage).isEmpty)
    }

    func testNoMatchYieldsEmpty() {
        XCTAssertTrue(TranscriptSearch.matchRanges(of: "zzz", in: Self.multiPage).isEmpty)
    }

    func testOverlappingCandidatesAdvanceWithoutInfiniteLoop() {
        // "aa" in "aaaa" should yield two non-overlapping matches, not hang.
        XCTAssertEqual(TranscriptSearch.matchCount(of: "aa", in: "aaaa"), 2)
    }

    // MARK: - Highlighting

    func testHighlightPreservesUnderlyingText() {
        let attributed = TranscriptSearch.highlighted(
            Self.multiPage,
            query: "projections",
            activeMatch: 0
        )
        XCTAssertEqual(String(attributed.characters), Self.multiPage)
    }

    func testHighlightWithEmptyQueryEqualsPlainText() {
        let attributed = TranscriptSearch.highlighted("hello world", query: "")
        XCTAssertEqual(String(attributed.characters), "hello world")
    }

    // MARK: - Match map / navigation

    func testMatchMapCountsPerBlockAndTotal() {
        let blocks = ["one one", "two", "one two one"]
        let map = TranscriptMatchMap(blocks: blocks, query: "one")
        XCTAssertEqual(map.perBlock, [2, 0, 2])
        XCTAssertEqual(map.total, 4)
    }

    func testMatchMapLocatesGlobalMatch() {
        let blocks = ["one one", "two", "one two one"]
        let map = TranscriptMatchMap(blocks: blocks, query: "one")

        XCTAssertEqual(map.location(of: 0).map { [$0.block, $0.localMatch] }, [0, 0])
        XCTAssertEqual(map.location(of: 1).map { [$0.block, $0.localMatch] }, [0, 1])
        XCTAssertEqual(map.location(of: 2).map { [$0.block, $0.localMatch] }, [2, 0])
        XCTAssertEqual(map.location(of: 3).map { [$0.block, $0.localMatch] }, [2, 1])
    }

    func testMatchMapOutOfRangeReturnsNil() {
        let map = TranscriptMatchMap(blocks: ["one"], query: "one")
        XCTAssertNil(map.location(of: -1))
        XCTAssertNil(map.location(of: 1))
    }

    func testMatchMapEmptyQueryHasNoMatches() {
        let map = TranscriptMatchMap(blocks: ["one", "two"], query: "")
        XCTAssertEqual(map.total, 0)
        XCTAssertNil(map.location(of: 0))
    }
}
