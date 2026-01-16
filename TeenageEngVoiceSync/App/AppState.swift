//
//  AppState.swift
//  TeenageEngVoiceSync
//
//  Central observable state for the app.
//

import SwiftUI
import os
import SwiftData
import Observation

@Observable
@MainActor
final class AppState {
    // Sync service (owns the device watch and sync pipeline)
    private(set) var syncService: SyncService?
    private var isInitialized = false

    // Error state
    var lastError: String?
    var showError = false

    // Forward device state from sync service
    var isDeviceConnected: Bool {
        syncService?.deviceWatch.isConnected ?? false
    }

    var connectedDeviceSerial: String? {
        syncService?.deviceWatch.currentDeviceSerial
    }

    // Forward sync state from sync service
    var isSyncing: Bool {
        syncService?.isSyncing ?? false
    }

    var pendingUploads: Int {
        syncService?.pendingCount ?? 0
    }

    // Services configured state
    var isS3Configured: Bool {
        UserDefaults.standard.string(forKey: "s3.bucket")?.isEmpty == false
    }

    var isElevenLabsConfigured: Bool {
        UserDefaults.standard.bool(forKey: "elevenlabs.enabled")
    }

    var isAppleNotesEnabled: Bool {
        UserDefaults.standard.bool(forKey: "applenotes.enabled")
    }

    var isDeviceWatchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "devicewatch.enabled")
    }

    // Status text for menu bar
    var statusText: String {
        if let error = lastError {
            // Truncate error message for menu bar
            let truncated = error.count > 50 ? String(error.prefix(47)) + "..." : error
            return "Error: \(truncated)"
        } else if isSyncing {
            return "Syncing..."
        } else if !isDeviceWatchEnabled {
            return "Watching disabled"
        } else if isDeviceConnected {
            return "Device connected"
        } else {
            return "Waiting for device"
        }
    }

    /// Initialize and start the sync service
    func initialize(modelContext: ModelContext) async {
        guard !isInitialized else { return }
        isInitialized = true

        AppLogger.app.info("Initializing sync service")

        let service = SyncService(modelContext: modelContext)
        self.syncService = service
        await service.start()

        AppLogger.app.info("Sync service started")
    }

    func setError(_ message: String) {
        lastError = message
        showError = true
    }

    func clearError() {
        lastError = nil
        showError = false
    }

    func setDeviceWatchEnabled(_ enabled: Bool) {
        guard let syncService else { return }
        Task { @MainActor in
            await syncService.setDeviceWatchEnabled(enabled)
        }
    }

    /// Reload services when settings change
    func reloadServices() {
        guard let syncService else { return }
        // Clear any existing error when reloading
        clearError()
        Task { @MainActor in
            await syncService.reloadServices()
        }
    }
}
