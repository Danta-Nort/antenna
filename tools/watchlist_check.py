#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Weekly machine check of the "Waiting for" list (docs/WATCHLIST.md).

Reads docs/watchlist.json, polls the sources (crates.io, GitHub, IETF datatracker,
text markers on pages), prints what changed since the previous check.
With --update writes the new values back into the JSON.

Python 3 standard library only. A failure of one source does not abort the run.
No LLM is needed here: a change in a machine-checked item is a signal to open WATCHLIST.md and
recheck the item by hand.

Exit codes:
  0 — no changes;
  1 — there are changes or new values (a reason to open WATCHLIST.md);
  3 — no source answered (network?).

Environment variables (optional):
  GITHUB_TOKEN       — token for api.github.com (without it the limit is 60 requests/hour, enough for us);
  WATCHLIST_CONTACT  — contact to add to the User-Agent (crates.io asks for a contact).

Examples:
  python3 tools/watchlist_check.py                 # only show
  python3 tools/watchlist_check.py --update        # show and write the new values
  python3 tools/watchlist_check.py --only w01-libcrux-ml-kem,w06-quic-multipath
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FILE = REPO_ROOT / "docs" / "watchlist.json"

TIMEOUT = 20
RETRIES = 1
MAX_BODY = 4 * 1024 * 1024


def user_agent() -> str:
    ua = "x-watchlist-check/1.0 (open_source_dev; stdlib urllib)"
    contact = os.environ.get("WATCHLIST_CONTACT", "").strip()
    if contact:
        ua += f" contact: {contact}"
    return ua


class FetchError(Exception):
    pass


def fetch(url: str, accept: str | None = None) -> bytes:
    headers = {"User-Agent": user_agent()}
    if accept:
        headers["Accept"] = accept
    host = urllib.parse.urlparse(url).hostname or ""
    if host == "api.github.com":
        headers.setdefault("Accept", "application/vnd.github+json")
        headers["X-GitHub-Api-Version"] = "2022-11-28"
        token = os.environ.get("GITHUB_TOKEN", "").strip()
        if token:
            headers["Authorization"] = f"Bearer {token}"
    last_err: Exception | None = None
    for attempt in range(RETRIES + 1):
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read(MAX_BODY)
        except urllib.error.HTTPError as e:
            # 404/410 are not cured by a retry; 403/429 is a rate limit, do not hammer it either.
            if e.code in (403, 404, 410, 429):
                raise FetchError(f"HTTP {e.code} {url}") from None
            last_err = e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last_err = e
        if attempt < RETRIES:
            time.sleep(2)
    raise FetchError(f"{type(last_err).__name__}: {last_err} ({url})")


def fetch_json(url: str):
    raw = fetch(url, accept="application/json")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise FetchError(f"not JSON: {e} ({url})") from None


def version_key(s: str):
    """Version sort key: v1.10.0 > v1.9.3; pre-releases sort below releases."""
    s = s.lstrip("vV")
    main, _, pre = s.partition("-")
    nums = []
    for part in re.split(r"[.]", main):
        m = re.match(r"(\d+)", part)
        nums.append(int(m.group(1)) if m else -1)
    return (nums, 0 if pre else 1, pre)


# Sources.

def src_crates(src: dict) -> str:
    name = src["name"]
    field = src.get("field", "max_version")
    d = fetch_json(f"https://crates.io/api/v1/crates/{urllib.parse.quote(name)}")
    crate = d.get("crate") or {}
    ver = crate.get(field) or crate.get("max_version")
    if not ver:
        raise FetchError(f"no field {field}")
    date = ""
    for v in d.get("versions") or []:
        if v.get("num") == ver:
            date = (v.get("created_at") or "")[:10]
            break
    return f"{ver} ({date})" if date else str(ver)


def src_github_release(src: dict) -> str:
    d = fetch_json(f"https://api.github.com/repos/{src['repo']}/releases/latest")
    return f"{d.get('tag_name')} ({(d.get('published_at') or '')[:10]})"


def src_github_tags(src: dict) -> str:
    d = fetch_json(f"https://api.github.com/repos/{src['repo']}/tags?per_page=100")
    pat = re.compile(src.get("pattern", r"^v?\d"))
    names = [t["name"] for t in d if pat.search(t.get("name", ""))]
    if not names:
        raise FetchError("no matching tags")
    return max(names, key=version_key)


def src_github_pr(src: dict) -> str:
    d = fetch_json(f"https://api.github.com/repos/{src['repo']}/pulls/{src['number']}")
    if d.get("merged_at"):
        return f"merged ({d['merged_at'][:10]})"
    if d.get("state") == "closed":
        return f"closed-unmerged ({(d.get('closed_at') or '')[:10]})"
    return "open"


def src_github_issue(src: dict) -> str:
    d = fetch_json(f"https://api.github.com/repos/{src['repo']}/issues/{src['number']}")
    state = d.get("state")
    if state == "closed":
        return f"closed:{d.get('state_reason') or '-'} ({(d.get('closed_at') or '')[:10]})"
    labels = sorted(lbl.get("name", "") for lbl in d.get("labels") or [])
    return "open [" + ",".join(labels) + "]"


