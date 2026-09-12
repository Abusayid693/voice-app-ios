# 2. Bundle a custom multi-voice Kokoro-ANE model set

**Status:** Accepted
**Date:** 2025-09

## Context

FluidAudio's own hosted HF repo only publishes one voice per language (`af_heart` English / `zf_001` Mandarin) — their docs call this a hard model-conversion constraint. Direct verification against the SDK source showed that's not true at the architecture level: Kokoro-ANE's 7-stage CoreML chain (Albert→PostAlbert→Alignment→Prosody→Noise→Vocoder→Tail) is voice-agnostic. `Albert`, `Alignment`, and `Tail` never touch voice data at all; `PostAlbert`/`Prosody` take `style_s` and `Noise`/`Vocoder` take `style_timbre` as plain runtime tensor inputs, not anything baked into compiled weights.

## Decision

Ship a custom-bundled model set (`local-tts/native-ios/CustomKokoroModel/`, gitignored, ~93MB, fully regeneratable) holding all 7 real FluidAudio stages plus all 28 standard Kokoro-82M English voice `.bin` files, extracted directly from the upstream PyTorch checkpoint (no CoreML reconversion needed — voice data is a plain runtime tensor). `DependencyContainer.kokoroManager` points at this bundle instead of the default download location.

**Regeneration recipe** — needed on a fresh clone, since the folder is gitignored:

Model stages + vocab (note the `_v2` suffixes on Noise/Tail — required exact filenames, and genuine upstream bug fixes: Noise_v2 fixes an atan2 phase-correction artifact, Tail_v2 fixes COLA-normalized iSTFT weights, since the un-fixed version's raw output is exactly 1.5x too loud):
```python
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="FluidInference/kokoro-82m-coreml",
    allow_patterns=[
        "ANE/KokoroAlbert.mlmodelc/*", "ANE/KokoroPostAlbert.mlmodelc/*",
        "ANE/KokoroAlignment.mlmodelc/*", "ANE/KokoroProsody.mlmodelc/*",
        "ANE/KokoroNoise_v2.mlmodelc/*", "ANE/KokoroVocoder.mlmodelc/*",
        "ANE/KokoroTail_v2.mlmodelc/*", "ANE/vocab.json",
    ],
)
```
`huggingface_hub` caches via symlinks into a shared blob store — copy with `cp -RL` (dereference) when moving into the project, or the bundled app ships broken links.

Voice packs (28 English voice names in `TTSViewModel.kokoroVoices`):
```python
import torch, numpy as np
from huggingface_hub import hf_hub_download
path = hf_hub_download(repo_id="hexgrad/Kokoro-82M", filename=f"voices/{name}.pt")
arr = torch.load(path, map_location="cpu", weights_only=True).numpy().astype(np.float32).reshape(510, 256)
open(f"{name}.bin", "wb").write(arr.tobytes())
```
Drop all of the above (7 `.mlmodelc` dirs + `vocab.json` + `*.bin` files) flat into `CustomKokoroModel/kokoro-82m-coreml/ANE/`.

## Consequences

Two non-obvious integration details required for this to run on-device:
- `project.yml` bundles `CustomKokoroModel/` with an explicit `type: folder` resource entry — makes Xcode copy it as one atomic directory (preserving each `.mlmodelc`'s internal structure) rather than risking it getting flattened by the default source-scanning behavior.
- The installed `.app` bundle is read-only at runtime, but CoreML's ANE compilation step needs to *write* analytics/cache data into a model's folder the first time it loads. `DependencyContainer` copies the bundled folder into `Application Support` (writable) once on first launch, and points `KokoroAneManager(directory:)` at that copy. Locate the bundled folder via `Bundle.main.bundleURL.appendingPathComponent(...)`, not `Bundle.main.url(forResource:withExtension:)` — the latter proved unreliable for this folder reference on-device.

A related bug this surfaced: `KokoroEngineService.ensureModels()` was once calling the SDK's resource downloader with no `directory:` override, checking/downloading into FluidAudio's *default* cache path instead of the bundled-copy directory — on a genuinely fresh install this could have triggered an unnecessary ~93MB network download of the stock single-voice repo. Fixed by threading `kokoroModelDirectory: URL?` from `DependencyContainer` through `KokoroEngineService`'s initializer into `ensureModels(directory:)`.
