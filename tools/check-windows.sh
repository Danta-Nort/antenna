#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Type check of the workspace for Windows (x86_64, MSVC) from Linux, without MSVC or the Windows SDK
# (docs/PORTABILITY-WINDOWS.md WP-32; the method of tools/check-darwin.sh, docs/PORTABILITY.md §3.1):
#   tools/check-windows.sh [clippy|check] [--release]
# Default: the two clippy passes of the Linux checks over the whole workspace for x86_64-pc-windows-msvc,
# `--all-targets -- -D warnings`, then `--lib --bins -- -D clippy::unwrap_used -D clippy::panic`; `check` runs a plain
# `cargo check --all-targets` instead. Every line of our code that Windows compiles is type-checked with Windows' cfg
# (unix-only code outside `cfg(unix)` fails here), tests and examples included, and linted.
# C dependencies are not built: tools/windows-check.toml replaces the build scripts of aws-lc-sys, ring and openssl-sys,
# the SQLCipher build script copies its prebuilt bindings instead of compiling (LIBSQLITE3_SYS_USE_PKG_CONFIG=1), blake3
# runs in `pure` mode, and wasmtime builds no C helper for Windows. So this is not a build: nothing is linked, no binary
# is made, no test runs, and the C parts, the Windows API behaviour and the import libraries are not checked. That is
# the job of .github/workflows/windows.yml on a Windows machine.
# Never a silent pass: no package is skipped, and a missing target, a stale override key or a build script that needs
# a C compiler stops the script with cargo's error.
# Time (8 jobs): about 1.5–2 min per profile the first time. After that ≈ 30 s for debug and ≈ 55 s for `--release` even
# when nothing changed: the two passes give clippy different arguments, so each re-lints our eight crates (dependencies
# are not checked again); `check` alone takes a few seconds.
# Requires: `rustup target add x86_64-pc-windows-msvc` (Rust's standard library for the target; no Microsoft files).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"

target=x86_64-pc-windows-msvc
mode=clippy
profile=()
for a in "$@"; do
  case "$a" in
    clippy|check) mode="$a" ;;
    --release) profile=(--release) ;;
    *) echo "usage: $0 [clippy|check] [--release]" >&2; exit 2 ;;
  esac
done

libdir="$(rustc --print target-libdir --target "$target")"
if [ ! -d "$libdir" ]; then
  echo "error: the Rust standard library for $target is not installed: rustup target add $target" >&2
  exit 1
fi

# libsqlite3-sys: its build script takes the "linked" path and copies the same prebuilt SQLCipher bindings
# (sqlcipher/bindgen_bundled_version.rs) that its bundled build uses, instead of compiling SQLCipher with a C compiler;
# it is built only for the Windows target here, so the Linux build of the crate is not affected
export LIBSQLITE3_SYS_USE_PKG_CONFIG=1
common=(--workspace --locked --target "$target" "${profile[@]}" --features blake3/pure
        --config "$root/tools/windows-check.toml")

step() {
  echo "== $*"
  nice -n 10 cargo "$@"
}

if [ "$mode" = clippy ]; then
  step clippy "${common[@]}" --all-targets -- -D warnings
  step clippy "${common[@]}" --lib --bins -- -D clippy::unwrap_used -D clippy::panic
else
  step check "${common[@]}" --all-targets
fi
echo "OK: $mode $target${profile[*]:+ ${profile[*]}}"
