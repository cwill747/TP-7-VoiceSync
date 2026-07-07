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
    @AppStorage("llm.formatPrompt") private var formatPrompt = ""
    @AppStorage("devicewatch.deleteAfterProcessing") private var deleteAfterProcessing = false

    @State private var promptText = ""
    @State private var saveStatus: SaveStatus?
    @State private var formatPromptText = ""
    @State private var formatSaveStatus: SaveStatus?
    @State private var showReprocessConfirm = false
    @State private var reprocessResult: ReprocessResult?
    @State private var showDeleteAfterProcessingConfirm = false

    enum SaveStatus {
        case success
    }

    /// Outcome of a finished reprocess pass. `reconcilePendingWork` swallows
    /// per-recording delivery errors (e.g. missing credentials), so success is
    /// judged by whether the pending count actually reached zero afterwards —
    /// not merely by the pass returning.
    enum ReprocessResult {
        case done
        case partial(remaining: Int)
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

                    reprocessStatusLabel
                }
            }

            Section("Device Storage") {
                Toggle("Delete from TP-7 after processing", isOn: Binding(
                    get: { deleteAfterProcessing },
                    set: { newValue in
                        if newValue {
                            showDeleteAfterProcessingConfirm = true
                        } else {
                            deleteAfterProcessing = false
                        }
                    }
                ))

                Text("Once a recording has been fully transferred, transcribed, and delivered to your configured destinations, its audio file is permanently removed from the TP-7 to free up device storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Transcript Cleanup Prompt") {
                Text("Customize the prompt used to clean up transcripts — punctuation, capitalization, and correction of likely transcription errors. Keep it conservative so meaning and wording are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $formatPromptText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )

                Text("The raw transcription text will be automatically appended to this prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset to Default") {
                        formatPromptText = OpenRouterService.defaultFormattingPrompt
                        formatPrompt = ""
                        formatSaveStatus = nil
                    }
                    .disabled(formatPromptText == OpenRouterService.defaultFormattingPrompt)

                    Spacer()

                    if let status = formatSaveStatus {
                        switch status {
                        case .success:
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    Button("Save") {
                        formatPrompt = formatPromptText
                        formatSaveStatus = .success
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                formatSaveStatus = nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(formatPromptText == formatPrompt || (formatPromptText == OpenRouterService.defaultFormattingPrompt && formatPrompt.isEmpty))
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
            formatPromptText = formatPrompt.isEmpty ? OpenRouterService.defaultFormattingPrompt : formatPrompt
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
                    reprocessResult = nil
                    await appState.reprocessAllRecordings()
                    // A completed pass leaves anything it couldn't deliver in the
                    // pending count; only report "Done" when it actually hit zero.
                    let remaining = appState.pendingRemoteCount
                    reprocessResult = remaining == 0 ? .done : .partial(remaining: remaining)
                    try? await Task.sleep(for: .seconds(4))
                    reprocessResult = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This applies your current destination and AI-title settings to \(appState.pendingRemoteCount) recording\(appState.pendingRemoteCount == 1 ? "" : "s") synced before you changed them. Existing notes and Notion pages are left as-is.")
        }
        .confirmationDialog(
            "Delete recordings from TP-7 after processing?",
            isPresented: $showDeleteAfterProcessingConfirm,
            titleVisibility: .visible
        ) {
            Button("Enable", role: .destructive) {
                deleteAfterProcessing = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Once a recording is fully transcribed and delivered to your configured destinations, its audio will be permanently deleted from the TP-7. This cannot be undone.")
        }
    }

    private var reprocessButtonTitle: String {
        let count = appState.pendingRemoteCount
        if count == 0 { return "Nothing to Reprocess" }
        return "Reprocess \(count) Recording\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var reprocessStatusLabel: some View {
        if appState.isOffline {
            Label("Offline", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else if let result = reprocessResult {
            switch result {
            case .done:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .partial(let remaining):
                Label("\(remaining) still pending", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Some recordings couldn't be delivered — check that the destination credentials are configured, then try again.")
            }
        }
    }
}

#Preview {
    AdvancedSettingsView()
        .environment(AppState())
}
