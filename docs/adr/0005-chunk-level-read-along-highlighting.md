# 5. Chunk-level, not word-level, read-along highlighting

**Status:** Accepted (word-level attempted and reverted — see below)
**Date:** 2026-09 (originally `WORD_HIGHLIGHTING_NOTES.md`)

## Context

Issue #10 (read-along player) needed some form of highlight-what's-being-spoken UI. Word-level was attempted first, using a genuine, previously-unused SDK capability, then reverted after real-device testing.

## What was attempted: real per-word timestamps from `synthesizeDetailed`

Direct verification against the FluidAudio SDK source (not assumption) found:

- `KokoroAneManager.synthesizeDetailed(text:voice:speed:)` is **public** and returns `KokoroAneSynthesisResult`, which includes:
  - `inputIds: [Int32]` — one token per phoneme *character* (`[BOS, ...perCharacterTokens..., EOS]`)
  - `predictedDurations: [Int32]` — the model's own real per-token acoustic-frame durations (PostAlbert's `pred_dur`), aligned 1:1 with `inputIds`
  - `acousticFrames: Int`, `durationSeconds: Double` — enough to derive `secondsPerFrame` per-call, no hardcoded hop-size constant needed
  - This app's `KokoroEngineService` only called the plain `synthesize`, which discards all of this.
- `KokoroAneManager.phonemes(for:)` is also public — the exact phoneme string fed to the model.
- The phonemizer (`KokoroAneEnglishPhonemizer`) joins each word's phonemes with a literal space. The bundled `vocab.json` confirms space **is** a real vocab entry (token id 16), so word-boundary spaces survive encoding as their own token — not silently dropped.

### The algorithm (`KokoroWordAligner`, since removed)

For a chunk's text + its phoneme string:
1. Split the phoneme string on literal spaces → one substring per word.
2. Split the chunk's own text on whitespace → one substring per word.
3. Require the two counts to match (defensive — see "why reverted" below).
4. Walk `predictedDurations[1..<count-1]` (skip BOS/EOS), consuming each word's phoneme-character-count of entries (+1 more for the separating space, still advancing the running frame offset since the pause takes real time).
5. Convert frame offsets to seconds via `durationSeconds / acousticFrames`.
6. Sanity check: the walk must land exactly on EOS with nothing left over, or bail (`nil`) — a silently-dropped phoneme character (not in vocab) would desync the walk otherwise.

Playback side: a polling `Task` (same 66ms cadence as the voice-preview metering) read `AVAudioPlayer.currentTime` and looked up which `WordTiming` range it fell into.

## Why it was reverted

Real-usage testing (pasting real text) showed the fallback triggering constantly, not rarely. Root cause, confirmed by reading `EnglishTextNormalizer.swift` in the FluidAudio SDK: `phonemes(for:)` runs a genuinely rich text-normalization pass before phonemizing — `"26"` → `"twenty six"`, `"1949"` → `"nineteen forty nine"`, `"1:49 PM"` → `"one forty nine p m"`, plus decimals, ordinals, decades, currency, dates, measures, fractions, ranges — routed through a full compiled FST engine (`NemoTextNormalizer`) for anything beyond the conservative baseline.

Any one of those anywhere in a chunk changes the phoneme string's word count relative to the raw chunk text, tripping the alignment's defensive `nil` fallback for the *entire* chunk. Hand-typed test sentences rarely have numbers; real pasted text (articles, books) very often does — so in practice, most real content fell back to chunk-level, undermining the point of building word-level in the first place.

**Why the mismatch can't just be queried ahead of time**: `EnglishTextNormalizer` and `NemoTextNormalizer` are both `internal` to the FluidAudio package (no `public` modifier) — there's no way to ask what text a given input will normalize to from this app.

## Decision

Reverted to chunk-level highlighting: `ReadAlongPlayerView` highlights a whole chunk at a time using data that already existed (`KokoroGeneration.currentChunkIndex` + `.isPlaying`) — no new engine work, and no fallback edge case to trip over.

## Fix idea to try next, if word-level is revisited: pre-expand numbers ourselves, keep our own mapping

Instead of feeding Kokoro raw text and hoping our word count matches whatever its hidden normalizer produces, do the expansion **ourselves**, before either synthesis or alignment:

1. Scan the chunk text for patterns we're willing to handle ourselves (start small: bare integers; expand later to currency/years/decimals if worth it).
2. Convert to words ourselves (`"23"` → `"twenty three"`) with a small local number-to-words function — doesn't need to match FluidAudio's NeMo engine exactly, just needs to be something reasonable we fully control.
3. Replace it in the text actually sent to `phonemes(for:)` / `synthesizeDetailed`.
4. Keep a **side mapping** (never inserted into the string handed to the SDK) recording, per chunk: the expanded word range ↔ the original display text.
5. Since Kokoro's normalizer only rewrites raw digit/date/currency *patterns*, and the fed text now has none left, the word counts should match — because both sides of the comparison were generated from the same known expansion, instead of guessing at a hidden one.
6. At render time, use the mapping to display the original text as one highlighted unit while still correctly identifying when playback is within its real audio span (the merged duration of the expanded words).

**Why not a placeholder token** (the originally-proposed `{#12: [...]}` form): a fake token like `"#12"` still has to survive the SDK's phonemizer and vocab — no guarantee `#`/digits phonemize predictably, reintroducing the exact uncertainty this fix is trying to remove. Sending the *real* expansion instead avoids that.

**Remaining costs / open questions if this gets built**:
- We'd own our own number/date/currency-to-words quality, necessarily smaller in scope than FluidAudio's NeMo engine. Whatever isn't handled should fall back to chunk-level for that chunk, same safety net as today, just covering less real text.
- Need to check whether pre-expanding changes how a chunk *sounds* vs. what FluidAudio's own normalizer would have produced (e.g. does FluidAudio read `"1949"` as a year specifically, while a naive cardinal converter reads it as "one thousand nine hundred forty nine"?) — worth listening to both on-device, not just trusting the word-count math.
- `KokoroTextChunker`'s chunking happens *before* this expansion — check whether expanding numbers first could push a chunk over its ~350-char budget, and whether that needs accounting for in the chunk-length calculation or should happen before chunking instead of after.
