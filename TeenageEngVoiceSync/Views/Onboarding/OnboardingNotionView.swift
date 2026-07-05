//
//  OnboardingNotionView.swift
//  TeenageEngVoiceSync
//
//  Notion integration setup (optional).
//

import SwiftUI

struct OnboardingNotionView: View {
    @Binding var isConfigured: Bool

    @AppStorage("notion.enabled") private var notionEnabled = false
    @AppStorage("notion.databaseId") private var notionDatabaseId = ""

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isProvisioning = false
    @State private var status: ProvisionStatus?
    @State private var warnings: [String] = []
    @State private var isLoading = true

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
                        TextField("ntn_… or secret_…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("ntn_… or secret_…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(isLoading)

                Link("Create an integration at notion.so/my-integrations", destination: URL(string: "https://www.notion.so/my-integrations")!)
                    .font(.caption)
            }

            // Database ID
            VStack(alignment: .leading, spacing: 10) {
                Text("Database")
                    .font(.headline)

                TextField("Database ID (32-char hex from the DB URL)", text: $notionDatabaseId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoading)

                Text("Share the database with your integration first (••• → Connections), then paste its ID from the URL.")
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
                    .disabled(apiKey.isEmpty || notionDatabaseId.isEmpty || isProvisioning)

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
            await loadExistingKey()
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

    private func loadExistingKey() async {
        isLoading = true
        defer { isLoading = false }

        if let existingKey = try? await KeychainService.shared.retrieve(for: .notionAPIKey),
           !existingKey.isEmpty {
            apiKey = existingKey
            isConfigured = notionEnabled
        }
    }

    private func provisionAndSave() async {
        isProvisioning = true
        status = nil
        warnings = []
        defer { isProvisioning = false }

        do {
            try await KeychainService.shared.save(apiKey, for: .notionAPIKey)
            let result = try await NotionService.provisionDatabase(apiKey: apiKey, databaseId: notionDatabaseId)
            result.props.store()
            status = .success
            warnings = result.warnings
            isConfigured = true
            notionEnabled = true
        } catch {
            status = .error("Failed: \(error.localizedDescription)")
            isConfigured = false
        }
    }
}

#Preview {
    OnboardingNotionView(isConfigured: .constant(false))
        .frame(width: 600, height: 480)
}
