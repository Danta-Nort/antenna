#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Manual check of `antenna update` on a Mac (D-82): what only macOS can show, on a throwaway copy of the app. The unit
# tests run the same installer against a fake macOS on any machine; this script runs it against the real tools:
# hdiutil (read-only mount), ditto --noqtn, codesign --verify --deep --strict, plutil, the atomic APFS swap
# (renamex_np RENAME_SWAP), the .previous copy, the rollback, and recovery after a crash in the middle.
#
#   packaging/macos/check-update.sh <Antenna-<version>-macos-arm64.dmg>
#
# The .dmg must be built from a commit that has `antenna update` (0.1.0-preview.2 or later): a release, or
# packaging/macos/build-dmg.sh on this Mac. Run it from the repository (it builds the debug antenna, antennad and
# antenna-release with cargo).
#
# What it does NOT touch: /Applications/Antenna.app, the LaunchAgent io.github.danta-nort.antenna.daemon, a running
# Antenna window, ~/.local/share/antenna. Everything lives in a temporary folder under /tmp with its own $HOME and data
# directory; the app copy there plays "the installed version". The LaunchAgent restart and the window relaunch are
# checked by a person with a real install: see the end of the output.
set -euo pipefail

DMG="${1:?usage: packaging/macos/check-update.sh <Antenna-<version>-macos-<arch>.dmg>}"
[ "$(uname -s)" = Darwin ] || { echo "this script runs on macOS" >&2; exit 2; }
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
NAME="$(basename "$DMG")"
case "$NAME" in Antenna-*-macos-*.dmg) ;; *) echo "expected Antenna-<version>-macos-<arch>.dmg, got $NAME" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

