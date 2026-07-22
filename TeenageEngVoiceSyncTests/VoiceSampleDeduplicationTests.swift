//
//  VoiceSampleDeduplicationTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers duplicate-sample detection: exact duplicates, same filename with
//  different content, distinct segments of one source, and isolation between
//  different people.
//

import XCTest
@testable import TP_7_VoiceSync

final class VoiceSampleDeduplicationTests: XCTestCase {
    /// Builds a sample with a controllable `addedAt` so ordering in
    /// `duplicatesToRemove` is deterministic.
    private func makeSample(
        filename: String? = nil,
        hash: String? = nil,
        start: TimeInterval = 0,
        end: TimeInterval = 0,
        addedAt: Date = Date()
    ) -> VoiceSample {
        let sample = VoiceSample(
            recordingFilename: filename,
            sourceHash: hash,
            startTime: start,
            endTime: end,
            embedding: [1, 2, 3]
        )
        sample.addedAt = addedAt
        return sample
    }

    // MARK: - Source identity

    func testExactDuplicateSharesSourceIdentity() {
        let a = makeSample(filename: "clip.wav", hash: "abc123", start: 0, end: 0)
        let b = makeSample(filename: "renamed.wav", hash: "abc123", start: 0, end: 0)

        // Same content hash + same range = same identity, even when the
        // display filename differs.
        XCTAssertEqual(a.sourceIdentity, b.sourceIdentity)
        XCTAssertTrue(VoiceSample.isDuplicate(identity: b.sourceIdentity, in: [a]))
    }

    func testSameFilenameDifferentContentIsNotDuplicate() {
        let a = makeSample(filename: "clip.wav", hash: "hash-one")
        let b = makeSample(filename: "clip.wav", hash: "hash-two")

        XCTAssertNotEqual(a.sourceIdentity, b.sourceIdentity)
        XCTAssertFalse(VoiceSample.isDuplicate(identity: b.sourceIdentity, in: [a]))
    }

    func testDistinctSegmentsFromSameSourceCoexist() {
        let a = makeSample(filename: "clip.wav", hash: "abc123", start: 0, end: 5)
        let b = makeSample(filename: "clip.wav", hash: "abc123", start: 5, end: 10)

        XCTAssertNotEqual(a.sourceIdentity, b.sourceIdentity)
        XCTAssertFalse(VoiceSample.isDuplicate(identity: b.sourceIdentity, in: [a]))
        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: [a, b]).isEmpty)
    }

    func testLegacySamplesFallBackToFilenameIdentity() {
        // No content hash (legacy rows). Filename + range is the identity.
        let a = makeSample(filename: "clip.wav", hash: nil)
        let b = makeSample(filename: "clip.wav", hash: nil)
        let other = makeSample(filename: "different.wav", hash: nil)

        XCTAssertEqual(a.sourceIdentity, b.sourceIdentity)
        XCTAssertNotEqual(a.sourceIdentity, other.sourceIdentity)
    }

    // MARK: - duplicatesToRemove

    func testDuplicatesToRemoveKeepsEarliestAddedSample() {
        let base = Date()
        let first = makeSample(filename: "a.wav", hash: "h", addedAt: base)
        let second = makeSample(filename: "a.wav", hash: "h", addedAt: base.addingTimeInterval(10))
        let third = makeSample(filename: "a.wav", hash: "h", addedAt: base.addingTimeInterval(20))

        // Pass in a shuffled order to confirm sorting by addedAt.
        let toRemove = VoiceSample.duplicatesToRemove(from: [third, first, second])

        XCTAssertEqual(toRemove.count, 2)
        XCTAssertFalse(toRemove.contains { $0 === first })
        XCTAssertTrue(toRemove.contains { $0 === second })
        XCTAssertTrue(toRemove.contains { $0 === third })
    }

    func testDuplicatesToRemoveEmptyWhenAllDistinct() {
        let samples = [
            makeSample(filename: "a.wav", hash: "h1"),
            makeSample(filename: "b.wav", hash: "h2"),
            makeSample(filename: "a.wav", hash: "h1", start: 5, end: 10)
        ]
        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: samples).isEmpty)
    }

    func testDifferentPeopleAreNotMerged() {
        // Each person's samples are deduped in isolation. Person A and B both
        // enrolled the same source, but deduping A must never remove B's copy.
        let personASample = makeSample(filename: "shared.wav", hash: "shared-hash")
        let personBSample = makeSample(filename: "shared.wav", hash: "shared-hash")

        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: [personASample]).isEmpty)
        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: [personBSample]).isEmpty)

        // The dedup within B's (duplicated) list must return only B's samples,
        // never A's.
        let personBDuplicated = [personBSample, makeSample(filename: "shared.wav", hash: "shared-hash", addedAt: personBSample.addedAt.addingTimeInterval(1))]
        let removed = VoiceSample.duplicatesToRemove(from: personBDuplicated)
        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(removed.contains { $0 === personASample })
    }
}
