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
    /// Set when the store had to be reset during init; surfaced as a one-time alert once the UI is up.
    let storeRecoveryMessage: String?

    @State private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// True when launched as the host process for the TeenageEngVoiceSyncTests
    /// bundle (Xcode sets this env var for hosted test runs). Guards the app
    /// away from the user's real on-disk store and live service credentials
    /// so running `xcodebuild test` can't quarantine production data or make
    /// real S3/Notion calls with the developer's saved secrets.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let schema = Schema([
            Recording.self,
            Device.self,
            Person.self,
            VoiceSample.self
        ])

        if Self.isRunningTests {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: schema, configurations: [configuration])
            storeRecoveryMessage = nil
            return
        }

        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDataURL = appSupportURL.appendingPathComponent("TeenageEngVoiceSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)
        let storeURL = appDataURL.appendingPathComponent("tp7sync.store")
        let configuration = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            storeRecoveryMessage = nil
        } catch {
            AppLogger.app.fault("ModelContainer init failed, attempting store recovery: \(error, privacy: .public)")
            Self.quarantineStoreFiles(at: storeURL)

            do {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
                AppLogger.app.fault("Recovered from corrupt store: created a fresh ModelContainer")
                storeRecoveryMessage = "Your local database couldn't be opened and had to be reset. The old data was preserved for debugging. Recordings will be restored automatically from your connected storage."
            } catch {
                fatalError("Could not initialize ModelContainer even after resetting the store: \(error)")
            }
        }
    }

    /// Moves the (possibly corrupt) store and its SQLite side files aside to timestamped backups
    /// so a fresh ModelContainer can be created in their place. Never deletes data.
    private static func quarantineStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent
        let timestamp = Int(Date().timeIntervalSince1970)

        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            AppLogger.app.error("Could not list \(directory.path, privacy: .public) to quarantine store files")
            return
        }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix(baseName) {
            let backupURL = directory.appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)")
            do {
                try fm.moveItem(at: fileURL, to: backupURL)
                AppLogger.app.error("Quarantined \(fileURL.lastPathComponent, privacy: .public) -> \(backupURL.lastPathComponent, privacy: .public)")
            } catch {
                AppLogger.app.error("Failed to quarantine \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    var body: some Scene {
        // Primary recordings window — task here bootstraps the whole app
        Window("TP-7 Recordings", id: "main") {
            ContentView()
                .environment(appState)
                .modelContainer(modelContainer)
                .task {
                    // Never start the real sync pipeline (Keychain-backed S3/Notion
                    // calls, USB device watch) when hosted by TeenageEngVoiceSyncTests.
                    guard !Self.isRunningTests else { return }

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

                    // Migrate before initialize so persons are in the DB when
                    // SyncService.loadServices() snapshots known speakers.
                    migrateEnrolledSpeakerIfNeeded(context: modelContainer.mainContext)
                    await appState.initialize(modelContext: modelContainer.mainContext)

                    if let storeRecoveryMessage {
                        appState.setError(storeRecoveryMessage)
                    }

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
