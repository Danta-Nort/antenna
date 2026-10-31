#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Adds the Antenna app to the application menu and registers it for antenna:// invite links, for the current user,
# no root. Run it from the built bundle (build/linux/x64/release/bundle): ./install-desktop-entry.sh [bundle path]
#   ./install-desktop-entry.sh --remove   — remove the menu entry and the icon
# The .desktop name equals the app's application id (io.github.danta_nort.antenna): Wayland uses it to find the icon.
set -eu
ID=io.github.danta_nort.antenna
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATA/applications"
ICON="$DATA/icons/hicolor/256x256/apps/$ID.png"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$APPS/$ID.desktop" "$ICON"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" || true
  echo "removed: $APPS/$ID.desktop"
  exit 0
fi

BUNDLE=$(cd "${1:-$(dirname "$0")}" 2>/dev/null && pwd) || { echo "no such bundle directory: ${1:-}" >&2; exit 2; }
EXEC="$BUNDLE/antenna-desktop"
[ -x "$EXEC" ] || { echo "missing $EXEC: pass the app bundle directory" >&2; exit 2; }
mkdir -p "$APPS" "$(dirname "$ICON")"
cp "$BUNDLE/data/app_icon.png" "$ICON"
# spaces in the path are fine (Exec quotes it); quotes and backslashes are not
case "$EXEC" in *\"*|*\\*|*\`*|*\$*) echo "the bundle path must not contain \" \\ \` \$" >&2; exit 2 ;; esac
sed "s|@EXEC@|$EXEC|" "$BUNDLE/data/$ID.desktop" > "$APPS/$ID.desktop"
chmod 0644 "$APPS/$ID.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" || true
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default "$ID.desktop" x-scheme-handler/antenna
  echo "antenna:// links open with: $(xdg-mime query default x-scheme-handler/antenna)"
else
  echo "xdg-mime not found: the antenna:// scheme is registered in $APPS/$ID.desktop (MimeType); the desktop environment will pick it up"
fi
echo "done: $APPS/$ID.desktop → $EXEC"
