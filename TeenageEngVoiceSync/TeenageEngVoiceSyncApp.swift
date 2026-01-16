//
//  TeenageEngVoiceSyncApp.swift
//  TeenageEngVoiceSync
//
//  Created by Andrew Armenante on 1/12/26.
//  Renamed from TP7VoiceSync to TeenageEngVoiceSync on 1/14/26.
//

import SwiftUI
import SwiftData

@main
struct TeenageEngVoiceSyncApp: App {
    let modelContainer: ModelContainer

    @State private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow

    init() {
        do {
            let schema = Schema([
                Recording.self,
                Device.self
            ])

            // Use app-specific storage location to avoid conflicts with other apps
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDataURL = appSupportURL.appendingPathComponent("TeenageEngVoiceSync", isDirectory: true)

            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)

            let storeURL = appDataURL.appendingPathComponent("tp7sync.store")

            // Create container with explicit URL
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        // Menu bar icon with popover
        MenuBarExtra {
            PopoverView()
                .environment(appState)
                .modelContainer(modelContainer)
        } label: {
            // The label is always rendered, so .task here runs on app launch
            MenuBarIcon(state: appState)
                .task {
                    await appState.initialize(modelContext: modelContainer.mainContext)
                    // Open onboarding wizard on first launch
                    if !hasCompletedOnboarding {
                        openWindow(id: "onboarding")
                    }
                }
        }
        .menuBarExtraStyle(.window)

        // Main recordings window
        Window("TP-7 Recordings", id: "main") {
            ContentView()
                .environment(appState)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // Settings window
        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(modelContainer)
        }

        // Onboarding wizard window
        Window("Setup Wizard", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
