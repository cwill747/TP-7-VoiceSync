//
//  OnboardingIntegrationDecision.swift
//  TeenageEngVoiceSync
//
//  Tracks what the user actually decided for an optional (or fallback)
//  integration in the current wizard run, separate from whether it happens to
//  already be configured from a previous run. "Skip" alone is ambiguous — it
//  could mean keep existing configuration, disable it, or just not touch it —
//  so the wizard records one of these explicit outcomes instead, and the
//  completion summary renders exactly that outcome.
//

import Foundation

enum IntegrationDecision: Equatable {
    /// Never configured before this run; the user hasn't acted on this step yet.
    case notConfigured
    /// Verified/enabled in this wizard run (first-time or reconfiguring).
    case configuredNow
    /// Already configured before this run; the user left it as-is.
    case keptExisting
    /// Already configured before this run; the user turned it off this run.
    case disabled
    /// Never configured before this run; the user explicitly skipped it.
    case skipped

    /// The starting decision for a step, based on whether the integration was
    /// already configured when the wizard was opened.
    static func initial(wasConfiguredAtSeed: Bool) -> IntegrationDecision {
        wasConfiguredAtSeed ? .keptExisting : .notConfigured
    }

    /// Whether this decision results in the integration being enabled when the
    /// draft commits. Also used to decide whether a fallback step (e.g. local
    /// audio folder when S3 isn't enabled) is needed.
    var isEnabled: Bool {
        switch self {
        case .configuredNow, .keptExisting: return true
        case .notConfigured, .skipped, .disabled: return false
        }
    }

    /// Label for the completion summary — distinguishes "kept as-is" from
    /// "configured in this run" and "skipped", matching the acceptance
    /// criteria for TP-16.
    var summaryLabel: String {
        switch self {
        case .configuredNow: return "Configured"
        case .keptExisting: return "Already Configured"
        case .disabled: return "Disabled"
        case .skipped, .notConfigured: return "Skipped"
        }
    }
}
