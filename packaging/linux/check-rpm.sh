#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Checks the output of build-rpm.sh (D-109, WP11): either the antenna-<ver>-linux-<arch>.rpm and
# antenna-desktop-<ver>-linux-<arch>.rpm packages themselves (a machine with `rpmbuild`), or, on a machine without
# it (this build server, 2026-10-06), the .spec files and source payloads build-rpm.sh wrote to OUT/rpm-sources/
# instead — checked as text, which is what is actually available to check without installing rpm-build.
#   packaging/linux/check-rpm.sh OUT VERSION ARCH
#     e.g. packaging/linux/check-rpm.sh dist 0.1.0-preview.1 x86_64
# Touches nothing outside a temporary directory; never runs `rpm -i` (no root, no change to any package database).
set -euo pipefail

OUT="${1:?output directory (as given to build-rpm.sh)}"
VERSION="${2:?version, e.g. 0.1.0-preview.1}"
ARCH="${3:?arch, e.g. x86_64}"
ID=io.github.danta_nort.antenna
fail() { echo "FAIL: $*" >&2; exit 1; }

CLI_RPM="$OUT/antenna-$VERSION-linux-$ARCH.rpm"
DESKTOP_RPM="$OUT/antenna-desktop-$VERSION-linux-$ARCH.rpm"

if [ -f "$CLI_RPM" ] && [ -f "$DESKTOP_RPM" ]; then
  echo "== real .rpm files present: checking them"
  if command -v rpm >/dev/null; then
    echo "== header fields"
    rpm -qp --queryformat 'antenna: %{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$CLI_RPM"
    desk_requires="$(rpm -qp --queryformat '%{REQUIRENAME}\n' "$DESKTOP_RPM")"
    echo "antenna-desktop: Requires $desk_requires"
    grep -q antenna <<< "$desk_requires" || fail "antenna-desktop .rpm does not Require antenna"
  else
    echo "rpm (the query tool) not installed: header fields not checked"
  fi
  if command -v rpm2cpio >/dev/null && command -v cpio >/dev/null; then
    T="$(mktemp -d)"
    trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/cli" "$T/desk"
    (cd "$T/cli" && rpm2cpio "$CLI_RPM" | cpio -idmv) >/dev/null 2>&1
    (cd "$T/desk" && rpm2cpio "$DESKTOP_RPM" | cpio -idmv) >/dev/null 2>&1
    for f in opt/antenna/bin/antennad opt/antenna/bin/antenna opt/antenna/bin/.antenna-package \
      usr/bin/antenna usr/bin/antennad usr/lib/systemd/user/antennad.service; do
      [ -e "$T/cli/$f" ] || fail "antenna .rpm: missing $f"
    done
    for f in opt/antenna/antenna-desktop "usr/share/applications/$ID.desktop" \
      "usr/share/icons/hicolor/256x256/apps/$ID.png"; do
      [ -e "$T/desk/$f" ] || fail "antenna-desktop .rpm: missing $f"
    done
    echo "rpm2cpio extraction: contents ok"
    grep -qx "ExecStart=/opt/antenna/bin/antennad --relay n0" "$T/cli/usr/lib/systemd/user/antennad.service" \
      || fail "ExecStart in the extracted unit"
    grep -qx 'Exec="/opt/antenna/antenna-desktop" %u' "$T/desk/usr/share/applications/$ID.desktop" \
      || fail "Exec in the extracted desktop entry"
    if command -v desktop-file-validate >/dev/null; then
      desktop-file-validate "$T/desk/usr/share/applications/$ID.desktop"
    else
      echo "desktop-file-validate not installed: skipped"
    fi
  else
    echo "rpm2cpio/cpio not installed: extraction-based checks skipped (header fields only, above)"
  fi
  echo "check-rpm: ok"
  exit 0
fi

SRC="$OUT/rpm-sources"
[ -d "$SRC" ] || fail "neither $CLI_RPM/$DESKTOP_RPM nor $SRC exist: run build-rpm.sh first"
echo "== no .rpm files (rpmbuild is not installed on this machine): checking the spec+sources fallback in $SRC"
for f in antenna.spec antenna-desktop.spec "antenna-$VERSION-payload.tar.gz" "antenna-desktop-$VERSION-payload.tar.gz"; do
  [ -f "$SRC/$f" ] || fail "missing $SRC/$f"
done
CLI_SPEC="$SRC/antenna.spec"
DESK_SPEC="$SRC/antenna-desktop.spec"
for field in Name Version Release Summary License URL BuildArch Source0; do
  grep -q "^$field:" "$CLI_SPEC" || fail "antenna.spec: no $field field"
done
grep -q "^Name: antenna$" "$CLI_SPEC" || fail "antenna.spec: wrong Name"
grep -q "^Requires: antenna " "$DESK_SPEC" || fail "antenna-desktop.spec: no Requires on antenna"
for path in /opt/antenna/bin/antennad /opt/antenna/bin/antenna /opt/antenna/bin/.antenna-package \
  /usr/bin/antenna /usr/bin/antennad /usr/lib/systemd/user/antennad.service; do
  grep -qxF "$path" "$CLI_SPEC" || fail "antenna.spec: %files is missing $path"
done
for path in /opt/antenna/antenna-desktop "/usr/share/applications/$ID.desktop" \
  "/usr/share/icons/hicolor/256x256/apps/$ID.png"; do
  grep -qxF "$path" "$DESK_SPEC" || fail "antenna-desktop.spec: %files is missing $path"
done
# The payload tarballs must actually contain what the spec's %files promises (tar -tf, no extraction needed).
# Listed into a variable first, not grepped straight off the pipe: under `pipefail`, `tar | grep -q` can make `tar`
# see SIGPIPE when grep quits early on a match, and pipefail then reports tar's 141, not grep's success.
cli_payload="$SRC/antenna-$VERSION-payload.tar.gz"
cli_payload_list="$(tar -tzf "$cli_payload")"
grep -qx "./opt/antenna/bin/antennad" <<< "$cli_payload_list" || fail "$cli_payload: no opt/antenna/bin/antennad"
grep -qx "./opt/antenna/bin/.antenna-package" <<< "$cli_payload_list" || fail "$cli_payload: no .antenna-package"
desk_payload="$SRC/antenna-desktop-$VERSION-payload.tar.gz"
desk_payload_list="$(tar -tzf "$desk_payload")"
grep -qx "./opt/antenna/antenna-desktop" <<< "$desk_payload_list" \
  || fail "$desk_payload: no opt/antenna/antenna-desktop"
echo "spec+sources fallback: ok (rpmbuild --define \"_topdir <dir>\" -bb $CLI_SPEC finishes the build elsewhere)"
echo "check-rpm: ok"
