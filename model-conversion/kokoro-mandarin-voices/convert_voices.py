#!/usr/bin/env python3
"""Converts hexgrad/Kokoro-82M's official Mandarin voice tensors (.pt) into
the raw [510, 256] fp32 .bin format Sources/App/DependencyContainer.swift's
KokoroAneManager expects — the same recipe docs/adr/0002-custom-kokoro-model-bundle.md
already documents for English's 28 voices, applied here to the 8 officially
graded Mandarin voices (zf_xiaobei/zf_xiaoni/zf_xiaoxiao/zf_xiaoyi,
zm_yunjian/zm_yunxi/zm_yunxia/zm_yunyang — see hexgrad/Kokoro-82M's own
VOICES.md; all graded "D" overall / thin training data, but these are the
only Mandarin voices hexgrad itself names and ships tensors for).

Chosen over FluidAudio's own ANE-zh/voices/ (100 numbered zf_NNN/zm_NNN
files) because that numbered set's provenance is undocumented — it doesn't
match hexgrad's own voice list, and traces instead to a third-party
project (ardorleo/kokoro-tts-zh) with no disclosed speaker/dataset source.
These 8 are the ones hexgrad itself documents and grades.

Usage:
    python3 convert_voices.py

Reads every .pt file in ./pt/, writes the converted .bin to ./bin/.
Requires: torch, numpy (no huggingface_hub needed — .pt files are already
downloaded into ./pt/ via a plain HTTPS resolve:// fetch, not the hub API).
"""

import os
from pathlib import Path

import numpy as np
import torch

SCRIPT_DIR = Path(__file__).resolve().parent
PT_DIR = SCRIPT_DIR / "pt"
BIN_DIR = SCRIPT_DIR / "bin"

VOICE_NAMES = [
    "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
    "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
]


def main() -> None:
    BIN_DIR.mkdir(exist_ok=True)
    for name in VOICE_NAMES:
        pt_path = PT_DIR / f"{name}.pt"
        if not pt_path.exists():
            print(f"skip {name}: {pt_path} not found")
            continue
        tensor = torch.load(pt_path, map_location="cpu", weights_only=True)
        arr = tensor.numpy().astype(np.float32)
        if arr.size != 510 * 256:
            raise ValueError(f"{name}: expected 510*256={510*256} elements, got {arr.size}")
        reshaped = arr.reshape(510, 256)
        out_path = BIN_DIR / f"{name}.bin"
        out_path.write_bytes(reshaped.tobytes())
        print(f"{name}: {pt_path.stat().st_size} bytes (.pt) -> {out_path.stat().st_size} bytes (.bin)")


if __name__ == "__main__":
    main()
