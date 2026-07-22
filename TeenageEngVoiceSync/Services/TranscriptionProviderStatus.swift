//
//  TranscriptionProviderStatus.swift
//  TeenageEngVoiceSync
//
//  Shared model combining the saved provider/enabled preference with the
//  provider's effective runtime availability, so Settings and the sync
//  engine always agree on whether transcription is actually going to run.
//

import Foundation

/// Why the selected provider isn't running, when it isn't.
///
/// `.modelNotDownloaded` and `.downloadingModel` only apply to the local
/// engines (WhisperKit/Parakeet/ParakeetUnified), which download their model
/// on demand on first use (`WhisperKitConfig(download: true)`,
/// `AsrModels.downloadAndLoad`) — they are informational, not blocking.
/// `.missingAPIKey` is the only state that actually prevents transcription,
/// since `SyncService` never constructs `ElevenLabsTranscriptionService`
/// without a key.
enum TranscriptionReadiness: Equatable {
    case ready
    case missingAPIKey
    case modelNotDownloaded
    case downloadingModel
}

struct TranscriptionProviderStatus: Equatable {
    let providerKind: TranscriptionProviderKind
    let preferenceEnabled: Bool
    let readiness: TranscriptionReadiness

    /// The saved preference is off — nothing to report.
    var isDisabled: Bool { !preferenceEnabled }

    /// The preference is on and the provider is actually able to transcribe
    /// (local engines still count as active even without a cached model,
    /// since they download it transparently on first use).
    var isEffectivelyActive: Bool {
        preferenceEnabled && readiness != .missingAPIKey
    }

    /// The user turned transcription on, but it cannot run without a manual
    /// fix (currently only a missing ElevenLabs API key).
    var isBlocked: Bool {
        preferenceEnabled && readiness == .missingAPIKey
    }

    var statusText: String {
        guard preferenceEnabled else { return "Transcription off" }
        switch readiness {
        case .ready: return "\(providerKind.shortName) active"
        case .missingAPIKey: return "Paused — API key required"
        case .modelNotDownloaded: return "\(providerKind.shortName) active — model downloads on first use"
        case .downloadingModel: return "\(providerKind.shortName) active — downloading model"
        }
    }

    var systemImage: String {
        guard preferenceEnabled else { return "circle.slash" }
        switch readiness {
        case .ready: return "checkmark.circle.fill"
        case .missingAPIKey: return "exclamationmark.triangle.fill"
        case .modelNotDownloaded: return "icloud.and.arrow.down"
        case .downloadingModel: return "arrow.down.circle"
        }
    }

    static func evaluate(
        providerKind: TranscriptionProviderKind,
        preferenceEnabled: Bool,
        hasElevenLabsKey: Bool,
        localModelReady: Bool,
        localModelDownloading: Bool = false
    ) -> TranscriptionProviderStatus {
        let readiness: TranscriptionReadiness
        switch providerKind {
        case .elevenLabs:
            readiness = hasElevenLabsKey ? .ready : .missingAPIKey
        case .whisperKit, .parakeet, .parakeetUnified:
            if localModelDownloading {
                readiness = .downloadingModel
            } else {
                readiness = localModelReady ? .ready : .modelNotDownloaded
            }
        }
        return TranscriptionProviderStatus(providerKind: providerKind, preferenceEnabled: preferenceEnabled, readiness: readiness)
    }

    /// Checks on-disk/keychain state for `providerKind` directly from
    /// `UserDefaults`, mirroring the model lookups `SyncService.loadServices()`
    /// already performs. Used where a live download-in-progress flag from a
    /// Settings view isn't available (e.g. the main-window status pipeline).
    static func evaluate(providerKind: TranscriptionProviderKind, preferenceEnabled: Bool, hasElevenLabsKey: Bool) -> TranscriptionProviderStatus {
        let localModelReady: Bool
        switch providerKind {
        case .elevenLabs:
            localModelReady = true // irrelevant for this branch, resolved via hasElevenLabsKey
        case .whisperKit:
            let modelID = UserDefaults.standard.string(forKey: "whisperkit.model") ?? "base"
            localModelReady = WhisperKitService.cachedModelPath(for: modelID) != nil
        case .parakeet:
            let variant = ParakeetModelVariant(rawValue: UserDefaults.standard.string(forKey: ParakeetService.modelKey) ?? ParakeetModelVariant.v2.rawValue) ?? .v2
            localModelReady = ParakeetService.cachedModelExists(for: variant)
        case .parakeetUnified:
            localModelReady = ParakeetUnifiedService.cachedModelExists()
        }
        return evaluate(
            providerKind: providerKind,
            preferenceEnabled: preferenceEnabled,
            hasElevenLabsKey: hasElevenLabsKey,
            localModelReady: localModelReady
        )
    }
}
