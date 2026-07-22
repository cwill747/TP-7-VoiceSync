//
//  OnboardingCompleteView.swift
//  TeenageEngVoiceSync
//
//  Completion screen with configuration summary.
//

import SwiftUI

struct OnboardingCompleteView: View {
    let draft: OnboardingDraft
    let transcriptionConfigured: Bool
    let s3Decision: IntegrationDecision
    let localAudioFolderDecision: IntegrationDecision
    let openRouterDecision: IntegrationDecision
    let appleNotesDecision: IntegrationDecision
    let localMarkdownFolderDecision: IntegrationDecision
    let notionDecision: IntegrationDecision

    // Reflect the pending draft selection (not the still-unchanged persisted value).
    private var transcriptionProvider: TranscriptionProviderKind {
        draft.transcriptionProvider
    }

    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            // Title
            VStack(spacing: 6) {
                Text("You're All Set!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("TP-7 VoiceSync is ready to use")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Configuration summary
            VStack(alignment: .leading, spacing: 10) {
                Text("Configuration Summary")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 6) {
                    configRow(
                        title: "Transcription (\(transcriptionProvider.shortName))",
                        configured: transcriptionConfigured,
                        required: true
                    )

                    // Show either S3 or Local Audio Folder
                    if s3Decision.isEnabled {
                        configRow(title: "S3 Storage", decision: s3Decision)
                    } else {
                        configRow(title: "Local Audio Storage", decision: localAudioFolderDecision)
                    }

                    configRow(title: "OpenRouter AI Titles", decision: openRouterDecision)

                    configRow(title: "Notion Integration", decision: notionDecision)

                    // Show either Apple Notes or Local Markdown
                    if appleNotesDecision.isEnabled {
                        configRow(title: "Apple Notes Integration", decision: appleNotesDecision)
                    } else {
                        configRow(title: "Local Markdown Notes", decision: localMarkdownFolderDecision)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Note about settings
            Text("You can change any of these later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func configRow(title: String, configured: Bool, required: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: configured ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(configured ? .green : .secondary)
                .font(.body)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)

            Spacer()

            if configured {
                Text("Configured")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if required {
                Text("Required")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Row for an optional/fallback integration — distinguishes "already
    /// configured / kept" from "configured now", "disabled", and "skipped" so
    /// the summary always matches what `apply()` is about to commit.
    @ViewBuilder
    private func configRow(title: String, decision: IntegrationDecision) -> some View {
        HStack(spacing: 10) {
            Image(systemName: decision.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(decision.isEnabled ? .green : .secondary)
                .font(.body)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)

            Spacer()

            Text(decision.summaryLabel)
                .font(.caption)
                .foregroundStyle(decision.isEnabled ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingCompleteView(
        draft: OnboardingDraft(),
        transcriptionConfigured: true,
        s3Decision: .keptExisting,
        localAudioFolderDecision: .notConfigured,
        openRouterDecision: .skipped,
        appleNotesDecision: .disabled,
        localMarkdownFolderDecision: .configuredNow,
        notionDecision: .configuredNow
    )
    .frame(width: 600, height: 440)
}
