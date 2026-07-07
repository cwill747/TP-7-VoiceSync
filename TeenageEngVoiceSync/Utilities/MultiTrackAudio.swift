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

    /// Frames processed per chunk — bounds peak memory regardless of file length
    /// (e.g. a 4ch/96kHz recording won't require buffering gigabytes at once).
    static let defaultChunkFrameCount: AVAudioFrameCount = 1 << 18

    /// Peak amplitude at or below which a whole track is considered silent and
    /// dropped. The TP-7 writes a fixed channel count for a recording and leaves
    /// unused track slots as digital zeros (an overdub bounced onto track 0
    /// leaves track 1 all-zero), so a real single-track file otherwise looks
    /// like a phantom multi-track/multi-speaker capture. ≈ -80 dBFS: well below
    /// speech (peaks ~0.3) but above dead silence, so a genuinely used track is
    /// never dropped.
    static let silenceThreshold: Float = 1e-4

    /// Splits an N-track WAV (2N channels) into mono WAV temp files, one per
    /// track that actually contains audio. Track i = average of channels
    /// [2i, 2i+1] (identical pair → lossless). All-silent tracks are dropped
    /// (see `silenceThreshold`); an entirely silent file keeps track 0 so there
    /// is always something to transcribe. Files with 2 or fewer channels are
    /// single-track; returns `[url]` unchanged. Caller deletes the temp files.
    /// Processes the source in bounded chunks rather than loading it whole.
    static func extractTracks(from url: URL, chunkFrameCount: AVAudioFrameCount = defaultChunkFrameCount) throws -> [URL] {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let channelCount = Int(sourceFormat.channelCount)

        guard channelCount > 2 else { return [url] }

        let trackCount = channelCount / 2

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1) else {
            throw MultiTrackAudioError.unableToCreateBuffer
        }

        var trackURLs: [URL] = []
        var outputFiles: [AVAudioFile] = []
        for track in 0..<trackCount {
            let trackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-track\(track).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ]
            outputFiles.append(try AVAudioFile(forWriting: trackURL, settings: settings))
            trackURLs.append(trackURL)
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrameCount),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrameCount) else {
            throw MultiTrackAudioError.unableToCreateBuffer
        }

        var trackPeak = [Float](repeating: 0, count: trackCount)

        while sourceFile.framePosition < sourceFile.length {
            try sourceFile.read(into: sourceBuffer, frameCount: chunkFrameCount)
            let framesRead = sourceBuffer.frameLength
            guard framesRead > 0 else { break }

            guard let sourceChannels = sourceBuffer.floatChannelData else {
                throw MultiTrackAudioError.unableToReadChannelData
            }

            monoBuffer.frameLength = framesRead
            let output = monoBuffer.floatChannelData![0]
            for track in 0..<trackCount {
                let left = sourceChannels[track * 2]
                let right = sourceChannels[track * 2 + 1]
                var peak = trackPeak[track]
                for frame in 0..<Int(framesRead) {
                    let sample = (left[frame] + right[frame]) * 0.5
                    output[frame] = sample
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
                trackPeak[track] = peak
                try outputFiles[track].write(from: monoBuffer)
            }
        }

        // Keep only tracks that carry audio; delete the silent ones' temp files.
        var kept: [URL] = []
        for (index, trackURL) in trackURLs.enumerated() where trackPeak[index] > silenceThreshold {
            kept.append(trackURL)
        }
        if kept.isEmpty {
            kept = [trackURLs[0]]  // entirely silent file — keep track 0
        }
        for trackURL in trackURLs where !kept.contains(trackURL) {
            try? FileManager.default.removeItem(at: trackURL)
        }
        return kept
    }
}
