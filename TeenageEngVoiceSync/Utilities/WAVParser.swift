//
//  WAVParser.swift
//  TeenageEngVoiceSync
//
//  Parse WAV file metadata (duration, sample rate, etc.)
//

import Foundation
import AVFoundation

struct WAVMetadata {
    let duration: TimeInterval
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
}

enum WAVParser {
    enum WAVError: LocalizedError {
        case fileNotFound
        case invalidFormat
        case unableToReadMetadata

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "WAV file not found"
            case .invalidFormat:
                return "Invalid WAV file format"
            case .unableToReadMetadata:
                return "Unable to read WAV metadata"
            }
        }
    }

    /// Parses metadata from a WAV file using AVFoundation
    static func parse(url: URL) async throws -> WAVMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WAVError.fileNotFound
        }

        let asset = AVURLAsset(url: url)

        // Load duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Load format descriptions from audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WAVError.invalidFormat
        }

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else {
            throw WAVError.unableToReadMetadata
        }

        // Extract audio stream basic description
        let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd = basicDescription?.pointee else {
            throw WAVError.unableToReadMetadata
        }

        return WAVMetadata(
            duration: durationSeconds,
            sampleRate: Int(asbd.mSampleRate),
            channels: Int(asbd.mChannelsPerFrame),
            bitDepth: Int(asbd.mBitsPerChannel)
        )
    }

    /// Extracts just the duration for quick access
    static func duration(url: URL) async throws -> TimeInterval {
        let metadata = try await parse(url: url)
        return metadata.duration
    }
}
