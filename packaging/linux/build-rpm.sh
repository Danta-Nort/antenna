#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# .rpm packages for Linux (D-109, WP11): `antenna` (the daemon and CLI) and `antenna-desktop` (the window), from the
# same already-built archives as build-deb.sh, sharing its staging (pkg-common.sh) so both package formats carry
# exactly the same files under /opt/antenna (D-111).
#
# `rpmbuild` is not installed on every build machine (this one included, 2026-10-06) and this script does not
# install it (no system packages, CLAUDE.md): with `rpmbuild` present, it builds the .rpm files as usual; without
# it, it writes the two .spec files and their source payload tarballs to $OUT/rpm-sources/ and says so plainly — a
# documented fallback, not a fake .rpm. Building from there, once rpmbuild (the `rpm-build` package) is available:
#   rpmbuild --define "_topdir $OUT/rpm-sources/rpmbuild" -bb $OUT/rpm-sources/antenna.spec
#   rpmbuild --define "_topdir $OUT/rpm-sources/rpmbuild" -bb $OUT/rpm-sources/antenna-desktop.spec
# then rename the files under rpmbuild/RPMS/*/ to antenna[-desktop]-$VERSION-linux-$ARCH.rpm (this script's own
# naming, matching the .deb and the archives) and move them into $OUT.
#
#   packaging/linux/build-rpm.sh
#     VERSION=0.1.0-preview.1  (default: packaging/version.sh)
#     ARCH                      (default: uname -m; mapped to RPM's x86_64/aarch64 for the package metadata only —
#                                the file names stay antenna-<ver>-linux-<arch>.rpm, like the archives and the .deb)
#     OUT=dist                  reads the two antenna[-desktop]-$VERSION-linux-$ARCH.tar.gz archives from here
#                                (build them first); writes the .rpm files (or the spec+sources fallback) here
# Requires nothing beyond the archives for the fallback; `rpmbuild` (package `rpm-build` / `rpm`) for a real build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=packaging/linux/pkg-common.sh
source "$ROOT/packaging/linux/pkg-common.sh"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$("$ROOT/packaging/version.sh")}"
VERSION="${VERSION#v}"
ARCH="${ARCH:-$(uname -m)}"
die() { echo "build-rpm: $*" >&2; exit 1; }

CLI_TGZ="$OUT/antenna-$VERSION-linux-$ARCH.tar.gz"
DESKTOP_TGZ="$OUT/antenna-desktop-$VERSION-linux-$ARCH.tar.gz"
[ -f "$CLI_TGZ" ] || die "missing $CLI_TGZ: build it first (packaging/linux/build-tarball.sh)"
[ -f "$DESKTOP_TGZ" ] || die "missing $DESKTOP_TGZ: build it first (packaging/linux/build-desktop.sh)"

case "$ARCH" in
  x86_64) RPM_ARCH=x86_64 ;;
  aarch64 | arm64) RPM_ARCH=aarch64 ;;
  *) RPM_ARCH="$ARCH" ;;
esac
# rpm's Version and Release fields may not contain '-': the SemVer pre-release tag moves into Release, prefixed
# "0." so a preview's Release sorts before a final release's plain "1" (the standard rpm pre-release convention).
if [[ "$VERSION" == *-* ]]; then
  RPM_VERSION="${VERSION%%-*}"
  RPM_RELEASE="0.${VERSION#*-}"
else
  RPM_VERSION="$VERSION"
  RPM_RELEASE="1"
