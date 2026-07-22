//
//  OnboardingWelcomeView.swift
//  TeenageEngVoiceSync
//
//  Welcome screen introducing the app and setup process.
//

import SwiftUI

struct OnboardingWelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            // App icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            // Welcome text
            VStack(spacing: 6) {
                Text("Welcome to TP-7 VoiceSync")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Automatically sync, transcribe, and organize your TP-7 recordings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Features overview
            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "cable.connector",
                    title: "TP-7 Connection",
                    description: DeviceConnectionCopy.onboardingDescription,
                    required: true
                )

                featureRow(
                    icon: "waveform",
                    title: "Transcription",
                    description: "Transcribe locally with recommended Parakeet TDT or Unified, or use WhisperKit or ElevenLabs",
                    required: true
                )

                featureRow(
                    icon: "externaldrive",
                    title: "Audio Storage",
                    description: "Keep recordings in a local folder or upload them to S3 for playback links",
                    required: false
                )

                featureRow(
                    icon: "brain",
                    title: "AI Enhancement",
                    description: "Generate titles and summaries with OpenRouter or a custom OpenAI-compatible provider",
                    required: false
                )

                featureRow(
                    icon: "note.text",
                    title: "Transcription Output",
                    description: "Save transcriptions to Apple Notes, local Markdown, Notion, or multiple outputs",
                    required: false
                )
            }
            .padding(.vertical, 8)

            Text("Let's set up your services. You can skip optional steps and configure them later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func featureRow(icon: String, title: String, description: String, required: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.medium)
                        .font(.subheadline)

                    if required {
                        Text("Required")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    } else {
                        Text("Optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingWelcomeView()
        .frame(width: 600, height: 440)
}
