//
//  OnboardingDraftTests.swift
//  TeenageEngVoiceSyncTests
//
//  Covers the transactional guarantee of the setup wizard: draft edits never
//  touch persisted settings until `apply()`, and a failed commit leaves the
//  previous configuration exactly as it was.
//

import XCTest
@testable import TP_7_VoiceSync

/// In-memory credential store standing in for the Keychain. `failOnSave` makes
/// the first save throw, simulating a failed final commit.
private final class MockCredentialStore: OnboardingCredentialStore, @unchecked Sendable {
    /// Live backing store; also seeded by tests to provide retrievable values.
    var stored: [KeychainService.Key: String] = [:]
    /// Record of keys that were successfully saved (for assertions).
    private(set) var saved: [KeychainService.Key: String] = [:]
    var failOnSave = false
    /// Fail only when saving this specific key (to exercise mid-sequence rollback).
    var failSaveForKey: KeychainService.Key?

    struct Boom: Error {}

    func save(_ value: String, for key: KeychainService.Key) async throws {
        if failOnSave || key == failSaveForKey { throw Boom() }
        stored[key] = value
        saved[key] = value
    }

    func retrieve(for key: KeychainService.Key) async throws -> String? {
        stored[key]
    }

    func delete(for key: KeychainService.Key) async throws {
        stored.removeValue(forKey: key)
    }
}

/// Records calls to the injected Notion provisioner so tests can assert whether
/// (and with what) provisioning ran during commit.
private actor ProvisionRecorder {
    struct Call { let apiKey: String; let databaseId: String }
    private(set) var calls: [Call] = []
    var result = NotionService.ProvisionResult(props: NotionService.PropertyNames(), warnings: [])

    func record(apiKey: String, databaseId: String) -> NotionService.ProvisionResult {
        calls.append(Call(apiKey: apiKey, databaseId: databaseId))
        return result
    }
}

@MainActor
final class OnboardingDraftTests: XCTestCase {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OnboardingDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    // MARK: Cancel / close

    /// Changing the provider (and other settings) in the draft and then never
    /// calling `apply()` — i.e. closing or canceling the wizard — must leave the
    /// persisted provider untouched. This is the exact TP-8 reproduction.
    func testDraftEditsDoNotTouchDefaultsWithoutApply() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pre-wizard state: ElevenLabs is the persisted provider.
        defaults.set(TranscriptionProviderKind.elevenLabs.rawValue, forKey: "transcription.provider")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        await draft.seed(defaults: defaults, credentials: credentials)

        // User switches to Parakeet and flips toggles in the draft…
        draft.transcriptionProvider = .parakeet
        draft.transcriptionEnabled = true
        draft.s3Enabled = true
        draft.notionEnabled = true