fi
ID=io.github.danta_nort.antenna
PKG_TMP_DIRS=()
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/antenna-rpm.XXXXXX")"
PKG_TMP_DIRS+=("$STAGE")
cleanup() { local d; for d in "${PKG_TMP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# %files: every plain file and symlink under the staged tree, as an absolute path (rpm records root:root regardless
# of the uid building it, via %defattr); plus %dir for the non-FHS top-level directories nothing else would own
# (passed in by the caller). Deeper asset directories (antenna-desktop's data/flutter_assets/…) are not individually
# declared: rpm creates them for their files without complaint, `rpm -e` just does not remove them if they end up
# empty — cosmetic, and cheaper than hand-tracking a tree whose shape changes with the Flutter build.
files_of() {
  local root="$1"
  find "$root" -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sed 's#^#/#' | sort
}

write_spec() {
  # $1 stage root, $2 package, $3 depends (rpm Requires, may be empty), $4 summary, $5 description, $6 extra %dir
  # lines (already formatted, may be empty), $7 spec output path, $8 payload tarball path
  local root="$1" name="$2" depends="$3" summary="$4" desc="$5" dirs="$6" spec="$7" payload="$8"
  tar -C "$root" -czf "$payload" .
  {
    echo "Name: $name"
    echo "Version: $RPM_VERSION"
    echo "Release: $RPM_RELEASE"
    echo "Summary: $summary"
    echo "License: AGPL-3.0-only"
    echo "URL: https://github.com/Danta-Nort/antenna"
    echo "Group: Applications/Internet"
    echo "BuildArch: $RPM_ARCH"
    [ -n "$depends" ] && echo "Requires: $depends"
    echo "Source0: $(basename "$payload")"
    echo "%global debug_package %{nil}"
    echo
    echo "%description"
    echo "$desc"
    echo
    echo "%install"
    echo 'rm -rf %{buildroot}'
    echo 'mkdir -p %{buildroot}'
    echo 'tar -C %{buildroot} -xzf %{SOURCE0}'
    echo
    echo "%files"
    echo '%defattr(-,root,root,-)'
    if [ -n "$dirs" ]; then printf '%s\n' "$dirs"; fi
    files_of "$root"
  } > "$spec"
}

# --- antenna: the daemon and CLI ------------------------------------------------------------------------------------
cli_root="$STAGE/cli-root"
pkg_stage_cli_tree "$CLI_TGZ" "$cli_root" "$ID"
write_spec "$cli_root" antenna "" \
  "P2P messenger for people and AI agents (daemon and CLI)" \
  "Antenna is a peer-to-peer messenger with no accounts and no servers of its own, with post-quantum end-to-end encryption and per-contact trust levels enforced by the daemon, antennad. This package installs antennad and the antenna CLI, and antennad as a systemd --user service (enable it yourself after install: systemctl --user enable --now antennad). Not updated by \`antenna update\`: use this package manager for updates instead." \
  "$(printf '%%dir /opt/antenna\n%%dir /opt/antenna/bin\n')" \
  "$STAGE/antenna.spec" "$STAGE/antenna-$VERSION-payload.tar.gz"

# --- antenna-desktop: the window, depends on antenna for the core binaries -----------------------------------------
desk_root="$STAGE/desk-root"
pkg_stage_desktop_tree "$DESKTOP_TGZ" "$desk_root" "$ID"
write_spec "$desk_root" antenna-desktop "antenna = $RPM_VERSION-$RPM_RELEASE" \
  "P2P messenger for people and AI agents (window)" \
  "The Antenna window: chats, contacts, files and settings for the antennad daemon. Depends on the antenna package for antennad, the antenna CLI and the local-model runtime: install both .rpm files together. Registers the antenna:// invite-link handler and an application-menu entry. Not updated by \`antenna update\`: use this package manager for updates instead." \
  "$(printf '%%dir /opt/antenna\n%%dir /opt/antenna/lib\n%%dir /opt/antenna/data\n')" \
  "$STAGE/antenna-desktop.spec" "$STAGE/antenna-desktop-$VERSION-payload.tar.gz"

CLI_RPM="$OUT/antenna-$VERSION-linux-$ARCH.rpm"
DESKTOP_RPM="$OUT/antenna-desktop-$VERSION-linux-$ARCH.rpm"

if command -v rpmbuild >/dev/null; then
  TOPDIR="$STAGE/rpmbuild"
  mkdir -p "$TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cp "$STAGE/antenna-$VERSION-payload.tar.gz" "$STAGE/antenna-desktop-$VERSION-payload.tar.gz" "$TOPDIR/SOURCES/"
  rpmbuild --define "_topdir $TOPDIR" -bb "$STAGE/antenna.spec"
  rpmbuild --define "_topdir $TOPDIR" -bb "$STAGE/antenna-desktop.spec"
  built_cli="$(find "$TOPDIR/RPMS" -name 'antenna-*.rpm' ! -name 'antenna-desktop-*' -print -quit)"
  built_desk="$(find "$TOPDIR/RPMS" -name 'antenna-desktop-*.rpm' -print -quit)"
  [ -n "$built_cli" ] && [ -n "$built_desk" ] || die "rpmbuild did not produce the expected .rpm files"
  rm -f "$CLI_RPM" "$DESKTOP_RPM"
  install -m 0644 "$built_cli" "$CLI_RPM"
  install -m 0644 "$built_desk" "$DESKTOP_RPM"
  (cd "$OUT" && sha256sum "$(basename "$CLI_RPM")" | tee "$(basename "$CLI_RPM").sha256")
  (cd "$OUT" && sha256sum "$(basename "$DESKTOP_RPM")" | tee "$(basename "$DESKTOP_RPM").sha256")
  echo "done: $CLI_RPM"
  echo "done: $DESKTOP_RPM"
else
  SRC_OUT="$OUT/rpm-sources"
  mkdir -p "$SRC_OUT"
  cp "$STAGE/antenna.spec" "$STAGE/antenna-desktop.spec" \
    "$STAGE/antenna-$VERSION-payload.tar.gz" "$STAGE/antenna-desktop-$VERSION-payload.tar.gz" "$SRC_OUT/"
  echo "build-rpm: rpmbuild not found on this machine (the rpm-build package; this script installs nothing)."
  echo "build-rpm: wrote the spec files and their source payloads to $SRC_OUT instead of a .rpm — a documented"
  echo "build-rpm: fallback (see this script's header for the exact rpmbuild command to finish the build elsewhere)."
  echo "build-rpm: no .rpm produced this run: $CLI_RPM and $DESKTOP_RPM are absent, and the release manifest will"
  echo "build-rpm: not list them."
fi
