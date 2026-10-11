#!/usr/bin/env python3
"""Generates app-stack.png — the README's overlapping screenshot fan.

GitHub's README sanitizer strips `style` attributes from HTML, so the live
negative-spacing/opacity/z-index stack this mimics (SettingsSheet.swift's
`voiceGallery`, "YOUR VOICE") can't be reproduced with markup alone. This
bakes the same arrangement into one flattened, transparent PNG instead.

Run from this directory: python3 generate-stack.py
Requires Pillow (`pip install pillow`).

Mirrors `voiceGallery`'s own numbers directly rather than inventing new
ones — re-run this if that function's sizes/opacities ever change:
  gallerySize(distance):    0->92  1->76  2->62  (ratios: 1, .826, .674)
  galleryOpacity(distance): 0->1   1->.90 2->.74
Five images, not the UI's seven (-3...3): a symmetric 7-wide fan needs an
odd count with a single true center, which only 5 of the 6 About
screenshots can give without dropping one twice. "Book Detail" is the one
left out — My Shelf already carries the shelf/book context, and the
remaining five (shelf, library, reading, listening, stats) span the app's
other core surfaces with no overlap in subject.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).parent

# distance-from-center -> (source file, size ratio, opacity), left to right.
# Matches voiceGallery's own ordering: centre is the hero, symmetric pairs
# step outward at the same two size/opacity tiers it uses.
ITEMS = [
    ("about-now-playing.jpg", 2, 0.674, 0.74),
    ("about-library.jpg", 1, 0.826, 0.90),
    ("about-shelf.jpg", 0, 1.000, 1.00),
    ("about-reader.jpg", 1, 0.826, 0.90),
    ("about-stats.jpg", 2, 0.674, 0.74),
]

CENTER_WIDTH = 220  # design points; matches the README table's own <img width>
OVERLAP_RATIO = 0.26  # ~voiceGallery's -24pt over its 92pt centre avatar
CORNER_RADIUS_RATIO = 19.8 / 118.8  # ScreenshotMarquee's own cornerRadius:cardWidth
BORDER_OPACITY = 0.14
SHADOW_OPACITY = 0.30
SHADOW_BLUR = 18
SHADOW_OFFSET_Y = 10
MARGIN = 56
RENDER_SCALE = 3  # supersample, then downsample for clean antialiasing


def rounded_card(src: Image.Image, width: int, height: int, radius: int) -> Image.Image:
    """Source image scaled to fill (width, height), rounded-rect clipped,
    with a faint border — the same treatment `ScreenshotMarquee` draws for
    every card in the live app."""
    fitted = scale_fill(src, width, height)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, height - 1], radius, fill=255)
    card = Image.new("RGBA", (width, height))
    card.paste(fitted, (0, 0), mask)
    border = Image.new("RGBA", (width, height))
    ImageDraw.Draw(border).rounded_rectangle(
        [0, 0, width - 1, height - 1], radius, outline=(0, 0, 0, int(255 * BORDER_OPACITY)),
        width=max(1, width // 160))
    card.alpha_composite(border)
    return card


def scale_fill(src: Image.Image, width: int, height: int) -> Image.Image:
    src_ratio = src.width / src.height
    target_ratio = width / height
    if src_ratio > target_ratio:
        new_height = height
        new_width = round(height * src_ratio)
    else:
        new_width = width
        new_height = round(width / src_ratio)
    resized = src.convert("RGBA").resize((new_width, new_height), Image.LANCZOS)
    left = (new_width - width) // 2
    top = (new_height - height) // 2
    return resized.crop((left, top, left + width, top + height))


def drop_shadow(width: int, height: int, radius: int) -> Image.Image:
    pad = SHADOW_BLUR * 3
    canvas = Image.new("RGBA", (width + pad * 2, height + pad * 2))
    ImageDraw.Draw(canvas).rounded_rectangle(
        [pad, pad, pad + width - 1, pad + height - 1], radius,
        fill=(0, 0, 0, int(255 * SHADOW_OPACITY)))
    return canvas.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))


def main() -> None:
    height_ratio = None
    cards: list[tuple[Image.Image, int]] = []  # (card, z-order key)
    positions: list[tuple[int, int]] = []  # left x, top y per card (centre line aligned)

    sizes = []
    for filename, distance, ratio, opacity in ITEMS:
        src = Image.open(HERE / filename)
        if height_ratio is None:
            height_ratio = src.height / src.width
        width = round(CENTER_WIDTH * ratio)
        height = round(width * height_ratio)
        sizes.append((filename, distance, width, height, opacity))

    # Lay cards left to right with proportional overlap, then centre the
    # whole row vertically against the tallest (centre) card.
    x = 0
    xs = []
    for i, (_, _, width, _, _) in enumerate(sizes):
        if i > 0:
            prev_width = sizes[i - 1][2]
            overlap = round(OVERLAP_RATIO * min(prev_width, width))
            x -= overlap
        xs.append(x)
        x += width
    total_width = x
    max_height = max(h for *_, h, _ in [(f, d, w, h, o) for f, d, w, h, o in sizes])

    canvas_w = total_width + MARGIN * 2
    canvas_h = max_height + MARGIN * 2
    scale = RENDER_SCALE
    canvas = Image.new("RGBA", (canvas_w * scale, canvas_h * scale))

    # Paint back-to-front by z (SwiftUI's zIndex = 4 - distance): farthest
    # pairs first, nearest pairs next, centre last — so inner cards sit
    # visually on top of outer ones, exactly like voiceGallery.
    order = sorted(range(len(sizes)), key=lambda i: -sizes[i][1])
    for i in order:
        filename, distance, width, height, opacity = sizes[i]
        radius = max(2, round(width * CORNER_RADIUS_RATIO))
        src = Image.open(HERE / filename)
        card = rounded_card(src, width * scale, height * scale, radius * scale)
        if opacity < 1:
            alpha = card.split()[3].point(lambda a, o=opacity: int(a * o))
            card.putalpha(alpha)

        shadow = drop_shadow(width * scale, height * scale, radius * scale)
        left = xs[i] + MARGIN
        top = MARGIN + (max_height - height) // 2
        shadow_pad = SHADOW_BLUR * 3
        canvas.alpha_composite(
            shadow,
            (left * scale - shadow_pad, (top + SHADOW_OFFSET_Y) * scale - shadow_pad))
        canvas.alpha_composite(card, (left * scale, top * scale))

    final = canvas.resize((canvas_w, canvas_h), Image.LANCZOS)
    out_path = HERE / "app-stack.png"
    final.save(out_path, optimize=True)
    print(f"wrote {out_path.name}: {final.width}x{final.height}px, "
          f"{out_path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
