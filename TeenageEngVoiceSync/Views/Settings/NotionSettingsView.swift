//
//  NotionSettingsView.swift
//  TeenageEngVoiceSync
//
//  Settings tab for the Notion output: integration secret + database ID.
//

import SwiftUI

struct NotionSettingsView: View {
    @State private var enabled = false
    @State private var apiKey = ""
    @State private var databaseId = ""
    @State private var showKey = false
    @State private var status: String?
    @State private var isValidating = false
    @State private var isLoading = true

    var body: some View {
        Form {
            Section {
                Toggle("Send transcriptions to Notion", isOn: $enabled)
                    .disabled(isLoading)
                    .onChange(of: enabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "notion.enabled")
                    }
            } footer: {
                Text("Creates a page per recording in your Notion database, dated so a view can sort by date.")
                    .font(.caption)
            }

            Section("Credentials") {
                HStack {
                    if showKey {
                        TextField("Integration Secret (ntn_… or secret_…)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Integration Secret (ntn_… or secret_…)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(isLoading)

                TextField("Database ID (32-char hex from the DB URL)", text: $databaseId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoading)

                HStack {
                    Button(isValidating ? "Validating…" : "Save & Validate") {
                        Task { await saveAndValidate() }
                    }
                    .disabled(isLoading || isValidating || apiKey.isEmpty || databaseId.isEmpty)

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status == "Connected" ? .green : .red)
                    }
                }
            } footer: {
                Text("Create an integration at notion.so/my-integrations, then share your database with it via ••• → Connections.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        enabled = UserDefaults.standard.bool(forKey: "notion.enabled")
        databaseId = UserDefaults.standard.string(forKey: "notion.databaseId") ?? ""
        apiKey = (try? await KeychainService.shared.retrieve(for: .notionAPIKey)) ?? ""
        isLoading = false
    }

    private func saveAndValidate() async {
        isValidating = true
        status = nil
        do {
            try await KeychainService.shared.save(apiKey, for: .notionAPIKey)
            UserDefaults.standard.set(databaseId, forKey: "notion.databaseId")
            try await NotionService.validate(apiKey: apiKey, databaseId: databaseId)
            status = "Connected"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
        isValidating = false
    }
}

#Preview {
    NotionSettingsView()
}
