import AppKit
import Combine
import SwiftData

@MainActor
final class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    weak var appState: AppState?
    var modelContext: ModelContext?
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?

    func initializeMenuBar() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "TP-7 VoiceSync")
            image?.isTemplate = true
            button.image = image
        }

        menu = NSMenu()
        menu?.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText = appState?.statusText ?? "Idle"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Work Offline toggle
        let offlineItem = NSMenuItem(
            title: "Work Offline",
            action: #selector(toggleWorkOffline),
            keyEquivalent: ""
        )
        offlineItem.target = self
        offlineItem.state = (appState?.isWorkOfflineForced ?? false) ? .on : .off
        menu.addItem(offlineItem)

        // Retry now (only when there's deferred work and we're online)
        if let count = appState?.pendingRemoteCount, count > 0 {
            let retryItem = NSMenuItem(
                title: "Retry Upload (\(count))",
                action: #selector(retryPending),
                keyEquivalent: ""
            )
            retryItem.target = self
            retryItem.isEnabled = !(appState?.isOffline ?? false)
            menu.addItem(retryItem)
        }

        let recent = fetchRecent()
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for recording in recent {
                let item = NSMenuItem(
                    title: recording.filename,
                    action: #selector(openMain),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open TP-7 VoiceSync",
            action: #selector(openMain),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openPrefs),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit TP-7 VoiceSync",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
    }

    @objc private func openPrefs() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    @objc private func toggleWorkOffline() {
        guard let appState else { return }
        appState.setWorkOffline(!appState.isWorkOfflineForced)
    }

    @objc private func retryPending() {
        appState?.retryPendingWork()
    }

    // MARK: - Private

    private func fetchRecent() -> [Recording] {
        guard let ctx = modelContext else { return [] }
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        return (try? ctx.fetch(descriptor)) ?? []
    }
}
