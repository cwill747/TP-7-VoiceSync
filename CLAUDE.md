# TeenageEngVoiceSync

macOS SwiftUI app (sandboxed) that syncs recordings from Teenage Engineering devices, transcribes them, and pushes notes to Notion/Apple Notes/Markdown.

## Building

- Local verify build: `xcodebuild -project TeenageEngVoiceSync.xcodeproj -scheme TeenageEngVoiceSync -configuration Debug build`
- Tests: `xcodebuild test -project TeenageEngVoiceSync.xcodeproj -scheme TeenageEngVoiceSync`

## IMPORTANT: never launch unsigned builds

Do not pass `CODE_SIGNING_ALLOWED=NO` to local builds whose product might be launched. An unsigned build has no App Sandbox entitlement, so it persists UserDefaults to `~/Library/Preferences` and its SwiftData store to `~/Library/Application Support` instead of the app container (`~/Library/Containers/us.cwill.TeenageEngVoiceSync`). Launching one makes all settings appear reset and forks the recordings database. `CODE_SIGNING_ALLOWED=NO` is for CI compile checks only; local signing with the Apple Development identity works and should be left on.
