#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Checks the antenna-<ver>-linux-<arch>.deb and antenna-desktop-<ver>-linux-<arch>.deb packages (D-109, WP11):
# extracts both with `dpkg-deb -x` into one temporary root, the way apt would lay them out together (/opt/antenna
# shared between them), and checks:
#  1. file list, ownership (root:root, from the .deb itself: `dpkg-deb -c`, not what unprivileged extraction gives
#     on disk), permissions, the Depends fields, the package-manager marker file;
#  2. the systemd user unit's content (ExecStart, no leftover @…@ placeholders);
#  3. the desktop entry (Exec, MimeType, StartupWMClass; `desktop-file-validate` when that tool is installed);
#  4. that `antenna update` on this layout refuses with `unsupported_install` and names the package manager — it
#     must never try to replace files dpkg/rpm track (the positive control is check-install.sh, which checks the
#     very same binaries DO self-update in the install.sh layout: reverting the marker-file check in
#     `antenna_update::install::target::Target::detect` makes this step fail, the negative control);
#  5. if `xvfb-run` is available, that the window starts the daemon from `/opt/antenna/bin` under this split layout
#     (the one thing specific to the package, not already covered by check-desktop.sh's launch check of the
#     self-contained tarball bundle). Wayland itself is not checked: no Wayland compositor is installed on this
#     build server (`weston`/`Xwayland`) to drive a real Wayland launch, only Xvfb (X11); said plainly rather than
#     claimed.
# Touches nothing outside the temporary directory; never runs `dpkg -i` (no root, no change to the system's package
# database).
#   packaging/linux/check-deb.sh dist/antenna-0.1.0-x-linux-x86_64.deb dist/antenna-desktop-0.1.0-x-linux-x86_64.deb
set -euo pipefail

CLI_DEB="${1:?path to antenna-…-linux-….deb}"
DESKTOP_DEB="${2:?path to antenna-desktop-…-linux-….deb}"
ID=io.github.danta_nort.antenna
T="$(mktemp -d)"
PKG=""
cleanup() {
  if [ -n "$PKG" ]; then
    pkill -f -- "$PKG/antenna-desktop" 2>/dev/null || true
    pkill -f -- "$PKG/bin/antennad" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== control fields"
for f in Package Version Architecture Depends; do
  v="$(dpkg-deb -f "$CLI_DEB" "$f")"
  [ -n "$v" ] || fail "antenna .deb: no $f field"
  echo "antenna: $f: $v"
done
[ "$(dpkg-deb -f "$CLI_DEB" Package)" = antenna ] || fail "antenna .deb: wrong Package"
DESK_DEPENDS="$(dpkg-deb -f "$DESKTOP_DEB" Depends)"
echo "antenna-desktop: Depends: $DESK_DEPENDS"
case "$DESK_DEPENDS" in
  *"antenna (= "*) ;;
  *) fail "antenna-desktop .deb does not Depend on an exact antenna version: $DESK_DEPENDS" ;;
esac

echo "== ownership and permissions recorded in the archives (root:root; dpkg-deb -c, not unprivileged extraction)"
cli_list="$(dpkg-deb -c "$CLI_DEB")"
desk_list="$(dpkg-deb -c "$DESKTOP_DEB")"
for line in \
  '-rwxr-xr-x root/root .*/opt/antenna/bin/antennad$' \
  '-rwxr-xr-x root/root .*/opt/antenna/bin/antenna$' \
  '-rw-r--r-- root/root .*/opt/antenna/bin/\.antenna-package$' \
  'root/root .*/usr/bin/antenna -> /opt/antenna/bin/antenna$' \
  'root/root .*/usr/bin/antennad -> /opt/antenna/bin/antennad$' \
  '-rw-r--r-- root/root .*/usr/lib/systemd/user/antennad.service$'; do
  echo "$cli_list" | grep -Eq -e "$line" || fail "antenna .deb: no match for /$line/"
