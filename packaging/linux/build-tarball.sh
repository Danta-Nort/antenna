#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Antenna node for Linux (a server for an always-on agent, a desktop without the app): antennad + antenna + install.sh +
# systemd user unit → dist/antenna-<version>-linux-<arch>.tar.gz and .sha256.
# Requires: rustup (version from rust-toolchain.toml), protoc, cmake, a C compiler, perl (vendored OpenSSL).
#   VERSION=0.1.0-preview.1  (default: packaging/version.sh, i.e. Cargo.toml)
#   OUT=dist                 (output directory)
#   ANTENNA_COMMIT=<hash>    (default: git rev-parse; shown by `antenna --version`)
#   LLAMA_DIR=<dir>          the local model runtime already built by packaging/llama/build.sh (its `llama/`
#                            folder); default: build it here
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$("$ROOT/packaging/version.sh")}"
VERSION="${VERSION#v}"
ARCH="$(uname -m)"
export ANTENNA_COMMIT="${ANTENNA_COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"

cd "$ROOT"
cargo build --release --locked -p antennad -p antenna-cli
got="$(target/release/antenna --version)"
case "$got" in
  "antenna $VERSION ($ANTENNA_COMMIT)") ;;
  *) echo "binary version '$got' does not match release $VERSION ($ANTENNA_COMMIT)" >&2; exit 1 ;;
esac
NAME="antenna-$VERSION-linux-$ARCH"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME/bin"
install -m 0755 target/release/antennad target/release/antenna "$STAGE/$NAME/bin/"
# The local model runtime next to the daemon (bin/llama/llama-server, D-104).
if [ -n "${LLAMA_DIR:-}" ]; then
  cp -a "$LLAMA_DIR" "$STAGE/$NAME/bin/llama"
else
  packaging/llama/build.sh "$STAGE/$NAME/bin"
fi
[ -x "$STAGE/$NAME/bin/llama/llama-server" ] || { echo "no bin/llama/llama-server" >&2; exit 1; }
install -m 0755 packaging/linux/install.sh "$STAGE/$NAME/install.sh"
install -m 0644 packaging/linux/antennad.service "$STAGE/$NAME/antennad.service"
cp LICENSE-AGPL-3.0 "$STAGE/$NAME/LICENSE"
cat > "$STAGE/$NAME/README.txt" <<TXT
Antenna $VERSION ($ANTENNA_COMMIT): node for Linux, with the antennad daemon and the antenna CLI, and in bin/llama/
the runtime of local models (llama.cpp's llama-server, MIT; experimental).

Install (no root; into ~/.local/bin; the daemon runs as the systemd user service antennad.service):
    ./install.sh
Options: ./install.sh --help
Then: antenna invite (a link for your other computer or a person) or antenna join <link>.
Guide: https://github.com/Danta-Nort/antenna/blob/main/docs/guide/add-a-server.md
TXT
mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" | tee "$NAME.tar.gz.sha256")
echo "done: $OUT/$NAME.tar.gz"
