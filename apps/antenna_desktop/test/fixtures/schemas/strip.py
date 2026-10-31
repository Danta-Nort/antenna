#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Make a test fixture from a vendor's published JSON schema: keep the top-level properties the tests' files use, the
definitions they reference (transitively) and the schema's own top-level keywords (`additionalProperties` stays), and
drop the human-readable annotations (description, title, …). Every validation keyword that is kept is exactly as
published, so a file our code writes is valid against the fixture if and only if its parts are valid against the full
schema.

    python3 strip.py <downloaded.schema.json> <fixture.schema.json> <top-level property>…
"""
import json
import re
import sys

ANNOTATIONS = {"description", "markdownDescription", "title", "examples", "$comment", "deprecationMessage"}
NAMES = ("properties", "patternProperties", "$defs", "definitions")


def strip(node, names=False):
    if isinstance(node, dict):
        # Inside "properties" / "$defs" / "definitions" the keys are names, not annotations: keep them all.
        return {k: strip(v, k in NAMES) for k, v in node.items() if names or k not in ANNOTATIONS}
    if isinstance(node, list):
        return [strip(v) for v in node]
    return node


def refs(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "$ref" and isinstance(v, str):
                out.add(v)
            refs(v, out)
    elif isinstance(node, list):
        for v in node:
            refs(v, out)


def main():
    src, dst, keep = sys.argv[1], sys.argv[2], sys.argv[3:]
    with open(src, encoding="utf-8") as f:
        schema = json.load(f)
    defs_key = "$defs" if "$defs" in schema else "definitions"
    defs = schema.get(defs_key, {})
    out = {k: v for k, v in schema.items() if k not in ("properties", defs_key)}
    out["properties"] = {k: schema["properties"][k] for k in keep}
    needed, todo = set(), [out["properties"]]
    while todo:
        found = set()
        refs(todo.pop(), found)
        for r in found:
            m = re.fullmatch(r"#/(?:\$defs|definitions)/(.+)", r)
            if m and m.group(1) not in needed:
                needed.add(m.group(1))
                todo.append(defs[m.group(1)])
    if needed:
        out[defs_key] = {k: defs[k] for k in sorted(needed)}
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(strip(out), f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
