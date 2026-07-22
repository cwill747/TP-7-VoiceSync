//
//  OnboardingLocalAudioFolderView.swift
//  TeenageEngVoiceSync
//
//  Local audio folder selection when S3 is skipped.
//

import SwiftUI
import AppKit

struct OnboardingLocalAudioFolderView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var isConfigured: Bool

    @State private var inputPath = ""
    @State private var isValidating = false
    @State private var validationStatus: ValidationStatus?

    enum ValidationStatus {
        case success
        case error(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Local Audio Storage")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Since you skipped S3 cloud storage, choose a local folder where your audio recordings will be copied.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Folder input
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage Folder")
                    .font(.headline)

                HStack {
                    TextField("e.g. /Users/you/Downloads/TP7-Audio", text: $inputPath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: inputPath) { _, _ in
                            validationStatus = nil
                        }

                    Button("Choose…") {
                        chooseFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isValidating)

                    Button("Validate") {
                        validateFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputPath.isEmpty || isValidating)
                }

                if let status = validationStatus {
                    statusLabel(for: status)
                }

                Text("Enter the full path to a folder on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Info
            VStack(spacing: 4) {
                Text("A folder is required to store your recordings locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("You can change this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Reflect a folder already staged in the draft (seeded or chosen earlier).
            if !draft.localAudioFolderPath.isEmpty {
                inputPath = draft.localAudioFolderPath
                isConfigured = true
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for status: ValidationStatus) -> some View {
        switch status {
        case .success:
            Label("Folder is valid and accessible!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func validateFolder() {
        isValidating = true
        validationStatus = nil

        let path = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Expand ~ to home directory
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Check if folder exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            validationStatus = .error("Folder does not exist")
            isValidating = false
            return
        }

        guard isDirectory.boolValue else {
            validationStatus = .error("Path is not a folder")
            isValidating = false
            return
        }

        // Try to write a test file
        let folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let testFile = folderURL.appendingPathComponent(".tp7-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
        } catch {
            validationStatus = .error("Cannot write to folder: \(error.localizedDescription)")
            isValidating = false
            return
        }

        // Stage the path and security-scoped bookmark in the draft. Bail out if the
        // bookmark can't be created rather than staging a folder we can't reopen.
        // Both are committed to UserDefaults only when onboarding completes.
        guard let bookmark = SecurityScopedBookmark.makeBookmarkData(for: folderURL) else {
            validationStatus = .error("Couldn't get lasting access to this folder. Click Choose… to grant access.")
            isValidating = false
            return
        }

        // Success - stage local storage in the draft (S3 is disabled when local
        // storage is chosen).
        draft.localAudioFolderPath = folderURL.path
        draft.localAudioBookmark = bookmark
        draft.localAudioEnabled = true
        draft.s3Enabled = false
        validationStatus = .success
        isConfigured = true
        isValidating = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        let startPath = inputPath.isEmpty ? draft.localAudioFolderPath : inputPath
        if !startPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: startPath).expandingTildeInPath)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputPath = url.path
        validateFolder()
    }
}

#Preview {
    OnboardingLocalAudioFolderView(draft: OnboardingDraft(), isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
