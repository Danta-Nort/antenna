#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The Antenna mark: the single source of geometry → SVG, PNG icons, geometry for the window (Dart), the site favicon
and OG image.

The geometry is fitted to the original artwork `antenna-logo-source.webp` (1254×1254, raster): every stroke is fitted by
least squares to the smoothed coverage (a straight stroke is a segment with round caps, a wave stroke is a circular
arc with its own center), left/right pairs are averaged and mirrored about the axis x = 627 (the canvas center).
Coordinates are in pixels of the original. Check the match with `python3 build.py --check`.

Run (from any directory):
    pip install --target <scratch>/pylib cairosvg pillow numpy scipy   # no apt needed; requires libcairo2 on the system
    PYTHONPATH=<scratch>/pylib python3 docs/design/logo/build.py          # regenerate everything
    PYTHONPATH=<scratch>/pylib python3 docs/design/logo/build.py --check  # overlay on the original, numbers
"""

from __future__ import annotations

import io
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

# Brand.
BLUE = "#1560F6"  # the dominant color of the original (by pixels); fill of the mark and the icon
WHITE = "#FFFFFF"

# Geometry (left half; the right half is mirrored about AXIS).
AXIS = 627.0
STROKE = 48.3  # waves and tower legs
CROSSBAR_STROKE = 45.6  # the crossbar is noticeably thinner in the original; keep it so
CIRCLE = (AXIS, 366.3, 90.8)  # cx, cy, r
# Waves: (x1, y1, x2, y2, arc radius), top to bottom; the arc bulges outward (away from the tower).
WAVES = [
    (349.7, 98.5, 306.6, 146.1, 699.8),  # outer wave
    (267.7, 208.6, 245.2, 261.2, 509.3),
    (230.1, 333.8, 230.1, 401.2, 376.1),
    (245.3, 474.4, 267.5, 527.4, 532.5),
    (304.6, 590.4, 345.5, 635.1, 709.2),
    (447.6, 200.5, 406.9, 249.6, 340.9),  # inner wave
    (377.4, 318.8, 375.3, 401.9, 211.7),
    (400.7, 474.2, 440.7, 527.5, 267.0),
]
# Tower legs: segments (x1, y1, x2, y2), top to bottom.
LEGS = [
    (598.2, 503.8, 575.8, 560.7),
    (550.9, 630.0, 525.0, 695.2),
    (501.2, 760.3, 475.2, 824.7),
    (450.6, 889.1, 424.9, 951.5),
    (400.8, 1011.1, 375.5, 1071.2),
    (351.5, 1130.8, 325.9, 1192.9),
]
# Crossbar: three strokes along y, centers at AXIS + offset, half the length of the center line.
CROSSBAR_Y = 1009.7
CROSSBAR_HALF = 30.3
CROSSBAR_OFFSETS = (-130.2, 0.0, 130.2)

SOURCE = 1254  # side of the original canvas


def mirror_x(x: float) -> float:
    return round(2 * AXIS - x, 1)


def f(v: float) -> str:
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def dashes():
    """All strokes of the mark: ('arc', x1, y1, x2, y2, r, sweep) and ('line', x1, y1, x2, y2), both halves."""
    out = []
    for x1, y1, x2, y2, r in WAVES:
        out.append(("arc", x1, y1, x2, y2, r, 0))  # left side: from the upper end to the lower one, counterclockwise
        out.append(("arc", mirror_x(x1), y1, mirror_x(x2), y2, r, 1))
    for x1, y1, x2, y2 in LEGS:
        out.append(("line", x1, y1, x2, y2))
        out.append(("line", mirror_x(x1), y1, mirror_x(x2), y2))
    return out


def crossbar():
    return [("line", AXIS + o - CROSSBAR_HALF, CROSSBAR_Y, AXIS + o + CROSSBAR_HALF, CROSSBAR_Y) for o in CROSSBAR_OFFSETS]


def path_d(items) -> str:
    parts = []
    for d in items:
        if d[0] == "arc":
            _, x1, y1, x2, y2, r, sweep = d
            parts.append(f"M{f(x1)} {f(y1)}A{f(r)} {f(r)} 0 0 {sweep} {f(x2)} {f(y2)}")
        else:
            _, x1, y1, x2, y2 = d
            parts.append(f"M{f(x1)} {f(y1)}L{f(x2)} {f(y2)}")
    return "".join(parts)


def mark_elements(color: str) -> str:
    cx, cy, r = CIRCLE
    return (
        f'<g fill="none" stroke="{color}" stroke-linecap="round">'
        f'<path stroke-width="{f(STROKE)}" d="{path_d(dashes())}"/>'
        f'<path stroke-width="{f(CROSSBAR_STROKE)}" d="{path_d(crossbar())}"/>'
        f"</g>"
        f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="{color}"/>'
    )


def mark_bounds() -> tuple[float, float, float, float]:
    """Exact bounds of the mark (including stroke width and arc bulge): x0, y0, x1, y1."""
    xs, ys = [], []
    h = STROKE / 2
    for d in dashes():
        if d[0] == "line":
            _, x1, y1, x2, y2 = d
            pts = [(x1, y1), (x2, y2)]
        else:
            pts = arc_points(*d[1:])
        for x, y in pts:
            xs += [x - h, x + h]
            ys += [y - h, y + h]
    cx, cy, r = CIRCLE
    xs += [cx - r, cx + r]
    ys += [cy - r, cy + r]
    hc = CROSSBAR_STROKE / 2
    for _, x1, y1, x2, y2 in crossbar():
        xs += [x1 - hc, x2 + hc]
        ys += [y1 - hc, y1 + hc]
    return min(xs), min(ys), max(xs), max(ys)


def arc_center(x1, y1, x2, y2, r, sweep):
    mx, my = (x1 + x2) / 2, (y1 + y2) / 2
    dx, dy = x2 - x1, y2 - y1
    q = math.hypot(dx, dy)
    k = math.sqrt(max(r * r - (q / 2) ** 2, 0))
    # SVG: large-arc=0; the center is left/right of the chord depending on sweep
    ux, uy = -dy / q, dx / q
    sign = 1 if sweep == 1 else -1
    return mx + sign * k * ux, my + sign * k * uy


def arc_points(x1, y1, x2, y2, r, sweep, n=24):
    cx, cy = arc_center(x1, y1, x2, y2, r, sweep)
    a1 = math.atan2(y1 - cy, x1 - cx)
    a2 = math.atan2(y2 - cy, x2 - cx)
    da = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
    return [(cx + r * math.cos(a1 + da * i / n), cy + r * math.sin(a1 + da * i / n)) for i in range(n + 1)]


# SVG files.
HEADER = "<!-- Antenna mark. Generated by docs/design/logo/build.py; do not edit by hand. -->"


def svg_mark(color: str) -> str:
    x0, y0, x1, y1 = mark_bounds()
    # viewBox from the mark bounds, symmetric about the axis (clear space: docs/DESIGN.md "Brand")
    half = math.ceil(max(AXIS - x0, x1 - AXIS))
    top, bottom = math.floor(y0), math.ceil(y1)
    vb = f"{f(AXIS - half)} {top} {2 * half} {bottom - top}"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{2 * half / 4:.0f}" '
        f'height="{(bottom - top) / 4:.0f}" role="img" aria-label="Antenna">{HEADER}{mark_elements(color)}</svg>\n'
    )


def svg_icon(rx: float = 0) -> str:
    """The original composition: the mark on a 1254×1254 blue square (rx > 0 rounds the corners, for the favicon)."""
    r = f' rx="{f(rx)}"' if rx else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SOURCE} {SOURCE}" role="img" aria-label="Antenna">'
        f'{HEADER}<rect width="{SOURCE}" height="{SOURCE}"{r} fill="{BLUE}"/>{mark_elements(WHITE)}</svg>\n'
    )


def squircle_d(x: float, y: float, w: float, h: float, radius: float, smoothing: float = 0.6) -> str:
    """A rounded rectangle with continuous corner curvature (like Apple icons; built like Figma's
    "corner smoothing", 60 % ≈ iOS/macOS corners)."""
    p = min((1 + smoothing) * radius, min(w, h) / 2)
    arc_measure = 90 * (1 - smoothing)
    arc_len = math.sin(math.radians(arc_measure / 2)) * radius * math.sqrt(2)
    alpha = (90 - arc_measure) / 2
    p3p4 = radius * math.tan(math.radians(alpha / 2))
    beta = 45 * smoothing
    c = p3p4 * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - arc_len - c - d) / 3
    a = 2 * b
    R = radius
    g = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")  # noqa: E731
    return (
        f"M{g(x + w - p)} {g(y)}"
        f"c{g(a)} 0 {g(a + b)} 0 {g(a + b + c)} {g(d)}"
        f"a{g(R)} {g(R)} 0 0 1 {g(arc_len)} {g(arc_len)}"
        f"c{g(d)} {g(c)} {g(d)} {g(b + c)} {g(d)} {g(a + b + c)}"
        f"L{g(x + w)} {g(y + h - p)}"
        f"c0 {g(a)} 0 {g(a + b)} {g(-d)} {g(a + b + c)}"
        f"a{g(R)} {g(R)} 0 0 1 {g(-arc_len)} {g(arc_len)}"
        f"c{g(-c)} {g(d)} {g(-(b + c))} {g(d)} {g(-(a + b + c))} {g(d)}"
        f"L{g(x + p)} {g(y + h)}"
        f"c{g(-a)} 0 {g(-(a + b))} 0 {g(-(a + b + c))} {g(-d)}"
        f"a{g(R)} {g(R)} 0 0 1 {g(-arc_len)} {g(-arc_len)}"
        f"c{g(-d)} {g(-c)} {g(-d)} {g(-(b + c))} {g(-d)} {g(-(a + b + c))}"
        f"L{g(x)} {g(y + p)}"
        f"c0 {g(-a)} 0 {g(-(a + b))} {g(d)} {g(-(a + b + c))}"
        f"a{g(R)} {g(R)} 0 0 1 {g(arc_len)} {g(-arc_len)}"
        f"c{g(c)} {g(-d)} {g(b + c)} {g(-d)} {g(a + b + c)} {g(-d)}Z"
    )


# macOS icon grid (Big Sur and later): canvas 1024, plate 824×824 with a 100 margin, radius 185.4, shadow under the plate.
MAC_CANVAS, MAC_INSET, MAC_SIDE, MAC_RADIUS = 1024, 100, 824, 185.4
MAC_MARK_HEIGHT = 0.70  # height of the mark as a fraction of the plate side


def mark_transform(box_x: float, box_y: float, box_side: float, height_frac: float) -> str:
    x0, y0, x1, y1 = mark_bounds()
    s = box_side * height_frac / (y1 - y0)
    # Horizontally the mark axis goes to the center; vertically the center of the bounds goes to the plate center
    tx = box_x + box_side / 2 - AXIS * s
    ty = box_y + box_side / 2 - (y0 + y1) / 2 * s
    return f"translate({tx:.2f} {ty:.2f}) scale({s:.5f})"


def svg_app_icon_macos(shadow: bool = True) -> str:
    sq = squircle_d(MAC_INSET, MAC_INSET, MAC_SIDE, MAC_SIDE, MAC_RADIUS)
    flt = (
        '<defs><filter id="s" x="-10%" y="-10%" width="120%" height="125%">'
        '<feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity=".3"/></filter></defs>'
        if shadow
        else ""
    )
    fa = ' filter="url(#s)"' if shadow else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {MAC_CANVAS} {MAC_CANVAS}" role="img" '
        f'aria-label="Antenna">{HEADER}{flt}<path d="{sq}" fill="{BLUE}"{fa}/>'
        f'<g transform="{mark_transform(MAC_INSET, MAC_INSET, MAC_SIDE, MAC_MARK_HEIGHT)}">{mark_elements(WHITE)}</g>'
        f"</svg>\n"
    )


def svg_favicon() -> str:
    """Favicon: the original composition with rounded corners (at 16–32 px the mark is as large as possible)."""
    return svg_icon(rx=SOURCE * 0.2)


# Dart: geometry for the window.
def dart_geometry() -> str:
    x0, y0, x1, y1 = mark_bounds()
    lines = [
        # REUSE-IgnoreStart
        "// SPDX-License-Identifier: AGPL-3.0-only",
        # REUSE-IgnoreEnd
        "// GENERATED by docs/design/logo/build.py. Do not edit by hand. Geometry of the Antenna mark in pixels of the",
        "// 1254×1254 source (docs/design/logo/antenna-logo-source.webp).",
        "",
        "abstract final class LogoGeometry {",
        f"  static const stroke = {STROKE};",
        f"  static const crossbarStroke = {CROSSBAR_STROKE};",
        f"  static const circle = <double>[{CIRCLE[0]}, {CIRCLE[1]}, {CIRCLE[2]}];",
        "",
        "  /// Bounds of the mark including stroke width: x0, y0, x1, y1.",
        f"  static const bounds = <double>[{x0:.2f}, {y0:.2f}, {x1:.2f}, {y1:.2f}];",
        "",
        "  /// Arcs: x1, y1, x2, y2, radius, sweep (1 means clockwise on screen).",
        "  static const arcs = <List<double>>[",
    ]
    for d in dashes():
        if d[0] == "arc":
            lines.append(f"    [{', '.join(str(float(v)) for v in d[1:])}],")
    lines += ["  ];", "", "  /// Straight strokes of the tower: x1, y1, x2, y2.", "  static const lines = <List<double>>["]
    for d in dashes():
        if d[0] == "line":
            lines.append(f"    [{', '.join(str(float(v)) for v in d[1:])}],")
    lines += ["  ];", "", "  /// Crossbar strokes: x1, y1, x2, y2.", "  static const crossbar = <List<double>>["]
    for d in crossbar():
        lines.append(f"    [{', '.join(f'{float(v):.1f}' for v in d[1:])}],")
    lines += ["  ];", "}", ""]
    return "\n".join(lines)


# Raster.
def png(svg: str, size: int, height: int | None = None) -> bytes:
    import cairosvg

    return cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=height or size)


def og_image() -> bytes:
    """Open Graph 1200×630: the icon mark and a product line, light background (site style)."""
    from PIL import Image, ImageDraw, ImageFont

    W, H = 1200, 630
    img = Image.new("RGB", (W, H), "#F5F8FF")
    # A soft light-blue circle at the top right, as on the site
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((760, -260, 1460, 440), fill=(21, 96, 246, 22))
    img.paste(glow, (0, 0), glow)
    icon = Image.open(io.BytesIO(png(svg_icon(rx=SOURCE * 0.22), 260))).convert("RGBA")
    img.paste(icon, (96, 185), icon)
    fonts = ROOT / "apps/antenna_desktop/assets/fonts"
    d = ImageDraw.Draw(img)
    d.text((402, 186), "Antenna", font=ImageFont.truetype(str(fonts / "IBMPlexSans-SemiBold.ttf"), 92), fill="#0B1B3A")
    sub = ImageFont.truetype(str(fonts / "IBMPlexSans-Regular.ttf"), 40)
    d.text((404, 318), "Secure channel and trust layer", font=sub, fill="#33415C")
    d.text((404, 370), "for AI agents", font=sub, fill="#33415C")
    d.text((404, 452), "antenna.contact", font=ImageFont.truetype(str(fonts / "IBMPlexSans-Medium.ttf"), 30), fill=BLUE)
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


def write(path: Path, data: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8")
    else:
        path.write_bytes(data)
    print("  ", path.relative_to(ROOT))


def build() -> None:
    print("SVG:")
    write(HERE / "antenna-mark.svg", svg_mark(WHITE))
    write(HERE / "antenna-mark-blue.svg", svg_mark(BLUE))
    write(HERE / "antenna-icon.svg", svg_icon())
    write(HERE / "antenna-app-icon-macos.svg", svg_app_icon_macos())
    print("PNG for viewing:")
    write(HERE / "png/antenna-icon-1024.png", png(svg_icon(), 1024))
    write(HERE / "png/antenna-app-icon-macos-1024.png", png(svg_app_icon_macos(), 1024))
    write(HERE / "png/antenna-mark-blue-512.png", png(svg_mark(BLUE), *_mark_px(512)))
    print("macOS AppIcon:")
    appicon = ROOT / "apps/antenna_desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        write(appicon / f"app_icon_{s}.png", png(svg_app_icon_macos(), s))
    print("Linux (window icon):")
    write(ROOT / "apps/antenna_desktop/linux/runner/resources/app_icon.png", png(svg_app_icon_macos(shadow=False), 256))
    print("Window (Dart):")
    write(ROOT / "apps/antenna_desktop/lib/theme/logo_geometry.dart", dart_geometry())
    print("Site:")
    pub = ROOT / "site/public"
    write(pub / "favicon.svg", svg_favicon())
    write(pub / "favicon-32.png", png(svg_favicon(), 32))
    write(pub / "apple-touch-icon.png", _opaque(png(svg_icon(), 180)))
    write(pub / "assets/mark-blue.svg", svg_mark(BLUE))
    write(pub / "assets/mark-white.svg", svg_mark(WHITE))
    write(pub / "og.png", og_image())


def _mark_px(height: int) -> tuple[int, int]:
    x0, y0, x1, y1 = mark_bounds()
    half = math.ceil(max(AXIS - x0, x1 - AXIS))
    h = math.ceil(y1) - math.floor(y0)
    return round(height * 2 * half / h), height


def _opaque(data: bytes) -> bytes:
    from PIL import Image

    im = Image.open(io.BytesIO(data)).convert("RGB")
    out = io.BytesIO()
    im.save(out, "PNG", optimize=True)
    return out.getvalue()


# Match check against the original.
def check(overlay: Path | None = None) -> None:
    import numpy as np
    from PIL import Image

    def whiteness(im):
        a = np.asarray(im.convert("RGB")).astype(float)
        blue = np.array([0x15, 0x60, 0xF6], float)
        w = np.array([255, 255, 255], float) - blue
        return np.clip(((a - blue) @ w) / (w @ w), 0, 1)

    src = whiteness(Image.open(HERE / "antenna-logo-source.webp"))
    ours = whiteness(Image.open(io.BytesIO(png(svg_icon(), SOURCE))))
    a, b = src > 0.5, ours > 0.5
    iou = (a & b).sum() / (a | b).sum()
    print(f"IoU (white > 50 %): {iou:.4f}")
    print(f"pixels differing: {(a ^ b).sum()} of {a.sum()} white ({(a ^ b).sum() / a.sum() * 100:.2f} %)")
    print(f"mean |Δ| of coverage over the canvas: {np.abs(src - ours).mean():.4f}")
    try:
        from scipy import ndimage

        def edge(m):
            return m ^ ndimage.binary_erosion(m)

        dt = ndimage.distance_transform_edt(~edge(a))
        dev = dt[edge(b)]
        print(f"contour deviation, px of 1254: median {np.median(dev):.2f}, 99 % {np.percentile(dev, 99):.2f}, "
              f"max {dev.max():.2f}")
    except ImportError:
        pass
    if overlay:
        rgb = np.zeros((SOURCE, SOURCE, 3), np.uint8) + 255
        rgb[a & b] = (150, 150, 150)
        rgb[a & ~b] = (230, 30, 30)  # only in the original
        rgb[~a & b] = (30, 90, 240)  # only in the vector
        Image.fromarray(rgb).save(overlay)
        print("overlay:", overlay)


if __name__ == "__main__":
    if "--check" in sys.argv:
        i = sys.argv.index("--check")
        check(Path(sys.argv[i + 1]) if len(sys.argv) > i + 1 else None)
    elif "--print" in sys.argv:
        print(json.dumps({"bounds": mark_bounds()}, indent=1))
    else:
        build()
