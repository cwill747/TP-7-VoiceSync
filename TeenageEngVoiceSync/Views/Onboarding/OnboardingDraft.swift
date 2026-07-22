//
//  OnboardingDraft.swift
//  TeenageEngVoiceSync
//
//  Wizard-owned draft configuration. Step views edit this in-memory draft
//  instead of writing straight to @AppStorage / Keychain / bookmarks, so a
//  canceled or closed wizard leaves persisted settings untouched. The complete
//  draft is committed atomically by `apply()` when the user presses
//  "Start Using TP-7 VoiceSync".
//

import Foundation

/// Persistence surface the draft commits to. Abstracted so tests can inject a
/// store that fails on demand (the "failed final commit" acceptance case).
protocol OnboardingCredentialStore {
    func save(_ value: String, for key: KeychainService.Key) async throws
    func retrieve(for key: KeychainService.Key) async throws -> String?
    func delete(for key: KeychainService.Key) async throws
}

extension KeychainService: OnboardingCredentialStore {}

/// Provisions a Notion database at commit time. Abstracted so tests can commit a
/// draft with Notion enabled without making a live API call.
typealias NotionProvisioner = @Sendable (_ apiKey: String, _ databaseId: String) async throws -> NotionService.ProvisionResult

@Observable
@MainActor
final class OnboardingDraft {
    // MARK: Transcription
    var transcriptionProvider: TranscriptionProviderKind = .elevenLabs
    var transcriptionEnabled = false
    var whisperKitModel = "base"
    var backupAfterTranscription = true
    var elevenLabsAPIKey = ""

    // MARK: S3 storage
    var s3Enabled = false
    var s3Provider: S3Provider = .aws
    var s3Bucket = ""
    var s3Region = "us-east-1"
    var s3Prefix = "recordings/"
    var awsAccessKeyId = ""
    var awsSecretAccessKey = ""

    // MARK: Local audio folder (S3 fallback)
    var localAudioEnabled = false
    var localAudioFolderPath = ""
    var localAudioBookmark: Data?

    // MARK: OpenRouter
    var openRouterEnabled = false
    var openRouterAPIKey = ""

    // MARK: Apple Notes
    var appleNotesEnabled = false
    var appleNotesFolder = "TP-7 Transcripts"

    // MARK: Local markdown folder (Apple Notes fallback)
    var markdownEnabled = false
    var markdownFolderPath = ""
    var markdownBookmark: Data?

    // MARK: Notion
    var notionEnabled = false
    var notionDatabaseId = ""
    var notionAPIKey = ""
    /// True when the Notion connection was (re)validated in this wizard session,
    /// so `apply()` should provision the database (adding any missing columns) at
    /// commit. Stays false for a seeded, already-provisioned config so completing
    /// the wizard offline doesn't force a redundant — and failable — round trip.
    var notionNeedsProvisioning = false

    /// True while `seed()` is loading current values; step views disable secret
    /// fields until it clears so an early keystroke isn't overwritten.
    var isSeeding = true

    // MARK: - Seed-time configuration snapshot
    //
    // Whether each optional/fallback integration was already fully configured
    // when the wizard opened. Captured once, right after `seed()` loads
    // persisted state, so step views can distinguish "already configured —
    // kept" from "configured now" and render (and record) the user's actual
    // decision instead of just inheriting the persisted enabled flag.
    var s3WasConfiguredAtSeed = false
    var openRouterWasConfiguredAtSeed = false
    var appleNotesWasConfiguredAtSeed = false
    var notionWasConfiguredAtSeed = false
    var localAudioWasConfiguredAtSeed = false
    var markdownWasConfiguredAtSeed = false

    // MARK: - Wizard-session test state
    //
    // Deliberately stored on the draft rather than as view `@State`: step
    // views are recreated (and their `@State` reset) every time
    // `OnboardingView` switches `currentStep`, so a per-view flag would
    // silently forget a failed test after Back/Forward navigation and let a
    // kept-existing decision be waved back to enabled without a fresh
    // successful test. The draft instance persists for the whole wizard run.
    var s3TestFailed = false
    var openRouterTestFailed = false
    var appleNotesTestFailed = false
    var notionTestFailed = false
    /// True once OpenRouter has been freshly verified in this session (as
    /// opposed to merely kept from a seeded config). Keeps the fresh "Enable"
    /// toggle visible after the user switches it off, without reintroducing
    /// the separate existing-configuration toggle for a pre-existing key.
    var openRouterVerifiedThisSession = false

