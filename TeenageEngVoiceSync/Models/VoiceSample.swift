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

    /// Stable identity used to detect exact duplicate samples. Prefers the
    /// content hash plus segment range so distinct segments of one recording
    /// stay distinct and renamed files still collide. Falls back to
    /// filename + range for legacy samples that predate content hashing.
    var sourceIdentity: String {
        Self.sourceIdentity(
            sourceHash: sourceHash,
            recordingFilename: recordingFilename,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// Builds a source identity from raw components. Exposed so the enrollment
    /// path can test a candidate for duplication before constructing a sample.
    static func sourceIdentity(
        sourceHash: String?,
        recordingFilename: String?,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> String {
        let range = "\(startTime)-\(endTime)"
        if let sourceHash, !sourceHash.isEmpty {
            return "hash:\(sourceHash)#\(range)"
        }
        if let recordingFilename, !recordingFilename.isEmpty {
            return "file:\(recordingFilename)#\(range)"
        }
        return "none:#\(range)"
    }

    /// True when a sample with `identity` already exists in `samples`.
    static func isDuplicate(identity: String, in samples: [VoiceSample]) -> Bool {
        samples.contains { $0.sourceIdentity == identity }
    }

    /// Returns the samples that duplicate an earlier one (by source identity)
    /// and should be removed. The earliest-added sample of each identity is
    /// kept; every later collision is returned for deletion.
    static func duplicatesToRemove(from samples: [VoiceSample]) -> [VoiceSample] {
        var seen = Set<String>()
        var duplicates: [VoiceSample] = []
        for sample in samples.sorted(by: { $0.addedAt < $1.addedAt }) {
            if !seen.insert(sample.sourceIdentity).inserted {
                duplicates.append(sample)
            }
        }
        return duplicates
    }
}
