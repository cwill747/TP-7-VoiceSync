//
//  OnboardingLocalMarkdownFolderView.swift
//  TeenageEngVoiceSync
//
//  Local markdown folder selection when Apple Notes is skipped.
//

import SwiftUI

struct OnboardingLocalMarkdownFolderView: View {
    @Binding var isConfigured: Bool

    @AppStorage("markdown.enabled") private var markdownEnabled = false
    @AppStorage("markdown.folderPath") private var folderPath = ""
    @AppStorage("applenotes.enabled") private var appleNotesEnabled = false

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
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Local Markdown Notes")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Since you skipped Apple Notes, your transcriptions will be saved as local markdown (.md) files. Choose a folder to store them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Folder input
            VStack(alignment: .leading, spacing: 10) {
                Text("Notes Folder")
                    .font(.headline)

                HStack {
                    TextField("e.g. /Users/you/Downloads/TP7-Notes", text: $inputPath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: inputPath) { _, _ in
                            validationStatus = nil
                        }

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
                Text("A folder is required to store your transcription notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Markdown files can be opened with any text editor or note-taking app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Load existing path
            if !folderPath.isEmpty {
                inputPath = folderPath
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
        let testFile = URL(fileURLWithPath: expandedPath).appendingPathComponent(".tp7-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
        } catch {
            validationStatus = .error("Cannot write to folder: \(error.localizedDescription)")
            isValidating = false
            return
        }

        // Success - save the path, bookmark, and enable markdown
        SecurityScopedBookmark.save(url: URL(fileURLWithPath: expandedPath), key: "markdown.folderPath")
        folderPath = expandedPath
        markdownEnabled = true
        appleNotesEnabled = false  // Disable Apple Notes when markdown is enabled
        validationStatus = .success
        isConfigured = true
        isValidating = false
    }
}

#Preview {
    OnboardingLocalMarkdownFolderView(isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
