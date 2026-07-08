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
    case parakeet = "parakeet"
    case parakeetUnified = "parakeet-unified"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs:
            return "ElevenLabs (Cloud)"
        case .whisperKit:
            return "WhisperKit (Local)"
        case .parakeet:
            return "Parakeet (Local, ANE)"
        case .parakeetUnified:
            return "Parakeet Unified (Local, English)"
        }
    }

    var shortName: String {
        switch self {
        case .elevenLabs:
            return "ElevenLabs"
        case .whisperKit:
            return "WhisperKit"
        case .parakeet:
            return "Parakeet"
        case .parakeetUnified:
            return "Parakeet Unified"
        }
    }

    var description: String {
        switch self {
        case .elevenLabs:
            return "Cloud transcription using ElevenLabs Scribe models."
        case .whisperKit:
            return "On-device transcription with optional offline model downloads."
        case .parakeet:
            return "On-device Parakeet TDT via FluidAudio, runs on the Apple Neural Engine."
        case .parakeetUnified:
            return "On-device Parakeet Unified via FluidAudio. Adds punctuation and capitalization natively (English only). No speaker diarization, multi-track splitting, or vocabulary boosting."
        }
    }
}

protocol TranscriptionProvider: Actor {
    static var providerName: String { get }
    func transcribe(localPath: String) async throws -> TranscriptionResult
    func transcribe(cloudStorageURL: String) async throws -> TranscriptionResult
}
