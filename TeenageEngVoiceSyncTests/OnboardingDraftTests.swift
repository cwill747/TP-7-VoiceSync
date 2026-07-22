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
    var stored: [KeychainService.Key: String] = [:]
    private(set) var saved: [KeychainService.Key: String] = [:]
    var failOnSave = false

    struct Boom: Error {}

    func save(_ value: String, for key: KeychainService.Key) async throws {
        if failOnSave { throw Boom() }
        saved[key] = value
    }

    func retrieve(for key: KeychainService.Key) async throws -> String? {
        stored[key]
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
        draft.notionDatabaseId = "db123"
        draft.notionAPIKey = "ntn_key"
        draft.notionProps = NotionService.PropertyNames()

        // Stage a real folder bookmark so persistFolderSelection runs.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        draft.localAudioEnabled = true
        draft.localAudioFolderPath = folder.path
        draft.localAudioBookmark = try XCTUnwrap(SecurityScopedBookmark.makeBookmarkData(for: folder))

        try await draft.apply(defaults: defaults, credentials: credentials)

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
}
