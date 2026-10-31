#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Check docs/guide/ against the window it documents and against its own screenshots.

A guide page points at the window with bold text and nothing else: a single label (`**Settings**`) or a path of them
joined with " → " (`**Settings → Advanced → Updates**`). General emphasis uses italics or plain text, never bold, so
every bold span in docs/guide/ is a claim about a literal English string the window shows — this check can verify the
claim instead of guessing at it. The source of truth for a label is the window's own string table,
`apps/antenna_desktop/lib/l10n/app_en.arb` (English: D-80); a page quoting a label the window does not have (renamed,
removed, or never existed) fails here before it reaches a reader.

Three independent checks, each prefixed in its own way so a failure says which rule it broke:
  1. label  — every bold pointer resolves to an exact app_en.arb string (`find_pointers`, `bad_pointers`).
  2. image  — every `img/<name>.png` a page references exists under docs/guide/img/ and matches the sha256
     `tools/guide_shots.py` recorded for it in docs/guide/img/manifest.json when it last copied that frame from
     docs/design/screens/ (`find_images`, `bad_images`); run `tools/guide_shots.py` first on every build, so this is
     normally checking that step's own output, not catching a hand-edited image.
  3. page   — every navigation item and Settings section the window has gets a guide page: some heading, anywhere
     under docs/guide/, with that exact label text (`missing_pages`). The required list is `NAV_KEYS` / `SETTINGS_KEYS`
     below, resolved against app_en.arb so a renamed section does not need a second edit here.

Negative controls for all three (a wrong label, a missing frame, a missing page, each made to fail on purpose and
seen failing): `tools/guide_check_test.py`.

Not implemented yet: `guide_check.py --since <ref>`, which the product plan §4.3 describes to enforce in CI
that a commit touching a golden frame or a navigation label also touches docs/guide/ (or says `Guide: unaffected
(<reason>)`). Left for a follow-up; this script only checks the tree as it stands.

Usage: tools/guide_check.py
Exit code 1 on any finding.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE_DIR = ROOT / "docs/guide"
IMG_DIR = GUIDE_DIR / "img"
MANIFEST_PATH = IMG_DIR / "manifest.json"
FRAMES_DIR = ROOT / "docs/design/screens"
ARB_PATH = ROOT / "apps/antenna_desktop/lib/l10n/app_en.arb"

BOLD = re.compile(r"\*\*([^*\n]+)\*\*")
IMG_REF = re.compile(r"!\[[^\]]*\]\(img/([A-Za-z0-9_.-]+\.png)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+\.)\s")
TABLE_ROW = re.compile(r"^\s*\|")
BLOCKQUOTE = re.compile(r"^\s*>")
ARROW = " → "

# The window's own navigation and Settings section keys (apps/antenna_desktop/lib/l10n/app_en.arb). Every one of
# these needs a guide page with a heading matching its current English text exactly.
NAV_KEYS = ["navChats", "navTeams", "navAgents", "navDevices", "navFiles", "navSettings"]
SETTINGS_KEYS = [
    "settingsSectionProfile",
    "settingsSectionGeneral",
    "settingsSectionInterface",
    "settingsSectionNetwork",
    "settingsSectionSecurity",
    "settingsSectionAgents",
    "settingsSectionCheck",
    "settingsSectionAdvanced",
]


