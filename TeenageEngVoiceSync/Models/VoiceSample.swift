import SwiftData
import Foundation

@Model
final class VoiceSample {
    var addedAt: Date
    /// Filename of the recording this sample was extracted from, if known.
    var recordingFilename: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var embedding: [Float]
    var person: Person?

    init(
        recordingFilename: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        embedding: [Float]
    ) {
        self.addedAt = Date()
        self.recordingFilename = recordingFilename
        self.startTime = startTime
        self.endTime = endTime
        self.embedding = embedding
    }
}
