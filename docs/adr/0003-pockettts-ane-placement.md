# 3. Use `.ane` placement for PocketTTS, not the SDK's `.gpu` default

**Status:** Accepted
**Date:** 2025-09

## Context

PocketTTS (`PocketTtsManager`) is a flow-matching LM + Mimi neural codec, fundamentally heavier than Kokoro-ANE (~500MB+ vs ~166MB download) but genuinely multi-voice (26 real published voices). The SDK's `.gpu` default placement is benchmarked and justified with Mac-specific numbers (M-series GPU vs. ANE per-call latency); the SDK's own `.ane` doc explicitly names "iOS placement" as a reason to use it instead.

## Decision

Use `.ane` placement, not the library default — this app's whole purpose is validating the ANE path on iPhone (see ADR 1), so defaulting to the Mac-benchmarked `.gpu` choice would work against that purpose.

## Consequences

`precision: .int8` has no effect under `.ane` placement — only `.gpu`'s FlowLM variant is quantizable. Actual download is ~503MB fp16, not the ~433MB int8+gpu figure that appeared in early testing before this was corrected. Don't "optimize" this back to int8 without re-deriving whether that's even possible under `.ane`.

Voice accent (American vs. other English) remains unconfirmed — no dialect metadata found in docs or accessible source, and the upstream `kyutai/pocket-tts` model card is gated. Don't assume "American English" without checking on-device.

Playback is streaming, not buffered — `synthesizeStreaming()` yields 80ms `AudioFrame`s fed incrementally into `AVAudioEngine`/`AVAudioPlayerNode` as they're generated. A known, unresolved issue: a small audible glitch/overlap at chunk boundaries within one long synthesis (the KV cache resets per chunk internally in the SDK). A fix was attempted (insert ~300ms silence buffer at each chunk boundary) and explicitly reverted at the user's request — do not re-attempt this exact approach without new direction; if revisiting, consider a smaller gap value and/or a crossfade instead of hard silence.
