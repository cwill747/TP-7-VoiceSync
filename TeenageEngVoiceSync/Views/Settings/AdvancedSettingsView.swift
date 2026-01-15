//
//  AdvancedSettingsView.swift
//  TeenageEngVoiceSync
//
//  Advanced settings including custom LLM prompt configuration.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage("llm.customPrompt") private var customPrompt = ""

    @State private var promptText = ""
    @State private var saveStatus: SaveStatus?

    enum SaveStatus {
        case success
    }

    var body: some View {
        Form {
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
        }
    }
}

#Preview {
    AdvancedSettingsView()
}
