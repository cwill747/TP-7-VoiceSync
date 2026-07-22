import AVFoundation
import XCTest
@testable import TP_7_VoiceSync

final class AudioPlaybackFileAccessTests: XCTestCase {
    func testLocalCopyPlaybackAcquiresConfiguredFolderScopeBeforeOpeningPlayer() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("local-copy.wav")
        try makeSilentWAV(at: audioURL)

        var startedURLs: [URL] = []
        var stoppedURLs: [URL] = []
        let access = AudioPlaybackFileAccess(
            configuredFolder: { folder },
            resolveBookmark: { folder },
            startAccessing: {
                startedURLs.append($0)
                return true
            },
            stopAccessing: { stoppedURLs.append($0) }
        )

        try access.acquire(for: audioURL)
        let player = try AVAudioPlayer(contentsOf: audioURL)

        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertEqual(startedURLs, [folder])
        XCTAssertTrue(stoppedURLs.isEmpty)

        access.release()
        XCTAssertEqual(stoppedURLs, [folder])
    }

    func testSwitchingFilesReleasesPreviousScopeAndDoesNotScopeDeviceCache() throws {
        let folder = URL(fileURLWithPath: "/external/audio", isDirectory: true)
        let localCopy = folder.appendingPathComponent("recording.wav")
        let cachedFile = URL(fileURLWithPath: "/app/container/cache/recording.wav")
        var startCount = 0
        var stopCount = 0
        let access = AudioPlaybackFileAccess(
            configuredFolder: { folder },
            resolveBookmark: { folder },
            startAccessing: { _ in
                startCount += 1
                return true
            },
            stopAccessing: { _ in stopCount += 1 }
        )

        try access.acquire(for: localCopy)
        try access.acquire(for: cachedFile)

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testPermissionFailureIsReportedForConfiguredLocalCopy() {
        let folder = URL(fileURLWithPath: "/external/audio", isDirectory: true)
        let access = AudioPlaybackFileAccess(
            configuredFolder: { folder },
            resolveBookmark: { folder },
            startAccessing: { _ in false }
        )

        XCTAssertThrowsError(try access.acquire(for: folder.appendingPathComponent("recording.wav"))) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "VoiceSync no longer has permission to read the local audio folder. Choose the folder again in Settings."
            )
        }
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp7-audio-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeSilentWAV(at url: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
        )
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}
