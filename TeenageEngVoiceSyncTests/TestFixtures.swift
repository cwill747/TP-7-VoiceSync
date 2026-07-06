//
//  TestFixtures.swift
//  TeenageEngVoiceSyncTests
//
//  Shared fixture builders used across multiple test files.
//

import Foundation

private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
}

/// Synthesizes a minimal canonical-PCM WAV file (44-byte header + silence).
func makeWAVData(sampleRate: UInt32 = 44100, channels: UInt16 = 1, bitsPerSample: UInt16 = 16, numSamples: Int = 4410) -> Data {
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(numSamples * Int(channels) * Int(bitsPerSample / 8))
    let chunkSize = 36 + dataSize

    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(contentsOf: littleEndianBytes(chunkSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(contentsOf: littleEndianBytes(UInt32(16)))
    data.append(contentsOf: littleEndianBytes(UInt16(1))) // PCM
    data.append(contentsOf: littleEndianBytes(channels))
    data.append(contentsOf: littleEndianBytes(sampleRate))
    data.append(contentsOf: littleEndianBytes(byteRate))
    data.append(contentsOf: littleEndianBytes(blockAlign))
    data.append(contentsOf: littleEndianBytes(bitsPerSample))
    data.append(contentsOf: Array("data".utf8))
    data.append(contentsOf: littleEndianBytes(dataSize))
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
}
