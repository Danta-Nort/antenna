#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Copy the golden frames the guide needs from docs/design/screens/ into docs/guide/img/.

docs/guide/ shows the window's own golden frames (`apps/antenna_desktop/test/goldens/showcase_test.dart`), never a
hand-made screenshot, so a guide image cannot drift from the real window. This script
finds every `img/<name>.png` a guide page references, copies the frame of the same name from docs/design/screens/ and
records its hash in docs/guide/img/manifest.json, so `tools/guide_check.py` can tell a stale copy from a fresh one
without relying on file modification times (a git checkout does not preserve them, so comparing mtimes between two
files checked out together proves nothing).

Cropping a frame to a sub-region is not implemented yet: every guide image today is a whole frame. Good enough for
the first guide pages; a future page that wants a tight crop (for example, just the Settings sidebar) needs this
script extended first — do not hand-crop a PNG and commit it, or `guide_check.py` cannot tell it apart from a stale one.

Run on every build: the release script (`packaging/release-linux.sh`) and CI (`.github/workflows/release.yml`, job
`linux`) run it right after the golden tests, so docs/guide/img/ is always exactly what `docs/design/screens/` says,
before `guide_check.py` is asked to verify it.

Usage: tools/guide_shots.py
Exit code 1 when a guide page names a frame that does not exist in docs/design/screens/ (everything else it could
copy is still copied).
"""

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE_DIR = ROOT / "docs/guide"
IMG_DIR = GUIDE_DIR / "img"
FRAMES_DIR = ROOT / "docs/design/screens"
MANIFEST_PATH = IMG_DIR / "manifest.json"

IMG_REF = re.compile(r"!\[[^\]]*\]\(img/([A-Za-z0-9_.-]+\.png)\)")


def needed_frames(guide_dir: Path) -> list:
    """Every `img/<name>.png` named by a guide page, sorted and de-duplicated."""
    names = set()
    for md in sorted(guide_dir.rglob("*.md")):
        names.update(IMG_REF.findall(md.read_text(encoding="utf-8")))
    return sorted(names)


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    names = needed_frames(GUIDE_DIR)
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {}
    missing = []
    for name in names:
        src = FRAMES_DIR / name
        if not src.exists():
            missing.append(name)
            continue
        data = src.read_bytes()
        (IMG_DIR / name).write_bytes(data)
        manifest[name] = {"sha256": hashlib.sha256(data).hexdigest(), "src": f"docs/design/screens/{name}"}
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for name in missing:
        print(f"guide_shots: {name}: no such frame in docs/design/screens/ "
              f"(a guide page under docs/guide/ names it; add the frame to showcase_test.dart or fix the page)",
              file=sys.stderr)
    print(f"guide_shots: {len(manifest)} frame(s) copied into docs/guide/img/, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