fact() { printf 'FACT update: %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
inode() { stat -f %i "$1"; }

# A short path: the daemon socket must fit in 103 bytes (PORTABILITY M-14).
T="$(mktemp -d /tmp/au.XXXXXX)"
T="$(cd "$T" && pwd -P)"
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null || true
  [ -d "$T/mnt" ] && hdiutil detach -force "$T/mnt" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

echo "== build the debug antenna, antennad and antenna-release"
(cd "$ROOT" && cargo build -p antenna-cli -p antennad -p antenna-release)
DBG="$ROOT/target/debug"

echo "== the new version: the app inside $NAME"
mkdir -p "$T/mnt" "$T/release" "$T/Applications" "$T/home" "$T/d"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$T/mnt" "$DMG" >/dev/null
NEW_LINE="$("$T/mnt/Antenna.app/Contents/Helpers/antenna" --version)"
VERSION="$(echo "$NEW_LINE" | sed -E 's/^antenna ([^ ]+) \(([0-9a-f]+)\)$/\1/')"
COMMIT="$(echo "$NEW_LINE" | sed -E 's/^antenna ([^ ]+) \(([0-9a-f]+)\)$/\2/')"
[ -n "$VERSION" ] && [ "$VERSION" != "$NEW_LINE" ] || fail "cannot read the version from '$NEW_LINE'"
# The "installed" version: a copy of the same app whose CLI is the debug build (it accepts the test key and the
# failure injection when asked; release builds never do).
ditto --noqtn "$T/mnt/Antenna.app" "$T/Applications/Antenna.app"
hdiutil detach "$T/mnt" >/dev/null
cp "$DBG/antenna" "$T/Applications/Antenna.app/Contents/Helpers/antenna"
APP="$T/Applications/Antenna.app"
# A Developer ID app with the hardened runtime does not start with a replaced helper: the kernel holds every binary of
# the bundle at _dyld_start on the broken seal ("nested code is modified or invalid"; TROUBLESHOOTING 2026-10-28). The
# throwaway copy is signed again as a whole, ad hoc; the new version from the .dmg keeps its own signature.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || fail "cannot re-sign the throwaway copy ad hoc"
A_INODE="$(inode "$APP")"
fact "new version $VERSION ($COMMIT) from $NAME; installed copy at $APP (inode $A_INODE)"

echo "== a test-signed manifest for it"
cp "$DMG" "$T/release/"
"$DBG/antenna-release" manifest --version "$VERSION" --commit "$COMMIT" \
  --out "$T/release/antenna-$VERSION-manifest.json" "$T/release"
"$DBG/antenna-release" sign --test-key "$T/release/antenna-$VERSION-manifest.json"

A_ENV=(env HOME="$T/home" ANTENNA_DATA_DIR="$T/d" ANTENNA_UPDATE_TEST_KEY=1 ANTENNA_UPDATE_CURRENT_VERSION=0.0.1)
PW="check-update-password-1"
start_daemon() {
  "$APP/Contents/Helpers/antennad" --data-dir "$T/d" --relay disabled --bind-ip 127.0.0.1 2>>"$T/antennad.log" &
  DPID=$!
  # The first start of a notarized binary from a new path waits for the system's assessment: up to a minute.
  for _ in $(seq 1 600); do [ -S "$T/d/antennad.sock" ] && break; sleep 0.1; done
  [ -S "$T/d/antennad.sock" ] || fail "the daemon did not start ($T/antennad.log)"
}

# A restarted daemon has its keys locked: the owner password is checked against the unlocked keystore.
unlock() {
  printf '%s\n' "$PW" | "${A_ENV[@]}" "$APP/Contents/Helpers/antenna" unlock --password-stdin >/dev/null
}

echo "== a daemon of the installed copy, a node"
start_daemon
printf '%s\n' "$PW" | "${A_ENV[@]}" "$APP/Contents/Helpers/antenna" init --password-stdin >/dev/null
# The installer finds a running window by the executable path that `ps -axo pid=,comm=` prints (the same call it makes;
# pgrep would not test that).
# The list is read whole first: with pipefail, `ps | grep -q` fails when grep stops at the match and ps gets SIGPIPE.
procs="$(ps -axo pid=,comm=)"
if grep -qE "^ *$DPID $APP/Contents/Helpers/antennad\$" <<<"$procs"; then
  fact "ps -axo comm shows the full executable path (the installer finds the window this way)"
else
  fail "ps -axo pid=,comm= does not show the full path: '$(ps -o pid=,comm= -p "$DPID")'"
fi

echo "== dry run"
out="$("${A_ENV[@]}" "$APP/Contents/Helpers/antenna" update --from "$T/release" --dry-run --json)"
echo "$out"
echo "$out" | grep -q '"kind":"macos_app"' || fail "not seen as a macOS app"
echo "$out" | grep -q '"valid":true' || fail "signature"

echo "== an error right after the swap: the old app is put back"
set +e
out="$(printf '%s\n' "$PW" | "${A_ENV[@]}" ANTENNA_UPDATE_FAIL_AT=swap1 "$APP/Contents/Helpers/antenna" update \
  --from "$T/release" --yes --password-stdin --json)"
set -e
echo "$out"
echo "$out" | grep -q 'was restored' || fail "no restore after the injected error"
[ "$(inode "$APP")" = "$A_INODE" ] || fail "the old app is not back after the error"
fact "error at swap1: restored, inode $(inode "$APP")"
kill -0 "$DPID" 2>/dev/null && kill "$DPID"
wait "$DPID" 2>/dev/null || true
start_daemon
unlock

echo "== the install"
out="$(printf '%s\n' "$PW" | "${A_ENV[@]}" "$APP/Contents/Helpers/antenna" update --from "$T/release" --yes \
  --password-stdin --json)"
echo "$out"
echo "$out" | grep -q '"action":"install"' || fail "install"
[ "$("$APP/Contents/Helpers/antenna" --version)" = "$NEW_LINE" ] || fail "the new app is not in place"
[ "$(inode "$APP.previous")" = "$A_INODE" ] || fail "the old app is not kept as .previous"
codesign --verify --deep --strict "$APP" || fail "the installed app's signature does not verify"
! kill -0 "$DPID" 2>/dev/null || fail "the daemon of the old app is still running"
DPID=""
xattr -lr "$APP" | grep -q com.apple.quarantine && fail "the installed app carries a quarantine flag"
fact "installed: $NEW_LINE; .previous inode $A_INODE; codesign ok; no quarantine flag; old daemon stopped"
tail -n 20 "$T/home/Library/Logs/Antenna/update.log"

echo "== rollback (by the new app's own CLI, no daemon running)"
out="$(env HOME="$T/home" ANTENNA_DATA_DIR="$T/d" "$APP/Contents/Helpers/antenna" update --rollback --yes --json)"
echo "$out"
[ "$(inode "$APP")" = "$A_INODE" ] || fail "rollback did not put the old app back"
fact "rollback: inode $(inode "$APP") is the original"

echo "== a crash right after the swap: the next antenna update undoes it"
start_daemon
unlock
set +e
printf '%s\n' "$PW" | "${A_ENV[@]}" ANTENNA_UPDATE_FAIL_AT=swap1:abort "$APP/Contents/Helpers/antenna" update \
  --from "$T/release" --yes --password-stdin --json >/dev/null
code=$?
set -e
[ "$code" = 99 ] || fail "expected the injected crash (exit 99), got $code"
[ "$(inode "$APP")" != "$A_INODE" ] || fail "the crash should have left the new app in place"
out="$(env HOME="$T/home" ANTENNA_DATA_DIR="$T/d" "$APP/Contents/Helpers/antenna" update --json)"
echo "$out"
echo "$out" | grep -q '"recovered":"' || fail "no recovery reported"
[ "$(inode "$APP")" = "$A_INODE" ] || fail "recovery did not put the old app back"
fact "crash at swap1 then antenna update: recovered, inode $(inode "$APP")"

cat <<EOF

OK: antenna update on this Mac: mount, copy, codesign, swap, .previous, rollback, recovery.

Still for a person, with the real app (it closes and reopens the window and restarts the daemon):
  1. Install Antenna $VERSION's predecessor (0.1.0-preview.2 or later) from its .dmg as usual, open it, unlock.
  2. Put the newer release's manifest, .sig and .dmg in one folder (or receive them over Antenna and accept them).
  3. Settings → Updates → "Install update from file…" → the folder → check version, channel, signature → "Install and
     restart"; or in Terminal: antenna update --from <folder>.
  4. Expect: the window closes, comes back with the new version, asks for the password (keys locked after the restart);
     ~/Library/Logs/Antenna/update.log has every step; /Applications/Antenna.app.previous exists;
     antenna update --rollback goes back.
EOF