        // …but closes the wizard without applying. Nothing is persisted.
        XCTAssertEqual(defaults.string(forKey: "transcription.provider"),
                       TranscriptionProviderKind.elevenLabs.rawValue)
        XCTAssertFalse(defaults.bool(forKey: "transcription.enabled"))
        XCTAssertFalse(defaults.bool(forKey: "s3.enabled"))
        XCTAssertFalse(defaults.bool(forKey: "notion.enabled"))
        XCTAssertTrue(credentials.saved.isEmpty)
    }

    // MARK: Back navigation

    /// Navigating forward, changing a value, then going Back (represented here as
    /// re-editing the draft) still persists nothing until completion.
    func testBackNavigationDoesNotCommit() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("us-east-1", forKey: "s3.region")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        await draft.seed(defaults: defaults, credentials: credentials)

        // Forward: pick a region. Back: change mind. No apply in between.
        draft.s3Region = "eu-west-1"
        draft.s3Region = "us-west-2"

        XCTAssertEqual(defaults.string(forKey: "s3.region"), "us-east-1")
    }

    // MARK: Successful completion

    /// `apply()` commits every staged value: UserDefaults flags, folder bookmark,
    /// Notion property names, and Keychain credentials.
    func testApplyCommitsEntireDraft() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()

        draft.transcriptionProvider = .parakeetUnified
        draft.transcriptionEnabled = true
        draft.elevenLabsAPIKey = "el-key"
        draft.s3Enabled = true
        draft.s3Bucket = "my-bucket"
        draft.s3Region = "eu-west-1"
        draft.awsAccessKeyId = "AKIA"
        draft.awsSecretAccessKey = "secret"
        draft.openRouterEnabled = true
        draft.openRouterAPIKey = "or-key"
        draft.notionEnabled = true
        draft.notionNeedsProvisioning = true
        draft.notionDatabaseId = "db123"
        draft.notionAPIKey = "ntn_key"

        // Stage a real folder bookmark so persistFolderSelection runs.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        draft.localAudioEnabled = true
        draft.localAudioFolderPath = folder.path
        draft.localAudioBookmark = try XCTUnwrap(SecurityScopedBookmark.makeBookmarkData(for: folder))

        let provisioned = ProvisionRecorder()
        try await draft.apply(defaults: defaults, credentials: credentials,
                              provisionNotion: { await provisioned.record(apiKey: $0, databaseId: $1) })

        // Notion was provisioned exactly once with the staged key + database.
        let calls = await provisioned.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.apiKey, "ntn_key")
        XCTAssertEqual(calls.first?.databaseId, "db123")

        XCTAssertEqual(defaults.string(forKey: "transcription.provider"),
                       TranscriptionProviderKind.parakeetUnified.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "transcription.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "s3.enabled"))
        XCTAssertEqual(defaults.string(forKey: "s3.bucket"), "my-bucket")
        XCTAssertEqual(defaults.string(forKey: "s3.region"), "eu-west-1")
        XCTAssertTrue(defaults.bool(forKey: "openrouter.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "notion.enabled"))
        XCTAssertEqual(defaults.string(forKey: "notion.databaseId"), "db123")
        XCTAssertNotNil(defaults.data(forKey: "notion.propertyNames"))

        // Folder path + bookmark both committed.
        XCTAssertEqual(defaults.string(forKey: "localaudio.folderPath"), folder.path)
        XCTAssertNotNil(defaults.data(forKey: "localaudio.folderPath.bookmark"))
        XCTAssertTrue(defaults.bool(forKey: "localaudio.enabled"))

        // Credentials saved.
        XCTAssertEqual(credentials.saved[.elevenLabsAPIKey], "el-key")
        XCTAssertEqual(credentials.saved[.awsAccessKeyId], "AKIA")
        XCTAssertEqual(credentials.saved[.awsSecretAccessKey], "secret")
        XCTAssertEqual(credentials.saved[.openRouterAPIKey], "or-key")
        XCTAssertEqual(credentials.saved[.notionAPIKey], "ntn_key")
    }

    /// Empty credential fields are not written to the Keychain on commit.
    func testApplySkipsEmptyCredentials() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        draft.transcriptionProvider = .parakeet

        try await draft.apply(defaults: defaults, credentials: credentials)

        XCTAssertTrue(credentials.saved.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "transcription.provider"),
                       TranscriptionProviderKind.parakeet.rawValue)
    }

    // MARK: Failed commit

    /// If a credential save fails, `apply()` throws and no UserDefaults are
    /// written — the previous configuration is left fully intact, never partial.
    func testFailedCommitLeavesConfigurationUnchanged() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pre-wizard configuration.
        defaults.set(TranscriptionProviderKind.elevenLabs.rawValue, forKey: "transcription.provider")
        defaults.set(false, forKey: "transcription.enabled")
        defaults.set(false, forKey: "notion.enabled")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        credentials.failOnSave = true
        await draft.seed(defaults: defaults, credentials: credentials)

        // User makes changes that require a credential save.
        draft.transcriptionProvider = .parakeet
        draft.transcriptionEnabled = true
        draft.elevenLabsAPIKey = "el-key"
        draft.notionEnabled = true

        do {
            try await draft.apply(defaults: defaults, credentials: credentials)
            XCTFail("apply() should have thrown when the credential save failed")
        } catch {
            // Expected.
        }

        // Nothing was applied: persisted config matches the pre-wizard state.
        XCTAssertEqual(defaults.string(forKey: "transcription.provider"),
                       TranscriptionProviderKind.elevenLabs.rawValue)
        XCTAssertFalse(defaults.bool(forKey: "transcription.enabled"))
        XCTAssertFalse(defaults.bool(forKey: "notion.enabled"))
    }

    /// When a later credential save fails, credentials written earlier in the
    /// sequence are rolled back to their prior values (or removed if they were
    /// new), so the commit is all-or-nothing rather than leaving active keys changed.
    func testFailedCredentialCommitRollsBackEarlierSaves() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        // OpenRouter already had a key from a prior setup; ElevenLabs did not.
        credentials.stored[.openRouterAPIKey] = "old-or-key"
        // The Notion save (last in the sequence) fails after the others succeed.
        credentials.failSaveForKey = .notionAPIKey

        draft.elevenLabsAPIKey = "new-el-key"
        draft.openRouterAPIKey = "new-or-key"
        draft.notionAPIKey = "ntn_key"
        draft.transcriptionProvider = .parakeet

        do {
            try await draft.apply(defaults: defaults, credentials: credentials)
            XCTFail("apply() should have thrown when the Notion save failed")
        } catch {
            // Expected.
        }

        // Prior OpenRouter key restored; newly-added ElevenLabs key removed.
        XCTAssertEqual(credentials.stored[.openRouterAPIKey], "old-or-key")
        XCTAssertNil(credentials.stored[.elevenLabsAPIKey])
        // No UserDefaults written.
        XCTAssertNil(defaults.string(forKey: "transcription.provider"))
    }

    // MARK: Notion provisioning is deferred

    /// A seeded, already-provisioned Notion config that the user doesn't touch is
    /// NOT re-provisioned at commit — so finishing the wizard offline still works.
    func testUnchangedNotionIsNotReprovisionedOnCommit() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "notion.enabled")
        defaults.set("db123", forKey: "notion.databaseId")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        credentials.stored[.notionAPIKey] = "ntn_key"
        await draft.seed(defaults: defaults, credentials: credentials)
        XCTAssertTrue(draft.notionEnabled)
        XCTAssertFalse(draft.notionNeedsProvisioning)

        let provisioned = ProvisionRecorder()
        try await draft.apply(defaults: defaults, credentials: credentials,
                              provisionNotion: { await provisioned.record(apiKey: $0, databaseId: $1) })

        let calls = await provisioned.calls
        XCTAssertTrue(calls.isEmpty, "Untouched Notion config should not be re-provisioned")
        XCTAssertTrue(defaults.bool(forKey: "notion.enabled"))
    }

    /// If provisioning fails at commit, `apply()` throws and no settings are
    /// persisted — the mutating Notion call is the first thing tried, so a failure
    /// leaves the local configuration untouched.
    func testFailedNotionProvisioningLeavesConfigurationUnchanged() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "notion.enabled")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()

        draft.notionEnabled = true
        draft.notionNeedsProvisioning = true
        draft.notionAPIKey = "ntn_key"
        draft.notionDatabaseId = "db123"
        draft.transcriptionProvider = .parakeet

        struct ProvisionBoom: Error {}
        do {
            try await draft.apply(defaults: defaults, credentials: credentials,
                                  provisionNotion: { _, _ in throw ProvisionBoom() })
            XCTFail("apply() should have thrown when provisioning failed")
        } catch {
            // Expected.
        }

        XCTAssertFalse(defaults.bool(forKey: "notion.enabled"))
        XCTAssertNil(defaults.string(forKey: "transcription.provider"))
        XCTAssertTrue(credentials.saved.isEmpty, "No credentials should be saved when provisioning fails first")
    }

    // MARK: Seeding

    /// Seeding mirrors existing persisted configuration into the draft so an
    /// unchanged setting is re-applied identically (first-run and re-run parity).
    func testSeedLoadsExistingConfiguration() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(TranscriptionProviderKind.whisperKit.rawValue, forKey: "transcription.provider")
        defaults.set(true, forKey: "transcription.enabled")
        defaults.set("large-v3", forKey: "whisperkit.model")
        defaults.set(true, forKey: "s3.enabled")
        defaults.set("existing-bucket", forKey: "s3.bucket")
        defaults.set("TP-7 Transcripts", forKey: "applenotes.folder")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        credentials.stored[.elevenLabsAPIKey] = "seeded-key"

        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertEqual(draft.transcriptionProvider, .whisperKit)
        XCTAssertTrue(draft.transcriptionEnabled)
        XCTAssertEqual(draft.whisperKitModel, "large-v3")
        XCTAssertTrue(draft.s3Enabled)
        XCTAssertEqual(draft.s3Bucket, "existing-bucket")
        XCTAssertEqual(draft.elevenLabsAPIKey, "seeded-key")
        XCTAssertFalse(draft.isSeeding)
    }

    // MARK: Seed-time configuration snapshot (TP-16)

    /// `seed()` must record which optional integrations were already fully
    /// configured, independent of the enabled flags it also loads — this is
    /// what lets a re-run distinguish "kept existing" from "configured now".
    /// An integration counts as configured-at-seed only when both its enabled
    /// flag AND its credential/data are present; a stray enabled flag with no
    /// credential (e.g. a prior failed setup) must not count as configured.
    func testSeedRecordsWhichIntegrationsWereAlreadyConfigured() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "s3.enabled")
        defaults.set("existing-bucket", forKey: "s3.bucket")
        defaults.set(true, forKey: "openrouter.enabled")
        defaults.set(true, forKey: "applenotes.enabled")
        defaults.set(true, forKey: "notion.enabled")
        defaults.set("db123", forKey: "notion.databaseId")
        defaults.set("/tmp/audio", forKey: "localaudio.folderPath")
        defaults.set(true, forKey: "localaudio.enabled")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        credentials.stored[.awsAccessKeyId] = "AKIA"
        credentials.stored[.awsSecretAccessKey] = "secret"
        credentials.stored[.openRouterAPIKey] = "or-key"
        credentials.stored[.notionAPIKey] = "ntn_key"

        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertTrue(draft.s3WasConfiguredAtSeed)
        XCTAssertTrue(draft.openRouterWasConfiguredAtSeed)
        XCTAssertTrue(draft.appleNotesWasConfiguredAtSeed)
        XCTAssertTrue(draft.notionWasConfiguredAtSeed)
        XCTAssertTrue(draft.localAudioWasConfiguredAtSeed)
        // Never configured.
        XCTAssertFalse(draft.markdownWasConfiguredAtSeed)
    }

    /// An enabled flag alone (no credential) must not count as "already
    /// configured" — this is the exact TP-16 reproduction for Notion, whose
    /// enabled flag can be true while it lacks a usable API key.
    func testEnabledFlagWithoutCredentialIsNotConfiguredAtSeed() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "notion.enabled")
        defaults.set("db123", forKey: "notion.databaseId")
        defaults.set(true, forKey: "openrouter.enabled")

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        // No stored API keys for either integration.

        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertFalse(draft.notionWasConfiguredAtSeed)
        XCTAssertFalse(draft.openRouterWasConfiguredAtSeed)
    }

    /// `s3.enabled` alone (no bucket or keychain credentials) must not count
    /// as "already configured" — `SyncService` won't actually stand up an S3
    /// client without a bucket and both keys, so treating the bare flag as
    /// configured would seed `.keptExisting`, hide the Skip path, skip the
    /// local-audio fallback, and re-apply a non-functional `s3.enabled = true`.
    func testS3EnabledFlagWithoutCredentialsIsNotConfiguredAtSeed() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "s3.enabled")
        // No bucket, no keychain credentials.

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertFalse(draft.s3WasConfiguredAtSeed)
    }

    /// `notion.enabled` with a key but no database ID (e.g. the Settings
    /// toggle was flipped before Save & Connect, or the DB field was cleared)
    /// must not count as "already configured" — the runtime Notion delivery
    /// path requires a non-empty database ID before it can create pages, so
    /// treating the bare flag+key as configured would seed `.keptExisting`,
    /// hide the skip path, and let `apply()` re-commit an unusable
    /// `notion.enabled = true` with no database to write to.
    func testNotionEnabledWithoutDatabaseIdIsNotConfiguredAtSeed() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "notion.enabled")
        // No database ID persisted.

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        credentials.stored[.notionAPIKey] = "ntn_key"

        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertFalse(draft.notionWasConfiguredAtSeed)
    }

    /// A fresh install with nothing persisted must report every optional
    /// integration as not-configured-at-seed, so a first-run skip resolves to
    /// `.skipped` rather than being mistaken for kept existing configuration.
    func testFreshInstallHasNoIntegrationsConfiguredAtSeed() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let draft = OnboardingDraft()
        let credentials = MockCredentialStore()
        await draft.seed(defaults: defaults, credentials: credentials)

        XCTAssertFalse(draft.s3WasConfiguredAtSeed)
        XCTAssertFalse(draft.openRouterWasConfiguredAtSeed)
        XCTAssertFalse(draft.appleNotesWasConfiguredAtSeed)
        XCTAssertFalse(draft.notionWasConfiguredAtSeed)
        XCTAssertFalse(draft.localAudioWasConfiguredAtSeed)
        XCTAssertFalse(draft.markdownWasConfiguredAtSeed)
    }
}
