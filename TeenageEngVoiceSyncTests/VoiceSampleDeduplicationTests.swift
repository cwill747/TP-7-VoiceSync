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

    /// Convenience: is `candidate` a duplicate of anything in `existing`?
    private func isDuplicate(_ candidate: VoiceSample, in existing: [VoiceSample]) -> Bool {
        VoiceSample.isDuplicate(
            sourceHash: candidate.sourceHash,
            recordingFilename: candidate.recordingFilename,
            startTime: candidate.startTime,
            endTime: candidate.endTime,
            in: existing
        )
    }

    // MARK: - Source matching

    func testExactDuplicateMatchesByContentHash() {
        let a = makeSample(filename: "clip.wav", hash: "abc123", start: 0, end: 0)
        let b = makeSample(filename: "renamed.wav", hash: "abc123", start: 0, end: 0)

        // Same content hash + same range = same source, even when the display
        // filename differs (rename).
        XCTAssertTrue(a.isSameSource(as: b))
        XCTAssertTrue(isDuplicate(b, in: [a]))
    }

    func testSameFilenameDifferentContentIsNotDuplicate() {
        let a = makeSample(filename: "clip.wav", hash: "hash-one")
        let b = makeSample(filename: "clip.wav", hash: "hash-two")

        XCTAssertFalse(a.isSameSource(as: b))
        XCTAssertFalse(isDuplicate(b, in: [a]))
    }

    func testDistinctSegmentsFromSameSourceCoexist() {
        let a = makeSample(filename: "clip.wav", hash: "abc123", start: 0, end: 5)
        let b = makeSample(filename: "clip.wav", hash: "abc123", start: 5, end: 10)

        XCTAssertFalse(a.isSameSource(as: b))
        XCTAssertFalse(isDuplicate(b, in: [a]))
        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: [a, b]).isEmpty)
    }

    func testLegacySamplesMatchByFilename() {
        // No content hash (legacy rows). Filename + range is the identity.
        let a = makeSample(filename: "clip.wav", hash: nil)
        let b = makeSample(filename: "clip.wav", hash: nil)
        let other = makeSample(filename: "different.wav", hash: nil)

        XCTAssertTrue(a.isSameSource(as: b))
        XCTAssertFalse(a.isSameSource(as: other))
    }

    func testHashedCandidateMatchesLegacyHashlessRowForSameFile() {
        // A pre-update sample stored without a hash must still be recognized as
        // a duplicate when the same file is re-added and now carries a hash.
        let legacy = makeSample(filename: "clip.wav", hash: nil)
        let hashed = makeSample(filename: "clip.wav", hash: "abc123")

        XCTAssertTrue(hashed.isSameSource(as: legacy))
        XCTAssertTrue(isDuplicate(hashed, in: [legacy]))
        // And the launch repair collapses the mixed pair to a single sample.
        XCTAssertEqual(VoiceSample.duplicatesToRemove(from: [legacy, hashed]).count, 1)
    }

    func testUnidentifiedSeedDoesNotMatchIdentifiedSample() {
        // A migrated seed sample carries no hash and no filename, at range 0...0.
        // It must not collide with a real full-file enrollment sharing that range,
        // or launch dedupe would delete legitimate samples.
        let seed = makeSample(filename: nil, hash: nil, start: 0, end: 0)
        let enrolled = makeSample(filename: "clip.wav", hash: "abc123", start: 0, end: 0)

        XCTAssertFalse(seed.isSameSource(as: enrolled))
        XCTAssertFalse(isDuplicate(enrolled, in: [seed]))
        XCTAssertTrue(VoiceSample.duplicatesToRemove(from: [seed, enrolled]).isEmpty)
    }

    func testTwoUnidentifiedSeedsCollapse() {
        // Two fully unidentified rows at the same range are indistinguishable,
        // so the later one is a duplicate.
        let base = Date()
        let a = makeSample(filename: nil, hash: nil, addedAt: base)
        let b = makeSample(filename: nil, hash: nil, addedAt: base.addingTimeInterval(1))

        XCTAssertTrue(a.isSameSource(as: b))
        XCTAssertEqual(VoiceSample.duplicatesToRemove(from: [a, b]).count, 1)
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
