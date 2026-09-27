# 12. Two playback engines: read-along and music mode stay separate

**Status:** Accepted
**Date:** 2026-09-28

## Context

The ask was a second way to consume a book: start it like an audiobook, lock the phone, and let it keep going page after page — cover art and a timeline, not text on screen. Read-along (`ChapterAudioPlayer`, `Features/Chapters/`) already exists and is this app's most performance-tuned surface; the question was whether music mode should be a new UI on top of that same player, or a genuinely separate playback owner.

Two things settled it:

1. **`ChapterAudioPlayer` cannot survive the lock screen as built.** It never configures `AVAudioSession` at all — reader audio only outlives a lock today if `VoicePreviewPlayer` happened to set `.playback` earlier in the launch — and it creates one `AVAudioPlayer` per chunk, so audio genuinely stops for a moment at every ~25s chunk boundary. `docs/adr/0011-kokoro-compute-units-no-gpu.md`'s closing section names both gaps directly and points at `StreamingPlaybackLab` as the prototype for the fix: one `AVAudioPlayerNode` with buffers scheduled onto it, gapless, plus a silence keep-alive so a slow synthesis stretch can't leave the node silent long enough for iOS to suspend the app (once suspended, synthesis stops too, and it never recovers).
2. **Read-along's word-level highlighting polls `AVAudioPlayer.currentTime` at 10-15Hz.** Moving the reader onto a node engine means replacing that with `AVAudioTime`/render-time bookkeeping — rebuilding the clock the app's most-tuned surface depends on, for a feature (gapless boundaries) read-along barely needs: a chunk boundary reading along is a few hundred milliseconds, unnoticed against the pace of following text; the same gap with the screen off and nothing to look at is the whole experience.

So this wasn't "swap the engine under one player" — it was two different sets of requirements pulling in different directions, and picking one path would have compromised the other.

## Decision

**Two independent playback owners**, both app-lifetime singletons in `AppEnvironment`:

- `ChapterAudioPlayer` (`Features/Chapters/`) — read-along, untouched. Still one `AVAudioPlayer` per chunk, still no `AVAudioSession` configuration of its own.
- `BookAudioPlayer` (`Features/Listening/`) — music mode. `StreamingPlaybackLab`'s engine (`AVAudioPlayerNode`, `.playback`/`.spokenAudio`/`.longFormAudio` session, Now Playing/remote commands, silence keep-alive) promoted into a real feature, with `ChapterAudioPlayer`'s page model — bounded lookahead, cross-page prefetch, position/stats — ported alongside it, deliberately simplified: no word timings, no play-from-word, since nothing here renders words.

**Mutual exclusion is structural, not a UI convention.** Both classes expose a `willStartPlaying` closure, fired the moment either one is about to start or resume audio. `KokoroAneTestApp` wires each to the other's `pauseIfPlaying()` — pausing, never stopping, so the yielded side's position and Reading Stats session both survive and resuming it later is instant. This was an explicit product decision, not a technical fallback: opening the reader while music mode is playing does **not** stop it, and the two remain independent until the user taps play on one of them.

**Position and stats are shared through seams, not a shared object.** Both playback owners are hand-given `LibraryViewModel.recordLastReadPage`/`project.lastReadPageIndex` (the same call `ChapterPlayerView` itself uses) and their own `ReadingStatsTracker` instance. A tracker holds a single `sessionID` and self-closes it on a new `beginListening` — sharing one instance between two independent playback owners would let either silently end the other's session, so each gets its own, both writing into the same underlying `ReadingStatsStore`.

**One synthesis queue, not two.** Both players are handed the same app-wide `ChapterSynthesisService`, whose `runSerially` FIFO already exists so unrelated synthesis requests don't interleave unpredictably. `ChapterSynthesisService` grew a second entry point, `synthesizeChunkSamples`, alongside the existing `synthesizeChunkDetailed` — English routes through the same `synthesizeDetailed` call either way (identical inference), but `synthesizeChunkSamples` stops at its pre-encode `.samples` output rather than paying for the `AudioWAV` encode and the G2P/`WordTimingDeriver` alignment pass that only `ChapterAudioPlayer` needs. `BookAudioPlayer` never had a reason to make its own `ChapterSynthesisService` the way `StreamingPlaybackLab` does — that duplication was fine for an isolated scratch harness, not for a shipping feature sharing the same CoreML models.

## Consequences

**A real duplicated-logic cost, accepted deliberately.** `BookAudioPlayer`'s page model — bounded lookahead, cross-page prefetch, per-chunk duration estimation — mirrors roughly 80 lines of `ChapterAudioPlayer`'s own shape, adapted for node-based scheduling instead of one-`AVAudioPlayer`-per-chunk. The two must be kept in step by hand; a bug fixed in one won't automatically apply to the other. This is the direct price of not disturbing read-along's tuned surface, and is worth revisiting only if the two playback models converge on their own.

**The reader does not follow music-mode page turns.** `ChapterPlayerView`'s auto-advance handling watches `chapterPlayer.activeRef` only — a different object, so if the reader happens to be open while music mode is playing, it stays on whatever page it was already showing. It picks up the new position the next time it's opened (both share `lastReadPageIndex`), but it will not visibly track music mode's live page in real time. Nothing in this decision precludes fixing that later; it just isn't what this feature covers.

**The book scrubber is page-scoped, not whole-book.** A `BookAudioPlayer` seek only ever targets the current page — a whole-book seek could drop onto a page far outside the bounded lookahead window, with nothing bounding how long that buffers for. The whole-book progress bar is therefore read-only, derived from `(pageIndex + fractionOfCurrentPage) / pageCount` rather than a total-character scan of every page file.

**Synthesis must still outpace playback on CPU-only routing.** `docs/adr/0011`'s open question — whether synthesis reliably stays ahead of playback now that no Kokoro stage runs on the GPU — applies here just as it does to the reader's own streaming, and music mode inherits the same silence-keep-alive fallback rather than a stronger guarantee. `BookAudioPlayer` keeps the same timestamped event log `StreamingPlaybackLab` uses (`chunk N synthesised in Xs (plays Ys)`) as the way to check that on device.

**Not attempted here:** unifying the two players onto one gapless engine. That remains a real follow-up — it would give read-along background survival too — but it means rebuilding the clock word-highlighting polls, which is a larger, riskier change than this feature needed to make.
