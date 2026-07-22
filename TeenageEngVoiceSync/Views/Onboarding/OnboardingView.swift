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
    case notion
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
        case .notion: return "Notion"
        case .complete: return "Complete"
        }
    }

    var isOptional: Bool {
        switch self {
        case .welcome, .transcription, .complete: return false
        case .localAudioFolder, .localMarkdownFolder: return false  // Required fallback steps
        case .s3Setup, .openRouter, .appleNotes, .notion: return true
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Wizard-owned draft. All step edits land here; nothing is persisted until
    /// `completeOnboarding()` commits it, so closing or canceling changes nothing.
    @State private var draft = OnboardingDraft()

    @State private var currentStep: OnboardingStep = .welcome

    // Configuration state passed between steps. Transcription is required (no
    // skip/disable semantics), so it stays a plain Bool. Everything optional or
    // fallback tracks an explicit IntegrationDecision so re-running the wizard
    // can distinguish "kept existing" from "configured now" and "skipped" (TP-16).
    @State private var transcriptionConfigured = false
    @State private var s3Decision: IntegrationDecision = .notConfigured
    @State private var localAudioFolderDecision: IntegrationDecision = .notConfigured
    @State private var openRouterDecision: IntegrationDecision = .notConfigured
    @State private var appleNotesDecision: IntegrationDecision = .notConfigured
    @State private var localMarkdownFolderDecision: IntegrationDecision = .notConfigured
    @State private var notionDecision: IntegrationDecision = .notConfigured

    // Final-commit state
    @State private var isCompleting = false
    @State private var completionError: String?

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
        .task {
            await draft.seed()
            // Seed each optional/fallback step's decision from its persisted state,
            // so "already configured" renders as kept, not as freshly configured.
            s3Decision = .initial(wasConfiguredAtSeed: draft.s3WasConfiguredAtSeed)
            localAudioFolderDecision = .initial(wasConfiguredAtSeed: draft.localAudioWasConfiguredAtSeed)
            openRouterDecision = .initial(wasConfiguredAtSeed: draft.openRouterWasConfiguredAtSeed)
            appleNotesDecision = .initial(wasConfiguredAtSeed: draft.appleNotesWasConfiguredAtSeed)
            localMarkdownFolderDecision = .initial(wasConfiguredAtSeed: draft.markdownWasConfiguredAtSeed)
            notionDecision = .initial(wasConfiguredAtSeed: draft.notionWasConfiguredAtSeed)
        }
        .alert("Couldn't Save Setup", isPresented: Binding(
            get: { completionError != nil },
            set: { if !$0 { completionError = nil } }
        )) {
            Button("OK", role: .cancel) { completionError = nil }
        } message: {
            Text(completionError ?? "")
        }
    }

    // MARK: - Active Steps (excluding conditional steps that don't apply)

    private var activeSteps: [OnboardingStep] {
        var steps: [OnboardingStep] = [.welcome, .transcription, .s3Setup]

        // Add local audio folder step once S3 has been explicitly resolved to
        // not-enabled (skipped/disabled) — not while still undecided on first visit.
        if s3Decision != .notConfigured && !s3Decision.isEnabled {
            steps.append(.localAudioFolder)
        }

        steps.append(.openRouter)
        steps.append(.appleNotes)

        // Add local markdown folder step once Apple Notes has been explicitly
        // resolved to not-enabled (skipped/disabled).
        if appleNotesDecision != .notConfigured && !appleNotesDecision.isEnabled {
            steps.append(.localMarkdownFolder)
        }

        steps.append(.notion)
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
            OnboardingTranscriptionView(draft: draft, isConfigured: $transcriptionConfigured)
        case .s3Setup:
            OnboardingS3View(draft: draft, decision: $s3Decision)
        case .localAudioFolder:
            OnboardingLocalAudioFolderView(draft: draft, decision: $localAudioFolderDecision)
        case .openRouter:
            OnboardingOpenRouterView(draft: draft, decision: $openRouterDecision)
        case .appleNotes:
            OnboardingAppleNotesView(draft: draft, decision: $appleNotesDecision)
        case .localMarkdownFolder:
            OnboardingLocalMarkdownFolderView(draft: draft, decision: $localMarkdownFolderDecision)
        case .notion:
            OnboardingNotionView(draft: draft, decision: $notionDecision)
        case .complete:
            OnboardingCompleteView(
                draft: draft,
                transcriptionConfigured: transcriptionConfigured,
                s3Decision: s3Decision,
                localAudioFolderDecision: localAudioFolderDecision,
                openRouterDecision: openRouterDecision,
                appleNotesDecision: appleNotesDecision,
                localMarkdownFolderDecision: localMarkdownFolderDecision,
                notionDecision: notionDecision
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

            // Skip button — only for optional steps that have never been
            // configured. Steps that already have existing configuration expose
            // an in-step Enable/Disable toggle instead, so this button never
            // silently reinterprets "skip" as "disable my existing setup".
            if currentStep.isOptional && !currentStepWasConfiguredAtSeed {
                Button("Skip for Now") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        handleSkip()
                    }
                }
                .buttonStyle(.bordered)
            }

            // Primary action button
            if currentStep == .complete {
                HStack(spacing: 8) {
                    if isCompleting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Button("Start Using TP-7 VoiceSync") {
                        Task { await completeOnboarding() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCompleting)
                }
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

    /// Whether the integration for `currentStep` was already configured when the
    /// wizard opened. Drives whether the bottom "Skip for Now" button appears —
    /// an already-configured step uses its own Enable/Disable toggle instead.
    private var currentStepWasConfiguredAtSeed: Bool {
        switch currentStep {
        case .s3Setup: return draft.s3WasConfiguredAtSeed
        case .openRouter: return draft.openRouterWasConfiguredAtSeed
        case .appleNotes: return draft.appleNotesWasConfiguredAtSeed
        case .notion: return draft.notionWasConfiguredAtSeed
        default: return false
        }
    }

    private func canContinueFromCurrentStep() -> Bool {
        switch currentStep {
        case .transcription:
            return transcriptionConfigured
        case .localAudioFolder:
            return localAudioFolderDecision.isEnabled
        case .localMarkdownFolder:
            return localMarkdownFolderDecision.isEnabled
        default:
            return true
        }
    }

    private func handleSkip() {
        switch currentStep {
        case .s3Setup:
            s3Decision = .skipped
        case .appleNotes:
            appleNotesDecision = .skipped
        case .openRouter:
            openRouterDecision = .skipped
        case .notion:
            notionDecision = .skipped
        default:
            break
        }
        goToNextStep()
    }

    private func goToNextStep() {
        // Handle special transitions
        switch currentStep {
        case .s3Setup:
            // Continuing without an explicit decision (no Skip press, no
            // successful test) is treated as skipping, same as pressing Skip.
            if s3Decision == .notConfigured { s3Decision = .skipped }
            // The decision is the source of truth for what gets committed —
            // sync the draft's flag to it so a skipped/disabled step can never
            // leave a stale `true` (e.g. from seeded-but-incomplete settings)
            // for `apply()` to re-commit.
            draft.s3Enabled = s3Decision.isEnabled
            currentStep = s3Decision.isEnabled ? .openRouter : .localAudioFolder

        case .localAudioFolder:
            currentStep = .openRouter

        case .openRouter:
            if openRouterDecision == .notConfigured { openRouterDecision = .skipped }
            draft.openRouterEnabled = openRouterDecision.isEnabled
            currentStep = .appleNotes

        case .appleNotes:
            if appleNotesDecision == .notConfigured { appleNotesDecision = .skipped }
            draft.appleNotesEnabled = appleNotesDecision.isEnabled
            currentStep = appleNotesDecision.isEnabled ? .notion : .localMarkdownFolder

        case .localMarkdownFolder:
            currentStep = .notion

        case .notion:
            if notionDecision == .notConfigured { notionDecision = .skipped }
            draft.notionEnabled = notionDecision.isEnabled
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
            currentStep = s3Decision.isEnabled ? .s3Setup : .localAudioFolder

        case .localMarkdownFolder:
            currentStep = .appleNotes

        case .notion:
            currentStep = appleNotesDecision.isEnabled ? .appleNotes : .localMarkdownFolder

        case .complete:
            currentStep = .notion

        default:
            // Standard sequential navigation
            guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
                  currentIndex > 0 else { return }
            currentStep = OnboardingStep.allCases[currentIndex - 1]
        }
    }

    private func completeOnboarding() async {
        isCompleting = true
        defer { isCompleting = false }

        do {
            // Commit the whole draft atomically. On failure nothing is persisted,
            // so the wizard stays open with settings unchanged and an actionable error.
            try await draft.apply()
            hasCompletedOnboarding = true
            dismiss()
        } catch {
            completionError = "Your settings couldn't be saved: \(error.localizedDescription). Please try again."
        }
    }
}

#Preview {
    OnboardingView()
}
