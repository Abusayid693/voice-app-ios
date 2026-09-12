# 4. Kokoro-ANE: app-level chunking + independent per-Generate tracks

**Status:** Accepted
**Date:** 2025-09/10

## Context

Kokoro-ANE is hard-capped at ≤510 phonemes per call (Albert's context window), with no built-in chunker and no streaming path at all — architecturally impossible, since Albert→PostAlbert→Alignment decide the entire frame count up front before the rest runs as one batched pass (unlike PocketTTS's genuinely autoregressive frame-by-frame generation). Long text either errored outright or required waiting for the whole thing to synthesize before hearing anything.

## Decision

`Features/TTS/Models/KokoroTextChunker.swift` splits text on sentence boundaries (falling back to word boundaries for one very long sentence) at a conservative ~350-character budget — phoneme count isn't knowable without running G2P, so this is a character-count stand-in with headroom.

Each "Generate" tap creates an independent track, not one shared continuous stream. `KokoroGeneration` holds one generation's sub-chunks, audio, and per-chunk state; `TTSViewModel.kokoroGenerations: [KokoroGeneration]` is append-only, like a playlist. Only one track plays at a time — selecting a different one stops whatever was active and starts the new one from its beginning, like switching songs; a track never auto-advances into a different track when it ends.

Generation itself is one persistent background worker (`ensureKokoroGenerationRunning()`) shared across all tracks — each iteration scans every track in creation order for its next `.waiting` chunk and synthesizes it, so a Generate tap while the worker is already running just adds more work to the same loop. A chunk that fails to synthesize is marked `.failed` (not left `.waiting` forever), and the worker moves on instead of dying — one bad chunk doesn't block the rest of the queue.

Playback uses one `AVAudioPlayer` per chunk (not the `AVAudioEngine`/`AVAudioPlayerNode` PocketTTS uses) — natively supports pause/resume mid-chunk; a small delegate bridges `audioPlayerDidFinishPlaying` to advance to the next chunk within the active track.

## Consequences

A bug already found and fixed once, worth guarding against reintroducing: an earlier version conflated "start playback" with "regenerate" — tapping Play both decided resume-vs-restart *and* triggered generation, gated only on whether the chunk list was non-empty. That flag never got cleared after a run finished or when the text changed, so playing new text after finishing old text just replayed the stale, already-finished player instead of generating anything new. The Generate/Play split above is the fix — keep the two actions explicit and separate; don't reintroduce a single combined "smart" button that tries to infer resume-vs-fresh from state.

This chunking later became the basis for the read-along player's chunk-level highlighting (ADR 5) and Library's per-chunk audio persistence.
