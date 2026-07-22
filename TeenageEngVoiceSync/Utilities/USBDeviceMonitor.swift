//
//  USBDeviceMonitor.swift
//  TeenageEngVoiceSync
//
//  Watches for a specific USB device (matched by vendor/product ID) attaching
//  or detaching, via IOKit matching notifications. This lets the app sleep
//  instead of busy-polling the USB bus: the kernel wakes us only when the
//  matching device actually appears or disappears, so the process can idle
//  (App Nap) whenever no TP-7 is around.
//

import Foundation
import IOKit
import os

/// All mutable IOKit state is confined to `queue`. `@unchecked Sendable` is
/// safe because start, stop, event handling, and destruction serialize access
/// through that queue.
nonisolated final class USBDeviceMonitor: @unchecked Sendable {
    private let vendorID: Int
    private let productID: Int
    /// Invoked on `queue` whenever a matching device is attached or detached.
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "USBDeviceMonitor")
    private let queueKey = DispatchSpecificKey<Void>()
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init(vendorID: Int, productID: Int, onChange: @escaping @Sendable () -> Void) {
        self.vendorID = vendorID
        self.productID = productID
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Cheap one-shot check of the IOKit registry (no USB bus traffic) for
    /// whether a matching device is currently attached. Used to decide how
    /// eagerly to retry an MTP connect: when the TP-7 is physically present but
    /// not yet connected (e.g. still enumerating right after power-on), poll
    /// fast; when it's absent, sleep long.
    static func isDevicePresent(vendorID: Int, productID: Int) -> Bool {
        guard let dict = IOServiceMatching("IOUSBHostDevice") else { return false }
        let mutable = dict as NSMutableDictionary
        mutable["idVendor"] = vendorID
        mutable["idProduct"] = productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var present = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            present = true
            service = IOIteratorNext(iterator)
        }
        return present
    }

    func start() {
        queue.async { [weak self] in self?.configure() }
    }

    func stop() {
        queue.sync { teardown() }
    }

    deinit {
        // stop() is expected before dealloc; this is a best-effort backstop.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    private func configure() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
                .handleEvent(iterator: iterator)
        }

        addNotification(type: kIOFirstMatchNotification, iterator: &addedIterator, port: port, callback: callback, refcon: refcon)
        addNotification(type: kIOTerminatedNotification, iterator: &removedIterator, port: port, callback: callback, refcon: refcon)
    }

    private func addNotification(
        type: String,
        iterator: inout io_iterator_t,
        port: IONotificationPortRef,
        callback: @escaping IOServiceMatchingCallback,
        refcon: UnsafeMutableRawPointer
    ) {
        // `IOUSBHostDevice` is the class the TP-7 registers as on modern macOS;
        // the idVendor/idProduct keys live on that registry entry.
        guard let matchingDict = IOServiceMatching("IOUSBHostDevice") else { return }
        let mutable = matchingDict as NSMutableDictionary
        mutable["idVendor"] = vendorID
        mutable["idProduct"] = productID

        let result = IOServiceAddMatchingNotification(port, type, matchingDict, callback, refcon, &iterator)
        guard result == KERN_SUCCESS else {
            AppLogger.device.error("USB matching notification (\(type, privacy: .public)) failed: \(result)")
            return
        }
        // Draining the iterator both releases the pre-existing matches and arms
        // the notification for future events. The already-connected device (if
        // any) is picked up by the watch loop's first pass, so we don't need to
        // fire `onChange` for it here.
        drain(iterator)
    }

    private func handleEvent(iterator: io_iterator_t) {
        if drain(iterator) {
            onChange()
        }
    }

    /// Releases every object the iterator holds; returns whether it held any.
    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Bool {
        var sawDevice = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            sawDevice = true
            service = IOIteratorNext(iterator)
        }
        return sawDevice
    }

    private func teardown() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }
}