    // MARK: - Seeding

    /// Populate the draft from currently persisted settings so the wizard shows
    /// existing configuration and re-applies anything the user leaves untouched.
    func seed(defaults: UserDefaults = .standard,
              credentials: OnboardingCredentialStore = KeychainService.shared) async {
        isSeeding = true

        transcriptionProvider = TranscriptionProviderKind(rawValue: defaults.string(forKey: "transcription.provider") ?? "") ?? .elevenLabs
        transcriptionEnabled = defaults.bool(forKey: "transcription.enabled")
        whisperKitModel = defaults.string(forKey: "whisperkit.model") ?? "base"
        backupAfterTranscription = defaults.object(forKey: "s3.backupAfterTranscription") as? Bool ?? true

        s3Enabled = defaults.bool(forKey: "s3.enabled")
        s3Provider = S3Provider(rawValue: defaults.string(forKey: "s3.provider") ?? "") ?? .aws
        s3Bucket = defaults.string(forKey: "s3.bucket") ?? ""
        s3Region = defaults.string(forKey: "s3.region") ?? "us-east-1"
        s3Prefix = defaults.string(forKey: "s3.prefix") ?? "recordings/"

        localAudioEnabled = defaults.bool(forKey: "localaudio.enabled")
        localAudioFolderPath = defaults.string(forKey: "localaudio.folderPath") ?? ""

        openRouterEnabled = defaults.bool(forKey: "openrouter.enabled")

        appleNotesEnabled = defaults.bool(forKey: "applenotes.enabled")
        appleNotesFolder = defaults.string(forKey: "applenotes.folder") ?? "TP-7 Transcripts"

        markdownEnabled = defaults.bool(forKey: "markdown.enabled")
        markdownFolderPath = defaults.string(forKey: "markdown.folderPath") ?? ""

        notionEnabled = defaults.bool(forKey: "notion.enabled")
        notionDatabaseId = defaults.string(forKey: "notion.databaseId") ?? ""

        elevenLabsAPIKey = (try? await credentials.retrieve(for: .elevenLabsAPIKey)) ?? ""
        awsAccessKeyId = (try? await credentials.retrieve(for: .awsAccessKeyId)) ?? ""
        awsSecretAccessKey = (try? await credentials.retrieve(for: .awsSecretAccessKey)) ?? ""
        openRouterAPIKey = (try? await credentials.retrieve(for: OpenRouterService.activeKeychainKey(defaults: defaults))) ?? ""
        notionAPIKey = (try? await credentials.retrieve(for: .notionAPIKey)) ?? ""

        s3WasConfiguredAtSeed = s3Enabled && !s3Bucket.isEmpty && !awsAccessKeyId.isEmpty && !awsSecretAccessKey.isEmpty
        // A local/custom OpenAI-compatible endpoint (llama-server, LM Studio,
        // Ollama, etc.) runs without an API key — see OpenRouterService's
        // guards and EnhancementSettingsView.canUseAI — so it counts as
        // configured even with no stored key.
        openRouterWasConfiguredAtSeed = openRouterEnabled
            && (!openRouterAPIKey.isEmpty || OpenRouterService.isLocalEndpoint(defaults: defaults))
        appleNotesWasConfiguredAtSeed = appleNotesEnabled
        notionWasConfiguredAtSeed = notionEnabled && !notionAPIKey.isEmpty && !notionDatabaseId.isEmpty
        localAudioWasConfiguredAtSeed = localAudioEnabled && !localAudioFolderPath.isEmpty
        markdownWasConfiguredAtSeed = markdownEnabled && !markdownFolderPath.isEmpty

        isSeeding = false
    }

    // MARK: - Commit

