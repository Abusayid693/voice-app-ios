# 0010: Chatterbox Nano — iOS 18 floor, short-form scope

## Status

Accepted.

## Context

FluidAudio's Chatterbox Nano backend (from FluidInference/FluidAudio#907, the
same PR as the Chatterbox Multilingual backend tracked in issue #3) is an
English-only, single-voice engine whose one distinct capability is ~20 inline
paralinguistic tags (`[laugh]`, `[sigh]`, `[whispering]`, …) — expressive
delivery nothing else in the app can do. Issue #30 tracks adding it.

Two properties of the SDK forced explicit decisions rather than a drop-in
integration matching Kokoro-ANE/Pocket TTS/Supertonic-3's pattern:

1. `ChatterboxNanoManager` is `@available(iOS 18.0, *)` — its T3 decode step
   keeps its KV cache in CoreML `MLState`. The app targeted iOS 17.
2. It has a hard ~512-token (~380 word) input cap and, unlike Kokoro
   (app-side `KokoroTextChunker`) or Supertonic-3 (SDK-side internal
   chunking), ships no chunker at all — long input throws
   `ChatterboxError.textTooLong` rather than being split.

## Decision

**Raise the deployment target to iOS 18.** The alternative — type-erasing
`ChatterboxNanoManager` to `Any?` in `DependencyContainer`, gating every
picker/pack-row/tile with an `isAvailable` flag, and adding a "Requires
iOS 18" state throughout the UI — is real, ongoing complexity for a single
beta, unreleased engine. Raising the floor removes it entirely: no `Any?`
storage, no `#available` checks anywhere in the app (this also let the one
pre-existing check, `ImportHomeView`'s `ScrolledToTopObserver`, be
simplified back to unconditional code).

**Ship Chatterbox Nano as a short-form/expressive-clip engine, not a
reader — do not build app-side chunking for it.** Each chunk would be an
independent AR decode + 8-step diffusion run with its own random seed and no
streaming; stitching multiple such chunks would produce audible prosody
discontinuities at every boundary, not just added latency. The ~512-token
cap is accepted and surfaced directly in the pack's own subtitle text and a
caption in the Write screen, rather than hidden until a user hits the error.
This makes it the only engine in the app that cannot handle long text — a
deliberate, documented asymmetry, not an oversight.

## Consequences

- iOS 17 devices can no longer install the app. No other engine required
  this — Kokoro-ANE, Pocket TTS, and Supertonic-3 all work on iOS 17.
- `DependencyContainer.chatterboxNanoManager` is a plain, always-available
  stored property, exactly like every other engine's manager — no special
  construction path.
- Long-form use cases (the app's Gutendex "Read Anything" flow, the
  read-along player, pasting book chapters) simply don't apply to this
  engine. Its Setup pack row, Trending tile, and voice picker entry should
  all make that scope clear rather than let it surface only as a runtime
  error.
- If a future FluidAudio revision adds chunking or streaming to Chatterbox
  Nano, this scoping decision (not the iOS 18 floor) should be revisited.
