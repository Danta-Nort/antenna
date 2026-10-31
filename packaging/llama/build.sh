#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The local model runtime (D-96, D-104): llama.cpp's `llama-server`, built from the source of the pinned release and
# checked by its SHA-256, with what Antenna never uses switched off at build time:
#   LLAMA_OPENSSL=OFF        no HTTPS client: the runtime cannot download anything, even if its sandbox failed
#   LLAMA_SUBPROCESS=OFF     no subprocesses: no built-in tools (`--tools` has a shell command), no MCP servers, no
#                            router mode
#   LLAMA_BUILD_UI=OFF, LLAMA_USE_PREBUILT_UI=OFF   no web UI (and nothing fetched during the build)
#   tests, examples, the unified binary: off
#   packaging/llama/build.sh <out-dir>
# writes <out-dir>/llama/: llama-server, its libraries (Linux: the CPU variants chosen at run time; macOS arm64: Metal
# with the shaders built in), templates/ (the official chat templates the catalog pins, packaging/models/*.jinja) and
# LICENSE-llama.cpp. The daemon finds it as `llama/llama-server` next to `antennad`.
# Environment: LLAMA_JOBS (default 8), LLAMA_SRC (a tarball already downloaded, for an offline build; still checked),
# NICE (default 10).
# Requires: curl, tar, cmake, ninja (or make), a C/C++ compiler; macOS: Xcode command-line tools.
set -euo pipefail

TAG=v0.6.0
COMMIT=d81235049384534c167caea52b85a694f6103d14
# The source archive GitHub serves for the tag (checked 2026-10-06; docs/STACK.md "Local models").
SHA256=09b36dba235fcac180efff18514da7038e65d8e5b9e4aefa59238468abfdec12
URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz"

die() { echo "llama/build.sh: $*" >&2; exit 1; }
[ $# -eq 1 ] || die "usage: $0 <out-dir>"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS="${LLAMA_JOBS:-8}"
NICE="${NICE:-10}"
for t in curl tar cmake; do command -v "$t" >/dev/null || die "missing: $t"; done
GEN=()
command -v ninja >/dev/null && GEN=(-G Ninja)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/antenna-llama.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SRC="${LLAMA_SRC:-$WORK/llama.cpp-$TAG.tar.gz}"
if [ ! -f "$SRC" ]; then
  echo "==> llama.cpp $TAG source"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' -o "$SRC" "$URL"
fi
if command -v sha256sum >/dev/null; then got="$(sha256sum "$SRC" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"; fi
[ "$got" = "$SHA256" ] || die "the source archive of $TAG has SHA-256 $got, expected $SHA256: not building it"
tar -xzf "$SRC" -C "$WORK"
S="$WORK/llama.cpp-${TAG#v}"
[ -f "$S/CMakeLists.txt" ] || die "unexpected archive layout"

FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_OPENSSL=OFF -DLLAMA_SUBPROCESS=OFF
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_APP=OFF
  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON
  -DGGML_NATIVE=OFF
)
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    # The CPU variants chosen at run time (AVX2, AVX-512, …), as upstream's Linux release; libraries next to the binary.
    FLAGS+=(-DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
      "-DCMAKE_INSTALL_RPATH=\$ORIGIN" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON)
    ;;
  Darwin-arm64)
    # Metal with the shaders compiled into the binary (no Metal compiler needed at run time for them), as upstream.
    FLAGS+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
      -DBUILD_SHARED_LIBS=OFF)
    ;;
  Darwin-x86_64)
    FLAGS+=(-DGGML_METAL=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 -DBUILD_SHARED_LIBS=OFF)
    ;;
  *) die "no runtime build for $(uname -s) $(uname -m)" ;;
esac

echo "==> llama.cpp $TAG ($COMMIT): configure"
nice -n "$NICE" cmake -S "$S" -B "$WORK/build" ${GEN[@]+"${GEN[@]}"} "${FLAGS[@]}" > "$WORK/cmake.log" 2>&1 \
  || { tail -30 "$WORK/cmake.log" >&2; die "cmake failed"; }
echo "==> build llama-server (-j$JOBS)"
nice -n "$NICE" cmake --build "$WORK/build" --target llama-server -j "$JOBS" > "$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log" >&2; die "build failed"; }

D="$OUT/llama"
rm -rf "$D"
mkdir -p "$D/templates"
B="$WORK/build/bin"
cp -P "$B"/llama-server "$D/"
# The shared libraries (Linux): the CPU variants are loaded from the binary's own folder.
find "$B" -maxdepth 1 \( -name 'lib*.so*' -o -name 'lib*.dylib' \) -exec cp -P {} "$D/" \;
rm -f "$D"/libllama-bench-impl.* 2>/dev/null || true
cp "$ROOT"/packaging/models/*.jinja "$D/templates/"
cp "$S/LICENSE" "$D/LICENSE-llama.cpp"
cat > "$D/README.txt" <<TXT
llama.cpp $TAG ($COMMIT), llama-server only, built for Antenna's local models (MIT, LICENSE-llama.cpp).
Built without its HTTPS client, web UI, subprocesses (tools, MCP, router), tests and examples. Antenna starts it in a
sandbox with no network, one model file read-only and a unix socket. templates/: the official chat templates of the
models in Antenna's catalog, pinned by SHA-256 in the catalog.
TXT
# A run of the binary itself: it loads (its libraries are found) and reports the pinned build.
"$D/llama-server" --version 2>&1 | head -3 || die "the built llama-server does not run"
du -sh "$D"
echo "done: $D"
