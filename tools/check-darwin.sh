#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Type check of the core for macOS from Linux, without the Apple SDK (docs/PORTABILITY.md §3.1):
#   tools/check-darwin.sh [clippy|check] [--release] [target…]
# Default: clippy --all-targets -D warnings for aarch64-apple-darwin and x86_64-apple-darwin, crates antenna-sys,
# antenna-proto, antenna-core, antennad, antenna-cli, antenna-files, antenna-update, antenna-release. C dependencies are
# not built (tools/darwin-check.toml replaces their build scripts), blake3 runs in `pure` mode; so binaries cannot be
# built and tests cannot run this way: that is the job of CI on macOS (.github/workflows/release.yml, job `core`).
# Requires: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"

mode=clippy
profile=()
targets=()
for a in "$@"; do
  case "$a" in
    clippy|check) mode="$a" ;;
    --release) profile=(--release) ;;
    *-apple-darwin) targets+=("$a") ;;
    *) echo "usage: $0 [clippy|check] [--release] [aarch64-apple-darwin|x86_64-apple-darwin]…" >&2; exit 2 ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || targets=(aarch64-apple-darwin x86_64-apple-darwin)

pkgs=(-p antenna-sys -p antenna-proto -p antenna-core -p antennad -p antenna-cli -p antenna-files -p antenna-update -p antenna-release)

# wasmtime (YARA-X in antenna-files) builds a tiny C helper `helpers.c` (stdbool, stdint, stdlib → NULL). Without the
# SDK, clang compiles it in freestanding mode with a stub stdlib.h; the object file is only needed by the build script,
# check/clippy do not link. Without clang, antenna-files is not checked for darwin (CI on a Mac proves the C build anyway).
if command -v clang >/dev/null 2>&1; then
  stub="$root/target/darwin-check-include"
  mkdir -p "$stub"
  printf '%s\n' '/* stub for tools/check-darwin.sh: for type checking only, not for building */' \
    '#include <stddef.h>' > "$stub/stdlib.h"
  for t in aarch64_apple_darwin x86_64_apple_darwin; do
    export "CC_$t=clang" "CFLAGS_$t=-ffreestanding -isystem $stub"
  done
else
  echo "warning: clang not found — antenna-files (wasmtime) is skipped" >&2
  pkgs=(-p antenna-sys -p antenna-proto -p antenna-core -p antennad -p antenna-cli)
fi
bindings="$(find "$HOME/.cargo/registry/src" -path '*/libsqlite3-sys-0.38.2/sqlcipher/bindgen_bundled_version.rs' | head -n 1)"

run() {
  local t="$1" log
  log="$(mktemp)"
  local args=("$mode" --target "$t" "${profile[@]}" "${pkgs[@]}" --all-targets --features blake3/pure
              --config "$root/tools/darwin-check.toml")
  [ "$mode" = clippy ] && args+=(-- -D warnings)
  if nice -n 10 cargo "${args[@]}" 2>"$log"; then
    rm -f "$log"; return 0
  fi
  # libsqlite3-sys takes its bindings from OUT_DIR, and its build script is replaced: put the prebuilt (bundled) ones in
  # and retry
  local want
  # (`|| true`: with no match grep would return 1, and `set -e` would silently abort the script without showing the error)
  want="$( (grep -o "couldn't find file \`[^\`]*libsqlite3-sys-[^\`]*/out/bindgen.rs\`" "$log" || true) | head -n 1 | sed "s/^couldn't find file \`//; s/\`\$//")"
  if [ -n "$want" ] && [ -n "$bindings" ]; then
    mkdir -p "$(dirname "$want")"
    cp "$bindings" "$want"
    rm -f "$log"
    nice -n 10 cargo "${args[@]}"
    return $?
  fi
  cat "$log" >&2; rm -f "$log"; return 1
}

for t in "${targets[@]}"; do
  echo "== $mode $t ${profile[*]}"
  run "$t"
done
echo "OK: $mode ${targets[*]} ${profile[*]}"
