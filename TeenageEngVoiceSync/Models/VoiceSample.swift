import SwiftData
import Foundation

@Model
final class VoiceSample {
    var addedAt: Date
    /// Filename of the recording this sample was extracted from, if known.
    var recordingFilename: String?
    /// SHA256 content hash of the source audio file. Combined with the segment
    /// range this forms a stable source identity for duplicate detection that
    /// survives renames. Nil for legacy samples enrolled before hashing existed.
    var sourceHash: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var embedding: [Float]
    var person: Person?

    init(
        recordingFilename: String? = nil,
        sourceHash: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        embedding: [Float]
    ) {
        self.addedAt = Date()
        self.recordingFilename = recordingFilename
        self.sourceHash = sourceHash
        self.startTime = startTime
        self.endTime = endTime
        self.embedding = embedding
    }

    /// Whether two samples describe the same source clip/segment. Segments must
    /// cover the same range; within that, matching non-empty content hashes are
    /// authoritative, and when either side lacks a hash (legacy rows) we fall
    /// back to comparing filenames. This cross-compatibility means a newly
    /// hashed sample still collides with a pre-update, hash-less row for the
    /// same file.
    func isSameSource(as other: VoiceSample) -> Bool {
        Self.isSameSource(
            sourceHash: sourceHash,
            recordingFilename: recordingFilename,
            startTime: startTime,
            endTime: endTime,
            asSourceHash: other.sourceHash,
            recordingFilename: other.recordingFilename,
            startTime: other.startTime,
            endTime: other.endTime
        )
    }

    /// Component-based `isSameSource`, so the enrollment/reassignment paths can
    /// test a candidate before constructing a sample.
    static func isSameSource(
        sourceHash lhsHash: String?,
        recordingFilename lhsFile: String?,
        startTime lhsStart: TimeInterval,
        endTime lhsEnd: TimeInterval,
        asSourceHash rhsHash: String?,
        recordingFilename rhsFile: String?,
        startTime rhsStart: TimeInterval,
        endTime rhsEnd: TimeInterval
    ) -> Bool {
        guard lhsStart == rhsStart, lhsEnd == rhsEnd else { return false }

        let lhsHasHash = !(lhsHash ?? "").isEmpty
        let rhsHasHash = !(rhsHash ?? "").isEmpty
        let lhsHasFile = !(lhsFile ?? "").isEmpty
        let rhsHasFile = !(rhsFile ?? "").isEmpty

        // Matching content hashes are authoritative.
        if lhsHasHash, rhsHasHash {
            return lhsHash == rhsHash
        }
        // When either side predates content hashing, fall back to comparing
        // filenames.
        if lhsHasFile, rhsHasFile {
            return lhsFile == rhsFile
        }
        // Range-only equality applies solely when BOTH sides are completely
        // unidentified (e.g. two migrated seed samples that carry neither a
        // hash nor a filename). An identified sample must never match an
        // unidentified one, or dedupe could delete legitimate samples.
        return !(lhsHasHash || lhsHasFile) && !(rhsHasHash || rhsHasFile)
    }

    /// True when `samples` already contains one describing the same source as
    /// the given candidate components.
    static func isDuplicate(
        sourceHash: String?,
        recordingFilename: String?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        in samples: [VoiceSample]
    ) -> Bool {
        samples.contains { existing in
            isSameSource(
                sourceHash: sourceHash,
                recordingFilename: recordingFilename,
                startTime: startTime,
                endTime: endTime,
                asSourceHash: existing.sourceHash,
                recordingFilename: existing.recordingFilename,
                startTime: existing.startTime,
                endTime: existing.endTime
            )
        }
    }

    /// Returns the samples that duplicate an earlier one (same source) and
    /// should be removed. The earliest-added sample of each source is kept;
    /// every later collision is returned for deletion.
    static func duplicatesToRemove(from samples: [VoiceSample]) -> [VoiceSample] {
        var kept: [VoiceSample] = []
        var duplicates: [VoiceSample] = []
        for sample in samples.sorted(by: { $0.addedAt < $1.addedAt }) {
            if kept.contains(where: { $0.isSameSource(as: sample) }) {
                duplicates.append(sample)
            } else {
                kept.append(sample)
            }
        }
        return duplicates
    }
}
