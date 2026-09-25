# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); version is read from `local-tts/native-ios/project.yml`'s `CFBundleShortVersionString`.

## [Unreleased]

### Changed
- Generate no longer synthesizes audio directly — it saves the text split into chapters (≤2000 words each), and a new chapters list lets each chapter be streamed on demand (any engine) or, for Kokoro, generated and saved as one real file with a proper music-player screen (artwork, scrubber, real elapsed/duration) — see `docs/adr/0010-chapters-and-per-chapter-saved-audio.md` (supersedes ADR 4)
- Library and Home's Projects row now open the same chapters list for every engine, not just Kokoro
- "Initializing model…" cold-start notice while an engine warms up for the first time
- Home's top action row is now two swipeable tabs ("Listen to text" / "Make audio")

### Removed
- The old Kokoro multi-track playlist system (`KokoroGeneration`, the chunk-scanning background worker, `ReadAlongPlayerView`, `KokoroGenerationListView`) and the retired `TTSHomeView`/`TextEntrySheet` debug screen, replaced by the chapters flow above
- Pocket TTS and voice cloning removed entirely — Kokoro-ANE is the only engine. `Engine.pocketTts` is gone with no legacy decode path, so any saved project still naming it will fail to decode

## [0.1.0] - 2026-09-12

### Added
- Two on-device TTS engines: Kokoro-ANE (28 custom-bundled voices, chunked multi-track playback for long text) and PocketTTS (26 voices, streaming synthesis, voice cloning)
- Import tab: Trending voices (playable previews, swipeable per-voice card sheet), What's trending (live Gutendex feed), Write text flow, Setup flow for both voice packs
- Read-along player for Kokoro generations — chunk-level highlighting, auto-scroll with manual override
- Library: saved generations with persisted per-chunk audio — replay without regenerating
- Voice cloning (PocketTTS only): record or import a sample, clone, generate with it
- Settings: Voice Packs / Storage (real on-disk sizes) / About
- Voice cover art: real AI-generated avatars for select voices, deterministic orb fallback for the rest
- Audio-reactive blob-shaped cover art deformation on the voice preview sheet
- Lucide icon set across the app

### Known limitations
- Onboarding/`AppCoordinator` not built — app opens straight to Import
- PocketTTS: chunk-boundary audio glitch unresolved; voice accent unconfirmed; no bundled previews yet
- Voice cloning not regression-tested on-device since it was built
- Most Kokoro voices and all Pocket voices still show an orb rather than a real avatar

See `docs/adr/` for the reasoning behind these and other non-obvious decisions.
