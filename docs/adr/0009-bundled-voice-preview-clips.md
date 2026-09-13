# 9. Voice previews: bundled pre-recorded clips, not live synthesis

**Status:** Accepted (Kokoro only — Pocket's clips not yet recorded)
**Date:** 2025-10

## Context

Each voice row in Import's "Trending voices" needed a play button that plays a short spoken sample of that exact voice. There's no external source of "54 voice actors" — the only source of these voices is this app's own on-device engines.

## Decision

Generate each voice's clip once (using the app's real synthesis, exactly like any other generation) and bundle the result, rather than synthesizing live on every tap. `Features/Import/Models/VoicePreviewLines.swift` holds a distinct, natural-sounding 16-20 word sentence per voice code (deliberately varied phrasing/topics, not one shared line repeated 54 times) so voices are easy to tell apart when auditioned back to back, plus one fallback sentence for any voice missing an entry.

Shipped runtime side is pure file playback, no engine involved: `TTSViewModel.togglePreview(voiceName:engine:)` resolves `Bundle.main.url(forResource:withExtension:"wav", subdirectory:)` and plays it with a dedicated `AVAudioPlayer` that never shares state with the real synthesis engines — so previewing never collides with an in-progress "Write text" generation and has no first-tap synthesis latency.

**Regeneration recipe** (redo this if a preview line changes, or to add Pocket's clips): the capture tooling was temporary and has been removed from the shipped app — to redo it, re-add a debug button that loops the voices, synthesizes each one's `VoicePreviewLines` line, writes each to `<Documents>/VoicePreviews/<voice>.wav`, and offers them via `ShareLink(items:)` to export off-device; copy the result into `VoicePreviews/Kokoro/` at the project root (not under `Sources/` — see the bundling gotcha below), then remove the debug tooling again. Pocket's 26 voices need the same pattern but accumulating `synthesizeStreaming`'s 80ms frames into one buffer via `AVAudioFile` instead of a one-shot call (Pocket has no one-shot synthesize) — not yet done, so Pocket voices' play buttons are still a no-op.

## Consequences

All 28 English + 10 Mandarin Kokoro clips are captured and bundled at `local-tts/native-ios/VoicePreviews/Kokoro/<voice>.wav` (raw exports also live at `assets/kokoro-previews/` as the source-of-truth copy). Mandarin's capture used the exact recipe below (a temporary `MandarinPreviewGeneratorView` debug screen under Settings > Debug, removed after capture — see `TTSViewModel.mandarinVoices` for the 10 voices and `VoicePreviewLines.swift` for their preview lines). Pocket's 26 still need the same treatment.

A bug found and fixed while wiring this up, worth remembering for any future bundled-folder addition: these were first added under `Sources/Resources/VoicePreviews/Kokoro/`, relying on `project.yml`'s plain whole-folder `sources: [Sources]` scan — which flattens loose files (subdirectory nesting is Xcode-navigator-only, not preserved in the built bundle). At runtime `Bundle.main.url(forResource:withExtension:subdirectory:)` always returned `nil`, and the play button silently no-op'd (by design, treating a missing clip like "not available"). Fixed by moving the folder to a top-level `VoicePreviews/` (sibling to `Sources/`, matching `CustomKokoroModel/`'s placement — see ADR 2) and giving it its own `type: folder` entry in `project.yml`, which is what actually makes Xcode copy it as one atomic directory with its internal structure intact.