def load_arb(path: Path) -> dict:
    """key -> English string, skipping ICU metadata keys (`@key`)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    return {k: v for k, v in data.items() if isinstance(v, str) and not k.startswith("@")}


def guide_files(guide_dir: Path) -> list:
    return sorted(p for p in guide_dir.rglob("*.md"))


def visible_lines(text: str):
    """(line number, line) pairs outside fenced code blocks, 1-based."""
    in_fence = False
    for no, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield no, line


def strip_code_spans(line: str) -> str:
    """Blank out inline `code` spans, so a literal "**x**" shown as an example of the syntax is not read as a
    pointer (matches link_check.py's own treatment of code spans)."""
    return re.sub(r"(`+)(.+?)\1", lambda m: " " * len(m.group(0)), line)


def paragraphs(text: str):
    """(starting line number, text) for each stretch of plain prose outside a fenced code block, with soft line
    wraps joined into one line first. A heading, list item, table row, blockquote or blank line always starts its
    own entry instead of joining its neighbors: a bold pointer is never expected to cross one of those on purpose,
    and joining them could stitch together unrelated text. Without this, a pointer that wraps across a line in
    flowing prose (`**Rekey\\nneeded**`, common once a paragraph is reflowed) would read as two broken halves
    instead of one — seen failing while writing the first guide pages."""
    buf_no, buf = None, []
    for no, line in visible_lines(text):
        starts_block = (not line.strip()) or HEADING.match(line) or LIST_ITEM.match(line) \
            or TABLE_ROW.match(line) or BLOCKQUOTE.match(line)
        if starts_block:
            if buf:
                yield buf_no, " ".join(buf)
                buf_no, buf = None, []
            if line.strip():
                yield no, line
            continue
        if buf_no is None:
            buf_no = no
        buf.append(line)
    if buf:
        yield buf_no, " ".join(buf)


def find_pointers(text: str):
    """(line number, bold span text) for every `**...**` outside a fenced code block or an inline code span."""
    for no, line in paragraphs(text):
        for m in BOLD.finditer(strip_code_spans(line)):
            yield no, m.group(1)


def bad_pointers(text: str, labels: set) -> list:
    """Pointer segments (split on " → ") that are not an exact app_en.arb string."""
    bad = []
    for no, span in find_pointers(text):
        for segment in span.split(ARROW):
            segment = segment.strip()
            if segment and segment not in labels:
                bad.append((no, segment))
    return bad


def find_images(text: str):
    """(line number, image name) for every `img/<name>.png` reference outside a fenced code block or code span."""
    for no, line in paragraphs(text):
        for m in IMG_REF.finditer(strip_code_spans(line)):
            yield no, m.group(1)


def bad_images(text: str, manifest: dict, img_dir: Path = IMG_DIR, root: Path = ROOT) -> list:
    """Image references that are missing, or whose manifest hash no longer matches their current source frame.
    `img_dir` and `root` default to this repository's docs/guide/img/ and its root; a test passes its own temporary
    ones instead, so it never touches the real tree."""
    bad = []
    for no, name in find_images(text):
        dest = img_dir / name
        if not dest.exists():
            bad.append((no, name, "missing from docs/guide/img/ (run tools/guide_shots.py)"))
            continue
        entry = manifest.get(name)
        if entry is None:
            bad.append((no, name, "not in docs/guide/img/manifest.json (run tools/guide_shots.py)"))
            continue
        src = root / entry["src"]
        if not src.exists():
            bad.append((no, name, f"its source frame {entry['src']} no longer exists"))
            continue
        if hashlib.sha256(src.read_bytes()).hexdigest() != entry["sha256"]:
            bad.append((no, name, "older than its frame: the frame changed since guide_shots.py last copied it "
                                   "(run tools/guide_shots.py)"))
    return bad


def heading_texts(guide_dir: Path) -> set:
    texts = set()
    for md in guide_files(guide_dir):
        for _, line in visible_lines(md.read_text(encoding="utf-8")):
            m = HEADING.match(line)
            if m:
                texts.add(m.group(2).replace("*", "").replace("`", "").strip())
    return texts


def missing_pages(guide_dir: Path, arb: dict, keys: list) -> list:
    """arb keys from `keys` whose current English text is not a heading anywhere under docs/guide/."""
    present = heading_texts(guide_dir)
    return [(key, arb[key]) for key in keys if key in arb and arb[key] not in present]


def main() -> int:
    if not GUIDE_DIR.is_dir():
        print(f"guide_check: {GUIDE_DIR} does not exist", file=sys.stderr)
        return 1
    arb = load_arb(ARB_PATH)
    labels = set(arb.values())
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8")) if MANIFEST_PATH.exists() else {}

    findings = []
    for md in guide_files(GUIDE_DIR):
        text = md.read_text(encoding="utf-8")
        rel = md.relative_to(ROOT)
        for no, segment in bad_pointers(text, labels):
            findings.append(f"{rel}:{no}: label: \"{segment}\" is not a string in app_en.arb")
        for no, name, why in bad_images(text, manifest):
            findings.append(f"{rel}:{no}: image: {name}: {why}")

    for key, value in missing_pages(GUIDE_DIR, arb, NAV_KEYS):
        findings.append(f"page: no guide heading for the navigation item \"{value}\" ({key})")
    for key, value in missing_pages(GUIDE_DIR, arb, SETTINGS_KEYS):
        findings.append(f"page: no guide heading for the Settings section \"{value}\" ({key})")

    for f in findings:
        print(f)
    print(f"guide_check: {len(guide_files(GUIDE_DIR))} page(s), {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
