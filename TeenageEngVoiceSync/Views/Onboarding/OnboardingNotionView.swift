//
//  OnboardingNotionView.swift
//  TeenageEngVoiceSync
//
//  Notion integration setup (optional).
//

import SwiftUI

struct OnboardingNotionView: View {
    @Bindable var draft: OnboardingDraft
    @Binding var isConfigured: Bool

    @State private var showKey = false
    @State private var isProvisioning = false
    @State private var status: ProvisionStatus?
    @State private var warnings: [String] = []

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

            // Provision button and status
            VStack(spacing: 10) {
                HStack {
                    Button(isProvisioning ? "Connecting…" : "Provision & Connect") {
                        Task { await provisionAndSave() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.notionAPIKey.isEmpty || draft.notionDatabaseId.isEmpty || isProvisioning)

                    if isProvisioning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let status {
                    statusLabel(for: status)
                }

                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Info text
            Text("Any missing properties (Date, Filename, Duration, Language, Audio, Summary) are added to the database automatically — existing columns and data are never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Reflect an existing, enabled configuration seeded into the draft.
            if !draft.notionAPIKey.isEmpty {
                isConfigured = draft.notionEnabled
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for status: ProvisionStatus) -> some View {
        switch status {
        case .success:
            Label("Connected! Database is ready.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func provisionAndSave() async {
        isProvisioning = true
        status = nil
        warnings = []
        defer { isProvisioning = false }

        do {
            // Provisioning adds any missing columns to the remote database (a real
            // side effect, allowed to run early). The key, database ID, resolved
            // property names, and enabled flag are staged in the draft and persisted
            // only when onboarding completes.
            let result = try await NotionService.provisionDatabase(apiKey: draft.notionAPIKey, databaseId: draft.notionDatabaseId)
            draft.notionProps = result.props
            status = .success
            warnings = result.warnings
            isConfigured = true
            draft.notionEnabled = true
        } catch {
            status = .error("Failed: \(error.localizedDescription)")
            isConfigured = false
        }
    }
}

#Preview {
    OnboardingNotionView(draft: OnboardingDraft(), isConfigured: .constant(false))
        .frame(width: 600, height: 480)
}
