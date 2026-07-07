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

    /// True while a manual "Reprocess all recordings" backfill pass is running.
    private(set) var isReprocessing = false

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

    // Forward offline state from sync service
    var isOffline: Bool {
        syncService?.isOffline ?? false
    }

    var pendingRemoteCount: Int {
        syncService?.pendingRemoteCount ?? 0
    }

    /// Whether the user has manually forced offline mode ("Work Offline").
    var isWorkOfflineForced: Bool {
        syncService?.reachability.forceOffline ?? false
    }

    // Services configured state
    var isS3Configured: Bool {
        UserDefaults.standard.string(forKey: "s3.bucket")?.isEmpty == false
    }

    var isTranscriptionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "transcription.enabled")
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
        } else if isOffline {
            return pendingRemoteCount > 0 ? "Offline — \(pendingRemoteCount) waiting" : "Offline"
        } else if isSyncing {
            return "Syncing..."
        } else if pendingRemoteCount > 0 {
            return "\(pendingRemoteCount) waiting to upload"
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

    /// Toggle the manual "Work Offline" override.
    func setWorkOffline(_ on: Bool) {
        syncService?.reachability.setForceOffline(on)
    }

    /// Manually retry deferred remote work now.
    func retryPendingWork() {
        guard let syncService else { return }
        Task { @MainActor in
            await syncService.reconcilePendingWork()
        }
    }

    /// Recompute the "N waiting" count from the database. Call after changing
    /// destination/AI settings so `pendingRemoteCount` reflects how many existing
    /// recordings now owe work under the new settings (e.g. after enabling Notion).
    func refreshPendingRemoteCount() {
        guard let syncService else { return }
        Task { @MainActor in
            await syncService.refreshPendingCount()
        }
    }

    /// Backfill newly-enabled destinations and AI titles onto existing recordings.
    /// Reuses the idempotent reconcile pass, so it only fills in missing remote
    /// steps — it never re-creates notes or Notion pages that already exist.
    /// No-op while offline (the reconcile pass requires connectivity).
    func reprocessAllRecordings() async {
        guard let syncService, !isReprocessing else { return }
        clearError()
        isReprocessing = true
        await syncService.reconcilePendingWork()
        isReprocessing = false
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
