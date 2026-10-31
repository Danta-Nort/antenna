#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Tests for tools/avatars.py: sizes, metadata stripped, the manifest, the pubspec and ARB files kept in step, and the
committed assets. Each protection is also made to fail on purpose (a negative control): a WebP with an EXIF chunk, an
oversized file, a missing Russian name, a stray file.

Plain assertions, no test framework (like tools/guide_check_test.py): each `check_*` function prints PASS or raises.
Run: python3 tools/avatars_test.py
"""

import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import avatars as av  # noqa: E402  (after sys.path setup)

from PIL import Image, PngImagePlugin  # noqa: E402

EN = '{\n  "@@locale": "en",\n  "hello": "Hello",\n  "@hello": {\n    "description": "Greeting."\n  }\n}\n'
RU = '{\n  "@@locale": "ru",\n  "hello": "Hi"\n}\n'
PUBSPEC = "name: x\nflutter:\n  assets:\n    - assets/logos/a.svg\n  fonts:\n    - family: X\n"


class Sandbox:
    """A copy of the window's inputs in a temporary folder, with the module pointed at it."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp())
        app = self.dir / "app"
        (app / "lib" / "l10n").mkdir(parents=True)
        (app / "lib" / "l10n" / "app_en.arb").write_text(EN, encoding="utf-8")
        (app / "lib" / "l10n" / "app_ru.arb").write_text(RU, encoding="utf-8")
        (app / "pubspec.yaml").write_text(PUBSPEC, encoding="utf-8")
        self.saved = (av.ROOT, av.APP, av.OUT, av.PUBSPEC, av.ARB_EN, av.ARB_RU)
        av.ROOT, av.APP = self.dir, app
        av.OUT = app / "assets" / "avatars"
        av.PUBSPEC = app / "pubspec.yaml"
        av.ARB_EN = app / "lib" / "l10n" / "app_en.arb"
        av.ARB_RU = app / "lib" / "l10n" / "app_ru.arb"
        self.src = self.dir / "src"

    def original(self, set_id: str, name: str, size=(900, 700), alpha=False):
        """An original with metadata a picture must not carry: EXIF (with a GPS-like tag), a text chunk, an ICC
        profile."""
        d = self.src / set_id
        d.mkdir(parents=True, exist_ok=True)
        img = Image.new("RGBA" if alpha else "RGB", size, (200, 120, 40, 128) if alpha else (200, 120, 40))
        # A blue block in the middle: the square crop keeps the middle of the original.
        w, h = size
        img.paste((0, 0, 255, 255) if alpha else (0, 0, 255), (w // 2 - 60, h // 2 - 60, w // 2 + 60, h // 2 + 60))
        info = PngImagePlugin.PngInfo()
        info.add_text("Comment", "SECRET-LOCATION 55.75,37.61")
        exif = Image.Exif()
        exif[0x010F] = "SecretCam"
        exif[0x8825] = {2: (55, 45, 0)}
        img.save(d / name, "PNG", pnginfo=info, exif=exif.tobytes(), icc_profile=b"\0" * 128)

    def close(self):
        av.ROOT, av.APP, av.OUT, av.PUBSPEC, av.ARB_EN, av.ARB_RU = self.saved
        shutil.rmtree(self.dir)


def expect_exit(fn, *args) -> str:
    try:
        fn(*args)
    except SystemExit as e:
        return str(e.code)
    raise AssertionError("expected the run to stop")


def check_build_sizes_metadata_manifest():
    s = Sandbox()
    try:
        s.original("set1", "02-owl.png")
        s.original("set1", "01-fox.png", size=(700, 900), alpha=True)
        s.original("set1", "notes.txt")  # not NN-<animal>.png: ignored (a PNG named like notes, on purpose)
        (s.src / "set1" / "prompts.txt").write_text("how they were made", encoding="utf-8")
        rc = av.build(s.src, {"fox": "Lisa", "owl": "Sova", "set1": "Soft-ru"}, gen_l10n=False)
        assert rc == 0, "check() after build"
        m = json.loads((av.OUT / "sets.json").read_text(encoding="utf-8"))
        assert m["sides"] == [512, 128]
        assert [s_["id"] for s_ in m["sets"]] == ["set1"]
        assert m["sets"][0]["name"] == "Soft"
        assert [a["id"] for a in m["sets"][0]["animals"]] == ["fox", "owl"], "ordered by the number, then the name"
        assert m["sets"][0]["animals"][0]["name"] == "Fox"
        for animal in ("fox", "owl"):
            for side in (512, 128):
                data = (av.OUT / "set1" / f"{animal}-{side}.webp").read_bytes()
                assert len(data) <= av.MAX_BYTES[side]
                assert not {"EXIF", "XMP ", "ICCP"} & set(av.webp_chunks(data)), "no metadata chunks"
                assert b"SECRET" not in data and b"SecretCam" not in data
                with Image.open(io.BytesIO(data)) as im:
                    assert im.size == (side, side)
                    assert "exif" not in im.info and "icc_profile" not in im.info
        assert not list(av.OUT.rglob("*.txt")), "nothing but the pictures and the manifest is shipped"
        # The crop is square from the middle: the blue marker row survives, nothing is stretched.
        with Image.open(av.OUT / "set1" / "owl-512.webp") as im:
            mid = im.convert("RGB").getpixel((256, 256))
            assert mid[2] > 150 and mid[0] < 120, f"the middle of the original is the middle of the picture: {mid}"
        # Transparency is composited over white, not black.
        with Image.open(av.OUT / "set1" / "fox-128.webp") as im:
            r, g, b = im.convert("RGB").getpixel((5, 5))
            assert r > 200 and g > 150, f"alpha over white: {(r, g, b)}"
        pub = av.PUBSPEC.read_text(encoding="utf-8")
        assert "    - assets/avatars/sets.json\n    - assets/avatars/set1/\n  fonts:" in pub
        en = json.loads(av.ARB_EN.read_text(encoding="utf-8"))
        ru = json.loads(av.ARB_RU.read_text(encoding="utf-8"))
        assert en["pictureAnimal"] == "{animal, select, fox{Fox} owl{Owl} other{{animal}}}"
        assert ru["pictureAnimal"] == "{animal, select, fox{Lisa} owl{Sova} other{{animal}}}"
        assert ru["pictureSet"] == "{set, select, set1{Soft-ru} other{{set}}}"
        assert en["@pictureAnimal"]["placeholders"] == {"animal": {"type": "String"}}
        assert "@pictureAnimal" not in ru, "the template alone carries descriptions"
        assert av.ARB_EN.read_text(encoding="utf-8").startswith(EN.rsplit("\n}", 1)[0]), "the rest stays as it was"
        print("PASS: sizes, metadata stripped, square crop, manifest, pubspec and ARB")

        assert "cover" not in m["sets"][0], "no covers folder: no cover"

        # A cover icon per set, by the set's number, transparency kept.
        (s.src / "covers").mkdir()
        icon = Image.new("RGBA", (600, 600), (0, 0, 0, 0))
        icon.paste((90, 140, 255, 255), (200, 200, 400, 400))
        icon.save(s.src / "covers" / "01-cloud.png")
        assert av.build(s.src, {}, False) == 0
        m = json.loads((av.OUT / "sets.json").read_text(encoding="utf-8"))
        assert m["sets"][0]["cover"] == "cover-128.webp"
        with Image.open(av.OUT / "set1" / "cover-128.webp") as im:
            assert im.size == (128, 128) and im.mode == "RGBA"
            assert im.getpixel((2, 2))[3] == 0, "transparent corners stay transparent"
            assert im.getpixel((64, 64))[3] == 255
        print("PASS: a set's cover icon keeps its transparency")

        # A second set and a second run: idempotent files, the first set kept, names reused.
        before = {p: p.read_bytes() for p in av.OUT.rglob("*")if p.is_file()}
        s.original("set2", "01-wolf.png")
        assert "wolf" in expect_exit(av.build, s.src, {}, False), "a missing Russian name stops the run"
        assert not (av.OUT / "set2").exists(), "nothing written before the names are complete"
        rc = av.build(s.src, {"wolf": "Volk", "set2": "Modern-ru"}, False)
        assert rc == 0
        for p, data in before.items():
            if p.name != "sets.json":
                assert p.read_bytes() == data, f"{p.name} is reproducible"
        m = json.loads((av.OUT / "sets.json").read_text(encoding="utf-8"))
        assert [x["name"] for x in m["sets"]] == ["Soft", "Modern"]
        pub = av.PUBSPEC.read_text(encoding="utf-8")
        assert pub.count("assets/avatars/set1/") == 1 and "assets/avatars/set2/" in pub
        print("PASS: adding a set is one run; a missing Russian name stops it (seen failing)")
    finally:
        s.close()


def check_negative_controls():
    s = Sandbox()
    try:
        s.original("set1", "01-fox.png")
        assert av.build(s.src, {"fox": "Lisa", "set1": "Soft-ru"}, False) == 0
        p = av.OUT / "set1" / "fox-512.webp"
        good = p.read_bytes()

        # Metadata kept: an EXIF chunk appended to the RIFF container must be caught.
        exif = b"EXIF" + (16).to_bytes(4, "little") + b"SECRET-LOCATION!"
        body = good[12:] + exif
        p.write_bytes(b"RIFF" + (len(body) + 4).to_bytes(4, "little") + b"WEBP" + body)
        assert "EXIF" in av.webp_chunks(p.read_bytes())
        assert av.check() == 1, "a picture with metadata fails the check"
        print("PASS: a picture with an EXIF chunk is caught (seen failing)")

        # Too large.
        big = io.BytesIO()
        Image.effect_noise((512, 512), 120).convert("RGB").save(big, "WEBP", quality=100)
        assert len(big.getvalue()) > av.MAX_BYTES[512]
        p.write_bytes(big.getvalue())
        assert av.check() == 1, "an oversized picture fails the check"
        print("PASS: an oversized picture is caught (seen failing)")

        # Wrong side, then a stray file.
        p.write_bytes(good)
        assert av.check() == 0
        small = io.BytesIO()
        Image.new("RGB", (500, 512)).save(small, "WEBP")
        p.write_bytes(small.getvalue())
        assert av.check() == 1, "a picture that is not square at its side fails"
        p.write_bytes(good)
        (av.OUT / "set1" / "wolf-512.webp").write_bytes(good)
        assert av.check() == 1, "a file the manifest does not list fails"
        print("PASS: a wrong size and a stray file are caught (seen failing)")
    finally:
        s.close()


def check_committed_assets():
    """The assets in the repository pass the same check."""
    assert av.check() == 0, "the committed assets"
    print("PASS: the committed assets")


if __name__ == "__main__":
    av.need_pillow()
    check_build_sizes_metadata_manifest()
    check_negative_controls()
    check_committed_assets()
