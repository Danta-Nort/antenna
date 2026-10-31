#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""The README's animated tour, docs/design/tour.gif, made from the window's own golden frames (docs/design/screens/),
never from hand-made screenshots: invite, the spoken code, the one-button confirm, AI apps, a conversation, an agent at
work in Code mode. Run after the goldens change:  python3 tools/readme_tour.py   (needs Pillow)."""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ["06_invite_link_qr", "07_invite_code_emoji", "42_invite_confirm_button", "37_ai_apps", "04_home_chat",
          "34_code_mode"]
DURATIONS_MS = [2600, 2600, 2600, 2600, 2600, 4000]
SIZE = (960, 600)

ims = [Image.open(ROOT / "docs/design/screens" / f"{f}.png").convert("RGB").resize(SIZE, Image.LANCZOS) for f in FRAMES]
# One palette for every frame (the last one has the most colours): no flicker between frames, no dithering noise.
pal = ims[-1].quantize(colors=255, method=Image.Quantize.MEDIANCUT)
q = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in ims]
out = ROOT / "docs/design/tour.gif"
q[0].save(out, save_all=True, append_images=q[1:], duration=DURATIONS_MS, loop=0, optimize=True)
print(f"{out.relative_to(ROOT)}: {len(q)} frames, {out.stat().st_size // 1024} KB")