def src_github_dir(src: dict) -> str:
    path = urllib.parse.quote(src.get("path", ""))
    d = fetch_json(f"https://api.github.com/repos/{src['repo']}/contents/{path}")
    pat = re.compile(src.get("pattern", r"."))
    names = [e["name"] for e in d if pat.search(e.get("name", ""))]
    if not names:
        raise FetchError("empty")
    return max(names)


_STATE_CACHE: dict[str, tuple[str, str]] = {}
_STATE_LOCK = threading.Lock()


def _ietf_state(uri: str) -> tuple[str, str]:
    with _STATE_LOCK:
        if uri in _STATE_CACHE:
            return _STATE_CACHE[uri]
    d = fetch_json(f"https://datatracker.ietf.org{uri}?format=json")
    st_type = d["type"].rstrip("/").split("/")[-1]
    res = (st_type, d["slug"])
    with _STATE_LOCK:
        _STATE_CACHE[uri] = res
    return res


def src_ietf_draft(src: dict) -> str:
    name = src["name"]
    base = "https://datatracker.ietf.org/api/v1"
    rel = fetch_json(
        f"{base}/doc/relateddocument/?source__name={name}&relationship__slug=became_rfc&format=json"
    )
    rfcs = [o["target"].rstrip("/").split("/")[-1].upper() for o in rel.get("objects", [])]
    if rfcs:
        return " ".join(rfcs)
    d = fetch_json(f"{base}/doc/document/{name}/?format=json")
    parts = []
    for uri in d.get("states", []):
        st_type, slug = _ietf_state(uri)
        short = st_type.replace("draft-stream-", "").replace("draft-", "")
        if short.startswith("iana"):
            continue  # IANA bookkeeping states change often and tell us nothing
        parts.append(f"{short}={slug}")
    # The record's last-modified date is not compared: datatracker bumps it on any event.
    return f"-{d.get('rev')} " + " ".join(sorted(parts))


def src_ietf_group(src: dict) -> str:
    d = fetch_json(
        f"https://datatracker.ietf.org/api/v1/group/group/?acronym={src['acronym']}&format=json"
    )
    objs = d.get("objects") or []
    if not objs:
        raise FetchError("group not found")
    return objs[0]["state"].rstrip("/").split("/")[-1]


def src_text(src: dict) -> str:
    raw = fetch(src["url"]).decode("utf-8", errors="replace")
    rx = re.compile(src["regex"], re.IGNORECASE | re.MULTILINE)
    mode = src.get("mode", "present")
    if mode == "count":
        return str(len(rx.findall(raw)))
    m = rx.search(raw)
    if mode == "present":
        return "present" if m else "absent"
    if mode == "first":
        if not m:
            return "absent"
        return m.group(1) if m.groups() else m.group(0)
    raise FetchError(f"unknown mode {mode}")


SOURCES = {
    "crates": src_crates,
    "github_release": src_github_release,
    "github_tags": src_github_tags,
    "github_pr": src_github_pr,
    "github_issue": src_github_issue,
    "github_dir": src_github_dir,
    "ietf_draft": src_ietf_draft,
    "ietf_group": src_ietf_group,
    "text": src_text,
}


def check_item(item: dict) -> tuple[str, str]:
    src = item["source"]
    fn = SOURCES.get(src.get("type"))
    if fn is None:
        return "error", f"unknown source type {src.get('type')!r}"
    try:
        return "ok", fn(src)
    except FetchError as e:
        return "error", str(e)
    except Exception as e:  # an unexpected response format must not abort the run
        return "error", f"{type(e).__name__}: {e}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, default=DEFAULT_FILE, help="path to watchlist.json")
    ap.add_argument("--update", action="store_true", help="write the new values into the JSON")
    ap.add_argument("--only", default="", help="comma-separated item ids")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    data = json.loads(args.file.read_text(encoding="utf-8"))
    items = data["items"]
    if args.only:
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        items = [i for i in items if i["id"] in wanted]

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        results = list(pool.map(check_item, items))

    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    changed = new = same = errors = 0
    lines = []
    for item, (status, value) in zip(items, results):
        iid = item["id"]
        last = item.get("last_value")
        if status == "error":
            errors += 1
            lines.append(f"ERROR    {iid}: {value}")
            continue
        if last is None:
            new += 1
            lines.append(f"NEW      {iid}: {value}")
            if args.update:
                item["last_value"] = value
                item["last_changed"] = today
        elif value != last:
            changed += 1
            lines.append(f"CHANGED  {iid}: {last!r} -> {value!r}   [{item.get('watch', '')}] {item.get('on_change', '')}")
            if args.update:
                item["previous_value"] = last
                item["last_value"] = value
                item["last_changed"] = today
        else:
            same += 1
            lines.append(f"same     {iid}: {value}")
        if args.update:
            item["last_checked"] = today

    order = {"CHANGED": 0, "NEW": 1, "ERROR": 2, "same": 3}
    lines.sort(key=lambda s: order.get(s.split()[0], 9))
    print(f"watchlist: {args.file} · {today} · items {len(items)}")
    for ln in lines:
        print(ln)
    print(f"total: changed {changed}, new {new}, unchanged {same}, errors {errors}")

    if args.update:
        data["last_run"] = today
        tmp = args.file.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, args.file)
        print(f"written: {args.file}")

    if items and errors == len(items):
        return 3
    return 1 if (changed or new) else 0


if __name__ == "__main__":
    sys.exit(main())
