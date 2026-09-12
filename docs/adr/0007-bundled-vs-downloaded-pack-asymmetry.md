# 7. Setup flow treats the two voice packs asymmetrically, on purpose

**Status:** Accepted
**Date:** 2025-10

## Context

The two engines' packs are fundamentally different in how they're obtained: Kokoro is bundled at build time (see ADR 2); PocketTTS has no bundled fallback and is a genuine ~500MB network download the user opts into. There's also no cheap, disk-based "is this already downloaded" check exposed by the SDK for Pocket — `manager.isAvailable()`-style flags only reflect what's loaded into the current process's RAM, always false on a fresh launch even if the model files are sitting in `Application Support` from a previous run.

## Decision

- **Kokoro**: copied into `Application Support` synchronously in `DependencyContainer.init()`, before any UI shows — so `TTSViewModel.isKokoroPackReady` is true for virtually every launch the instant the ViewModel exists. `downloadKokoroPackIfNeeded()` only does real work if that bundle copy failed.
- **PocketTTS**: `TTSViewModel.isPocketPackDownloaded` is a persisted `UserDefaults` flag, set the first time `downloadPocketPackIfNeeded()` succeeds and read back at `init` — not derived from any SDK availability check.
- A "Setup" button on Import always opens `SetupSheet`, showing both packs as either a checkmark ("already downloaded") or a "Download" button with progress — **never hidden**, per explicit direction ("keep button, show as already-set-up" rather than hiding it once done).

## Consequences

Download progress itself needed real byte totals the SDK doesn't provide (`ProgressHandler` only reports a fraction) — the app queries HuggingFace's public tree API directly and sums file sizes, filtered to just the files the chosen precision/placement config actually downloads (verified against `ModelNames.swift`'s `requiredModels(precision:placement:)` source). Progress-fraction weighting also differs by path: Kokoro's repo-download reserves 0.0–0.5 for download + 0.5–1.0 for a compile phase that never fires for these pre-compiled bundles (normalized by dividing by 0.5); PocketTTS's subdirectory-download path spans the full 0.0–1.0. Get this wrong and progress bars either stall at 50% or never reach 100%.

Settings currently offers no pack-deletion path — Kokoro's pack is bundled with the app (nothing meaningful to delete), and Pocket has no re-download-on-demand flow from Settings yet. Flagged as a prerequisite to resolve before adding delete buttons there.
