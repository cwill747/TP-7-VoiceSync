//
//  Recording.swift
//  TeenageEngVoiceSync
//
//  SwiftData model for audio recordings.
//

import SwiftData
import Foundation

@Model
final class Recording {
    // Identity
    @Attribute(.unique) var filename: String
    var localPath: String
    var deviceSerial: String?
    /// Which on-device TP-7 folder this recording came from, when known.
    /// Nil for recordings recovered from S3/Notion/local storage with no device origin.
    var sourceFolder: RecordingSource?
    /// The literal on-device filename, needed for MTP delete calls. Differs from
    /// `filename` for /memo recordings, whose app-wide identity is qualified with
    /// a prefix to stay collision-free against /recordings (see
    /// `DeviceWatchService.localFilename`). Nil for non-device recordings.
    var deviceFilename: String?

    // Audio metadata
    var recordedAt: Date
    var duration: TimeInterval?
    var sampleRate: Int?
    var fileSize: Int64
    /// Number of TP-7 tracks packed into this file (2 channels per track,
    /// dual-mono pairs). 1 for plain single-track recordings.
    var trackCount: Int = 1

    // Upload status
    var s3Key: String?
    var s3UploadedAt: Date?
    var fileHash: String?
    var localCopyPath: String?  // Path in user's configured audio folder (not TP-7 device)

    // Transcription
    var transcriptionText: String?
    var transcriptionLanguage: String?
    @Attribute var transcriptionStatus: TranscriptionStatus
    var transcribedAt: Date?

    // LLM-generated content
    var llmTitle: String?
    var llmSummary: String?
    var llmProcessedAt: Date?

    // Apple Notes integration
    var appleNoteCreatedAt: Date?

    // Notion integration
    var notionPageCreatedAt: Date?

    // Diarization output — JSON-encoded [StoredSpeakerSegment]
    var speakerSegmentsData: Data?

    // Overdub notes output (memo tracks 1+) — JSON-encoded [OverdubNote]
    var overdubNotesData: Data?

    // Metadata
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        filename: String,
        localPath: String,
        fileSize: Int64,
        recordedAt: Date
    ) {
        self.filename = filename
        self.localPath = localPath
        self.fileSize = fileSize
        self.recordedAt = recordedAt
        self.transcriptionStatus = .none
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var isUploaded: Bool { s3Key != nil }
    var isTranscribed: Bool { transcriptionStatus == .completed }
    var isDeleted: Bool { deletedAt != nil }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedDuration: String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum TranscriptionStatus: String, Codable {
    case none
    case pending
    case processing
    case completed
    case failed
}

/// Which on-device TP-7 folder a recording was ingested from. The TP-7 can be
/// configured to split recordings between these two MTP folders. Only /memo
/// is guaranteed to be the primary user's voice alone (used to skip
/// diarization); /recordings can capture other speakers (interviews,
/// meetings, etc.) and goes through diarization as normal.
enum RecordingSource: String, Codable, CaseIterable {
    case recordings
    case memo

    var displayName: String {
        switch self {
        case .recordings: return "Recording"
        case .memo: return "Memo"
        }
    }
}

/// One speaker turn extracted during diarization, stored on the recording so
/// labels can be corrected and the transcript re-derived without re-running ASR.
nonisolated struct StoredSpeakerSegment: Codable, Identifiable, Sendable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// Raw speaker ID from the diarizer (opaque string, stable within a recording).
    var rawSpeakerId: String
    /// The words attributed to this segment.
    var text: String
    /// Speaker embedding extracted during diarization — used to add this segment
    /// as a VoiceSample when the user corrects a label.
    var embedding: [Float]
    /// User-assigned person name (overrides the auto-resolved label).
    var assignedPersonName: String?
    /// Stable person ID so renaming a person doesn't lose the correction.
    var assignedPersonId: String?

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        rawSpeakerId: String,
        text: String,
        embedding: [Float],
        assignedPersonName: String? = nil,
        assignedPersonId: String? = nil
    ) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.rawSpeakerId = rawSpeakerId
        self.text = text
        self.embedding = embedding
        self.assignedPersonName = assignedPersonName
        self.assignedPersonId = assignedPersonId
    }
}

/// A transcribed overdub layer on top of a TP-7 /memo recording's base track.
/// Memo overdubs are the same speaker as the base track (no diarization needed) —
/// this just records the note text and where it falls on the base memo's timeline,
/// since every track in an overdubbed memo is the same length and shares that timeline.
struct OverdubNote: Codable, Sendable, Identifiable {
    var id: UUID
    /// 1-based overdub layer (track 0 is the base memo and isn't represented here).
    var trackIndex: Int
    /// Time on the base memo's timeline where this note begins.
    var startTime: TimeInterval
    var text: String

    init(trackIndex: Int, startTime: TimeInterval, text: String) {
        self.id = UUID()
        self.trackIndex = trackIndex
        self.startTime = startTime
        self.text = text
    }
}
