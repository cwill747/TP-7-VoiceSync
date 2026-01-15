//
//  DeviceWatchService.swift
//  TeenageEngVoiceSync
//
//  Watches for TP-7 devices via FieldKit container polling.
//

import Foundation
import os
import Observation

@Observable
final class DeviceWatchService {
    private(set) var isConnected = false
    private(set) var currentDeviceSerial: String?
    private(set) var recordingsPath: String?

    private var watchTask: Task<Void, Never>?
    private let fieldKitPath: URL
    private var lastKnownDevice: String?
    private var deviceWasLost = false
    private var hasLoggedInitialScan = false

    // Callbacks
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: ((String) -> Void)?
    var onNewRecordings: (([URL], String) -> Void)?

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        fieldKitPath = homeDir
            .appendingPathComponent("Library/Containers/engineering.teenage.fieldkit/Data/Documents")
    }

    /// Start watching for TP-7 devices
    func startWatching() {
        guard watchTask == nil else { return }

        AppLogger.device.info("Starting device watch")

        watchTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    /// Stop watching
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        isConnected = false
        currentDeviceSerial = nil
        recordingsPath = nil
        lastKnownDevice = nil
        deviceWasLost = false
    }

    private func watchLoop() async {
        // Initial device check
        await detectDevices()

        // Dynamic polling: fast when disconnected, slow when connected
        while !Task.isCancelled {
            let interval: Duration = isConnected ? .seconds(10) : .seconds(1)

            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { break }

            await detectDevices()
        }
    }

    private func detectDevices() async {
        let result = findTP7Device()

        switch result {
        case .success(let device):
            handleDeviceFound(device)
        case .failure:
            handleDeviceNotFound()
        }
    }

    private func handleDeviceFound(_ device: TP7Device) {
        let isReconnection = deviceWasLost && lastKnownDevice == device.serial
        let isNewDevice = lastKnownDevice != device.serial

        AppLogger.device.info("Device found (serial=\(device.serial, privacy: .private), reconnection=\(isReconnection), newDevice=\(isNewDevice))")

        if isReconnection {
            isConnected = true
            currentDeviceSerial = device.serial
            recordingsPath = device.recordingsPath
            deviceWasLost = false
            onDeviceConnected?(device.serial)

            // Scan for new recordings after reconnection
            Task {
                // Wait for MTP mount to be ready
                try? await Task.sleep(for: .seconds(3))
                await scanRecordings(at: device.recordingsPath, serial: device.serial)
            }
        } else if isNewDevice {
            isConnected = true
            currentDeviceSerial = device.serial
            recordingsPath = device.recordingsPath
            lastKnownDevice = device.serial
            deviceWasLost = false
            onDeviceConnected?(device.serial)

            // Scan for recordings
            Task {
                try? await Task.sleep(for: .seconds(3))
                await scanRecordings(at: device.recordingsPath, serial: device.serial)
            }
        }
    }

    private func handleDeviceNotFound() {
        if isConnected && !deviceWasLost {
            if let serial = lastKnownDevice {
                onDeviceDisconnected?(serial)
            }
            deviceWasLost = true
            isConnected = false
            currentDeviceSerial = nil
            recordingsPath = nil
        }
    }

    private func findTP7Device() -> Result<TP7Device, DeviceError> {
        let fileManager = FileManager.default

        // Check if FieldKit container exists
        guard fileManager.fileExists(atPath: fieldKitPath.path) else {
            AppLogger.device.info("FieldKit container not found")
            return .failure(.containerNotFound)
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: fieldKitPath,
                includingPropertiesForKeys: nil
            )

            if !hasLoggedInitialScan {
                AppLogger.device.debug("Initial scan found \(contents.count, privacy: .public) items in FieldKit container")
                hasLoggedInitialScan = true
            }

            // Look for TP-7 MTP Device folders
            for item in contents {
                let name = item.lastPathComponent

                if name.hasPrefix("TP-7 MTP Device-") {
                    // Extract serial from folder name
                    let serial = String(name.dropFirst("TP-7 MTP Device-".count))
                    AppLogger.device.debug("Found TP-7 folder (serial=\(serial, privacy: .private))")

                    // Find recordings folder
                    let recordingsDir = item.appendingPathComponent("recordings")

                    if fileManager.fileExists(atPath: recordingsDir.path) {
                        AppLogger.device.debug("Found recordings folder")
                        return .success(TP7Device(
                            serial: serial,
                            recordingsPath: recordingsDir.path,
                            basePath: item.path
                        ))
                    } else {
                        AppLogger.device.debug("No recordings folder found")
                    }
                }
            }

            return .failure(.noDeviceFound)
        } catch {
            AppLogger.device.error("Error reading FieldKit container: \(String(describing: error), privacy: .public)")
            return .failure(.accessError(error))
        }
    }

    private func scanRecordings(at path: String, serial: String) async {
        let fileManager = FileManager.default
        let recordingsURL = URL(fileURLWithPath: path)

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: recordingsURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )

            let wavFiles = contents.filter { url in
                let name = url.lastPathComponent
                return !name.hasPrefix(".") &&
                       name.lowercased().hasSuffix(".wav")
            }

            if !wavFiles.isEmpty {
                onNewRecordings?(wavFiles, serial)
            }
        } catch {
            AppLogger.device.error("Failed to scan recordings: \(String(describing: error), privacy: .public)")
        }
    }
}

struct TP7Device {
    let serial: String
    let recordingsPath: String
    let basePath: String
}

enum DeviceError: Error {
    case containerNotFound
    case noDeviceFound
    case accessError(Error)
}
