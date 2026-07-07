//
//  SpeakerAssignmentTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class SpeakerAssignmentTests: XCTestCase {
    func testApplyAssignmentUpdatesEverySegmentWithMatchingSpeakerHash() {
        var segments = [
            StoredSpeakerSegment(
                startTime: 0,
                endTime: 1,
                rawSpeakerId: "speaker-a",
                speakerHash: "hash-a",
                text: "first",
                embedding: [1, 2]
            ),
            StoredSpeakerSegment(
                startTime: 1,
                endTime: 2,
                rawSpeakerId: "speaker-b",
                speakerHash: "hash-b",
                text: "second",
                embedding: [3, 4]
            ),
            StoredSpeakerSegment(
                startTime: 2,
                endTime: 3,
                rawSpeakerId: "speaker-a",
                speakerHash: "hash-a",
                text: "third",
                embedding: [1, 2]
            )
        ]

        let changed = StoredSpeakerSegment.applyAssignment(
            to: &segments,
            matching: "hash-a",
            personId: "person-1",
            personName: "Alex"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(segments[0].assignedPersonId, "person-1")
        XCTAssertEqual(segments[0].assignedPersonName, "Alex")
        XCTAssertNil(segments[1].assignedPersonId)
        XCTAssertNil(segments[1].assignedPersonName)
        XCTAssertEqual(segments[2].assignedPersonId, "person-1")
        XCTAssertEqual(segments[2].assignedPersonName, "Alex")
        XCTAssertEqual(
            StoredSpeakerSegment.transcript(from: segments),
            "Alex: first\n\nspeaker-b: second\n\nAlex: third"
        )
    }

    func testApplyAssignmentFallsBackToRawSpeakerIdForLegacySegments() {
        var segments = [
            StoredSpeakerSegment(
                startTime: 0,
                endTime: 1,
                rawSpeakerId: "legacy-speaker",
                text: "hello",
                embedding: []
            ),
            StoredSpeakerSegment(
                startTime: 1,
                endTime: 2,
                rawSpeakerId: "other-speaker",
                text: "there",
                embedding: []
            )
        ]

        let changed = StoredSpeakerSegment.applyAssignment(
            to: &segments,
            matching: "legacy-speaker",
            personId: "person-2",
            personName: "Sam"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(segments[0].assignedPersonName, "Sam")
        XCTAssertNil(segments[1].assignedPersonName)
    }

    func testSpeakerHashIsStableForSameEmbedding() {
        let embedding: [Float] = [0.1, -0.2, 0.3]

        XCTAssertEqual(
            StoredSpeakerSegment.hash(for: embedding, fallback: "speaker"),
            StoredSpeakerSegment.hash(for: embedding, fallback: "other-speaker")
        )
        XCTAssertEqual(StoredSpeakerSegment.hash(for: [], fallback: "fallback"), "fallback")
    }
}
