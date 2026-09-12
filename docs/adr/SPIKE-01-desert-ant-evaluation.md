# SPIKE 1. Desert Ant SDK — potential features for Voicenote

**Status:** Exploratory — no decision made, not started
**Date:** 2025-09

Source: https://desertant.com/docs/ (Swift/Kotlin/JS SDKs, on-device AI models). Evaluated for fit against Voicenote (the Expo voice-note app), not this TTS test harness — everything here is on the STT/post-processing side, complementary to FluidAudio's TTS engines rather than overlapping.

## High value

### Voz — on-device transcription
- Converts audio → text with word-level timestamps, fully on-device (no cloud).
- 467 MB model, 25 languages (no auto-detect), ~290x real-time on long files.
- Word error rate 7.40% (vs. Whisper large-v3-turbo's 7.00%), timestamp accuracy ~83–95ms mean absolute error.
- API sketch: `let voz = try await Voz()`, `let result = try await voz.transcribe(url)`, `result.text`, `result.words[i].start`. Optional `Voz.download()` to avoid a 20s Neural Engine specialization delay on first use.
- **Fit**: this is the core "transcribe the note" feature if Voicenote doesn't already have on-device STT.

### Align — timestamp refinement
- Refines Apple's own SpeechAnalyzer word timestamps; ~60% error reduction vs. raw Apple output.
- Two-stage coarse-to-fine cascade, ~117k params/stage, tiny footprint (~0.3MB weights/stage + ~40KB mel filters + ~70KB calibrator). iOS 26+ only.
- Supports English, Spanish, French, Italian, Portuguese, German, Japanese, Korean, Chinese.
- API sketch: `let refiner = try await SpeechTimestampRefiner(locale: locale)`, attached to an analyzer, output via `result.words: [WordTiming]`.
- **Fit**: only relevant if Voicenote uses Apple's built-in SpeechAnalyzer rather than Voz — Voz already produces its own timestamps directly.

### Clear — audio enhancement
- On-device denoising/enhancement, no cloud processing.
- **Fit**: useful for notes recorded in noisy environments before transcription or playback.

### Uhm — filler-word detection
- Detects filler words ("uh", "um", "hmm") directly from **raw audio** — no transcript or Voz dependency needed. Internally resamples to 16kHz, processes in 30s windows, 20ms-resolution frame predictions.
- Output: timestamped spans (start/end/confidence) — **flags positions only, does not cut/edit audio itself**. Actual trimming (e.g. via AVFoundation) is on the app side.
- ~45MB Core ML. English-trained only; other-language accuracy unverified ("acoustic transfer").
- API sketch: `let uhm = Uhm()`, `let result = try await uhm.analyze(audioPath:)`, `result.fillers[i].start/.end/.confidence`.
- **Fit**: pairs with Clear as a standalone "better audio" pipeline independent of transcription — Clear denoises, Uhm locates filler words, app splices them out. Also useful as a polish pass on top of a Voz transcript (mark filler words in the text too).

### Redact — on-device PII filtering
- Filters personally identifiable information, on-device.
- **Fit**: relevant if notes are ever shared or exported and a privacy pass is wanted.

## Lower priority

- **Title** — auto-generates titles/descriptions. Useful for a searchable note library view.
- **Gist** — topic tagging. Also useful for search/organization.
- **Tongue** / **Ear** — language identification from text or a 30s audio sample. Only useful if Voicenote needs to auto-pick a transcription language.
- **Emo** — emoji suggestions. Doesn't fit a voice-note product.
- **Clips** — video clip/highlight creation. Not applicable (Voicenote is audio-only).
- **Shapes** — sketch-to-shape recognition. Not applicable.

## Upcoming (beta, per docs)

Content moderation, structured JSON extraction, image/video analysis, speaker identification, face recognition, hate speech detection — none currently relevant to Voicenote.

## Combinations worth calling out

- **Clear + Uhm** — a standalone "better audio" pipeline, no transcription needed: enhance the recording, then locate (and app-side splice out) filler words. Good fit for a one-tap "clean up this note" action on the audio itself.
- **Clear + Voz + Uhm** — full pipeline: enhance audio → transcribe (higher accuracy on cleaned input) → flag fillers in both the transcript and, via Voz's word timestamps, the audio. Gives both a polished transcript and an optional polished audio cut, at the cost of chaining three on-device models (latency/footprint stack — background processing, not live).

## Recommended next step

Same validation pattern already used for FluidAudio in this repo (ADR 1): pull the actual SDK, verify claims (WER, model size, on-device ANE behavior) against real code and real-device testing rather than trusting docs alone, before committing to it in Voicenote. Voz is the natural first candidate to test standalone, since transcription is the highest-value addition and the docs' WER/speed claims are worth independently confirming.
