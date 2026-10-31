#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Negative controls for tools/guide_check.py: a wrong label, a missing frame (stale image) and a missing page, each
made to fail on purpose and checked to actually fail — a check that was never seen failing proves nothing (CONTRIBUTING.md
"Tests"). Also covers the bold-pointer-across-a-soft-line-break bug the first guide pages hit, so a future edit cannot reintroduce it unnoticed.

Plain assertions, no test framework (matching this repository's other `tools/*.py` checks): each `check_*` function
prints PASS or raises on failure. Run: python3 tools/guide_check_test.py
"""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guide_check as gc  # noqa: E402  (after sys.path setup)

LABELS = {"Settings", "Advanced", "Updates", "Chats", "Agents"}


def check_pointer_positive():
    text = "Open **Settings → Advanced → Updates** to see it.\n"
    bad = gc.bad_pointers(text, LABELS)
    assert bad == [], f"a real label was wrongly flagged: {bad}"
    print("PASS: a correct pointer is not flagged")


def check_pointer_negative_wrong_label():
    text = "Open **Settings → Advnaced → Updates** to see it.\n"  # "Advnaced": a wrong label, on purpose
    bad = gc.bad_pointers(text, LABELS)
    assert bad == [(1, "Advnaced")], f"the wrong label was not caught: {bad}"
    print("PASS: a wrong label is caught (seen failing)")


def check_pointer_soft_wrap():
    """The bug found while writing the first guide pages: a bold span that wraps across a line, as a word processor
    or an editor's reflow would leave it, must still read as one pointer."""
    text = "See **Settings → Advanced →\nUpdates** for it.\n"
    bad = gc.bad_pointers(text, LABELS)
    assert bad == [], f"a pointer that wraps across a soft line break was wrongly split: {bad}"
    print("PASS: a pointer wrapped across a soft line break is still read whole")


def check_image_positive(tmp_path: Path):
    img_dir = tmp_path / "img"
    img_dir.mkdir(parents=True)
    frames_dir = tmp_path / "frames"
    frames_dir.mkdir(parents=True)
    data = b"frame bytes"
    (frames_dir / "04_home_chat.png").write_bytes(data)
    (img_dir / "04_home_chat.png").write_bytes(data)
    manifest = {"04_home_chat.png": {"sha256": hashlib.sha256(data).hexdigest(), "src": "frames/04_home_chat.png"}}
    bad = gc.bad_images("![x](img/04_home_chat.png)\n", manifest, img_dir=img_dir, root=tmp_path)
    assert bad == [], f"a fresh, correctly copied image was wrongly flagged: {bad}"
    print("PASS: a fresh image copy is not flagged")


def check_image_negative_missing(tmp_path: Path):
    img_dir = tmp_path / "img-missing"
    img_dir.mkdir(parents=True)
    bad = gc.bad_images("![x](img/64_image_viewer.png)\n", {}, img_dir=img_dir, root=tmp_path)
    assert len(bad) == 1 and bad[0][1] == "64_image_viewer.png" and "missing" in bad[0][2], \
        f"a missing image was not caught: {bad}"
    print("PASS: a missing image is caught (seen failing)")


def check_image_negative_stale(tmp_path: Path):
    """The frame changed after guide_shots.py last copied it: the manifest's recorded hash no longer matches."""
    img_dir = tmp_path / "img-stale"
    img_dir.mkdir(parents=True)
    frames_dir = tmp_path / "frames-stale"
    frames_dir.mkdir(parents=True)
    (frames_dir / "22_settings.png").write_bytes(b"new frame bytes")
    (img_dir / "22_settings.png").write_bytes(b"old copy bytes")
    manifest = {"22_settings.png": {"sha256": hashlib.sha256(b"old copy bytes").hexdigest(),
                                     "src": "frames-stale/22_settings.png"}}
    bad = gc.bad_images("![x](img/22_settings.png)\n", manifest, img_dir=img_dir, root=tmp_path)
    assert len(bad) == 1 and "older than its frame" in bad[0][2], f"a stale image was not caught: {bad}"
    print("PASS: a stale image (frame changed since the last copy) is caught (seen failing)")


def check_missing_page(tmp_path: Path):
    guide_dir = tmp_path / "guide-no-files"
    (guide_dir / "img").mkdir(parents=True)
    (guide_dir / "chats.md").write_text("# Chats\n\nNothing about Settings here.\n", encoding="utf-8")
    arb = {"navChats": "Chats", "navSettings": "Settings"}
    missing = gc.missing_pages(guide_dir, arb, ["navChats", "navSettings"])
    assert missing == [("navSettings", "Settings")], f"the missing page was not caught: {missing}"
    print("PASS: a navigation item with no guide page is caught (seen failing)")

    (guide_dir / "settings.md").write_text("# Settings\n\nHere it is.\n", encoding="utf-8")
    missing = gc.missing_pages(guide_dir, arb, ["navChats", "navSettings"])
    assert missing == [], f"adding the page did not clear the finding: {missing}"
    print("PASS: adding the page clears the finding")


def main() -> int:
    import tempfile
    check_pointer_positive()
    check_pointer_negative_wrong_label()
    check_pointer_soft_wrap()
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        check_image_positive(tmp_path / "a")
        check_image_negative_missing(tmp_path / "b")
        check_image_negative_stale(tmp_path / "c")
        check_missing_page(tmp_path / "d")
    print("guide_check_test: all negative controls seen failing as expected; all positives clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