done
for line in \
  '-rwxr-xr-x root/root .*/opt/antenna/antenna-desktop$' \
  "root/root .*/usr/bin/antenna-desktop -> /opt/antenna/antenna-desktop\$" \
  "-rw-r--r-- root/root .*/usr/share/applications/$ID.desktop\$" \
  "-rw-r--r-- root/root .*/usr/share/icons/hicolor/256x256/apps/$ID.png\$"; do
  echo "$desk_list" | grep -Eq -e "$line" || fail "antenna-desktop .deb: no match for /$line/"
done
echo "contents ok"

ROOT="$T/root"
mkdir -p "$ROOT"
dpkg-deb -x "$CLI_DEB" "$ROOT"
dpkg-deb -x "$DESKTOP_DEB" "$ROOT"
PKG="$ROOT/opt/antenna"

echo "== the package-manager marker, and antenna update refuses on this layout (D-109)"
[ -f "$PKG/bin/.antenna-package" ] || fail "no .antenna-package marker in the extracted tree"
"$PKG/bin/antenna" --version
UPD="$("$PKG/bin/antenna" update --json)"
echo "$UPD"
echo "$UPD" | grep -q '"kind":"unsupported"' || fail "antenna update does not refuse the .deb layout"
echo "$UPD" | grep -qi "package manager" || fail "the refusal does not name the package manager"

echo "== systemd user unit"
UNIT="$ROOT/usr/lib/systemd/user/antennad.service"
grep -qx "ExecStart=/opt/antenna/bin/antennad --relay n0" "$UNIT" || fail "ExecStart in $UNIT"
grep -q '@.*@' "$UNIT" && fail "leftover @…@ placeholder in $UNIT"
echo "unit ok"

echo "== desktop entry and antenna:// scheme"
DE="$ROOT/usr/share/applications/$ID.desktop"
grep -qx 'Exec="/opt/antenna/antenna-desktop" %u' "$DE" || fail "Exec in $DE"
grep -qx "MimeType=x-scheme-handler/antenna;" "$DE" || fail "MimeType in $DE"
grep -qx "StartupWMClass=$ID" "$DE" || fail "StartupWMClass in $DE"
[ -f "$ROOT/usr/share/icons/hicolor/256x256/apps/$ID.png" ] || fail "icon"
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$DE"
  echo "desktop-file-validate: ok"
else
  echo "desktop-file-validate not installed: skipped (not required on this build server)"
fi
echo "desktop entry ok"

if ! command -v xvfb-run >/dev/null; then
  echo "== no xvfb-run: launch check skipped (contents, ownership, unit and desktop entry only)"
  exit 0
fi

echo "== the window starts the daemon from the package's split layout (/opt/antenna/bin, not a self-contained bundle)"
H="$T/home"
mkdir -p "$H" "$T/run"
chmod 700 "$T/run"
cat > "$T/run.sh" <<EOF
#!/bin/sh
set -u
cd "$PKG"
./antenna-desktop > "$T/window.log" 2>&1 &
i=0
while [ ! -S "$H/.local/share/antenna/antennad.sock" ] && [ \$i -lt 120 ]; do sleep 0.5; i=\$((i+1)); done
[ -S "$H/.local/share/antenna/antennad.sock" ] || { echo "the app did not start the daemon"; exit 3; }
"$PKG/bin/antenna" --json status > "$T/status.json" || exit 4
EOF
chmod +x "$T/run.sh"
out="$(env -i HOME="$H" XDG_RUNTIME_DIR="$T/run" PATH=/usr/bin:/bin LANG=C.UTF-8 \
  timeout 60 xvfb-run -a -s "-screen 0 1440x900x24" "$T/run.sh")" || { cat "$T/window.log" >&2; fail "app launch: $out"; }
grep -q '"state": *"uninitialized"' "$T/status.json" || { cat "$T/status.json" >&2; fail "status of the daemon started by the app"; }
echo "app ok: started the daemon from opt/antenna/bin (status: uninitialized)"
echo "check-deb: ok"
