# Standalone iOS prototype: FluidAudio's real Kokoro-ANE TTS

## Context

We spent a long session chasing GPU/ANE-accelerated TTS for the Voicenote app. The npm wrapper `@fluidinference/react-native-fluidaudio` turned out to have TTS entirely stubbed out (fake, empty responses). We then found the *real* implementation — `KokoroAneManager` in the actual `FluidInference/FluidAudio` Swift SDK — is genuine, tested, production code (used by a real shipping app, "Local Narrator," from FluidAudio's own showcase). But it's reachable only via Swift Package Manager, never CocoaPods, which means wiring it into the Expo app requires a real, somewhat risky change (`useFrameworks: dynamic`, affecting the app's already-working CPU TTS path).

Before touching the Expo app at all, the user wants to validate this directly and simply: a small standalone native iOS app, no Expo/CocoaPods/prebuild involved, that downloads the real Kokoro-ANE model and runs synthesis on their actual iPhone — mirroring how they already tried "Local Narrator" itself. This de-risks the real unknown (does `KokoroAneManager` actually work well, how big is the download, how fast is it, does anything crash) independently of the separate, unrelated question of getting Expo's build to link it.

One fact already resolved by checking the connected device (`xcrun xctrace list devices`): the test device, "Rehan's iPhone," is on **iOS 26.6.1** — past FluidAudio's documented fix line for the BNNS crash bug ("Fixed in the 26.6 line"). So no crash workaround/warning is needed for this prototype.

## Approach

**New, fully separate Xcode project, at `local-tts/native-ios/`** — inside the repo for convenience, but structurally independent: its own `.xcodeproj`, never touched by `expo prebuild`, no relation to the Expo-managed (gitignored, regenerated) `ios/` directory or `app.json`.

1. **Install `xcodegen`** (`brew install xcodegen` — Homebrew is available). Used to generate a correct `.xcodeproj` from a simple YAML spec, including a proper Swift Package reference — far more reliable than hand-writing `project.pbxproj` (a documented source of subtle bugs even in mature tooling, per what we already found investigating `xcode`/`@expo/config-plugins`' limitations for the main app).

2. **`project.yml`**:
   ```yaml
   name: KokoroAneTest
   options:
     deploymentTarget:
       iOS: "17.0"
   packages:
     FluidAudio:
       url: https://github.com/FluidInference/FluidAudio
       exactVersion: 0.15.6
   targets:
     KokoroAneTest:
       type: application
       platform: iOS
       sources: [Sources]
       dependencies:
         - package: FluidAudio
           product: FluidAudio
       info:
         path: Sources/Info.plist
         properties:
           UILaunchScreen: {}
   ```
   `xcodegen generate` produces `KokoroAneTest.xcodeproj`.

3. **Minimal SwiftUI app** (`Sources/KokoroAneTestApp.swift`, `Sources/ContentView.swift`) — one screen:
   - A text field, defaulting to "Hello from FluidAudio!"
   - A "Download & Speak" button. On tap: create `KokoroAneManager()` once, call `try await manager.initialize()` (first run downloads + compiles the 7 CoreML stages — this is the real, unknown-size download we want to observe directly), then `try await manager.synthesize(text:)` (the `Data`/WAV-returning variant — simplest possible playback path via `AVAudioPlayer(data:)`, no manual PCM buffer handling needed for a prototype).
   - Status text showing what's happening (Idle / Downloading & compiling… / Synthesizing… / Playing / Error: `<message>`) plus wall-clock timing for init and for synthesis, printed via `print()`/visible in the UI — so the user can directly observe real download size (checked from the on-disk cache the docs describe, under the app's container), cold vs. warm load time, and synthesis speed on their own device, and confirm nothing crashes.
   - No chunking, no voice picker, no error recovery beyond a visible error message — this is a throwaway validation harness, not production code.

4. **Build & run on the connected device.** The device (UDID `00008110-001631CE0C92401E`, already used successfully for the Expo app via `npx expo run:ios --device`) showed as "Offline" in the device list at plan time — likely just needs a cable/Wi-Fi reconnect. Two ways to run once generated:
   - `xcodebuild -project KokoroAneTest.xcodeproj -scheme KokoroAneTest -destination 'id=00008110-001631CE0C92401E' build` then install/launch via `xcrun devicectl device install app` / `xcrun devicectl device process launch`, or
   - Simpler and more reliable for a one-off: open `KokoroAneTest.xcodeproj` directly in Xcode and hit Run with the device selected — avoids fighting devicectl/signing quirks for a throwaway project. Recommend this as the primary path; only reach for `xcodebuild` CLI if Xcode itself isn't convenient in the moment.
   - Code signing: will need the same Apple ID/team already used for the Expo app's on-device builds — Xcode's automatic signing should pick this up once a team is selected in the project's Signing & Capabilities tab.

## What this tells us, and what happens after

If this works cleanly: real confirmation that `KokoroAneManager` is worth integrating into Voicenote, plus real numbers (download size, synthesis speed, quality) to replace the guesses this session has been working from. The Swift logic from this prototype (init/synthesize calls) carries over almost directly into a future Expo native module (`modules/fluid-kokoro-tts/`) if we proceed with the full integration later — that larger, riskier Expo-side plan (SPM-via-CocoaPods-bridge, `useFrameworks: dynamic`, etc.) is intentionally deferred until this prototype confirms the payload itself is worth the integration risk.

If it crashes, downloads something unreasonably large, or sounds/performs worse than expected, we've learned that cheaply — without having touched the Expo app's working CPU TTS path at all.
