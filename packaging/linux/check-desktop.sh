#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Checks the app archive antenna-desktop-<ver>-linux-<arch>.tar.gz in a temporary directory (touches nothing outside):
#  1. archive contents, core version, no unresolved libraries for the app binaries (ldd);
#  2. install-desktop-entry.sh installs the menu entry (Exec, %u, x-scheme-handler/antenna, StartupWMClass) and icon;
#  3. if xvfb-run is available, the app starts on a virtual display and starts the daemon from bin/ itself (the socket
#     appears in the temporary $HOME, `antenna status` answers); a second launch with an antenna:// link hands it to
#     the first window and exits (no second window).
#   packaging/linux/check-desktop.sh dist/antenna-desktop-0.1.0-preview.1-linux-x86_64.tar.gz
set -euo pipefail

TGZ="${1:?path to antenna-desktop-…-linux-….tar.gz}"
T="$(mktemp -d)"
PKG=""
cleanup() {
  # the app and its child daemon, matched by binary path in the temporary directory (other processes are untouched)
  if [ -n "$PKG" ]; then
    pkill -f -- "$PKG/antenna-desktop" 2>/dev/null || true
    pkill -f -- "$PKG/bin/antennad" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

tar -C "$T" -xzf "$TGZ"
PKG="$(echo "$T"/antenna-desktop-*)"
ID=io.github.danta_nort.antenna
# lib/libflutter_pty.so: the pseudo-terminal of Code mode (the flutter_pty plugin's native library).
for f in antenna-desktop bin/antennad bin/antenna lib/libapp.so lib/libflutter_linux_gtk.so lib/libflutter_pty.so data/icudtl.dat \
  data/flutter_assets data/app_icon.png "data/$ID.desktop" install-desktop-entry.sh LICENSE README.txt; do
  [ -e "$PKG/$f" ] || fail "archive is missing $f"
done
echo "== contents ok; $("$PKG/bin/antenna" --version)"

echo "== ldd"
for b in "$PKG/antenna-desktop" "$PKG"/lib/*.so; do
  if ldd "$b" | grep -q "not found"; then ldd "$b" | grep "not found" >&2; fail "ldd $b"; fi
done
echo "ldd ok: all libraries of the app and plugins resolved"

echo "== menu entry and antenna:// scheme"
XDG="$T/xdg"
XDG_DATA_HOME="$XDG" sh "$PKG/install-desktop-entry.sh" "$PKG" >/dev/null
DE="$XDG/applications/$ID.desktop"
[ -f "$DE" ] || fail "missing $DE"
grep -qx "Exec=\"$PKG/antenna-desktop\" %u" "$DE" || fail "Exec in $DE"
grep -qx "MimeType=x-scheme-handler/antenna;" "$DE" || fail "MimeType in $DE"
grep -qx "StartupWMClass=$ID" "$DE" || fail "StartupWMClass in $DE"
[ -f "$XDG/icons/hicolor/256x256/apps/$ID.png" ] || fail "icon"
XDG_DATA_HOME="$XDG" sh "$PKG/install-desktop-entry.sh" --remove >/dev/null
[ ! -e "$DE" ] || fail "--remove did not remove the entry"
echo "menu entry ok"

if ! command -v xvfb-run >/dev/null; then
  echo "== no xvfb-run: app launch skipped (build, contents and ldd only)"
  exit 0
fi

echo "== app on a virtual display"
H="$T/home"
mkdir -p "$H" "$T/run"
chmod 700 "$T/run"
LINK='antenna://pair#q7k2m4c9x1v8b3n6p0z5r2t7y4w1e8u3i6o9a2s5d8f1g4h7j0kl.mz3xq8c1v6b9n2p5r8t1y4w7e0u3i6o9a2s5d8f1g4h7j0k3l6z9xq.aHR0cHM6Ly9ldWMxLTEucmVsYXkubjAuaXJvaC1jYW5hcnkuaXJvaC5saW5rLi8'
cat > "$T/run.sh" <<EOF
#!/bin/sh
set -u
cd "$PKG"
./antenna-desktop > "$T/window.log" 2>&1 &
i=0
# the app starts the daemon from bin/ itself: wait for its socket in the temporary HOME
while [ ! -S "$H/.local/share/antenna/antennad.sock" ] && [ \$i -lt 120 ]; do sleep 0.5; i=\$((i+1)); done
[ -S "$H/.local/share/antenna/antennad.sock" ] || { echo "the app did not start the daemon"; exit 3; }
"$PKG/bin/antenna" --json status > "$T/status.json" || exit 4
# the app listens for links on its socket: a second launch hands the link over and exits
while [ ! -S "$T/run/antenna-window.sock" ] && [ \$i -lt 160 ]; do sleep 0.5; i=\$((i+1)); done
./antenna-desktop "$LINK" > "$T/second.log" 2>&1
echo "second=\$?"
EOF
chmod +x "$T/run.sh"
out="$(env -i HOME="$H" XDG_RUNTIME_DIR="$T/run" PATH=/usr/bin:/bin LANG=C.UTF-8 \
  timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" "$T/run.sh")" || { cat "$T/window.log" >&2; fail "app launch: $out"; }
grep -q '"state": *"uninitialized"' "$T/status.json" || { cat "$T/status.json" >&2; fail "status of the daemon started by the app"; }
[ "$out" = "second=0" ] || { cat "$T/second.log" >&2; fail "second launch with a link: $out"; }
echo "app ok: started the daemon from bin/ (status: uninitialized); the second launch handed over the antenna:// link and exited"
echo "check-desktop: ok"
