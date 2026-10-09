# 11. Kokoro compute units: keep every stage off the GPU

**Status:** Accepted
**Date:** 2026-09-26

## Context

The goal was continuous listening with the screen locked: start a long text, lock the phone, and have the app keep synthesising and playing chunk after chunk. The app already declares the `audio` background mode, so playback itself is permitted; the open question was whether *synthesis* could keep running.

It cannot, on the routing we were using. A device test produced:

```
IOGPUMetalError: Insufficient Permission (to submit GPU work from background)
(00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)
loc(".../KokoroNoise_v2.mlmodelc/model.mil":127:12):
  error: 'mps.multiply' op operands don't have broadcast-compatible shapes
MPSGraphUtilities.h:165: failed assertion `Type is unranked.'
```

Three things matter in that trace:

1. **iOS refuses Metal work to a backgrounded app.** This is a platform rule, not a bug, and it is **not version gated** — raising the deployment target does nothing. Any Kokoro stage on the GPU simply cannot run once the screen locks.
2. **The failure is not catchable.** The denied command buffer leaves MPSGraph with an unranked type and it trips an assertion, which aborts the process. The app does not log an error and stop; it crashes. No amount of audio-session or buffering work on our side can defend against that.
3. **It was the noise stage.** FluidAudio's `KokoroAneComputeUnits.default` resolves to `aneTailGpu` on the OS 26 line, which places **noise** and **tail (iSTFT)** on `.cpuAndGPU`.

That default is well reasoned for foreground use, and the reasoning is worth preserving because it explains why the obvious "just put everything on the ANE" is not free: both stages are fp32-only graphs, and the ANE is fp16-only. FluidAudio's own note records that `noise` on `.cpuAndNeuralEngine` therefore degenerates to plain CPU anyway, and measured *slower* than asking for `.cpuOnly` outright. The tail is additionally documented as crashing `libBNNS` when placed on CPU/ANE on some builds (their #667), which is why it was pinned to the GPU in the first place.

So the trade is real: the GPU routing is the faster and, historically, the more stable one. It is also the one that makes background synthesis impossible.

## Decision

`DependencyContainer` passes `computeUnits: .aneTailCpu` explicitly to every `KokoroAneManager` it constructs — English (both the bundled-model and fallback paths), Mandarin, and Japanese. Every stage runs on the ANE or the CPU; **no stage runs on the GPU**.

This is not a bespoke configuration. `.aneTailCpu` is one of FluidAudio's own presets, and is what their `.default` already resolves to on OS 27+ — where the GPU stages abort inside MPSGraph under CoreML even in the foreground (their #843, FB24243070). We are adopting that routing early rather than inventing one.

The constant lives as `DependencyContainer.kokoroComputeUnits` so all five construction sites share it and the reasoning sits in one place.

## Consequences

**Foreground synthesis gets slower.** The noise and tail stages lose the GPU across the whole app, not just in the background — this affects ordinary reading, not only the locked case. The production `BookAudioPlayer` logs each chunk as `synthesised in Xs (plays Ys)`, which is the measurement to make before assuming the trade is worth it. If synthesis time approaches playback time, streaming cannot stay ahead and this whole direction is dead regardless of the GPU question.

**Background synthesis becomes possible, not guaranteed.** Removing the GPU removes the hard blocker. Whether synthesis actually outpaces playback on CPU, sustained over ten-plus minutes with thermal throttling and reduced background CPU headroom, is an empirical question this decision does not answer.

**Stability is not improved, and may be worse.** FluidAudio's own comment says the CPU route "is not known to be safe either" (#889), and the SDK logs a warning on this OS line that a BNNS bug can crash Kokoro synthesis *regardless of compute-unit routing*. A future crash on this path would present as `EXC_BAD_ACCESS` in `libBNNS`, which looks nothing like the MPSGraph assertion above — worth knowing so the two are not confused.

**This alone did not give the reader background playback.** Two separate gaps remained in the former `ChapterAudioPlayer`: it did not configure `AVAudioSession`, and it created one `AVAudioPlayer` per chunk, so audio genuinely stopped at every chunk boundary. A long enough silence is itself grounds for suspension. The now-retired `StreamingPlaybackLab` prototyped the alternative — scheduling PCM buffers onto a single `AVAudioPlayerNode`, which is gapless and keeps the node rendering — before that engine was promoted into production.

**Update (2026-09-28):** proven, and promoted — see `docs/adr/0012-two-playback-engines.md`. The prototype engine now backs `BookAudioPlayer` (`Features/Listening/`), a real, shipping feature. The scratch harness was later removed after the unified production player superseded it; see `docs/adr/0013-unified-player.md`.

**The fallback if CPU synthesis proves too slow** is to stop synthesising in the background at all: pre-generate pages with the existing `ChapterSynthesisService.generateAndSave` while the app is in the foreground, then play the merged WAV when locked. Playing a WAV needs no GPU and no inference, so it sidesteps every problem above — at the cost of requiring generation before listening, and auto-advance only reaching pages that were generated ahead of time.