    /// Commit the complete draft. Credential saves (the only fallible step) run
    /// first: if any throws, no UserDefaults are written, so the persisted
    /// configuration is left exactly as it was — never partially applied.
    func apply(defaults: UserDefaults = .standard,
               credentials: OnboardingCredentialStore = KeychainService.shared,
               provisionNotion: NotionProvisioner = { try await NotionService.provisionDatabase(apiKey: $0, databaseId: $1) }) async throws {
        // 1) Fallible work. Provision Notion first (it mutates a remote database,
        //    so it must run before anything local is written and only when the
        //    user actually (re)connected Notion in this session). Its result is
        //    committed in phase 2 with everything else.
        var provisionedNotionProps: NotionService.PropertyNames?
        if notionEnabled, notionNeedsProvisioning, !notionAPIKey.isEmpty, !notionDatabaseId.isEmpty {
            provisionedNotionProps = try await provisionNotion(notionAPIKey, notionDatabaseId).props
        }

        // Persist non-empty credentials. Keychain has no transaction, so snapshot
        // each key's prior value and roll the whole set back if a later save fails —
        // otherwise a mid-sequence failure would leave some credentials changed
        // while we report the commit failed and skip the UserDefaults writes.
        let pending: [(KeychainService.Key, String)] = [
            (.elevenLabsAPIKey, elevenLabsAPIKey),
            (.awsAccessKeyId, awsAccessKeyId),
            (.awsSecretAccessKey, awsSecretAccessKey),
            (OpenRouterService.activeKeychainKey(defaults: defaults), openRouterAPIKey),
            (.notionAPIKey, notionAPIKey)
        ].filter { !$0.1.isEmpty }

        var rollback: [(KeychainService.Key, String?)] = []
        do {
            for (key, value) in pending {
                let prior = try? await credentials.retrieve(for: key)
                try await credentials.save(value, for: key)
                rollback.append((key, prior))
            }
        } catch {
            // Restore each key we already overwrote to its prior value (or remove
            // it if it didn't exist before), then surface the original failure.
            for (key, prior) in rollback.reversed() {
                if let prior {
                    try? await credentials.save(prior, for: key)
                } else {
                    try? await credentials.delete(for: key)
                }
            }
            throw error
        }

        // 2) Non-fallible work: write every setting in one burst so the
        //    user-visible configuration flips over together.
        defaults.set(transcriptionProvider.rawValue, forKey: "transcription.provider")
        defaults.set(transcriptionEnabled, forKey: "transcription.enabled")
        defaults.set(whisperKitModel, forKey: "whisperkit.model")
        defaults.set(backupAfterTranscription, forKey: "s3.backupAfterTranscription")

        defaults.set(s3Enabled, forKey: "s3.enabled")
        defaults.set(s3Provider.rawValue, forKey: "s3.provider")
        defaults.set(s3Bucket, forKey: "s3.bucket")
        defaults.set(s3Region, forKey: "s3.region")
        defaults.set(s3Prefix, forKey: "s3.prefix")

        defaults.set(localAudioEnabled, forKey: "localaudio.enabled")
        if let localAudioBookmark, !localAudioFolderPath.isEmpty {
            SecurityScopedBookmark.persistFolderSelection(
                path: localAudioFolderPath, bookmarkData: localAudioBookmark,
                key: "localaudio.folderPath", defaults: defaults
            )
        }

        defaults.set(openRouterEnabled, forKey: "openrouter.enabled")

        defaults.set(appleNotesEnabled, forKey: "applenotes.enabled")
        defaults.set(appleNotesFolder, forKey: "applenotes.folder")

        defaults.set(markdownEnabled, forKey: "markdown.enabled")
        if let markdownBookmark, !markdownFolderPath.isEmpty {
            SecurityScopedBookmark.persistFolderSelection(
                path: markdownFolderPath, bookmarkData: markdownBookmark,
                key: "markdown.folderPath", defaults: defaults
            )
        }

        defaults.set(notionEnabled, forKey: "notion.enabled")
        defaults.set(notionDatabaseId, forKey: "notion.databaseId")
        provisionedNotionProps?.store(in: defaults)
    }
}
