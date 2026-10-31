#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Notarize a .dmg that build-dmg.sh signed with a Developer ID (SIGN_IDENTITY), staple the ticket and check what a
# user's Mac will check (D-105):
#
#   packaging/macos/notarize.sh dist/Antenna-<version>-macos-<arch>.dmg
#
#   NOTARY_PROFILE=antenna-notary  (the notarytool keychain profile: `xcrun notarytool store-credentials`, an App Store
#                                   Connect API key or an Apple ID with an app-specific password; default antenna-notary)
#   NOTARY_KEYCHAIN=<path>         (the keychain that holds the profile; default: the search list)
#
# The binaries of the CLI archive are the same signed files as in the app, so the .dmg's ticket covers them too;
# Gatekeeper finds it online (a bare Mach-O cannot carry a stapled ticket).
set -euo pipefail

DMG="${1:?usage: notarize.sh <path to .dmg>}"
[ -f "$DMG" ] || { echo "no such file: $DMG" >&2; exit 2; }
PROFILE="${NOTARY_PROFILE:-antenna-notary}"
AUTH=(--keychain-profile "$PROFILE")
[ -z "${NOTARY_KEYCHAIN:-}" ] || AUTH+=(--keychain "$NOTARY_KEYCHAIN")

# Refuse early what notarization would refuse after minutes in the queue.
codesign --verify --strict --verbose=2 "$DMG"
codesign -dv "$DMG" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]' \
  || { echo "$DMG is not signed with a Developer ID (build-dmg.sh with SIGN_IDENTITY)" >&2; exit 1; }

echo "==> notarytool submit (waits for Apple's answer)"
LOG="$(mktemp -d)"
trap 'rm -rf "$LOG"' EXIT
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 2h --output-format json | tee "$LOG/submit.json"
id="$(plutil -extract id raw -o - "$LOG/submit.json")"
status="$(plutil -extract status raw -o - "$LOG/submit.json")"
if [ "$status" != Accepted ]; then
  # The log lists every file that failed and why (no signature, no hardened runtime, no secure timestamp).
  xcrun notarytool log "$id" "${AUTH[@]}" >&2 || true
  echo "notarization: $status ($id)" >&2
  exit 1
fi
xcrun notarytool log "$id" "${AUTH[@]}" "$LOG/notary.json" && grep -E '"(status|statusSummary|issues)"' "$LOG/notary.json" || true

echo "==> stapler"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> checks a user's Mac makes"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
MNT="$LOG/mnt"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
ok=0
codesign --verify --deep --strict --verbose=2 "$MNT/Antenna.app" && spctl --assess --type execute --verbose=2 "$MNT/Antenna.app" || ok=$?
hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null
[ "$ok" -eq 0 ] || exit "$ok"

# Stapling changed the file: its published checksum changes with it.
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "notarized and stapled: $DMG ($id)"
