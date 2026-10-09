# 13. One player, two surfaces

**Status:** Accepted
**Date:** 2026-09-28
**Supersedes:** `0012-two-playback-engines.md`

## Context

ADR 0012 accepted two playback engines for the same book — `ChapterAudioPlayer` for read-along (word timings, one `AVAudioPlayer` per chunk, no audio session) and `BookAudioPlayer` for music mode (gapless `AVAudioPlayerNode`, session, now-playing, silence keep-alive) — and named the cost plainly: ~80 lines of duplicated page-queue logic kept in step by hand, a reader that could not follow music-mode page turns, and mutual-exclusion machinery (`willStartPlaying`/`pauseIfPlaying`/`isYielded`, two `ReadingStatsTracker` instances) that existed only because there were two owners. It closed by naming unification as "a real follow-up" whose blocker was rebuilding the clock word highlighting polls.

The product goal that forced the issue is what Speechify and ElevenReader do: one player, an audio surface and a read-along surface, an icon in each that switches to the other. Two engines cannot express that — switching surfaces would mean switching *sessions*, i.e. stopping and restarting audio at a seam the user is looking at.

## Decision

**One playback owner: `BookAudioPlayer`.** `ChapterAudioPlayer` is deleted. The gapless node engine wins because it carries everything the reader's engine never had — `AVAudioSession` configuration, Now Playing, remote commands, and the silence keep-alive that keeps a backgrounded app alive across a starvation stretch — while the reader's engine contributed things that port cleanly: word timings, seek, `chunkTexts`, and the continuous-playback preference.

**Three surfaces, one screen.** `ChapterPlayerView` renders `.text` (read-along), `.originalPage` (the PDF image) or `.audio` (artwork, scrubber, transport) as branches of one `readingSurface`, extending the pattern the PDF toggle already used. Switching re-renders a branch; it cannot re-run `.onAppear` and never touches the player, so audio continues uninterrupted at the same position. The audio surface stopped being a `.fullScreenCover`.

**Position comes from the node's render clock.** This was 0012's stated blocker, and the resolution is a sample map: every buffer handed to the node records a `ScheduledSpan(startSample, frameCount, chunkIndex, isSilence, chunkOffset)`, and `resolvedPosition()` turns `node.playerTime(forNodeTime: node.lastRenderTime).sampleTime` into `(chunk, offset within chunk)`. Chunk-relative, because `WordTiming.start` is. The map resets with `playbackEpoch` on every flush, since `node.stop()` zeroes the node's own sample clock at the same moment.

Two consequences are improvements rather than parity:

- **Silence spans hold the position** at the preceding speech span's end, so a starvation stretch parks the highlight on the last spoken word instead of sliding past it. The wall clock this replaced counted keep-alive silence as spoken time and never recovered.
- **`currentChunkIndex` reports what is *sounding*,** resolved from the clock, rather than what has *finished*, reported by a completion callback. The per-chunk-`AVAudioPlayer` design lagged by the callback latency.

`currentWordIndex()` deliberately takes no time argument: it resolves chunk and offset from a single clock read, so a chunk boundary cannot match the new chunk's offset against the old chunk's timings.

## Consequences

**Leaving the reader no longer stops playback.** `ChapterPlayerView.onDisappear` used to call `stop()`; it can't now, or dismissing the reader would kill the session the floating mini player exists to carry. Playback ends only on an explicit stop, a different book starting, or the end of the current one. Correspondingly, `.onAppear` adopts a session already running on its page instead of restarting it — otherwise opening the reader from the mini player would stop the very audio the user tapped.

**The 0012 limitations disappear** rather than being worked around: the reader follows page turns because there is one `activeRef`; there is one stats session because there is one tracker; there is no mutual exclusion because there is nothing to exclude.

**Read-along inherits background playback.** It was previously the surface that could not survive a lock (no audio session of its own, silence at every chunk boundary). It now runs on the engine built for exactly that.

**Compute units stay `.aneTailCpu`** — the unification request originally included running ANE+GPU in the foreground and switching to ANE+CPU in the background. Rejected on evidence: `KokoroAneComputeUnits` is applied per stage at `MLModel(contentsOf:configuration:)` load time and held as a `private let`, so there is no reconfigure API and switching means rebuilding `KokoroAneManager` and reloading all seven CoreML models on every scene transition. The payoff is small — FluidAudio's comments put the noise stage at "~10% of en synth" with GPU 1.9–3.3× faster on it, and their own field note on the CPU route reads "imperceptible perf cost" — and the cost includes an uncatchable abort: on OS 27+ their `.default` *is* `.aneTailCpu` precisely because the GPU stages "abort intermittently inside MPSGraph under CoreML" in the **foreground** too (#843), on top of the background ban ADR 0011 documented. See ADR 0011, which this leaves standing unchanged.

**Word timings are always derived,** foreground and background alike, which is what makes switching surfaces free: there is no degraded background mode to recover from, and no "restart playback to get highlighting back" path. `ChapterSynthesisService.synthesizeChunkSamples` therefore returns timings alongside samples while preserving its original benefit: raw `[Float]` for the node with no `AudioWAV` round-trip. The retired lab and its WAV-only synthesis entry point were removed after this unified path became the sole production implementation.

**Risk concentrated in the clock.** Everything else here is deletion or plumbing; the sample map is genuinely new and the thing to distrust. Its failure mode is visible rather than silent — the highlight drifting from the voice — which is what makes it testable by hand.
