//
//  MultiTrackAudioTests.swift
//  TeenageEngVoiceSyncTests
//
//  Exercises MultiTrackAudio against synthesized dual-mono fixtures modeling
//  real TP-7 output: a 2ch dual-mono file (1 track) and a 4ch file with two
//  independent dual-mono track pairs (2 tracks).
//

import XCTest
import AVFoundation
@testable import TP_7_VoiceSync

final class MultiTrackAudioTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiTrackAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func write(_ data: Data, name: String) -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private func readFloatSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw WAVParser.WAVError.unableToReadMetadata
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameCount)))
    }

    func testDualMonoStereoReturnsSingleTrackUnchanged() throws {
        let mono: [Int16] = (0..<100).map { Int16($0 * 10) }
        let data = makeMultiChannelWAVData(channelSamples: [mono, mono])
        let url = write(data, name: "dual-mono.wav")

        let tracks = try MultiTrackAudio.extractTracks(from: url)

        XCTAssertEqual(tracks, [url])
    }

    func testFourChannelSplitsIntoTwoIndependentTracks() throws {
        let track0: [Int16] = (0..<200).map { Int16($0 % 100) }
        let track1: [Int16] = (0..<200).map { Int16(($0 * 3) % 100) }
        // Dual-mono pairs: channels [0,1] = track0, channels [2,3] = track1.
        let data = makeMultiChannelWAVData(channelSamples: [track0, track0, track1, track1])
        let url = write(data, name: "quad.wav")

        let tracks = try MultiTrackAudio.extractTracks(from: url)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertNotEqual(tracks[0], url)
        XCTAssertNotEqual(tracks[1], url)

        let file0 = try AVAudioFile(forReading: tracks[0])
        let file1 = try AVAudioFile(forReading: tracks[1])
        XCTAssertEqual(file0.processingFormat.channelCount, 1)
        XCTAssertEqual(file1.processingFormat.channelCount, 1)

        let samples0 = try readFloatSamples(tracks[0])
        let samples1 = try readFloatSamples(tracks[1])

        XCTAssertEqual(samples0.count, 200)
        XCTAssertEqual(samples1.count, 200)
        for index in 0..<200 {
            XCTAssertEqual(samples0[index], Float(track0[index]) / 32768.0, accuracy: 0.0001)
            XCTAssertEqual(samples1[index], Float(track1[index]) / 32768.0, accuracy: 0.0001)
        }
        XCTAssertNotEqual(samples0, samples1)

        try? FileManager.default.removeItem(at: tracks[0])
        try? FileManager.default.removeItem(at: tracks[1])
    }

    func testSilentTrackPairIsDropped() throws {
        // A TP-7 recording with the overdub bounced onto track 0 leaves track 1
        // (channels 2,3) all-zero — it should be dropped, leaving a single track.
        let track0: [Int16] = (0..<200).map { Int16(($0 % 50) * 100) }
        let silent = [Int16](repeating: 0, count: 200)
        let data = makeMultiChannelWAVData(channelSamples: [track0, track0, silent, silent])
        let url = write(data, name: "quad-silent-second.wav")

        let tracks = try MultiTrackAudio.extractTracks(from: url)

        XCTAssertEqual(tracks.count, 1)
        let samples0 = try readFloatSamples(tracks[0])
        XCTAssertEqual(samples0.count, 200)
        for index in 0..<200 {
            XCTAssertEqual(samples0[index], Float(track0[index]) / 32768.0, accuracy: 0.0001)
        }

        try? FileManager.default.removeItem(at: tracks[0])
    }

    func testEntirelySilentFileKeepsSingleTrack() throws {
        let silent = [Int16](repeating: 0, count: 200)
        let data = makeMultiChannelWAVData(channelSamples: [silent, silent, silent, silent])
        let url = write(data, name: "quad-all-silent.wav")

        let tracks = try MultiTrackAudio.extractTracks(from: url)

        XCTAssertEqual(tracks.count, 1)

        try? FileManager.default.removeItem(at: tracks[0])
    }

    func testChunkedReadProducesSameResultAsSingleChunk() throws {
        let track0: [Int16] = (0..<200).map { Int16($0 % 100) }
        let track1: [Int16] = (0..<200).map { Int16(($0 * 3) % 100) }
        let data = makeMultiChannelWAVData(channelSamples: [track0, track0, track1, track1])
        let url = write(data, name: "quad-chunked.wav")

        // Forces ~7 chunk iterations over 200 frames to exercise chunk-boundary handling.
        let tracks = try MultiTrackAudio.extractTracks(from: url, chunkFrameCount: 32)

        XCTAssertEqual(tracks.count, 2)
        let samples0 = try readFloatSamples(tracks[0])
        let samples1 = try readFloatSamples(tracks[1])

        XCTAssertEqual(samples0.count, 200)
        XCTAssertEqual(samples1.count, 200)
        for index in 0..<200 {
            XCTAssertEqual(samples0[index], Float(track0[index]) / 32768.0, accuracy: 0.0001)
            XCTAssertEqual(samples1[index], Float(track1[index]) / 32768.0, accuracy: 0.0001)
        }

        try? FileManager.default.removeItem(at: tracks[0])
        try? FileManager.default.removeItem(at: tracks[1])
    }
}
