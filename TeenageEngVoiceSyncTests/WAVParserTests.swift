//
//  WAVParserTests.swift
//  TeenageEngVoiceSyncTests
//
//  Exercises WAVParser against tiny fixture WAVs synthesized in-memory:
//  a valid file, a truncated header, and non-WAV bytes.
//

import XCTest
@testable import TP_7_VoiceSync

final class WAVParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVParserTests-\(UUID().uuidString)", isDirectory: true)
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

    func testParsesValidWAVMetadata() async throws {
        let url = write(makeWAVData(sampleRate: 44100, channels: 1, bitsPerSample: 16, numSamples: 4410), name: "valid.wav")

        let metadata = try await WAVParser.parse(url: url)

        XCTAssertEqual(metadata.sampleRate, 44100)
        XCTAssertEqual(metadata.channels, 1)
        XCTAssertEqual(metadata.bitDepth, 16)
        XCTAssertEqual(metadata.duration, 0.1, accuracy: 0.01) // 4410 samples / 44100 Hz
        XCTAssertEqual(metadata.trackCount, 1)
    }

    func testParsesStereoWAVMetadata() async throws {
        let url = write(makeWAVData(sampleRate: 48000, channels: 2, bitsPerSample: 24, numSamples: 4800), name: "stereo.wav")

        let metadata = try await WAVParser.parse(url: url)

        XCTAssertEqual(metadata.sampleRate, 48000)
        XCTAssertEqual(metadata.channels, 2)
        XCTAssertEqual(metadata.bitDepth, 24)
        XCTAssertEqual(metadata.trackCount, 1) // dual-mono stereo = 1 track
    }

    func testFourChannelWAVReportsTwoTracks() async throws {
        let url = write(makeWAVData(sampleRate: 44100, channels: 4, bitsPerSample: 16, numSamples: 100), name: "quad.wav")

        let metadata = try await WAVParser.parse(url: url)

        XCTAssertEqual(metadata.channels, 4)
        XCTAssertEqual(metadata.trackCount, 2)
    }

    func testFileNotFoundThrowsExactError() async throws {
        let missingURL = tempDirectory.appendingPathComponent("does-not-exist.wav")

        do {
            _ = try await WAVParser.parse(url: missingURL)
            XCTFail("Expected fileNotFound to be thrown")
        } catch let error as WAVParser.WAVError {
            guard case .fileNotFound = error else {
                XCTFail("Expected .fileNotFound, got \(error)")
                return
            }
        }
    }

    func testTruncatedHeaderThrows() async throws {
        let fullData = makeWAVData()
        let truncated = fullData.prefix(20) // cuts off mid "fmt " chunk
        let url = write(truncated, name: "truncated.wav")

        do {
            _ = try await WAVParser.parse(url: url)
            XCTFail("Expected parsing a truncated header to throw")
        } catch {
            // AVFoundation's exact failure mode for malformed input isn't part
            // of the contract we're testing — only that it doesn't succeed.
        }
    }

    func testNonWAVDataThrows() async throws {
        let url = write("this is not a wav file".data(using: .utf8)!, name: "notawav.wav")

        do {
            _ = try await WAVParser.parse(url: url)
            XCTFail("Expected parsing non-WAV bytes to throw")
        } catch {
            // Same rationale as testTruncatedHeaderThrows.
        }
    }
}
