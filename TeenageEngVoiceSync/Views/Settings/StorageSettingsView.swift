//
//  StorageSettingsView.swift
//  TeenageEngVoiceSync
//
//  Storage configuration: S3 cloud storage and/or local folder.
//

import SwiftUI
import AppKit

struct StorageSettingsView: View {
    @Environment(AppState.self) private var appState

    // S3 Settings
    @AppStorage("s3.enabled") private var s3Enabled = false
    @AppStorage("s3.provider") private var providerRaw = S3Provider.aws.rawValue
    @AppStorage("s3.bucket") private var bucket = ""
    @AppStorage("s3.region") private var region = "us-east-1"
    @AppStorage("s3.prefix") private var prefix = "recordings/"

    private var provider: S3Provider {
        S3Provider(rawValue: providerRaw) ?? .aws
    }

    // Local Audio Settings
    @AppStorage("localaudio.enabled") private var localAudioEnabled = false
    @AppStorage("localaudio.folderPath") private var localFolderPath = ""

    @State private var isTesting = false
    @State private var hasCredentials = false
    @State private var testStatus: TestStatus?
    @State private var localInputPath = ""
    @State private var localValidationStatus: ValidationStatus?
    @State private var s3ReloadTask: Task<Void, Never>?

    enum TestStatus {
        case success
        case error(String)
    }

    enum ValidationStatus: Equatable {
        case success
        case error(String)
    }

    var body: some View {
        Form {
            // MARK: - S3 Cloud Storage
            Section("S3 Cloud Storage") {
                Toggle("Enable S3 cloud storage", isOn: $s3Enabled)
                    .onChange(of: s3Enabled) { _, _ in
                        appState.reloadServices()
                    }
                    .onChange(of: providerRaw) { _, _ in scheduleS3Reload() }
                    .onChange(of: bucket) { _, _ in scheduleS3Reload() }
                    .onChange(of: region) { _, _ in scheduleS3Reload() }
                    .onChange(of: prefix) { _, _ in scheduleS3Reload() }

                if s3Enabled {
                    Picker("Provider", selection: Binding(
                        get: { provider },
                        set: { newValue in
                            providerRaw = newValue.rawValue
                            region = newValue.defaultRegion
                        }
                    )) {
                        ForEach(S3Provider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    TextField("Bucket Name", text: $bucket)
                        .textFieldStyle(.roundedBorder)

                    if provider == .aws {
                        Picker("Region", selection: $region) {
                            ForEach(awsRegions, id: \.self) { region in
                                Text(region).tag(region)
                            }
                        }
                    } else {
                        TextField("Region (e.g. us-west-004)", text: $region)
                            .textFieldStyle(.roundedBorder)

                        Text("Find your bucket's region in the Backblaze B2 console under Bucket Settings (Endpoint).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Key Prefix", text: $prefix)
                        .textFieldStyle(.roundedBorder)

                    Text("Files will be uploaded to: s3://\(bucket)/\(prefix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !hasCredentials {
                        Label("Configure credentials in the API Keys tab", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else {
                        Label("Credentials configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    if let status = testStatus {
                        switch status {
                        case .success:
                            Label("Connection successful", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(bucket.isEmpty || !hasCredentials || isTesting)

                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
            }

            // MARK: - Local Storage
            Section("Local Folder Storage") {
                Toggle("Save audio files locally", isOn: $localAudioEnabled)
                    .onChange(of: localAudioEnabled) { _, _ in
                        appState.reloadServices()
                    }

                if localAudioEnabled {
                    HStack {
                        TextField("e.g. ~/Downloads/TP7-Audio", text: $localInputPath)
                            .textFieldStyle(.roundedBorder)
                            .onAppear {
                                if !localFolderPath.isEmpty {
                                    localInputPath = localFolderPath
                                }
                            }
                            .onChange(of: localFolderPath) { _, newValue in
                                if localInputPath.isEmpty || localValidationStatus == .success {
                                    localInputPath = newValue
                                }
                            }
                            .onChange(of: localInputPath) { _, _ in
                                localValidationStatus = nil
                            }

                        Button("Choose…") {
                            chooseLocalFolder()
                        }

                        Button("Validate") {
                            validateLocalFolder()
                        }
                        .disabled(localInputPath.isEmpty)
                    }

                    if let status = localValidationStatus {
                        switch status {
                        case .success:
                            Label("Folder is valid and accessible", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    if !localFolderPath.isEmpty {
                        Text("Current: \(localFolderPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Audio recordings will be copied to this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Info
            Section {
                if !s3Enabled && !localAudioEnabled {
                    Label("Enable S3 and/or local storage to sync recordings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else if s3Enabled && localAudioEnabled {
                    Label("Audio files will be uploaded to S3 and saved locally", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else if s3Enabled {
                    Label("Audio files will be uploaded to S3", systemImage: "cloud.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                } else if localAudioEnabled {
                    Label("Audio files will be saved locally", systemImage: "folder.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await checkCredentials()
        }
    }

    // MARK: - S3 Methods

    /// Debounces service reloads while the user is editing S3 fields. Typing in
    /// the bucket/region/prefix TextFields would otherwise tear down and rebuild
    /// every service (incl. keychain reads) on each keystroke.
    private func scheduleS3Reload() {
        testStatus = nil
        s3ReloadTask?.cancel()
        s3ReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            appState.reloadServices()
        }
    }

    private func checkCredentials() async {
        do {
            let accessKey = try await KeychainService.shared.retrieve(for: .awsAccessKeyId)
            let secretKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey)
            hasCredentials = (accessKey != nil && !accessKey!.isEmpty) &&
                           (secretKey != nil && !secretKey!.isEmpty)
        } catch {
            hasCredentials = false
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        do {
            let accessKeyId = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
            let secretAccessKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""

            let service = S3Service(
                bucket: bucket,
                region: region,
                prefix: prefix,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                provider: provider
            )

            try await service.validateBucket()
            testStatus = .success

            // Clear success message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    testStatus = nil
                }
            }
        } catch {
            testStatus = .error("Failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Local Folder Methods

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        let startPath = localInputPath.isEmpty ? localFolderPath : localInputPath
        if !startPath.isEmpty {
            let expanded = NSString(string: startPath).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        localInputPath = url.path
        validateLocalFolder()
    }

    private func validateLocalFolder() {
        localValidationStatus = nil

        let path = localInputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Check if folder exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            localValidationStatus = .error("Folder does not exist")
            return
        }

        guard isDirectory.boolValue else {
            localValidationStatus = .error("Path is not a folder")
            return
        }

        // Try to write a test file
        let folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let testFile = folderURL.appendingPathComponent(".tp7-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
        } catch {
            localValidationStatus = .error("Cannot write to folder")
            return
        }

        // Save the path and security-scoped bookmark together. Bail out if the
        // bookmark can't be created rather than persisting a folder we can't reopen.
        guard SecurityScopedBookmark.saveFolderSelection(url: folderURL, key: "localaudio.folderPath") else {
            localValidationStatus = .error("Couldn't get lasting access to this folder. Use Choose… to grant access.")
            return
        }

        // Update the @AppStorage binding so the "Current:" label refreshes now (a
        // direct UserDefaults write to a dotted key is not observed by @AppStorage).
        localFolderPath = folderURL.path
        localValidationStatus = .success
        appState.reloadServices()
    }

    private var awsRegions: [String] {
        [
            "us-east-1", "us-east-2", "us-west-1", "us-west-2",
            "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
            "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
            "ap-south-1", "sa-east-1", "ca-central-1"
        ]
    }
}

#Preview {
    StorageSettingsView()
}
