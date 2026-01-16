//
//  TranscriptionProvider.swift
//  TeenageEngVoiceSync
//
//  Shared protocol and provider metadata for transcription services.
//

import Foundation

enum TranscriptionProviderKind: String, CaseIterable, Identifiable {
    case elevenLabs = "elevenlabs"
    case whisperKit = "whisperkit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs:
            return "ElevenLabs (Cloud)"
        case .whisperKit:
            return "WhisperKit (Local)"
        }
    }

    var shortName: String {
        switch self {
        case .elevenLabs:
            return "ElevenLabs"
        case .whisperKit:
            return "WhisperKit"
        }
    }

    var description: String {
        switch self {
        case .elevenLabs:
            return "Cloud transcription using ElevenLabs Scribe models."
        case .whisperKit:
            return "On-device transcription with optional offline model downloads."
        }
    }
}

protocol TranscriptionProvider: Actor {
    static var providerName: String { get }
    func transcribe(localPath: String) async throws -> TranscriptionResult
    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult
}
