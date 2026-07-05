import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibilityPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { $0.level == .normal && $0.styleMask.contains(.titled) }
            .map { $0.makeKeyAndOrderFront(nil) }
        return true
    }

    func applyDockVisibilityPolicy() {
        let showInDock = UserDefaults.standard.object(forKey: "app.showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
