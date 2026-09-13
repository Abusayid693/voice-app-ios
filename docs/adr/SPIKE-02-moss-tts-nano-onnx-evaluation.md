# SPIKE 2. MOSS-TTS-Nano via ONNX Runtime + CoreML/ANE

**Status:** Paused — blocked on a suspected ONNX Runtime external-data path bug, not a decision against the model
**Date:** 2025-09 (branch `moss-tts-nano-prototype`, not merged)

## Goal

Issue #25 asks to evaluate [OpenMOSS-Team/MOSS-TTS-Nano](https://github.com/OpenMOSS/MOSS-TTS-Nano) (0.1B-param, 20-language, Apache-2.0 TTS model) as a possible third engine alongside Kokoro-ANE and Pocket TTS. You asked to actually run it on-device via ONNX Runtime with the CoreML execution provider (how ORT reaches the ANE), to get real CPU-vs-ANE timing rather than reason about it from docs. This is the first ONNX Runtime usage anywhere in this app — everything else runs through FluidAudio/CoreML directly.

## What's verified — reusable by a future attempt without re-deriving it

- **License**: Apache-2.0, confirmed from the real `LICENSE` file in `OpenMOSS/MOSS-TTS-Nano`.
- **Both required ONNX artifact repos exist officially, no PyTorch export needed**:
  [`OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX`](https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX) (the LLM: prefill/decode_step/local_* graphs + `tokenizer.model` + `browser_poc_manifest.json`) and
  [`OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX`](https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX) (the codec: `decode_full`/`decode_step`/`encode`). Total required download for playback-only (no live voice cloning): **~717.5MB**, verified against the real HF file listings byte-for-byte.
- **A working native reference implementation exists and is the best resource for any retry**: `OpenMOSS/MOSS-TTS-Nano`'s own repo ships `examples/android_onnx_runtime/app/src/main/java/com/openmoss/ttsnano/onnxruntime/MossOnnxDemoEngine.kt` — a complete, from-scratch Kotlin/`onnxruntime-android` pipeline. Read in full (not summarized) and ported to Swift 1:1. Key findings baked into the port:
  - Of the 5 shipped TTS graphs, only `prefill`, `decode_step`, and `local_fixed_sampled_frame` are ever called — `local_decoder`/`local_cached_step` are dead weight in the reference.
  - `local_fixed_sampled_frame` handles all 16 RVQ codebook channels in one call (`frame_token_ids`), not a per-channel loop.
  - KV-cache threading: `decode_input_names.drop(2)` (past_key/value names) lines up positionally with `decode_output_names.drop(1)` (present_key/value names) — each step's present output feeds the next step's matching past input.
  - Voice cloning there uses **pre-tokenized reference audio codes baked into the manifest** (`builtin_voices[].prompt_audio_codes`), not live mic encoding — no text tokenizer is exercised on-device anywhere upstream; `DemoPrompts.kt` hardcodes two fixed pre-tokenized sentences instead.
  - Registers no explicit execution provider — plain CPU only. Getting CoreML+ANE working is genuinely new work, not demonstrated upstream on any platform.
- **ONNX Runtime Swift package structure** (`microsoft/onnxruntime-swift-package-manager`, pinned `1.24.2`): the SPM **product** is `"onnxruntime"`, but the importable Swift **module** is the target backing it, `OnnxRuntimeBindings` — `import onnxruntime` fails with "Unable to resolve module dependency"; `import OnnxRuntimeBindings` is correct. Verified every `ORTSession`/`ORTValue`/`ORTSessionOptions`/`ORTCoreMLExecutionProviderOptions` API call against ORT's own tagged Swift test file (`swift/OnnxRuntimeBindingsTests/SwiftOnnxRuntimeBindingsTests.swift`), including `ORTIsCoreMLExecutionProviderAvailable()` as a guard so a CoreML-less build can't silently masquerade as an ANE run.
- **Tokenizer**: no working on-device SentencePiece text tokenizer exists upstream (see above). `jkrukowski/swift-sentencepiece` was tried first but **ships a prebuilt `sentencepiece.xcframework` whose `Headers/module.modulemap` collides with FluidAudio's own bundled xcframework** at the same flattened `Build/Products/<config>/include/module.modulemap` path — a known SPM binary-target packaging class, not specific to these two libraries ("Multiple commands produce..."). Switched to `liuliu/swift-sentencepiece` (pinned by revision `4c8baf1b03569428ab38dda7fdecf27886a16c1f`, no release tags exist), which compiles real SentencePiece C++ source directly — no `.xcframework` in the chain, so it can't collide this way. Its real API: `SentencePiece(file:)` (non-throwing), `encode(_:) -> [(piece: String, id: Int32, surface: String)]`.

