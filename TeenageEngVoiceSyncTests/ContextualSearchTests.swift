//
//  ContextualSearchTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the section-scoped toolbar search (TP-11): each sidebar section owns
//  its own prompt and filtering, an empty/whitespace query means "no search",
//  and search state never leaks between sections.
//

import XCTest
@testable import TP_7_VoiceSync

final class ContextualSearchTests: XCTestCase {

    // MARK: Fixtures

    private func makeRecording(
        filename: String,
        title: String? = nil,
        transcript: String? = nil
    ) -> Recording {
        let recording = Recording(
            filename: filename,
            localPath: "/tmp/\(filename)",
            fileSize: 1234,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        recording.llmTitle = title
        recording.transcriptionText = transcript
        return recording
    }

    // MARK: Prompt / searchability per section

    func testEachSectionHasContextualPrompt() {
        XCTAssertEqual(SidebarItem.recordings.searchPrompt, "Search recordings")
        XCTAssertEqual(SidebarItem.people.searchPrompt, "Search people")
        XCTAssertNil(SidebarItem.settings.searchPrompt)
    }

    func testSettingsIsNotSearchable() {
        XCTAssertTrue(SidebarItem.recordings.isSearchable)
        XCTAssertTrue(SidebarItem.people.isSearchable)
        XCTAssertFalse(SidebarItem.settings.isSearchable)
    }

    // MARK: isActive

    func testIsActiveTreatsEmptyAndWhitespaceAsInactive() {
        XCTAssertFalse(ContextualSearch.isActive(""))
        XCTAssertFalse(ContextualSearch.isActive("   "))
        XCTAssertFalse(ContextualSearch.isActive("\n\t"))
        XCTAssertTrue(ContextualSearch.isActive("a"))
        XCTAssertTrue(ContextualSearch.isActive("  a  "))
    }

    // MARK: Recording filtering

    func testEmptyQueryReturnsAllRecordings() {
        let recordings = [makeRecording(filename: "0001.wav"), makeRecording(filename: "0002.wav")]
        XCTAssertEqual(ContextualSearch.filter(recordings: recordings, query: "").count, 2)
        XCTAssertEqual(ContextualSearch.filter(recordings: recordings, query: "   ").count, 2)
    }

    func testRecordingFilterMatchesTitleFilenameAndTranscript() {
        let byTitle = makeRecording(filename: "0001.wav", title: "Weekly planning sync")
        let byFilename = makeRecording(filename: "standup.wav")
        let byTranscript = makeRecording(filename: "0003.wav", transcript: "we discussed the budget")
        let recordings = [byTitle, byFilename, byTranscript]

        XCTAssertEqual(ContextualSearch.filter(recordings: recordings, query: "planning"), [byTitle])
        XCTAssertEqual(ContextualSearch.filter(recordings: recordings, query: "standup"), [byFilename])
        XCTAssertEqual(ContextualSearch.filter(recordings: recordings, query: "budget"), [byTranscript])
    }

    func testRecordingFilterIsCaseInsensitiveAndTrimsQuery() {
        let recording = makeRecording(filename: "0001.wav", title: "Weekly Planning Sync")
        XCTAssertEqual(ContextualSearch.filter(recordings: [recording], query: "  PLANNING  "), [recording])
    }

    func testRecordingFilterNoMatchesReturnsEmpty() {
        let recordings = [makeRecording(filename: "0001.wav", title: "Standup")]
        XCTAssertTrue(ContextualSearch.filter(recordings: recordings, query: "nonexistent").isEmpty)
    }

    // MARK: Person filtering

    func testEmptyQueryReturnsAllPersons() {
        let persons = [Person(name: "Alice"), Person(name: "Bob")]
        XCTAssertEqual(ContextualSearch.filter(persons: persons, query: "").count, 2)
        XCTAssertEqual(ContextualSearch.filter(persons: persons, query: "  ").count, 2)
    }

    func testPersonFilterMatchesByNameCaseInsensitively() {
        let alice = Person(name: "Alice")
        let bob = Person(name: "Bob")
        let persons = [alice, bob]

        XCTAssertEqual(ContextualSearch.filter(persons: persons, query: "ali").map(\.name), ["Alice"])
        XCTAssertEqual(ContextualSearch.filter(persons: persons, query: "BOB").map(\.name), ["Bob"])
    }

    func testPersonFilterTrimsQuery() {
        let persons = [Person(name: "Cameron")]
        XCTAssertEqual(ContextualSearch.filter(persons: persons, query: "  cam  ").map(\.name), ["Cameron"])
    }

    func testPersonFilterNoMatchesReturnsEmpty() {
        let persons = [Person(name: "Alice")]
        XCTAssertTrue(ContextualSearch.filter(persons: persons, query: "zzz").isEmpty)
    }

    // MARK: Cross-section isolation
    //
    // The explicit rule (ContentView clears searchText on section switch) means a
    // query only ever runs against its own section's collection. These assert that
    // the two filters are independent: a person-oriented query does not smuggle
    // recordings through, and vice versa.

    func testPersonQueryDoesNotMatchUnrelatedRecordings() {
        let recordings = [makeRecording(filename: "0001.wav", title: "Standup notes")]
        // "Alice" is a person's name; it must not accidentally match recordings.
        XCTAssertTrue(ContextualSearch.filter(recordings: recordings, query: "Alice").isEmpty)
    }
}
