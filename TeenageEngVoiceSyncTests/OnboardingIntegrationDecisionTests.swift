//
//  OnboardingIntegrationDecisionTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers TP-16: the setup wizard must record what the user actually decided
//  for an optional integration, distinct from whether it happened to already
//  be configured — so "Skip" on a re-run never gets reported as "Configured".
//

import XCTest
@testable import TP_7_VoiceSync

final class OnboardingIntegrationDecisionTests: XCTestCase {

    // MARK: First-run skip

    /// An integration that was never configured, skipped on a first run, must
    /// resolve to `.skipped` (not `.notConfigured`, not enabled), and summarize
    /// as "Skipped" — never "Configured".
    func testFirstRunSkipYieldsSkippedDecision() {
        var decision = IntegrationDecision.initial(wasConfiguredAtSeed: false)
        XCTAssertEqual(decision, .notConfigured)
        XCTAssertFalse(decision.isEnabled)

        // User presses "Skip for Now".
        decision = .skipped

        XCTAssertFalse(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Skipped")
    }

    /// Continuing past an optional step without configuring it or pressing
    /// Skip (the implicit-skip path in `OnboardingView.goToNextStep`) must
    /// still land on a decision that reports "Skipped", not silently stay
    /// `.notConfigured` and risk being read as truthy elsewhere.
    func testFirstRunImplicitSkipStillReportsSkipped() {
        let decision = IntegrationDecision.notConfigured
        // Mirrors OnboardingView.goToNextStep's normalization.
        let resolved: IntegrationDecision = decision == .notConfigured ? .skipped : decision

        XCTAssertFalse(resolved.isEnabled)
        XCTAssertEqual(resolved.summaryLabel, "Skipped")
    }

    // MARK: Re-run with an existing integration

    /// Re-opening the wizard with an integration already configured must
    /// default to "kept", not "configured now" — this is the exact TP-16
    /// reproduction (Notion inheriting persisted state and showing as
    /// "Configured" after being skipped).
    func testRerunWithExistingIntegrationDefaultsToKeptExisting() {
        let decision = IntegrationDecision.initial(wasConfiguredAtSeed: true)

        XCTAssertEqual(decision, .keptExisting)
        XCTAssertTrue(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Already Configured")
        XCTAssertNotEqual(decision.summaryLabel, "Configured",
                           "Kept-existing config must read distinctly from freshly-configured")
    }

    // MARK: Disabling an existing integration

    /// Turning off the in-step toggle for an already-configured integration
    /// must resolve to `.disabled`, not enabled, and summarize as "Disabled".
    func testDisablingExistingIntegrationYieldsDisabledDecision() {
        var decision = IntegrationDecision.initial(wasConfiguredAtSeed: true)
        XCTAssertTrue(decision.isEnabled)

        // User flips the Enable/Disable toggle off.
        decision = .disabled

        XCTAssertFalse(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Disabled")
    }

    // MARK: Configuring a new integration

    /// Successfully testing/verifying a brand-new integration must resolve to
    /// `.configuredNow`, enabled, and summarize as "Configured" — distinct from
    /// a kept pre-existing configuration.
    func testConfiguringNewIntegrationYieldsConfiguredNowDecision() {
        var decision = IntegrationDecision.initial(wasConfiguredAtSeed: false)
        XCTAssertFalse(decision.isEnabled)

        // User successfully tests/verifies the integration.
        decision = .configuredNow

        XCTAssertTrue(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Configured")
    }

    /// Reconfiguring (re-testing) an already-configured integration also
    /// resolves to `.configuredNow`, distinguishing an active change from
    /// simply leaving the existing setup untouched.
    func testReconfiguringExistingIntegrationYieldsConfiguredNowDecision() {
        var decision = IntegrationDecision.initial(wasConfiguredAtSeed: true)
        XCTAssertEqual(decision, .keptExisting)

        // User re-tests with new credentials.
        decision = .configuredNow

        XCTAssertTrue(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Configured")
    }

    /// A failed re-test of an already-configured integration must NOT stay
    /// `.keptExisting` — the fields on screen may be edited, unvalidated
    /// values, and a kept `.isEnabled` decision would let `apply()` commit
    /// them as a working configuration. Step views resolve a failed test to
    /// `.disabled` (see OnboardingS3View/OnboardingOpenRouterView/
    /// OnboardingNotionView's `catch` blocks).
    func testFailedRetestOfExistingIntegrationMustNotStayEnabled() {
        var decision = IntegrationDecision.initial(wasConfiguredAtSeed: true)
        XCTAssertTrue(decision.isEnabled)

        // User edits credentials and re-tests; the test fails.
        decision = .disabled

        XCTAssertFalse(decision.isEnabled)
        XCTAssertEqual(decision.summaryLabel, "Disabled")
    }
}