## What's built (branch `moss-tts-nano-prototype`, not merged)

`Sources/Features/MossPrototype/` — a standalone benchmark screen (Settings → Experimental), not wired into `Engine`/`VoicePack`/the real voice pickers:
- `Models/MossNanoManifest.swift`, `MossNanoTimings.swift` — Decodable mirrors of the 3 real manifest JSONs; per-stage timing struct + `MossNanoExecutionProvider` (`.cpu`/`.coreMLANE`)
- `Services/MossNanoModelDownloader.swift` — downloads the two HF repos into Application Support
- `Services/MossNanoTokenizer.swift` — wraps `liuliu/swift-sentencepiece`
- `Services/MossNanoTensor.swift` — `ORTValue` ↔ `[Int]`/`[Float]` helpers, dtype-aware on read (doesn't assume a fixed integer width)
- `Services/MossNanoEngineService.swift` — the 4 ORT sessions + KV-cache decode loop, ported from the Android reference
- `ViewModels/MossNanoBenchmarkViewModel.swift`, `Views/MossNanoBenchmarkView.swift` — download/run UI, WAV playback via `AVAudioPlayer`

`project.yml` gained 2 new SPM packages (`onnxruntime` 1.24.2, `SentencePiece` @ the pinned revision above) — this app's first non-FluidAudio dependencies.

## Current blocker

On-device, both execution paths fail:
- **CPU**: crashes.
- **CoreML+ANE**: throws `open file ".../MossTtsNano/tts/moss_tts_prefill.onnx/moss_tts_global_shared.data" failed: Not a directory`.

Root cause traced by reading the raw ONNX protobuf directly (not guessed): the external-weight reference recorded inside `moss_tts_prefill.onnx` is a clean bare filename —
```
location: "moss_tts_global_shared.data"
```
with no directory component, and the model's own filename never appears inside the graph. Per the ONNX external-data spec, that location should resolve relative to the model file's *parent directory*. ONNX Runtime instead appears to be joining it onto the model's *full path*, treating the `.onnx` file itself as a directory — hence "Not a directory."

Attempted fix: ORT exposes `session.model_external_initializers_file_folder_path` (a documented `ORTSessionOptions` config key, set via `addConfigEntry(withKey:value:)`) to pin the external-data folder explicitly instead of deriving it. Implemented per-directory session options (TTS graphs and the codec graph live in different folders, so one shared options object can't carry both paths). **Did not fix it** — same error persisted after this change, and CPU now fails with a crash rather than a clean thrown error (harder failure, not necessarily a different root cause — plausibly the same bug hit on a different, unguarded code path).

Was mid-way through reading ORT's own C++ source (`onnxruntime/core/framework/tensorprotoutils.cc` and related) to confirm exactly when/whether that config key is honored on the file-load path (its doc comment specifically says "when loading model from memory buffer," which may mean it's a no-op for our file-path-based `ORTSession` init) when this spike was paused. No public GitHub issue matching this exact symptom was found in a search pass.

## Next steps for a future attempt

1. Finish reading ORT's C++ source for the exact conditions under which `model_external_initializers_file_folder_path` applies — confirm or rule out the "memory-buffer-only" hypothesis above.
2. If that key genuinely doesn't apply to file-path loading, the more reliable fix is likely restructuring the on-disk layout to match what ORT's default resolution actually expects (which the protobuf inspection didn't fully pin down), or merging external weights back into the `.onnx` files at download time (trading simplicity for the ~717MB staying uncompressed/unsplit).
3. Worth testing whether this is CoreML-EP-specific (the EP partitions the graph, a known place for external-data base paths to get lost) by getting the plain-CPU path working first in isolation before touching CoreML again — the two failure modes (CPU crash vs. CoreML clean-throw) were never conclusively shown to share one root cause, just presumed to.
4. `k2-fsa/sherpa-onnx` was evaluated as an alternative runtime and ruled out for this specific goal: it doesn't support MOSS-TTS-Nano's architecture (open feature request, no maintainer response — [k2-fsa/sherpa-onnx#3652](https://github.com/k2-fsa/sherpa-onnx/issues/3652)), and more fundamentally its CoreML execution provider has never been extended to iOS (open since 2023, filed by its own lead maintainer — [k2-fsa/sherpa-onnx#152](https://github.com/k2-fsa/sherpa-onnx/issues/152)) — so it can't reach the ANE on iOS at all today, which is the entire point of this spike.
5. Branch and all code are preserved as-is (uncommitted) — nothing was deleted. Resuming should start from re-reading this doc plus `MossNanoEngineService.swift`'s `makeSessionOptions`, not from scratch.
