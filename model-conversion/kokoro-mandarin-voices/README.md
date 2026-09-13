# Kokoro Mandarin voice conversion (zf_xiaobei / zm_yunjian / …)

One-time conversion of hexgrad/Kokoro-82M's 8 officially-named Mandarin
voices from their raw `.pt` tensors into the `.bin` format
`KokoroAneManager` expects, mirroring the recipe
`docs/adr/0002-custom-kokoro-model-bundle.md` already documents for
English's 28 voices.

## Why these 8, not FluidAudio's 100 numbered voices

FluidAudio's own hosted repo (`FluidInference/kokoro-82m-coreml/ANE-zh/voices/`)
ships 100 numbered voices (`zf_001`…`zf_099`, `zm_009`…`zm_100`). Their
provenance is undocumented — they don't match hexgrad's own official voice
list at all, and trace instead to a third-party project
(`ardorleo/kokoro-tts-zh`) with no disclosed speaker/dataset source, so
there's no way to confirm they're genuinely distinct voices rather than
duplicates/synthetic variants.

hexgrad/Kokoro-82M's own `VOICES.md` documents exactly 8 Mandarin voices —
`zf_xiaobei`, `zf_xiaoni`, `zf_xiaoxiao`, `zf_xiaoyi`, `zm_yunjian`,
`zm_yunxi`, `zm_yunxia`, `zm_yunyang` — all graded **"D" overall / thin
training data**, but these are the ones hexgrad itself names, grades, and
ships tensors for.

## Contents

- `pt/` — the 8 raw voice tensors, downloaded from
  `https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/<name>.pt`
  (plain HTTPS `resolve`, not the hub API — no `huggingface_hub` dependency).
- `convert_voices.py` — reads `pt/`, writes the converted `[510, 256]` fp32
  raw `.bin` files to `bin/`.
- `bin/` — the conversion output; these are what actually get bundled into
  the app (see `Sources/App/DependencyContainer.swift` /
  `docs/adr/0002-custom-kokoro-model-bundle.md`'s bundling convention).

## Regenerating

```
pip install torch numpy
python3 convert_voices.py
```

## Provenance

- Source repo: https://huggingface.co/hexgrad/Kokoro-82M
- Voice list/grades: https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
- Downloaded: 2026-09-13
