//
//  GeneralSettingsView.swift
//  TeenageEngVoiceSync
//
//  General app settings.
//

import AppKit
import SwiftUI
import os
import ServiceManagement

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("app.showInDock") private var showInDock = true
    @AppStorage("notify.onConnect") private var notifyOnConnect = true
    @AppStorage("notify.onSync") private var notifyOnSync = true
    @AppStorage("daemon.debounceMs") private var debounceMs = 2000
    @AppStorage("devicewatch.enabled") private var deviceWatchEnabled = true

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLoginItem(enabled: newValue)
                    }
                Toggle("Show icon in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in
                        (NSApp.delegate as? AppDelegate)?.applyDockVisibilityPolicy()
                    }
            }

            Section("Notifications") {
                Toggle("Notify when device connects", isOn: $notifyOnConnect)
                Toggle("Notify when sync completes", isOn: $notifyOnSync)
            }

            Section("Sync Behavior") {
                Toggle("Watch TP-7 device for new recordings", isOn: $deviceWatchEnabled)
                    .onChange(of: deviceWatchEnabled) { _, newValue in
                        appState.setDeviceWatchEnabled(newValue)
                    }

                Text(DeviceConnectionCopy.settingsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("File stability delay", selection: $debounceMs) {
                    Text("1 second").tag(1000)
                    Text("2 seconds").tag(2000)
                    Text("3 seconds").tag(3000)
                    Text("5 seconds").tag(5000)
                }
                .pickerStyle(.menu)

                Text("Wait for files to be fully written before syncing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }

                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                }
            }

            Section("Setup") {
                Button("Run Setup Wizard Again") {
                    openWindow(id: "onboarding")
                }

                Text("Re-run the initial setup wizard to reconfigure services")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.app.error("Failed to update login item: \(String(describing: error), privacy: .public)")
        }
    }
}

#Preview {
    GeneralSettingsView()
}
