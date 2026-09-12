# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); version is read from `local-tts/native-ios/project.yml`'s `CFBundleShortVersionString`.

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
