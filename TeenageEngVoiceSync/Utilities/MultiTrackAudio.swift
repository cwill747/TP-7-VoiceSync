//
//  MultiTrackAudio.swift
//  TeenageEngVoiceSync
//
//  Splits a TP-7 multi-track WAV (2N channels, dual-mono pairs) into N mono
//  WAV temp files so each track can be transcribed independently.
//

import Foundation
import AVFoundation

enum MultiTrackAudio {
    enum MultiTrackAudioError: LocalizedError {
        case unableToCreateBuffer
        case unableToReadChannelData

        var errorDescription: String? {
            switch self {
            case .unableToCreateBuffer:
                return "Unable to allocate audio buffer for track splitting"
            case .unableToReadChannelData:
                return "Unable to read channel data from audio file"
            }
        }
    }

    /// Splits an N-track WAV (2N channels) into N mono WAV temp files.
    /// Track i = average of channels [2i, 2i+1] (identical pair → lossless).
    /// Files with 2 or fewer channels are single-track; returns `[url]` unchanged.
    /// Returns an array of length `trackCount`; caller deletes the temp files.
    static func extractTracks(from url: URL) throws -> [URL] {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let channelCount = Int(sourceFormat.channelCount)

        guard channelCount > 2 else { return [url] }

        let trackCount = channelCount / 2
        let frameCount = AVAudioFrameCount(sourceFile.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw MultiTrackAudioError.unableToCreateBuffer
        }
        try sourceFile.read(into: sourceBuffer)

        guard let sourceChannels = sourceBuffer.floatChannelData else {
            throw MultiTrackAudioError.unableToReadChannelData
        }

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1) else {
            throw MultiTrackAudioError.unableToCreateBuffer
        }

        var trackURLs: [URL] = []
        for track in 0..<trackCount {
            guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
                throw MultiTrackAudioError.unableToCreateBuffer
            }
            monoBuffer.frameLength = frameCount

            let left = sourceChannels[track * 2]
            let right = sourceChannels[track * 2 + 1]
            let output = monoBuffer.floatChannelData![0]
            for frame in 0..<Int(frameCount) {
                output[frame] = (left[frame] + right[frame]) * 0.5
            }

            let trackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-track\(track).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ]
            let outputFile = try AVAudioFile(forWriting: trackURL, settings: settings)
            try outputFile.write(from: monoBuffer)

            trackURLs.append(trackURL)
        }

        return trackURLs
    }
}
