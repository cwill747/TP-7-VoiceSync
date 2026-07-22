//
//  OnboardingNotionView.swift
//  TeenageEngVoiceSync
//
//  Notion integration setup (optional).
//

import SwiftUI

struct OnboardingNotionView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var decision: IntegrationDecision

    @State private var showKey = false
    @State private var isTesting = false
    @State private var status: ProvisionStatus?

    enum ProvisionStatus {
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
                    .accessibilityHidden(true)

                Text("Notion Integration")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Optional: Create a page per recording in a Notion database, alongside Apple Notes or Markdown if enabled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Integration secret
            VStack(alignment: .leading, spacing: 10) {
                Text("Integration Secret")
                    .font(.headline)

                HStack {
                    if showKey {
                        TextField("ntn_… or secret_…", text: $draft.notionAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("ntn_… or secret_…", text: $draft.notionAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(showKey ? "Hide API key" : "Show API key"))
                }
                .disabled(draft.isSeeding)

                Link("Create an integration at notion.so/my-integrations", destination: URL(string: "https://www.notion.so/my-integrations")!)
                    .font(.caption)
            }

            // Database ID
            VStack(alignment: .leading, spacing: 10) {
                Text("Database")
                    .font(.headline)

                TextField("Database ID (paste the DB URL or the 32-char hex ID)", text: $draft.notionDatabaseId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.isSeeding)
                    .onChange(of: draft.notionDatabaseId) { _, newValue in
                        let extracted = NotionService.extractDatabaseId(from: newValue)
                        if extracted != newValue {
                            draft.notionDatabaseId = extracted
                        }
                    }

                Text("Share the database with your integration first (••• → Connections), then paste the \"Copy link\" URL or its ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Existing configuration control (re-run only)
            if draft.notionWasConfiguredAtSeed {
                existingConfigurationToggle
            }

            // Test button and status
            VStack(spacing: 10) {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.notionAPIKey.isEmpty || draft.notionDatabaseId.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let status {
                    statusLabel(for: status)
                }
            }

            // Info text
            Text("Any missing properties (Date, Filename, Duration, Language, Audio, Summary) are added to the database when you finish setup — existing columns and data are never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var existingConfigurationToggle: some View {
        Toggle(isOn: Binding(
            get: { decision.isEnabled },
            set: { newValue in
                decision = newValue ? .keptExisting : .disabled
                draft.notionEnabled = newValue
            }
        )) {
            Text(decision.isEnabled ? "Notion is already configured — keep it enabled" : "Notion integration is disabled")
                .font(.caption)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func statusLabel(for status: ProvisionStatus) -> some View {
        switch status {
        case .success:
            Label("Connected! The database is set up when you finish setup.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func testConnection() async {
        isTesting = true
        status = nil
        defer { isTesting = false }

        do {
            // Read-only check that the secret works and the database is shared. The
            // key, database ID, and enabled flag are staged in the draft; the
            // database is provisioned (missing columns added) only when onboarding
            // completes.
            try await NotionService.validateDatabaseAccess(apiKey: draft.notionAPIKey, databaseId: draft.notionDatabaseId)
            status = .success
            decision = .configuredNow
            draft.notionEnabled = true
            draft.notionNeedsProvisioning = true
        } catch {
            status = .error("Failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    OnboardingNotionView(draft: OnboardingDraft(), decision: .constant(.notConfigured))
        .frame(width: 600, height: 480)
}
