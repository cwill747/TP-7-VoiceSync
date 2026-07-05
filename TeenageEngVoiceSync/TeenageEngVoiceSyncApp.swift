//
//  TeenageEngVoiceSyncApp.swift
//  TeenageEngVoiceSync
//
//  Created by Andrew Armenante on 1/12/26.
//  Renamed from TP7VoiceSync to TeenageEngVoiceSync on 1/14/26.
//

import SwiftUI
import SwiftData
import os

@main
struct TeenageEngVoiceSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarManager = MenuBarManager()

    let modelContainer: ModelContainer

    @State private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() {
        do {
            let schema = Schema([
                Recording.self,
                Device.self,
                Person.self,
                VoiceSample.self
            ])

            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDataURL = appSupportURL.appendingPathComponent("TeenageEngVoiceSync", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)
            let storeURL = appDataURL.appendingPathComponent("tp7sync.store")

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        // Primary recordings window — task here bootstraps the whole app
        Window("TP-7 Recordings", id: "main") {
            ContentView()
                .environment(appState)
                .modelContainer(modelContainer)
                .task {
                    // Wire the menu bar manager before showing the menu bar item
                    menuBarManager.appState = appState
                    menuBarManager.modelContext = modelContainer.mainContext
                    menuBarManager.openMainWindow = {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "main")
                    }
                    menuBarManager.openSettings = {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                    menuBarManager.initializeMenuBar()

                    await appState.initialize(modelContext: modelContainer.mainContext)
                    migrateEnrolledSpeakerIfNeeded(context: modelContainer.mainContext)

                    if !hasCompletedOnboarding {
                        openWindow(id: "onboarding")
                    }
                }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // Settings window
        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(modelContainer)
        }

        // Onboarding wizard
        Window("Setup Wizard", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// One-time migration: if the old single-user EnrolledSpeakerProfile exists in UserDefaults,
    /// create a Person(isSelf: true) from it and clear the blob so we don't migrate twice.
    private func migrateEnrolledSpeakerIfNeeded(context: ModelContext) {
        guard let profile = ParakeetService.EnrolledSpeakerProfile.loadStored() else { return }

        let descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.isSelf == true })
        let existing = try? context.fetch(descriptor)
        guard existing?.isEmpty != false else {
            // Already migrated — just clear the UserDefaults blob
            ParakeetService.EnrolledSpeakerProfile.clearStored()
            return
        }

        let person = Person(name: profile.name, isSelf: true, embedding: profile.embedding)
        let sample = VoiceSample(startTime: 0, endTime: 0, embedding: profile.embedding)
        sample.person = person
        context.insert(person)
        context.insert(sample)
        try? context.save()
        ParakeetService.EnrolledSpeakerProfile.clearStored()
        AppLogger.app.info("Migrated enrolled speaker \"\(profile.name, privacy: .private)\" to Person model")
    }
}
