//
//  OnboardingAppleNotesView.swift
//  TeenageEngVoiceSync
//
//  Apple Notes integration setup (optional).
//

import SwiftUI

struct OnboardingAppleNotesView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var isConfigured: Bool

    @State private var isTesting = false
    @State private var testStatus: TestStatus?

    enum TestStatus {
        case success
        case error(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Apple Notes Integration")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Optional: Automatically create Apple Notes with your transcriptions. Each recording will get its own note with the full text and audio playback links.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Folder configuration
            VStack(alignment: .leading, spacing: 10) {
                Text("Notes Folder")
                    .font(.headline)

                TextField("Folder name", text: $draft.appleNotesFolder)
                    .textFieldStyle(.roundedBorder)

                Text("Notes will be created in this folder in your Apple Notes app. The folder will be created automatically if it doesn't exist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Test button - testing successfully enables the integration
            VStack(spacing: 10) {
                HStack {
                    Button("Test & Enable") {
                        testNoteCreation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.appleNotesFolder.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let status = testStatus {
                    statusLabel(for: status)
                }
            }

            // Info text
            VStack(spacing: 4) {
                Text("The first time a note is created, macOS will ask for permission to control Apple Notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("You can grant this permission in System Settings > Privacy & Security > Automation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            // Note about skipping
            Text("If you skip this step, you'll be asked to select a folder for local markdown files instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusLabel(for status: TestStatus) -> some View {
        switch status {
        case .success:
            Label("Test note created! Check your Notes app.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func testNoteCreation() {
        isTesting = true
        testStatus = nil

        Task {
            let service = AppleNotesService()
            do {
                try await service.createNote(
                    title: "Test Note - \(Date().formatted())",
                    body: "<p>This is a test note from TP-7 VoiceSync setup wizard.</p><p>If you can see this, Apple Notes integration is working correctly!</p>",
                    folder: draft.appleNotesFolder
                )
                await MainActor.run {
                    testStatus = .success
                    isTesting = false
                    isConfigured = true
                    // Stage Apple Notes as enabled; markdown is disabled when Apple
                    // Notes is chosen. Persisted only when onboarding completes.
                    draft.appleNotesEnabled = true
                    draft.markdownEnabled = false
                }
            } catch {
                await MainActor.run {
                    testStatus = .error("Failed: \(error.localizedDescription)")
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    OnboardingAppleNotesView(draft: OnboardingDraft(), isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
