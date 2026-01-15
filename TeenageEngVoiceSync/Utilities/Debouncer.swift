//
//  Debouncer.swift
//  TeenageEngVoiceSync
//
//  Debounce file events to ensure file stability before processing.
//

import Foundation

actor Debouncer {
    private var pendingItems: [String: Date] = [:]
    private let delay: TimeInterval
    private var processingTask: Task<Void, Never>?

    init(delay: TimeInterval = 2.0) {
        self.delay = delay
    }

    /// Records an event for an item, resetting its debounce timer
    func recordEvent(for key: String) {
        pendingItems[key] = Date()
    }

    /// Returns items that have been stable for the debounce period
    func getStableItems() -> [String] {
        let now = Date()
        var stable: [String] = []

        for (key, lastEvent) in pendingItems {
            if now.timeIntervalSince(lastEvent) >= delay {
                stable.append(key)
            }
        }

        // Remove stable items from pending
        for key in stable {
            pendingItems.removeValue(forKey: key)
        }

        return stable
    }

    /// Removes an item from pending (e.g., if file was deleted)
    func remove(key: String) {
        pendingItems.removeValue(forKey: key)
    }

    /// Clears all pending items
    func clear() {
        pendingItems.removeAll()
    }

    /// Returns count of pending items
    var pendingCount: Int {
        pendingItems.count
    }

    /// Start periodic processing with a callback for stable items
    func startProcessing(interval: TimeInterval = 0.5, handler: @escaping ([String]) async -> Void) {
        processingTask?.cancel()
        processingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                let stable = await getStableItems()
                if !stable.isEmpty {
                    await handler(stable)
                }
            }
        }
    }

    /// Stop periodic processing
    func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }
}
