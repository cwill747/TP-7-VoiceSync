# TP-7 VoiceSync → Parakeet + Notion — remaining tasks

This fork of [armynante/TP-7-VoiceSync](https://github.com/armynante/TP-7-VoiceSync) swaps
transcription to **Parakeet** (via [FluidAudio](https://github.com/FluidInference/FluidAudio),
on the Apple Neural Engine) and adds a **Notion** output. All code wiring is committed.
The items below are what you still need to do — most can only happen inside Xcode / your accounts.

## Required to build & run

- [ ] **Add the FluidAudio Swift package** (can't be scripted — do it in Xcode):
      File → Add Package Dependencies → `https://github.com/FluidInference/FluidAudio.git`,
      "Up to Next Major" from `0.12.4`. Add the **FluidAudio** library product to the
      `TeenageEngVoiceSync` target. `ParakeetService.swift` won't compile until this is done.
- [ ] **Set your signing team** in the target's Signing & Capabilities (use a local bundle ID).
- [ ] **Build.** The project uses file-system-synchronized groups, so the new files
      (`ParakeetService.swift`, `NotionService.swift`, `NotionSettingsView.swift`) are already
      in the target. Expect at most a small compile nit — see "Unverified" below.

## Configure at runtime

- [ ] **Grant your Notion integration access to the database.** The DB "TP-7 Recordings"
      already exists (see below), but it was created through a different connection. Open it,
      ••• → Connections → add the integration whose secret you paste into the app.
      - Database ID: `87e40ed22d10487ea6fee679784b7a3f`
      - URL: https://app.notion.com/p/87e40ed22d10487ea6fee679784b7a3f
      - Properties: Name (title), Date, Filename, Duration, Language, Audio (url), Summary
- [ ] Create an integration at https://www.notion.so/my-integrations, copy its secret.
- [ ] In the app: **Settings → Notion**, toggle on, paste secret + the database ID above,
      click Save & Validate (should say "Connected").
- [ ] In the app: **Settings → Transcription**, choose **Parakeet**. First run downloads the
      CoreML model (~once), then transcription runs locally on the ANE.
- [ ] Add a sorted view in Notion: open the DB → new view → Sort → **Date**, descending.

## Baseline (do first, before trusting the above)

- [ ] Install **FieldKit** from the Mac App Store; plug in the TP-7; MTP mode = shift+com → T4;
      toggle "connect" in FieldKit. Confirm the app detects the device.
- [ ] Sync one recording end-to-end and confirm a Notion page appears with the Date set.

## Optional / nice-to-have

- [ ] **Parakeet model picker.** Defaults to v3 (multilingual). To expose v2 (English, higher
      recall), add a Picker bound to UserDefaults key `parakeet.model` over
      `ParakeetModelVariant.allCases` in `TranscriptionSettingsView.swift`.
- [ ] **Language code.** Parakeet doesn't surface a per-clip language; v3 reports "auto",
      v2 reports "en". Cosmetic. Wire real detection if FluidAudio exposes it later.
- [ ] Remove Apple Notes / S3 paths entirely if you only want Parakeet → Notion (they're
      independent and off by default, so this is only cleanup).

## Unverified (I couldn't compile here)

- FluidAudio API is matched to its official `Documentation/ASR/GettingStarted.md`:
  `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager()`, `loadModels(_:)`,
  `transcribe(_ url:source:)` with `source: .system`. If a newer release renames
  `AsrModelVersion`, adjust `ParakeetModelVariant.asrVersion` in `ParakeetService.swift`.
- Notion payloads use API version `2022-06-28`. Local `file://` audio links are intentionally
  omitted from the Notion URL property/bookmark (Notion rejects non-http URLs) and surfaced as
  body text instead — only relevant when S3 backup is off.

## What changed in this fork (for the commit / PR description)

- `Services/ParakeetService.swift` (new) — `TranscriptionProvider` backed by FluidAudio.
- `Services/NotionService.swift` (new) — creates a Notion DB page per transcription.
- `Views/Settings/NotionSettingsView.swift` (new) — Notion settings tab.
- `Services/TranscriptionProvider.swift` — added `.parakeet` provider kind.
- `Services/KeychainService.swift` — added `notionAPIKey` key.
- `Models/Recording.swift` — added `notionPageCreatedAt` (SwiftData light migration).
- `Services/SyncService.swift` — construct Parakeet; local-first flags; `createNotionPage`
  delivery after each note; defaults; retranscribe resets Notion dedupe.
- `Views/Settings/SettingsView.swift` — added Notion tab.
