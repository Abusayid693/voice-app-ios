# 8. Voice cloning: its own feature area, riding directly on existing SDK APIs

**Status:** Accepted
**Date:** 2025-10

## Context

Users can record a short sample of their own voice and get a reusable PocketTTS voice back — Pocket-only (Kokoro-ANE has no cloning capability). Confirmed against the exact pinned FluidAudio version (`v0.15.6`, via `Package.resolved`, not assumed) that this rides entirely on APIs already present: `PocketTtsManager.cloneVoice(from:)` runs a sample through Kyutai's Mimi encoder to produce `PocketTtsVoiceData`; `synthesize(text:voiceData:)`/`synthesizeStreaming(text:voiceData:)` are parallel overloads of the normal `text:voice:` calls that accept it directly. No upstream SDK gap, no fork needed.

## Decision

Built as its own feature area (`Features/VoiceClone/`), not folded into `TTSViewModel` — recording/cloning/managing a list of user-created voices is a genuinely separate concern from TTS-generation orchestration. `VoiceCloneViewModel` gets its own `PocketEngineService` instance (safely sharing the same underlying `PocketTtsManager` actor/`AVAudioEngine` as `TTSViewModel`'s, since the service holds no state of its own beyond those shared references).

Persistence: `ClonedVoice` (id, name, createdAt) as UserDefaults+JSON metadata, same convention as the pack-downloaded flag (ADR 7); the actual `PocketTtsVoiceData` binary lives at `Application Support/ClonedVoices/<id>.bin`, computed from one static path both `VoiceCloneViewModel` (writes) and `TTSViewModel` (reads, to generate with a cloned voice) share without needing a reference to each other's instance.

Recording (`AVAudioRecorder`, 44.1kHz mono 16-bit WAV, capped at 20s) and importing an existing file (`.fileImporter` + `AVAudioConverter` transcode) both funnel into the same temp WAV location, so everything downstream treats a recording and an import identically.

## Consequences

`cloneVoice` lazily downloads a separate `mimi_encoder.mlmodelc` model on first call (language-agnostic) with no progress callback exposed — the UI shows an indeterminate spinner rather than a real progress bar.

Known upstream limitation (not a concern for this app, which only uses `.english`): live cloning is fully reliable for English and the 24-layer non-English packs, best-effort on the smaller 6-layer non-English packs (FluidAudio GitHub issue #793, a confirmed architecture constraint).

This feature has not been regression-tested on-device since it was built — the mic permission, recording, cloning, and generation-with-a-cloned-voice paths are unverified beyond `xcodegen generate` succeeding. In particular `isVoiceCloningAvailable()`'s exact semantics (checks mimi_encoder presence, not the main Pocket pack, per its doc comment) and the encoder download's first-run latency/UX need a real-device pass before trusting either.
