#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Screenshot of the desktop app for the hero of antenna.contact.

    python3 site/build/screens.py [source.png]

Source: a PNG of the app window, 16:10 (the window is shot at 2160x1350). Default:
site/public/assets/screen-light.png (kept out of the upload by public/.assetsignore).

Writes three WebP files next to it, for the <img srcset> in index.html:
    screen-light.webp       2160 px  (also the img src)
    screen-light-1440.webp  1440 px
    screen-light-720.webp    720 px
Quality starts at 85 and steps down (to 70 at most) until a file fits BUDGET; the result is
printed. Needs Pillow with WebP support.
"""
import sys
from pathlib import Path

from PIL import Image

PUBLIC = Path(__file__).resolve().parent.parent / "public" / "assets"
DEFAULT_SRC = PUBLIC / "screen-light.png"
# (width, file name) — keep in sync with srcset/sizes in public/index.html
OUTPUTS = [(2160, "screen-light.webp"), (1440, "screen-light-1440.webp"), (720, "screen-light-720.webp")]
RATIO = 16 / 10
BUDGET = 250 * 1024
QUALITIES = (85, 80, 75, 70)


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
    img = Image.open(src)
    img.load()
    w, h = img.size
    if abs(w / h - RATIO) > 0.005:
        print(f"screens: {src} is {w}x{h}, expected 16:10 (index.html reserves 2160x1350)", file=sys.stderr)
        return 1
    if w < OUTPUTS[0][0]:
        print(f"screens: {src} is {w} px wide, need at least {OUTPUTS[0][0]}", file=sys.stderr)
        return 1
    img = img.convert("RGB")  # the screenshot has no transparency; RGB keeps WebP smaller
    over = False
    for width, name in OUTPUTS:
        height = round(width / RATIO)
        frame = img if (w, h) == (width, height) else img.resize((width, height), Image.LANCZOS)
        out = PUBLIC / name
        for q in QUALITIES:
            frame.save(out, "WEBP", quality=q, method=6)
            size = out.stat().st_size
            if size <= BUDGET:
                break
        over |= size > BUDGET
        flag = "  OVER BUDGET" if size > BUDGET else ""
        print(f"screens: {name:24} {width}x{height}  q={q}  {size / 1024:.0f} KB{flag}")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
