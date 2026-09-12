# 1. Build a standalone native iOS prototype before touching Voicenote

**Status:** Accepted
**Date:** 2025-09 (originally `plan.md`)

## Context

Voicenote (a separate Expo app) needs real, on-device TTS. FluidAudio's Swift SDK (`FluidInference/FluidAudio`) has a genuine, production-tested `KokoroAneManager` — used by a real shipping app ("Local Narrator") — but it's reachable only via Swift Package Manager, never CocoaPods. Wiring it into Voicenote's Expo/CocoaPods build means `useFrameworks: dynamic`, a real, risky change that affects the app's already-working CPU TTS path.

Before touching that working path at all, we needed to validate the SDK itself: does `KokoroAneManager` actually work well, how big is the download, how fast is synthesis, does anything crash — independently of the separate question of getting Expo's build to link it.

## Decision

Build a small, fully separate native iOS app — no Expo, no CocoaPods, no `expo prebuild` involvement — that downloads the real Kokoro-ANE model and runs synthesis directly on real hardware. `local-tts/native-ios/`, generated via `xcodegen` from `project.yml` (far more reliable than hand-writing `project.pbxproj`), pinned to FluidAudio `0.15.6`.

Deliberately a throwaway validation harness at first, not production code: one screen, a text field, a "Download & Speak" button, visible status/timing so the download size, cold-vs-warm load time, and synthesis speed could be observed directly on-device.

## Consequences

This decision is why this entire repo/app exists. The prototype validated cleanly and grew into the full two-engine app documented in the rest of `docs/adr/` — the original throwaway scope no longer applies (see the later ADRs for what it became: multi-voice Kokoro bundling, PocketTTS integration, the full Import/Library/Settings UI). The larger, riskier Expo-side integration (a `modules/fluid-kokoro-tts/` native module, `useFrameworks: dynamic`) remains deferred until this app's validation work is judged sufficient to justify it — that decision hasn't been revisited since.
