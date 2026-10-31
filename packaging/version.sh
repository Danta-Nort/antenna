#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Product version: `[workspace.package] version` in Cargo.toml (the same in apps/antenna_desktop/pubspec.yaml and
# lib/version.dart; an app test checks all three). `packaging/version.sh` → 0.1.0-preview.1;
# `packaging/version.sh --numeric` → 0.1.0 (CFBundleShortVersionString on macOS is numbers only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(awk '/^\[workspace\.package\]/{p=1; next} /^\[/{p=0} p && /^version *=/{gsub(/.*= *"|".*/, ""); print; exit}' "$ROOT/Cargo.toml")"
[ -n "$v" ] || { echo "version.sh: no [workspace.package] version in Cargo.toml" >&2; exit 1; }
if [ "${1:-}" = "--numeric" ]; then v="${v%%-*}"; v="${v%%+*}"; fi
printf '%s\n' "$v"
