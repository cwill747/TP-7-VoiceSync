//
//  AdvancedSettingsView.swift
//  TeenageEngVoiceSync
//
//  Advanced settings including custom LLM prompt configuration.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("llm.customPrompt") private var customPrompt = ""

    @State private var promptText = ""
    @State private var saveStatus: SaveStatus?
    @State private var showReprocessConfirm = false
    @State private var reprocessCompleted = false

    enum SaveStatus {
        case success
    }

    var body: some View {
        Form {
            Section("Reprocess Recordings") {
                Text("Apply your current destination and AI-title settings to recordings that were synced before you changed them. This only fills in missing steps — notes and Notion pages that already exist are left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        showReprocessConfirm = true
                    } label: {
                        if appState.isReprocessing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Reprocessing…")
                            }
                        } else {
                            Text(reprocessButtonTitle)
                        }
                    }
                    .disabled(appState.isReprocessing || appState.isOffline || appState.pendingRemoteCount == 0)

                    Spacer()

                    if appState.isOffline {
                        Label("Offline", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else if reprocessCompleted {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }

            Section("LLM Prompt Template") {
                Text("Customize the prompt used to generate titles and summaries from your transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )

                Text("The transcription text will be automatically appended to this prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset to Default") {
                        promptText = OpenRouterService.defaultPrompt
                        customPrompt = ""
                        saveStatus = nil
                    }
                    .disabled(promptText == OpenRouterService.defaultPrompt)

                    Spacer()

                    if let status = saveStatus {
                        switch status {
                        case .success:
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    Button("Save") {
                        customPrompt = promptText
                        saveStatus = .success
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                saveStatus = nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(promptText == customPrompt || (promptText == OpenRouterService.defaultPrompt && customPrompt.isEmpty))
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tips for writing effective prompts:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("- Request specific formats (e.g., JSON, bullet points)")
                        Text("- Specify maximum lengths for titles and summaries")
                        Text("- Include instructions for handling different content types")
                        Text("- The transcription is appended after your prompt")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Load current prompt or default
            promptText = customPrompt.isEmpty ? OpenRouterService.defaultPrompt : customPrompt
            // Recompute how many recordings owe work under the current settings,
            // in case a destination was just enabled in another tab.
            appState.refreshPendingRemoteCount()
        }
        .confirmationDialog(
            "Reprocess recordings?",
            isPresented: $showReprocessConfirm,
            titleVisibility: .visible
        ) {
            Button(reprocessButtonTitle) {
                Task {
                    reprocessCompleted = false
                    await appState.reprocessAllRecordings()
                    reprocessCompleted = true
                    try? await Task.sleep(for: .seconds(3))
                    reprocessCompleted = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This applies your current destination and AI-title settings to \(appState.pendingRemoteCount) recording\(appState.pendingRemoteCount == 1 ? "" : "s") synced before you changed them. Existing notes and Notion pages are left as-is.")
        }
    }

    private var reprocessButtonTitle: String {
        let count = appState.pendingRemoteCount
        if count == 0 { return "Nothing to Reprocess" }
        return "Reprocess \(count) Recording\(count == 1 ? "" : "s")"
    }
}

#Preview {
    AdvancedSettingsView()
        .environment(AppState())
}
