//
//  OnboardingCompleteView.swift
//  TeenageEngVoiceSync
//
//  Completion screen with configuration summary.
//

import SwiftUI

struct OnboardingCompleteView: View {
    let elevenLabsConfigured: Bool
    let s3Configured: Bool
    let localAudioFolderConfigured: Bool
    let openRouterConfigured: Bool
    let appleNotesConfigured: Bool
    let localMarkdownFolderConfigured: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

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
                        title: "ElevenLabs Transcription",
                        configured: elevenLabsConfigured,
                        required: true
                    )

                    // Show either S3 or Local Audio Folder
                    if s3Configured {
                        configRow(
                            title: "AWS S3 Storage",
                            configured: true,
                            required: false
                        )
                    } else {
                        configRow(
                            title: "Local Audio Storage",
                            configured: localAudioFolderConfigured,
                            required: false
                        )
                    }

                    configRow(
                        title: "OpenRouter AI Titles",
                        configured: openRouterConfigured,
                        required: false
                    )

                    // Show either Apple Notes or Local Markdown
                    if appleNotesConfigured {
                        configRow(
                            title: "Apple Notes Integration",
                            configured: true,
                            required: false
                        )
                    } else {
                        configRow(
                            title: "Local Markdown Notes",
                            configured: localMarkdownFolderConfigured,
                            required: false
                        )
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Note about settings
            Text("You can change any of these settings later in Preferences.")
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
    }
}

#Preview {
    OnboardingCompleteView(
        elevenLabsConfigured: true,
        s3Configured: true,
        localAudioFolderConfigured: false,
        openRouterConfigured: false,
        appleNotesConfigured: false,
        localMarkdownFolderConfigured: true
    )
    .frame(width: 600, height: 440)
}
