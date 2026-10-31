#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Turn the drawn profile picture sets into the window's assets.

The originals are large square PNGs kept outside the repository, one folder per set:

    <src>/set1/01-fox.png, <src>/set1/02-owl.png, ...      (the number orders the grid; the word is the animal id)
    <src>/set2/...
    <src>/covers/01-cloud.png, 02-moon.png, ...             (optional: one icon per set, by the set's number)

For every set this writes, under apps/antenna_desktop/assets/avatars/:

    <set>/<animal>-512.webp and <set>/<animal>-128.webp    square, metadata stripped, ≤ 60 KB at 512 px
    <set>/cover-128.webp                                   the set's icon for the picker's tabs, transparency kept
    sets.json                                              the manifest: sets, their animals and English names

and keeps the window's other inputs in step:

    pubspec.yaml      one asset folder per set
    app_en.arb        the `pictureSet` and `pictureAnimal` select messages (English names)
    app_ru.arb        the same messages in Russian: an animal or set without a Russian name stops the run until it is
                      given with --ru <id>=<name> (the repository keeps Russian only in the Russian localization)

then runs `flutter gen-l10n` when Flutter is found. Adding a set is dropping its folder next to the others and running

    python3 tools/avatars.py --src <folder with set1, set2, ...>

Only files named `NN-<animal>.png` (or .jpg/.webp) are taken; anything else in a set folder is ignored.
`--check` verifies the committed assets against the manifest without the originals (sizes, metadata, files).
"""

import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "antenna_desktop"
OUT = APP / "assets" / "avatars"
PUBSPEC = APP / "pubspec.yaml"
ARB_EN = APP / "lib" / "l10n" / "app_en.arb"
ARB_RU = APP / "lib" / "l10n" / "app_ru.arb"

SIZES = (512, 128)
MAX_BYTES = {512: 60 * 1024, 128: 12 * 1024}
COVER = "cover-128.webp"
COVER_SIDE = 128
COVER_MAX = 16 * 1024
SET_ID = re.compile(r"^set[0-9]{1,3}$")
ANIMAL_ID = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
SOURCE = re.compile(r"^(\d{1,3})-([a-z][a-z0-9-]{0,31})\.(png|jpe?g|webp)$", re.I)
# English names of the sets the maintainer planned; a set not listed here is named "Set N" until renamed in app_en.arb.
SET_NAMES = {"set1": "Soft", "set2": "Modern", "set3": "Playful"}
PUBSPEC_MARK = "    # Profile pictures (tools/avatars.py): the manifest and one folder per set.\n"


def need_pillow():
    try:
        from PIL import Image, features  # noqa: F401
    except ImportError:
        sys.exit("tools/avatars.py needs Pillow (python3 -m pip install pillow)")
    if not features.check("webp"):
        sys.exit("this Pillow has no WebP support")


def sources(src: Path) -> "OrderedDict[str, list[tuple[int, str, Path]]]":
    """Set id → [(order, animal id, path)] from the originals' folder, sets and animals in their order."""
    sets = OrderedDict()
    for d in sorted(p for p in src.iterdir() if p.is_dir() and SET_ID.match(p.name)):
        items = []
        seen = set()
        for f in sorted(d.iterdir()):
            m = SOURCE.match(f.name)
            if not m or not f.is_file():
                continue
            animal = m.group(2).lower()
            if animal in seen:
                sys.exit(f"{d.name}: two files for '{animal}'")
            seen.add(animal)
            items.append((int(m.group(1)), animal, f))
        if items:
            items.sort(key=lambda t: (t[0], t[1]))
            sets[d.name] = items
    return sets


def covers(src: Path) -> dict:
    """Set id → the path of its cover icon: `<src>/covers/NN-<name>.png`, NN being the set's number."""
    d = src / "covers"
    out = {}
    if not d.is_dir():
        return out
    for f in sorted(d.iterdir()):
        m = SOURCE.match(f.name)
        if m and f.is_file():
            out[f"set{int(m.group(1))}"] = f
    return out


def encode_cover(path: Path) -> bytes:
    """The cover at COVER_SIDE with its transparency (WebP with alpha), no metadata, at most COVER_MAX bytes."""
    from PIL import Image

    with Image.open(path) as im:
        im.load()
        img = square(im.convert("RGBA")).resize((COVER_SIDE, COVER_SIDE), Image.LANCZOS)
    for q in range(92, 39, -4):
        buf = io.BytesIO()
        img.save(buf, "WEBP", quality=q, alpha_quality=100, method=6)
        if len(buf.getvalue()) <= COVER_MAX:
            return buf.getvalue()
    sys.exit(f"cannot fit the cover {path.name} into {COVER_MAX} bytes")


def square(img):
    """Center square crop (the originals are square already; anything else is cropped, never stretched)."""
    w, h = img.size
    s = min(w, h)
    left, top = (w - s) // 2, (h - s) // 2
    return img.crop((left, top, left + s, top + s))


def encode(img, side: int) -> bytes:
    """A side×side WebP with no metadata (no EXIF, XMP or ICC: Pillow writes only what it is given), the best quality
    that fits MAX_BYTES[side]."""
    from PIL import Image

    small = img.resize((side, side), Image.LANCZOS)
    for q in range(92, 39, -4):
        buf = io.BytesIO()
        small.save(buf, "WEBP", quality=q, method=6)
        data = buf.getvalue()
        if len(data) <= MAX_BYTES[side]:
            return data
    sys.exit(f"cannot fit a {side} px picture into {MAX_BYTES[side]} bytes")


def load(path: Path):
    from PIL import Image

    with Image.open(path) as im:
        im.load()
        # Composite transparency over white: a picture is always drawn on a full tile.
        if im.mode in ("RGBA", "LA", "P"):
            rgba = im.convert("RGBA")
            bg = Image.new("RGB", rgba.size, (255, 255, 255))
            bg.paste(rgba, mask=rgba.split()[3])
            return square(bg)
        return square(im.convert("RGB"))


def title(animal: str) -> str:
    return " ".join(w.capitalize() for w in animal.split("-"))


def set_title(set_id: str) -> str:
    return SET_NAMES.get(set_id, "Set " + set_id[3:])


# ARB select messages ------------------------------------------------------------------------------------------------

SELECT = re.compile(r"^\{(\w+), select, (.*)\}$", re.S)
CASE = re.compile(r"\s*([a-z0-9_-]+)\{([^{}]*(?:\{\w+\}[^{}]*)*)\}")


def parse_select(msg: str) -> "OrderedDict[str, str]":
    m = SELECT.match(msg or "")
    out = OrderedDict()
    if not m:
        return out
    for c in CASE.finditer(m.group(2)):
        if c.group(1) != "other":
            out[c.group(1)] = c.group(2)
    return out


def build_select(arg: str, cases: "OrderedDict[str, str]") -> str:
    # ICU select keys are identifiers: a hyphenated animal id cannot be a case, so it is written with "_".
    body = " ".join(f"{k.replace('-', '_')}{{{v}}}" for k, v in cases.items())
    return f"{{{arg}, select, {body} other{{{{{arg}}}}}}}"


def update_arb(path: Path, key: str, arg: str, wanted: "OrderedDict[str, str]", description: str | None) -> bool:
    """Write the select message `key` with the `wanted` cases (id → name); returns whether the file changed. Only the
    message's own line changes (or the message is appended with its description): the rest of the hand-formatted
    file stays byte for byte."""
    text = path.read_text(encoding="utf-8")
    value = json.dumps(build_select(arg, wanted), ensure_ascii=False)
    line = re.compile(r'^  "' + re.escape(key) + r'": "(?:[^"\\]|\\.)*"(,?)$', re.M)
    m = line.search(text)
    if m:
        new = text[:m.start()] + f'  "{key}": {value}{m.group(1)}' + text[m.end():]
    else:
        end = text.rstrip().rfind("}")
        body = text[:end].rstrip()
        add = f',\n  "{key}": {value}'
        if description is not None:
            add += (f',\n  "@{key}": {{\n    "description": {json.dumps(description, ensure_ascii=False)},\n'
                    f'    "placeholders": {{\n      "{arg}": {{"type": "String"}}\n    }}\n  }}')
        new = body + add + "\n}\n"
    json.loads(new)
    if new != text:
        path.write_text(new, encoding="utf-8")
    return new != text


def arb_cases(path: Path, key: str) -> "OrderedDict[str, str]":
    data = json.loads(path.read_text(encoding="utf-8"))
    return OrderedDict((k.replace("_", "-"), v) for k, v in parse_select(data.get(key, "")).items())


def localize(sets, ru_given: dict) -> None:
    """Keep the names in both ARB files in step with the sets; stop if a Russian name is missing."""
    en_animals = arb_cases(ARB_EN, "pictureAnimal")
    ru_animals = arb_cases(ARB_RU, "pictureAnimal")
    en_sets = arb_cases(ARB_EN, "pictureSet")
    ru_sets = arb_cases(ARB_RU, "pictureSet")
    animals = OrderedDict()
    for items in sets.values():
        for _, a, _ in items:
            animals.setdefault(a, None)
    missing = []
    want_en, want_ru = OrderedDict(), OrderedDict()
    for a in animals:
        want_en[a] = en_animals.get(a, title(a))
        ru = ru_given.get(a, ru_animals.get(a))
        if ru is None:
            missing.append(a)
        else:
            want_ru[a] = ru
    want_en_sets, want_ru_sets = OrderedDict(), OrderedDict()
    for s in sets:
        want_en_sets[s] = en_sets.get(s, set_title(s))
        ru = ru_given.get(s, ru_sets.get(s))
        if ru is None:
            missing.append(s)
        else:
            want_ru_sets[s] = ru
    if missing:
        hint = " ".join(f"--ru {m}=<name>" for m in missing)
        sys.exit(f"no Russian name for: {', '.join(missing)}\nrun again with {hint}")
    update_arb(ARB_EN, "pictureAnimal", "animal", want_en,
               "The name of a drawn animal picture (Settings → Profile → Your picture), by its id in assets/avatars/"
               "sets.json; kept in step by tools/avatars.py")
    update_arb(ARB_RU, "pictureAnimal", "animal", want_ru, None)
    update_arb(ARB_EN, "pictureSet", "set", want_en_sets,
               "The name of a set of drawn pictures (a tab of the picture picker), by its id; kept in step by "
               "tools/avatars.py")
    update_arb(ARB_RU, "pictureSet", "set", want_ru_sets, None)


def update_pubspec(set_ids) -> None:
    text = PUBSPEC.read_text(encoding="utf-8")
    lines = [PUBSPEC_MARK, "    - assets/avatars/sets.json\n"] + [f"    - assets/avatars/{s}/\n" for s in set_ids]
    block = "".join(lines)
    start = text.find(PUBSPEC_MARK)
    if start >= 0:
        end = start + len(PUBSPEC_MARK)
        rest = text[end:].splitlines(keepends=True)
        n = 0
        while n < len(rest) and rest[n].startswith("    - assets/avatars/"):
            n += 1
        text = text[:start] + block + "".join(rest[n:])
    else:
        anchor = "  fonts:\n"
        i = text.find(anchor)
        if i < 0:
            sys.exit("pubspec.yaml: no `fonts:` section to put the assets before")
        text = text[:i] + block + text[i:]
    PUBSPEC.write_text(text, encoding="utf-8")


def flutter_bin() -> str | None:
    for c in (os.environ.get("FLUTTER"), shutil.which("flutter"), str(Path.home() / "flutter" / "bin" / "flutter")):
        if c and Path(c).is_file():
            return c
    return None


def build(src: Path, ru_given: dict, gen_l10n: bool) -> int:
    need_pillow()
    sets = sources(src)
    if not sets:
        sys.exit(f"{src}: no set folders (set1, set2, ...) with NN-<animal>.png files")
    localize(sets, ru_given)
    manifest = {"version": 1, "sides": list(SIZES), "sets": []}
    icons = covers(src)
    for set_id, items in sets.items():
        d = OUT / set_id
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
        animals = []
        for _, animal, path in items:
            img = load(path)
            for side in SIZES:
                (d / f"{animal}-{side}.webp").write_bytes(encode(img, side))
            animals.append({"id": animal, "name": title(animal)})
        entry = {"id": set_id, "name": set_title(set_id)}
        if set_id in icons:
            (d / COVER).write_bytes(encode_cover(icons[set_id]))
            entry["cover"] = COVER
        entry["animals"] = animals
        manifest["sets"].append(entry)
    # Sets that are gone from the originals are gone from the app too.
    for old in OUT.iterdir() if OUT.exists() else []:
        if old.is_dir() and SET_ID.match(old.name) and old.name not in sets:
            shutil.rmtree(old)
    (OUT / "sets.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    update_pubspec(list(sets))
    total = sum(f.stat().st_size for f in OUT.rglob("*.webp"))
    print(f"{sum(len(i) for i in sets.values())} pictures in {len(sets)} set(s), {total / 1024:.0f} KB of WebP")
    if gen_l10n:
        fl = flutter_bin()
        if fl:
            subprocess.run([fl, "gen-l10n"], cwd=APP, check=True)
        else:
            print("Flutter not found: run `flutter gen-l10n` in apps/antenna_desktop")
    return check()


def webp_chunks(data: bytes) -> list[str]:
    """The RIFF chunk names of a WebP file (VP8, VP8L, VP8X, EXIF, XMP , ICCP, ...)."""
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("not a WebP file")
    out, i = [], 12
    while i + 8 <= len(data):
        name = data[i:i + 4].decode("latin-1")
        size = int.from_bytes(data[i + 4:i + 8], "little")
        out.append(name)
        i += 8 + size + (size & 1)
    return out


def check() -> int:
    """The committed assets match the manifest: every file there, square at its side, ≤ its byte limit, no metadata
    chunks, no stray files; the pubspec lists every set."""
    from PIL import Image

    problems = []
    manifest = json.loads((OUT / "sets.json").read_text(encoding="utf-8"))
    pubspec = PUBSPEC.read_text(encoding="utf-8")
    expected = set()
    for s in manifest["sets"]:
        if not SET_ID.match(s["id"]):
            problems.append(f"bad set id {s['id']}")
        if f"    - assets/avatars/{s['id']}/\n" not in pubspec:
            problems.append(f"pubspec.yaml does not list assets/avatars/{s['id']}/")
        if "cover" in s:
            p = OUT / s["id"] / s["cover"]
            expected.add(p)
            if s["cover"] != COVER or not p.is_file():
                problems.append(f"{s['id']}: cover {s['cover']} is missing")
            else:
                data = p.read_bytes()
                if len(data) > COVER_MAX:
                    problems.append(f"{p.relative_to(ROOT)}: {len(data)} bytes > {COVER_MAX}")
                if {"EXIF", "XMP ", "ICCP"} & set(webp_chunks(data)):
                    problems.append(f"{p.relative_to(ROOT)}: metadata chunks")
                with Image.open(p) as im:
                    if im.size != (COVER_SIDE, COVER_SIDE):
                        problems.append(f"{p.relative_to(ROOT)}: {im.size} is not {COVER_SIDE}x{COVER_SIDE}")
        for a in s["animals"]:
            if not ANIMAL_ID.match(a["id"]):
                problems.append(f"bad animal id {a['id']}")
            for side in manifest["sides"]:
                p = OUT / s["id"] / f"{a['id']}-{side}.webp"
                expected.add(p)
                if not p.is_file():
                    problems.append(f"missing {p.relative_to(ROOT)}")
                    continue
                data = p.read_bytes()
                if len(data) > MAX_BYTES[side]:
                    problems.append(f"{p.relative_to(ROOT)}: {len(data)} bytes > {MAX_BYTES[side]}")
                chunks = webp_chunks(data)
                meta = [c for c in chunks if c in ("EXIF", "XMP ", "ICCP")]
                if meta:
                    problems.append(f"{p.relative_to(ROOT)}: metadata chunks {meta}")
                with Image.open(p) as im:
                    if im.size != (side, side):
                        problems.append(f"{p.relative_to(ROOT)}: {im.size} is not {side}x{side}")
    for f in OUT.rglob("*.webp"):
        if f not in expected:
            problems.append(f"stray file {f.relative_to(ROOT)}")
    for p in problems:
        print(p)
    if not problems:
        n = sum(len(s["animals"]) for s in manifest["sets"])
        print(f"assets OK: {n} pictures in {len(manifest['sets'])} set(s)")
    return 1 if problems else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--src", type=Path, help="the folder with set1/, set2/, ... of original pictures")
    ap.add_argument("--ru", action="append", default=[], metavar="ID=NAME",
                    help="the Russian name of an animal or a set that app_ru.arb does not have yet")
    ap.add_argument("--no-gen-l10n", action="store_true", help="do not run flutter gen-l10n")
    ap.add_argument("--check", action="store_true", help="only check the committed assets")
    a = ap.parse_args()
    if a.check:
        need_pillow()
        return check()
    if a.src is None:
        ap.error("--src is required (or --check)")
    ru = {}
    for item in a.ru:
        k, sep, v = item.partition("=")
        if not sep or not v.strip():
            ap.error(f"--ru {item!r}: expected ID=NAME")
        ru[k.strip()] = v.strip()
    return build(a.src, ru, not a.no_gen_l10n)


if __name__ == "__main__":
    sys.exit(main())
