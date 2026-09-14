#!/usr/bin/env python3
"""Converts hexgrad/Kokoro-82M's hf_/hm_ voice tensors (.pt) into the raw
[510, 256] fp32 .bin format the bundled English Kokoro-ANE pack expects —
same recipe as docs/adr/0002-custom-kokoro-model-bundle.md and
model-conversion/kokoro-mandarin-voices/.

These 4 are real Hindi-trained voices (see FluidInference/FluidAudio#920),
but FluidAudio's Swift port has no Hindi text frontend yet — added here as
extra English-phoneme voices with an Indian-accented timbre, same
category as the bf_/bm_ (British) voices already in the English roster.

Usage:
    python3 convert_voices.py

Reads every .pt file in ./pt/, writes the converted .bin to ./bin/.
Output then gets copied flat into
local-tts/native-ios/CustomKokoroModel/kokoro-82m-coreml/ANE/ (gitignored,
regeneratable — see ADR 2).
"""

from pathlib import Path

import numpy as np
import torch

SCRIPT_DIR = Path(__file__).resolve().parent
PT_DIR = SCRIPT_DIR / "pt"
BIN_DIR = SCRIPT_DIR / "bin"

VOICE_NAMES = ["hf_alpha", "hf_beta", "hm_omega", "hm_psi"]


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
