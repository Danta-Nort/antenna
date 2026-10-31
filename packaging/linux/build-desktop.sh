#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Antenna app for Linux (Flutter, GTK 3) with the core inside → dist/antenna-desktop-<version>-linux-<arch>.tar.gz and .sha256.
# The archive holds: antenna-desktop (the app), bin/antennad and bin/antenna (the app starts the daemon as a child
# process if it is not running), Flutter lib/ and data/, install-desktop-entry.sh (menu, icon and antenna:// links,
# no root), LICENSE, README.txt. The core is the same release binaries as in antenna-<ver>-linux-<arch>.tar.gz.
#
#   VERSION=0.1.0-preview.1  (default: packaging/version.sh, i.e. Cargo.toml)
#   ANTENNA_COMMIT=<hash>    (default: git rev-parse; shown by `antenna --version` and in the app)
#   BUILD_NUMBER=1           (app build number; the run number in CI)
#   CORE_BIN_DIR=target/release  (where to take antennad and antenna from; if missing, cargo build --release)
#   OUT=dist
#
# Requires: Flutter 3.47.6, clang, cmake, ninja, pkg-config, libgtk-3-dev; for the core: rustup, protoc, cmake, perl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$("$ROOT/packaging/version.sh")}"
VERSION="${VERSION#v}"
NUMERIC="${VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="$(uname -m)"
export ANTENNA_COMMIT="${ANTENNA_COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
CORE_BIN_DIR="${CORE_BIN_DIR:-$ROOT/target/release}"
APP_DIR="$ROOT/apps/antenna_desktop"

for tool in flutter cmake ninja pkg-config clang++; do
  command -v "$tool" >/dev/null || { echo "$tool not found in PATH" >&2; exit 2; }
done
pkg-config --exists gtk+-3.0 || { echo "GTK 3 development files not found (libgtk-3-dev)" >&2; exit 2; }

if [ ! -x "$CORE_BIN_DIR/antennad" ] || [ ! -x "$CORE_BIN_DIR/antenna" ]; then
  echo "==> core (cargo build --release)"
  (cd "$ROOT" && cargo build --release --locked -p antennad -p antenna-cli)
  CORE_BIN_DIR="$ROOT/target/release"
fi
got="$("$CORE_BIN_DIR/antenna" --version)"
[ "$got" = "antenna $VERSION ($ANTENNA_COMMIT)" ] || { echo "core version '$got' does not match release $VERSION ($ANTENNA_COMMIT)" >&2; exit 1; }

echo "==> app (flutter build linux --release)"
cd "$APP_DIR"
flutter config --no-analytics >/dev/null
flutter pub get
flutter build linux --release --build-name "$NUMERIC" --build-number "$BUILD_NUMBER" \
  --dart-define=ANTENNA_COMMIT="$ANTENNA_COMMIT"
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"
[ -x "$BUNDLE/antenna-desktop" ] || { echo "missing $BUNDLE/antenna-desktop" >&2; exit 1; }

NAME="antenna-desktop-$VERSION-linux-$ARCH"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$BUNDLE" "$STAGE/$NAME"
install -d "$STAGE/$NAME/bin"
install -m 0755 "$CORE_BIN_DIR/antennad" "$CORE_BIN_DIR/antenna" "$STAGE/$NAME/bin/"
# The local model runtime next to the daemon (D-104): LLAMA_DIR from packaging/llama/build.sh, or built here.
if [ -n "${LLAMA_DIR:-}" ]; then
  cp -a "$LLAMA_DIR" "$STAGE/$NAME/bin/llama"
else
  "$ROOT/packaging/llama/build.sh" "$STAGE/$NAME/bin"
fi
cp "$ROOT/LICENSE-AGPL-3.0" "$STAGE/$NAME/LICENSE"
cat > "$STAGE/$NAME/README.txt" <<TXT
Antenna $VERSION ($ANTENNA_COMMIT): the app for Linux (x86_64, GTK 3) with the core inside: the bin/antennad daemon
and the bin/antenna CLI. The app starts the daemon itself if it is not running (as a child process, while the
window is open) and offers to create your node.

Run without installing:
    ./antenna-desktop

To add it to the app menu with an icon, and let antenna:// invite links open the app (in ~/.local/share, no root):
    ./install-desktop-entry.sh            # to undo: ./install-desktop-entry.sh --remove
You can keep this folder anywhere (for example ~/.local/opt/antenna-desktop); after moving it, run the script again.

For a node that runs without the app (a server that is always online), use antenna-$VERSION-linux-$ARCH.tar.gz and
its install.sh (systemd user service). The app connects to it by itself via ~/.local/share/antenna/antennad.sock.

Requires the GTK 3 libraries (on Ubuntu/Debian the libgtk-3-0 package, usually already present on a desktop).
Guide: https://github.com/Danta-Nort/antenna/blob/main/docs/guide/getting-started.md
TXT
mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" | tee "$NAME.tar.gz.sha256")
echo "done: $OUT/$NAME.tar.gz"
