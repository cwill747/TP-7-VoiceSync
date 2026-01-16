//
//  OnboardingView.swift
//  TeenageEngVoiceSync
//
//  Main onboarding wizard container with step navigation.
//

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case transcription
    case s3Setup
    case localAudioFolder  // Only shown if S3 is skipped
    case openRouter
    case appleNotes
    case localMarkdownFolder  // Only shown if Apple Notes is skipped
    case complete

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .transcription: return "Transcription"
        case .s3Setup: return "S3 Storage"
        case .localAudioFolder: return "Audio Folder"
        case .openRouter: return "OpenRouter"
        case .appleNotes: return "Apple Notes"
        case .localMarkdownFolder: return "Notes Folder"
        case .complete: return "Complete"
        }
    }

    var isOptional: Bool {
        switch self {
        case .welcome, .transcription, .complete: return false
        case .localAudioFolder, .localMarkdownFolder: return false  // Required fallback steps
        case .s3Setup, .openRouter, .appleNotes: return true
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var currentStep: OnboardingStep = .welcome

    // Configuration state passed between steps
    @State private var transcriptionConfigured = false
    @State private var s3Configured = false
    @State private var s3Skipped = false
    @State private var localAudioFolderConfigured = false
    @State private var openRouterConfigured = false
    @State private var appleNotesConfigured = false
    @State private var appleNotesSkipped = false
    @State private var localMarkdownFolderConfigured = false

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator - fixed height
            progressIndicator
                .frame(height: 44)
                .padding(.horizontal, 24)

            Divider()

            // Current step content - fills remaining space
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons - fixed height
            navigationButtons
                .frame(height: 60)
                .padding(.horizontal, 24)
        }
        .frame(width: 600, height: 550)
    }

    // MARK: - Active Steps (excluding conditional steps that don't apply)

    private var activeSteps: [OnboardingStep] {
        var steps: [OnboardingStep] = [.welcome, .transcription, .s3Setup]

        // Add local audio folder step if S3 was skipped
        if s3Skipped && !s3Configured {
            steps.append(.localAudioFolder)
        }

        steps.append(.openRouter)
        steps.append(.appleNotes)

        // Add local markdown folder step if Apple Notes was skipped
        if appleNotesSkipped && !appleNotesConfigured {
            steps.append(.localMarkdownFolder)
        }

        steps.append(.complete)
        return steps
    }

    // Steps to show in progress indicator (excludes complete and conditional steps not yet determined)
    private var progressSteps: [OnboardingStep] {
        activeSteps.filter { $0 != .complete }
    }

    // MARK: - Progress Indicator

    @ViewBuilder
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(progressSteps.enumerated()), id: \.element) { index, step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(stepColor(for: step))
                        .frame(width: 8, height: 8)

                    if currentStep == step {
                        Text(step.title)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }

                if index < progressSteps.count - 1 {
                    Rectangle()
                        .fill(stepIsBefore(step, currentStep) ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 20, height: 2)
                }
            }
        }
    }

    private func stepColor(for step: OnboardingStep) -> Color {
        if stepIsBefore(step, currentStep) {
            return .accentColor
        } else if step == currentStep {
            return .accentColor
        } else {
            return .secondary.opacity(0.3)
        }
    }

    private func stepIsBefore(_ step: OnboardingStep, _ current: OnboardingStep) -> Bool {
        guard let stepIndex = activeSteps.firstIndex(of: step),
              let currentIndex = activeSteps.firstIndex(of: current) else {
            return false
        }
        return stepIndex < currentIndex
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            OnboardingWelcomeView()
        case .transcription:
            OnboardingTranscriptionView(isConfigured: $transcriptionConfigured)
        case .s3Setup:
            OnboardingS3View(isConfigured: $s3Configured)
        case .localAudioFolder:
            OnboardingLocalAudioFolderView(isConfigured: $localAudioFolderConfigured)
        case .openRouter:
            OnboardingOpenRouterView(isConfigured: $openRouterConfigured)
        case .appleNotes:
            OnboardingAppleNotesView(isConfigured: $appleNotesConfigured)
        case .localMarkdownFolder:
            OnboardingLocalMarkdownFolderView(isConfigured: $localMarkdownFolderConfigured)
        case .complete:
            OnboardingCompleteView(
                transcriptionConfigured: transcriptionConfigured,
                s3Configured: s3Configured,
                localAudioFolderConfigured: localAudioFolderConfigured,
                openRouterConfigured: openRouterConfigured,
                appleNotesConfigured: appleNotesConfigured,
                localMarkdownFolderConfigured: localMarkdownFolderConfigured
            )
        }
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private var navigationButtons: some View {
        HStack {
            // Back button (show on all steps except welcome)
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        goToPreviousStep()
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            // Skip button for optional steps (S3, OpenRouter, Apple Notes)
            if currentStep.isOptional {
                Button("Skip") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        handleSkip()
                    }
                }
                .buttonStyle(.bordered)
            }

            // Primary action button
            if currentStep == .complete {
                Button("Start Using TP-7 VoiceSync") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
            } else {
                let canContinue = canContinueFromCurrentStep()
                Button(currentStep == .welcome ? "Get Started" : "Continue") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        goToNextStep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
    }

    // MARK: - Navigation Logic

    private func canContinueFromCurrentStep() -> Bool {
        switch currentStep {
        case .transcription:
            return transcriptionConfigured
        case .localAudioFolder:
            return localAudioFolderConfigured
        case .localMarkdownFolder:
            return localMarkdownFolderConfigured
        default:
            return true
        }
    }

    private func handleSkip() {
        switch currentStep {
        case .s3Setup:
            s3Skipped = true
            goToNextStep()
        case .appleNotes:
            appleNotesSkipped = true
            goToNextStep()
        default:
            goToNextStep()
        }
    }

    private func goToNextStep() {
        // Handle special transitions
        switch currentStep {
        case .s3Setup:
            if s3Configured {
                // S3 configured, skip local audio folder step
                s3Skipped = false
                currentStep = .openRouter
            } else if s3Skipped {
                // S3 skipped, go to local audio folder
                currentStep = .localAudioFolder
            } else {
                // Just continuing without configuring - treat as skip
                s3Skipped = true
                currentStep = .localAudioFolder
            }

        case .localAudioFolder:
            currentStep = .openRouter

        case .appleNotes:
            if appleNotesConfigured {
                // Apple Notes configured, skip local markdown folder step
                appleNotesSkipped = false
                currentStep = .complete
            } else if appleNotesSkipped {
                // Apple Notes skipped, go to local markdown folder
                currentStep = .localMarkdownFolder
            } else {
                // Just continuing without configuring - treat as skip
                appleNotesSkipped = true
                currentStep = .localMarkdownFolder
            }

        case .localMarkdownFolder:
            currentStep = .complete

        default:
            // Standard sequential navigation
            guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
                  currentIndex + 1 < OnboardingStep.allCases.count else { return }
            currentStep = OnboardingStep.allCases[currentIndex + 1]
        }
    }

    private func goToPreviousStep() {
        switch currentStep {
        case .localAudioFolder:
            currentStep = .s3Setup

        case .openRouter:
            if s3Skipped && !s3Configured {
                currentStep = .localAudioFolder
            } else {
                currentStep = .s3Setup
            }

        case .localMarkdownFolder:
            currentStep = .appleNotes

        case .complete:
            if appleNotesSkipped && !appleNotesConfigured {
                currentStep = .localMarkdownFolder
            } else {
                currentStep = .appleNotes
            }

        default:
            // Standard sequential navigation
            guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
                  currentIndex > 0 else { return }
            currentStep = OnboardingStep.allCases[currentIndex - 1]
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        dismiss()
    }
}

#Preview {
    OnboardingView()
}
