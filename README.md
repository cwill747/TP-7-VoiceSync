> ## Fork: Parakeet + Notion
>
> This is a fork of [armynante/TP-7-VoiceSync](https://github.com/armynante/TP-7-VoiceSync).
> It swaps transcription to **Parakeet** via [FluidAudio](https://github.com/FluidInference/FluidAudio)
> (Apple Neural Engine), adds a **Notion** output (a database page per recording, sorted by date),
> and talks to the TP-7 directly over MTP — no FieldKit required. Original README below.

# TP-7 VoiceSync

A macOS menu bar app that automatically syncs, transcribes, and organizes your Teenage Engineering TP-7 voice recordings. Defaults to **fully local transcription** via **Parakeet** ([FluidAudio](https://github.com/FluidInference/FluidAudio), Apple Neural Engine), with optional on-device **speaker diarization** and a **People** manager that learns who's who. Outputs to **Notion**, Apple Notes, or local Markdown, and talks to the TP-7 directly over MTP.

## Features

- **Automatic Device Detection** — Detects when your TP-7 connects over MTP (no FieldKit required)
- **Local Transcription via Parakeet** — On-device Parakeet TDT via FluidAudio, running on the Apple Neural Engine, with no API key or internet required (after the model auto-downloads)
- **Also Supports WhisperKit & ElevenLabs** — WhisperKit as an alternative local engine, or ElevenLabs for cloud transcription
- **Speaker Diarization** — Optionally split transcripts into per-speaker turns entirely on-device (Parakeet only)
- **People Manager** — Enroll voices, reassign speaker turns to named people, and let the app auto-label known speakers in future recordings
- **Notion Output** — One database page per recording, sorted by date; the app provisions any missing properties for you
- **Cloud Backup to S3 (Optional)** — Upload recordings to AWS S3 with SHA256 deduplication
- **Local Storage (Optional)** — Copy recordings to a folder on your Mac when skipping S3
- **Smart Titles & Summaries** — Generates meaningful titles using an LLM via OpenRouter (optional)
- **Apple Notes / Markdown Output** — Creates notes with transcriptions, metadata, and playable audio links, or writes local Markdown files
- **Menu Bar Interface** — Quick access to recent recordings and sync status
- **Soft Delete** — Prevents re-syncing of recordings you've deleted
- **Startup Recovery** — Rebuilds the local library from S3, your local audio folder, and Notion if local state is lost (reinstall, container reset)

> [!CAUTION]
> This app is 1000% vibe-coded using Claude Code while I was waiting for builds to pass on another project. It is definitely not reviewed seriously for security concerns or major bugs that could crash your computer. Install with caution.

## Local Transcription

Both local engines transcribe **without sending audio to any cloud service** and **without an API key**. Models auto-download from Hugging Face on first use and are cached locally, so no network is required afterward.

### Parakeet (default, Apple Neural Engine)

Parakeet is the recommended engine. It runs [Parakeet TDT](https://huggingface.co/FluidInference) on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio), so it's fast and battery-friendly.

- **Choose Parakeet (Local, ANE)** in the Setup Wizard or **Settings > Transcription**
- **Pick a model variant:**
  - **v2** — English-only, highest recall (default)
  - **v3** — multilingual (25 European languages plus Japanese and Chinese)
- **Download the model** — click "Download Model" and it fetches automatically, caching under `~/.cache/fluidaudio`
- **Speaker diarization (optional)** — enable it to split transcripts into per-speaker turns entirely on-device. This downloads a separate, small diarization model. See [Speakers & People](#speakers--people).

### Parakeet Unified (native punctuation, English)

Parakeet Unified is a separate FluidAudio model that adds **punctuation and capitalization natively**, so transcripts come out already formatted and you can turn off the AI cleanup pass. It also runs on the Apple Neural Engine.

- **Choose Parakeet Unified (Local, English)** in the Setup Wizard or **Settings > Transcription**, then click "Download Model"
- **English only** — for other languages, use Parakeet TDT v3
- **Trade-offs:** no speaker diarization, no per-speaker splitting of multi-track TP-7 `/recordings`, no overdub notes for multi-track `/memo` files, and no vocabulary boosting (dictionary trigger→replacement still applies). Single-track memos — the common TP-7 case — are unaffected.
- **AI cleanup becomes optional** — since punctuation is native, you can disable transcript cleanup under **Settings > Transcription**. The LLM is still useful for false-start removal, paragraphing, bullet points, and titles/summaries.

### WhisperKit (alternative local engine)

[WhisperKit](https://github.com/argmaxinc/WhisperKit) by [Argmax](https://www.argmaxinc.com/) is also supported if you prefer Whisper models.

1. **Choose WhisperKit (Local)** in the Setup Wizard or **Settings > Transcription**
2. **Select a model** (Base or Distil Large v3 recommended)
3. **Download the model** — it fetches from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) and runs on-device via CoreML

Each model is cached independently, so you can switch models and download the new one the same way.

## Speakers & People

When speaker diarization is enabled (Parakeet only), each transcript is broken into "Speaker N" turns. The **People** manager lets you turn those anonymous labels into named people — and teaches the app to recognize them automatically next time.

- **Add people** in the People screen. Mark yourself with "This is me" if you like.
- **Reassign a turn** in a recording's detail view: tap a speaker label and pick a person (or create one on the spot). The audio for that turn is enrolled as a voice sample and folded into that person's voice embedding.
- **Auto-labeling** — as you correct turns, the roster of known voices grows. Future recordings match segments against enrolled people and label them automatically, so the corrections you make compound over time.

All voice embeddings and samples live locally in the app's database; nothing is uploaded.

### Future: Local LLM for Titles & Summaries

AI-generated titles and summaries currently require OpenRouter (a cloud LLM API). Local LLM inference — so titles and summaries can also run fully offline on Apple Silicon — is a possible future addition. Suggestions and contributions are welcome via an issue.

## About the TP-7

### The TP-7 Field Recorder

The [Teenage Engineering TP-7](https://teenage.engineering/products/tp-7) is a premium portable audio recorder designed to capture sound, music, interviews, and ideas with zero friction. Key features include:

- **128GB internal storage** — enough to record 5 minutes a day for 20 years
- **24-bit/96kHz audio quality** — professional-grade recording
- **Motorized tape reel** — a beautiful, functional interface element for scrubbing and navigation
- **Built-in microphone and speaker** — record and playback anywhere
- **7-hour battery life** — all-day recording capability
- **Instant memo mode** — press the memo button when the device is off to start recording immediately

- [Teenage Engineering](https://teenage.engineering) — Official website
- [TP-7 Product Page](https://teenage.engineering/products/tp-7) — Full specs and details
- [TP-7 Guide](https://teenage.engineering/guides/tp-7) — Official user guide

## Requirements

- **macOS 14.0 (Sonoma)** or later (Apple Silicon recommended for Parakeet)
- **Transcription** (pick one):
  - **Parakeet** (local, free, ANE) — download a model once, then transcribe offline (recommended)
  - **WhisperKit** (local, free) — download a model once, then transcribe offline
  - **ElevenLabs API key** (cloud) — pay-per-use cloud transcription
- **Storage** (pick one):
  - **AWS S3 bucket** with access credentials (optional, enables playback links in notes)
  - **Local folder** on your Mac (required if you skip S3)
- **Output** (optional, any combination): **Notion**, **Apple Notes**, or **local Markdown files**
- **OpenRouter API key** (optional) for AI-generated titles and summaries

## Installation

1. Download the latest release from [GitHub Releases](../../releases)
2. Open the DMG file
3. Drag the app to your Applications folder
4. Launch TP-7 VoiceSync from Applications

## Setup Guide

### Setup Wizard (runs on first launch)

On first launch, TP-7 VoiceSync opens a Setup Wizard to walk you through configuration. You can also re-run it anytime via **Settings > General > Run Setup Wizard Again**.

The wizard guides you through:

- **Transcription (required)**: Parakeet (local, ANE) — or WhisperKit (local) or ElevenLabs (cloud)
- **Storage (choose one)**: S3 (optional) or a local folder on your Mac
- **AI Titles (optional)**: OpenRouter
- **Notes (optional)**: Apple Notes, or local Markdown files if you skip Notes
- **Notion (optional)**: point it at a database and it provisions any missing properties for you

After setup, **watching/syncing TP-7 recordings is enabled by default** (you can toggle it in **Settings > General**). If you run into weird syncing behavior right after initial setup or a permissions prompt, try **quitting the app and launching it again**.

### Step 1: Connect Your TP-7

1. Connect your TP-7 via USB
2. On the TP-7, enter MTP mode (hold STOP while turning the device on)
3. The app detects the device automatically over MTP

### Step 2: Configure Transcription

**Option A: Parakeet (Local, ANE — Recommended)**

1. In the Setup Wizard or **Settings > Transcription**, select "Parakeet (Local, ANE)"
2. Choose a model variant (v2 for English, v3 for multilingual)
3. Click "Download Model" and wait for the download to complete
4. (Optional) Enable **Speaker diarization** to split transcripts by speaker — see [Speakers & People](#speakers--people)
5. Enable "Enable automatic transcription"

**Option B: WhisperKit (Local)**

1. In the Setup Wizard or **Settings > Transcription**, select "WhisperKit (Local)"
2. Choose a model (Base or Distil Large v3 recommended)
3. Click "Download Model" and wait for the download to complete
4. Enable "Enable automatic transcription"

**Option C: ElevenLabs (Cloud)**

1. Sign up at [elevenlabs.io](https://elevenlabs.io)
2. Go to your profile and copy your API key
3. In TP-7 VoiceSync, go to **Settings > API Keys**
4. Enter your ElevenLabs API key and click "Validate"

### Step 3: Configure Storage (Optional)

You can skip this step — recordings will be stored in a local folder. If you want cloud backup with playback links in notes:

1. Create an S3 bucket in the [AWS Console](https://console.aws.amazon.com/s3)
2. Create an IAM user with S3 access (recommended policy: `AmazonS3FullAccess` or a custom policy for your bucket)
3. Generate an Access Key ID and Secret Access Key for the IAM user
4. In TP-7 VoiceSync, go to **Settings > Storage** and enter your bucket name, region, and prefix
5. Go to **Settings > API Keys** and enter your AWS Access Key ID and Secret Access Key
6. Back in **Settings > Storage**, click "Test Connection" to verify

### Step 4: Set Up OpenRouter (Optional)

OpenRouter provides LLM access for generating intelligent titles and summaries.

1. Sign up at [openrouter.ai](https://openrouter.ai)
2. Get your API key from the dashboard
3. In TP-7 VoiceSync, go to **Settings > API Keys**
4. Enter your OpenRouter API key
5. Go to **Settings > Transcription** and select your preferred model

### Step 5: Configure Apple Notes (Optional)

1. In TP-7 VoiceSync, go to **Settings > Transcription**
2. Enable "Send to Apple Notes"
3. Set your preferred folder name (default: "TP-7 Transcripts")
4. Choose the link expiry duration for audio playback links

### Step 6: Configure Notion (Optional)

The app provisions the database for you — point it at any database (even a blank one) and it adds whatever properties are missing.

1. Create an internal integration at [notion.so/my-integrations](https://www.notion.so/my-integrations) and copy its "Internal Integration Secret" (starts with `ntn_` or `secret_`)
2. Share your target database with that integration: open the database, click **••• > Connections**, and add the integration
3. Copy the database ID from its URL — the 32-character hex string right before `?v=`
4. In the Setup Wizard (or **Settings > Transcription**), enter the Integration Secret and Database ID, then click "Provision & Connect"

The app adds any of these properties that don't already exist — it never modifies or deletes existing columns or data:

| Property   | Type      | Used for                                                   |
| ---------- | --------- | ----------------------------------------------------------- |
| *(title)*  | Title     | Page title — reuses whatever your title column is called   |
| `Date`     | Date      | Recording date, so views can sort by date                  |
| `Filename` | Rich text | TP-7 device filename                                        |
| `Duration` | Rich text | Recording length (mm:ss)                                    |
| `Language` | Rich text | Detected language                                            |
| `Size`     | Rich text | Audio file size                                              |
| `Audio`    | URL       | Playback/download link (only set if S3 is enabled)          |
| `File`     | Rich text | Download URL or local file path                              |
| `Summary`  | Rich text | LLM-generated summary (only set if OpenRouter is enabled)   |

Only the transcript and overdubbed notes are written into the page body. Summary and recording details are stored in properties. If a property name already exists with an incompatible type (e.g. you already have a `Duration` number column), the app creates an alternate `TP7 Duration` column instead and shows a warning.

## Startup Recovery

The local recording database lives in a SwiftData store on your Mac. If that store is lost — you reinstall the app, reset the container, or move to a new machine — the app rebuilds it on launch by scanning whatever sources you have configured, in this order:

1. **S3** — lists every `.wav` under your configured bucket/prefix and re-creates any recording that isn't already tracked (restoring size, S3 key, and recorded date).
2. **Local audio folder** — scans for `.wav`/`.mp3`/`.m4a` files not already tracked and re-parses WAV metadata (duration, sample rate).
3. **Notion** — reads back every page in your database, restores recordings that only exist there (title, summary, language, and the transcript from the page body), and enriches recordings recovered from S3/local that are still missing a transcription.

Recovery is idempotent — recordings are matched by filename, so re-running it never creates duplicates. It runs automatically at startup before device watching begins; no action is required. Sources you haven't configured are skipped.

## Permissions & Privacy

TP-7 VoiceSync runs locally by default, and only uses network services if you enable them (S3, ElevenLabs, OpenRouter). Credentials are stored in your Mac's Keychain.

When you first use the app, you may see the following permission prompts:

### USB Device Access

To watch for new recordings, the app talks to the TP-7 directly over MTP via USB. macOS may prompt you to allow access to the device.

### Keychain Storage

API keys and cloud credentials are stored securely in the macOS Keychain (not in plaintext files).

### Local vs Cloud Processing

- **Parakeet / WhisperKit (Local)**: transcription, and speaker diarization/voice enrollment, run on-device after you download a model. No audio is sent anywhere.
- **ElevenLabs / OpenRouter / S3 / Notion**: audio and/or text is sent to those services when enabled.

### Apple Notes Automation

The app uses AppleScript to create notes in Apple Notes. macOS will ask for permission to allow the app to control Notes. Click "OK" to grant this permission.

### Notifications

The app can notify you when your TP-7 connects and when recordings are synced. You can enable or disable these in **Settings > General**.

### Network Access

The app needs network access to upload to S3, sync to Notion, and communicate with the ElevenLabs and OpenRouter APIs. This is handled automatically by macOS. If you use Parakeet (or WhisperKit) with local storage and local Markdown output, no network access is required after the initial model download.

## Usage

1. **Connect your TP-7** via USB and enter MTP mode (hold STOP while turning the device on)
2. **New recordings automatically sync** — the app detects new WAV files and processes them (watching is enabled by default)
3. **View recent recordings** in the menu bar popover
4. **Access all recordings** via "Open Recordings" in the menu
5. **Find transcriptions** in whichever outputs you enabled — Notion, Apple Notes, and/or local Markdown
6. **Correct speakers** in a recording's detail view when diarization is on — reassigning turns to people trains auto-labeling for future recordings

Each transcript includes:

- Full transcription text (split into per-speaker turns when diarization is enabled)
- AI-generated title and summary (if enabled)
- Recording metadata (date, filename, duration, file size, language)
- Play and download links for the audio (when S3 is enabled)

## Troubleshooting

### Device Not Detected

- Check that your TP-7 is in MTP mode (hold STOP while turning the device on)
- Try disconnecting and reconnecting the USB cable
- Check **Settings > General** to ensure device watching is enabled (it's on by default)
- If you just installed the app or just granted a permission prompt, try **quitting the app and launching it again**

### Upload Fails

- Verify your S3 bucket settings in **Settings > Storage**
- Verify your AWS credentials in **Settings > API Keys**
- Check that your IAM user has permission to write to the bucket
- Ensure you have internet connectivity
- Try the "Test Connection" button in Storage settings

### Transcription Fails

- **Parakeet / WhisperKit**: Make sure the model is downloaded (check **Settings > Transcription** for status)
- **ElevenLabs**: Verify your API key in **Settings > API Keys** and check your account balance
- Ensure the recording uploaded successfully to S3 first (if using ElevenLabs)

### Model Won't Download

- Check your internet connection
- Ensure you have enough disk space (WhisperKit models range from 75 MB to 3 GB; Parakeet and the diarization model are smaller)
- For WhisperKit, try a smaller model first (Tiny or Base)
- Check Console.app for detailed error messages

### Speakers Not Being Labeled

- Speaker diarization is Parakeet-only — confirm Parakeet is selected and **Speaker diarization** is enabled in **Settings > Transcription**
- Make sure the diarization model finished downloading
- Auto-labeling only kicks in once you've enrolled voices by reassigning turns to people; the first recording of a new speaker will show generic "Speaker N" labels

### Notes Not Appearing

- Check that Apple Notes integration is enabled in **Settings > Transcription**
- Verify the app has permission to control Notes (System Settings > Privacy & Security > Automation)
- Make sure the Notes app is installed and signed in

### Notion Pages Not Appearing

- Confirm the integration is shared with your database (**••• > Connections** on the database)
- Re-check the Integration Secret and Database ID in **Settings > Transcription**, then click "Provision & Connect"
- Look for a type-conflict warning — if a property already exists with an incompatible type, the app writes to an alternate `TP7 …` column instead

## Contributing

If you're interested in contributing, you're more than welcome. Bug fixes, small UX improvements, and documentation PRs are all appreciated.

- Open an issue (or just a PR) with a clear description of the change
- Build/run locally with Xcode: `open TeenageEngVoiceSync.xcodeproj`
- Or build from the CLI: `xcodebuild -project TeenageEngVoiceSync.xcodeproj -scheme TeenageEngVoiceSync -configuration Debug build`

Please avoid committing secrets — API keys are stored in Keychain.

## License

MIT License — see LICENSE file for details.
