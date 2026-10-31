#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# .deb packages for Linux (D-109, WP11): `antenna` (the daemon and CLI) and `antenna-desktop` (the window), built
# from the already-built antenna-<ver>-linux-<arch>.tar.gz and antenna-desktop-<ver>-linux-<arch>.tar.gz archives
# (no new compilation: the same binaries) with `dpkg-deb --root-owner-group` (no root, nothing installed). The file
# layout is shared with build-rpm.sh in pkg-common.sh.
#
# Layout (D-111): /opt/antenna/… — not /usr/lib/antenna/…, because this ships a self-contained bundle (its own
# binaries and, when present, the vendored local-model runtime, D-104), not libraries the dynamic linker or other
# packages consume, which is exactly what FHS §4 reserves /opt for. It also keeps the two packages' file lists
# disjoint without duplicating the core binaries: `antenna-desktop` only carries the window and Depends on `antenna`
# for antennad/antenna/llama/, in `/opt/antenna/bin` next to it — `apps/antenna_desktop/lib/host/binaries.dart`
# already looks for `<exe dir>/bin/<name>` first, so the window finds the daemon whichever package provided it.
# `/usr/bin/antenna{,d,-desktop}` are symlinks for PATH and for `antenna` inside agent configs.
#
#   packaging/linux/build-deb.sh
#     VERSION=0.1.0-preview.1  (default: packaging/version.sh)
#     ARCH                      (default: uname -m; mapped to Debian's amd64/arm64 for the package metadata only —
#                                the file names stay antenna-<ver>-linux-<arch>.deb, like the archives)
#     OUT=dist                  reads antenna-$VERSION-linux-$ARCH.tar.gz and antenna-desktop-$VERSION-linux-$ARCH.tar.gz
#                                from here (build them first), writes the .deb files and their .sha256 here
# Requires: dpkg-deb (part of dpkg, always present on a Debian/Ubuntu machine); installs nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=packaging/linux/pkg-common.sh
source "$ROOT/packaging/linux/pkg-common.sh"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$("$ROOT/packaging/version.sh")}"
VERSION="${VERSION#v}"
ARCH="${ARCH:-$(uname -m)}"
die() { echo "build-deb: $*" >&2; exit 1; }
command -v dpkg-deb >/dev/null || die "dpkg-deb not found (part of dpkg; this script installs nothing)"

CLI_TGZ="$OUT/antenna-$VERSION-linux-$ARCH.tar.gz"
DESKTOP_TGZ="$OUT/antenna-desktop-$VERSION-linux-$ARCH.tar.gz"
[ -f "$CLI_TGZ" ] || die "missing $CLI_TGZ: build it first (packaging/linux/build-tarball.sh)"
[ -f "$DESKTOP_TGZ" ] || die "missing $DESKTOP_TGZ: build it first (packaging/linux/build-desktop.sh)"

case "$ARCH" in
  x86_64) DEB_ARCH=amd64 ;;
  aarch64 | arm64) DEB_ARCH=arm64 ;;
  *) DEB_ARCH="$ARCH" ;;
esac
# Debian version comparison treats '~' as sorting before everything, even the empty string, so a preview sorts
# before the stable release it precedes ("0.1.0~preview.8" < "0.1.0"); a plain '-' would instead be read as a
# "debian revision" with the opposite effect on some comparisons. Our version has at most one '-' (SemVer pre-release).
DEB_VERSION="${VERSION/-/\~}"
ID=io.github.danta_nort.antenna
PKG_TMP_DIRS=()
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/antenna-deb.XXXXXX")"
PKG_TMP_DIRS+=("$STAGE")
cleanup() { local d; for d in "${PKG_TMP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

build_control() {
  # $1 stage root, $2 package, $3 architecture, $4 depends (comma-joined, may be empty), $5 description file
  mkdir -p "$1/DEBIAN"
  {
    echo "Package: $2"
    echo "Version: $DEB_VERSION"
    echo "Section: net"
    echo "Priority: optional"
    echo "Architecture: $3"
    [ -n "$4" ] && echo "Depends: $4"
    echo "Maintainer: Antenna Release <release@example.com>"
    echo "Homepage: https://github.com/Danta-Nort/antenna"
    cat "$5"
  } > "$1/DEBIAN/control"
}

# --- antenna: the daemon and CLI ------------------------------------------------------------------------------------
cli_root="$STAGE/cli-root"
pkg_stage_cli_tree "$CLI_TGZ" "$cli_root" "$ID"
cat > "$STAGE/cli-desc" <<'EOF'
Description: P2P messenger for people and AI agents (daemon and CLI)
 Antenna is a peer-to-peer messenger with no accounts and no servers of its own, with post-quantum end-to-end
 encryption and per-contact trust levels enforced by the daemon, antennad. This package installs antennad and the
 antenna CLI, and antennad as a systemd --user service (enable it yourself after install: systemctl --user enable
 --now antennad; see /opt/antenna for the local-model runtime when the release has one).
 This is not updated by `antenna update`: use this package manager for updates instead.
EOF
build_control "$cli_root" antenna "$DEB_ARCH" "$(deb_depends_of "$cli_root/opt/antenna/bin/antennad")" "$STAGE/cli-desc"
CLI_DEB="$OUT/antenna-$VERSION-linux-$ARCH.deb"
rm -f "$CLI_DEB"
dpkg-deb --build --root-owner-group "$cli_root" "$CLI_DEB"

# --- antenna-desktop: the window, depends on antenna for the core binaries -----------------------------------------
desk_root="$STAGE/desk-root"
pkg_stage_desktop_tree "$DESKTOP_TGZ" "$desk_root" "$ID"
cat > "$STAGE/desk-desc" <<'EOF'
Description: P2P messenger for people and AI agents (window)
 The Antenna window: chats, contacts, files and settings for the antennad daemon. Depends on the antenna package
 for antennad, the antenna CLI and the local-model runtime: install both .deb files together.
 Registers the antenna:// invite-link handler and an application-menu entry. Not updated by `antenna update`: use
 this package manager for updates instead.
EOF
# libgtk-3-0 pulls in glib/pango/cairo/atk/gdk-pixbuf/X11 transitively (seen in `ldd antenna-desktop`): declaring the
# whole ldd closure here would just repeat what libgtk-3-0 already depends on.
build_control "$desk_root" antenna-desktop "$DEB_ARCH" "antenna (= $DEB_VERSION), libgtk-3-0, libstdc++6" \
  "$STAGE/desk-desc"
DESKTOP_DEB="$OUT/antenna-desktop-$VERSION-linux-$ARCH.deb"
rm -f "$DESKTOP_DEB"
dpkg-deb --build --root-owner-group "$desk_root" "$DESKTOP_DEB"

(cd "$OUT" && sha256sum "$(basename "$CLI_DEB")" | tee "$(basename "$CLI_DEB").sha256")
(cd "$OUT" && sha256sum "$(basename "$DESKTOP_DEB")" | tee "$(basename "$DESKTOP_DEB").sha256")
echo "done: $CLI_DEB"
echo "done: $DESKTOP_DEB"
