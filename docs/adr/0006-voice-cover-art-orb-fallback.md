# 6. Voice cover art: real avatars, else a deterministic orb — never a third tier

**Status:** Accepted
**Date:** 2026-09-12

## Context

Voice avatars went through three tiers before settling on two: a real per-voice AI-generated avatar (sparse — only some Kokoro voices have one) → a hash-cycled generic stock photo for any other *available* voice → a plain gradient for unavailable voices and cloned voices (which never have a photo at all). This was inconsistent and duplicated across three call sites (`VoiceTileView.avatar`, `VoicePreviewCard.coverArt`, `VoicesTabView.avatar`), each independently branching on `tile.isAvailable`.

## Decision

Collapse to two tiers: a real named avatar, else an orb — available or not, Kokoro or Pocket, cloned or not. `OrbCoverArt.swift` (`DesignSystem/`) holds a small, growing array of orb image names; `assetName(for:)` hashes the seed string (`unicodeScalars.reduce` sum, `% count` — same deterministic pattern the old gradient helper used, so the same voice always shows the same orb, never re-randomized on redraw). `VoiceCoverArt.assetName(for:)` becomes just `realAvatarAssetNames[voiceName] ?? OrbCoverArt.assetName(for: voiceName)` — every call site calls this one function unconditionally, no `isAvailable ? … : …` branching duplicated per screen.

Real avatars were briefed via hand-written AI image prompts, keyed off each voice's persona tagline plus its real `af_`/`am_`/`bf_`/`bm_` gender/accent prefix — portraits shot with generous negative space around the subject so a circular crop never clips the figure.

## Consequences

No Pocket TTS voice has a real named avatar (all 26 are LibriVox-style narrator names with no persona-generation work done) — they all render via `OrbCoverArt`. Only 16 of 28 Kokoro voices have one as of this writing; the rest show an orb too, until more avatars are generated (`assets/voice-covers/kokoro-avatar-prompts.md` has the prompts for the remaining ones).

`LinearGradient.stablePlaceholder` is *not* dead code — `OpenLibraryBookCard` (book covers) still uses it; only voice cover art moved off it.

Orb source images have been swapped/added multiple times during design iteration — if `assets/orbs/` ever looks out of sync with `OrbCoverArt.assetNames`, resync by copying into fresh `VoiceOrbN.imageset` folders in the asset catalog and updating the array; same mechanical steps every time.
