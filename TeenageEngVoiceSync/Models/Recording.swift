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

    // Audio metadata
    var recordedAt: Date
    var duration: TimeInterval?
    var sampleRate: Int?
    var fileSize: Int64

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
