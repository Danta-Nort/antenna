#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Checks the antenna-<ver>-linux-<arch>.tar.gz archive: unpack it into a temporary directory, run install.sh into a
# temporary prefix and a temporary $HOME (no systemd), start antennad from the prefix, create a node via install.sh,
# verify the version and state; separately, that install.sh removes the service and binaries of the earlier `x` preview,
# that the systemd unit template renders (--dry-run), that `antenna update` sees the layout and does not trust the
# public test key (D-82) but has the built-in update URL (D-137), and that the daemon does not trust the public owner
# test key (D-102). Touches nothing outside
# the temporary directory.
#   packaging/linux/check-install.sh dist/antenna-0.1.0-preview.1-linux-x86_64.tar.gz
set -euo pipefail

TGZ="${1:?path to antenna-…-linux-….tar.gz}"
T="$(mktemp -d)"
AD_PID=""
cleanup() {
  [ -n "$AD_PID" ] && kill "$AD_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

tar -C "$T" -xzf "$TGZ"
PKG="$(echo "$T"/antenna-*)"
for f in bin/antenna bin/antennad bin/llama/llama-server bin/llama/LICENSE-llama.cpp install.sh antennad.service README.txt LICENSE; do
  [ -e "$PKG/$f" ] || { echo "FAIL: archive is missing $f" >&2; exit 1; }
done
HOME_T="$T/home"
mkdir -p "$HOME_T"
export HOME="$HOME_T"
unset ANTENNA_DATA_DIR ANTENNA_SOCKET X_DATA_DIR X_SOCKET XDG_DATA_HOME XDG_CONFIG_HOME ANTENNA_UPDATE_URL

# earlier `x` preview: a service and "old" binaries in the prefix (fakes that print versions like the old x/xd)
PREFIX="$T/prefix"
mkdir -p "$PREFIX/bin" "$HOME_T/.config/systemd/user"
printf '#!/bin/sh\necho "xd 0.0.1"\n' > "$PREFIX/bin/xd"
printf '#!/bin/sh\necho "x 0.0.1"\n' > "$PREFIX/bin/x"
chmod +x "$PREFIX/bin/xd" "$PREFIX/bin/x"
printf '[Service]\nExecStart=%s/bin/xd\n' "$PREFIX" > "$HOME_T/.config/systemd/user/xd.service"

echo "== install.sh --dry-run (unit from the template)"
"$PKG/install.sh" --prefix "$PREFIX" --dry-run --no-init > "$T/dry.txt"
grep -q "ExecStart=$PREFIX/bin/antennad --relay n0" "$T/dry.txt" || { cat "$T/dry.txt"; echo "FAIL: unit" >&2; exit 1; }

echo "== install.sh (no systemd, no init): binaries in the prefix, old ones removed"
"$PKG/install.sh" --prefix "$PREFIX" --no-systemd --no-init
[ ! -e "$PREFIX/bin/xd" ] && [ ! -e "$PREFIX/bin/x" ] || { echo "FAIL: old xd/x not removed" >&2; exit 1; }
[ ! -e "$HOME_T/.config/systemd/user/xd.service" ] || { echo "FAIL: xd.service not removed" >&2; exit 1; }
"$PREFIX/bin/antenna" --version
"$PREFIX/bin/antennad" --version

echo "== antenna update sees this layout, and a release build never trusts the public test key (D-82)"
UPD="$(ANTENNA_UPDATE_TEST_KEY=1 "$PREFIX/bin/antenna" update --json)"
echo "$UPD"
echo "$UPD" | grep -q '"kind":"bin_dir"' || { echo "FAIL: antenna update does not see the install.sh layout" >&2; exit 1; }
echo "$UPD" | grep -q '"test_key":false' || { echo "FAIL: the release binary trusts the test key" >&2; exit 1; }
# D-137: a release build checks the project's update address by itself (nothing configured in this $HOME), and `off`
# turns it off.
echo "$UPD" | grep -q '"update_url":"https://' || { echo "FAIL: the release binary has no built-in update URL" >&2; exit 1; }
ANTENNA_UPDATE_URL=off "$PREFIX/bin/antenna" update --json | grep -q '"update_url":null' \
  || { echo "FAIL: ANTENNA_UPDATE_URL=off does not turn the update URL off" >&2; exit 1; }

echo "== antennad from the prefix (default directory in the temporary \$HOME) + install.sh creates the node"
# ANTENNA_OWNER_TEST_KEY=1 asks for the public owner test key: a release build must refuse it all the same (D-102)
ANTENNA_OWNER_TEST_KEY=1 "$PREFIX/bin/antennad" --relay disabled --bind-ip 127.0.0.1 2>"$T/antennad.log" &
AD_PID=$!
printf 'ci-password-123\n' | "$PKG/install.sh" --prefix "$PREFIX" --no-systemd --password-stdin
STATUS="$("$PREFIX/bin/antenna" --json status)"
echo "$STATUS"
echo "$STATUS" | grep -q '"state":"unlocked"' || { echo "FAIL: node not created" >&2; exit 1; }
[ -S "$HOME_T/.local/share/antenna/antennad.sock" ] || { echo "FAIL: no socket in ~/.local/share/antenna" >&2; exit 1; }
echo "== a release daemon never trusts the public owner test key (D-102), even when asked"
printf 'ci-password-123\n' | "$PREFIX/bin/antenna" --json login --password-stdin >/dev/null
KEYS="$("$PREFIX/bin/antenna" --json owner-key list)"
echo "$KEYS"
echo "$KEYS" | grep -q '"test_key":false' || { echo "FAIL: the release daemon trusts the owner test key" >&2; exit 1; }
kill "$AD_PID"; wait "$AD_PID" 2>/dev/null || true; AD_PID=""
echo "OK: $(basename "$TGZ") installs and works"
