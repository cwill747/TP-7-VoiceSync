//
//  ReachabilityService.swift
//  TeenageEngVoiceSync
//
//  Tracks network connectivity and a manual "Work Offline" override, exposing a
//  single "effective online" signal used to decide whether remote pipeline
//  stages (S3, LLM, Notion, notes) run now or get deferred.
//

import Foundation
import Network
import os
import Observation

@Observable
@MainActor
final class ReachabilityService {
    /// Raw network-interface reachability from `NWPathMonitor`. Starts optimistic
    /// so we don't wrongly defer remote work during the brief window before the
    /// first path update arrives.
    private(set) var isReachable: Bool = true

    /// The user's manual "Work Offline" override (persisted). When true we behave
    /// as offline even if the network is up.
    private(set) var forceOffline: Bool = UserDefaults.standard.bool(forKey: ReachabilityService.forceOfflineKey)

    /// Effective connectivity: online only when the network is up AND the user
    /// hasn't forced offline mode.
    var isOnline: Bool { isReachable && !forceOffline }

    /// Fired on a `false -> true` transition of `isOnline` (network restored or
    /// the user turned off "Work Offline"). Wired to reconciliation.
    var onBecameOnline: (() -> Void)?

    static let forceOfflineKey = "offline.forceOffline"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ReachabilityService.monitor")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                self?.updateReachable(reachable)
            }
        }
        monitor.start(queue: queue)
        AppLogger.network.info("Reachability monitoring started")
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }

    /// Sets the manual override, persists it, and fires `onBecameOnline` when the
    /// change brings us back online.
    func setForceOffline(_ on: Bool) {
        guard on != forceOffline else { return }
        let wasOnline = isOnline
        forceOffline = on
        UserDefaults.standard.set(on, forKey: Self.forceOfflineKey)
        AppLogger.network.info("Work Offline set to \(on, privacy: .public)")
        handleTransition(wasOnline: wasOnline)
    }

    private func updateReachable(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        let wasOnline = isOnline
        isReachable = reachable
        AppLogger.network.info("Network reachability changed: reachable=\(reachable, privacy: .public)")
        handleTransition(wasOnline: wasOnline)
    }

    private func handleTransition(wasOnline: Bool) {
        if !wasOnline && isOnline {
            AppLogger.network.info("Became online — triggering reconciliation")
            onBecameOnline?()
        }
    }
}
