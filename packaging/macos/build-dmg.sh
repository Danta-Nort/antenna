#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Antenna build for macOS: core (antennad, antenna) + app (Flutter) → Antenna.app with the core inside →
#   dist/Antenna-<version>-macos-<arch>.dmg          — the app (CLI and daemon built in);
#   dist/antenna-<version>-macos-<arch>-cli.tar.gz   — command line and daemon only (the same signed binaries);
# plus a .sha256 for each. Runs on a Mac (locally or in .github/workflows/release.yml). Signed ad hoc by default (without
# a signature macOS on Apple Silicon will not run the binaries at all); with SIGN_IDENTITY, by a Developer ID with the
# hardened runtime and a secure timestamp on all code, ready for packaging/macos/notarize.sh (D-105).
#
#   ARCH=arm64|x86_64|universal  (default arm64 — Apple Silicon)
#   VERSION=0.1.0-preview.1      (default: packaging/version.sh, i.e. Cargo.toml)
#   ANTENNA_COMMIT=<hash>        (default: git rev-parse; shown by `antenna --version` and in the app)
#   BUILD_NUMBER=1               (CFBundleVersion; the run number in CI)
#   OUT=dist                     (output directory)
#   SIGN_IDENTITY="Developer ID Application: <company> (<team>)"   (or its SHA-1; default: ad hoc)
#   SIGN_KEYCHAIN=<path>         (the keychain that holds the identity; default: the search list)
#
# Requires: Xcode (or Command Line Tools + Xcode for flutter build macos), rustup (version from rust-toolchain.toml),
# protoc and cmake (brew install protobuf cmake), Flutter 3.47.6.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="${ARCH:-arm64}"
# same as the app (Runner.xcodeproj); otherwise Rust uses 11.0 for arm64 and 10.12 for x86_64 (docs/PORTABILITY.md §3)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$("$ROOT/packaging/version.sh")}"
VERSION="${VERSION#v}"
NUMERIC="${VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
export ANTENNA_COMMIT="${ANTENNA_COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
APP_DIR="$ROOT/apps/antenna_desktop"

case "$ARCH" in
  arm64) TARGETS=(aarch64-apple-darwin) ;;
  x86_64) TARGETS=(x86_64-apple-darwin) ;;
  universal) TARGETS=(aarch64-apple-darwin x86_64-apple-darwin) ;;
  *) echo "ARCH: arm64 | x86_64 | universal" >&2; exit 2 ;;
esac

for tool in cargo rustup flutter protoc cmake codesign hdiutil lipo swiftc; do
  command -v "$tool" >/dev/null || { echo "$tool not found in PATH" >&2; exit 2; }
done
# flutter_pty (Code mode's terminal) ships a CocoaPods podspec and no Swift package, so Flutter builds it through
# CocoaPods next to the Swift packages of the other plugins.
command -v pod >/dev/null || { echo "CocoaPods (pod) not found: brew install cocoapods" >&2; exit 2; }

mkdir -p "$OUT/bin"
echo "==> core: ${TARGETS[*]} (Antenna $VERSION, $ANTENNA_COMMIT)"
cd "$ROOT"
for t in "${TARGETS[@]}"; do
  rustup target add "$t"
  cargo build --release --locked -p antennad -p antenna-cli --target "$t"
done
for b in antennad antenna; do
  if [ "${#TARGETS[@]}" -gt 1 ]; then
    parts=()
    for t in "${TARGETS[@]}"; do parts+=("$ROOT/target/$t/release/$b"); done
    lipo -create -output "$OUT/bin/$b" "${parts[@]}"
  else
    cp "$ROOT/target/${TARGETS[0]}/release/$b" "$OUT/bin/$b"
  fi
  lipo -info "$OUT/bin/$b"
done
got="$("$OUT/bin/antenna" --version)"
[ "$got" = "antenna $VERSION ($ANTENNA_COMMIT)" ] || { echo "binary version '$got' does not match release $VERSION ($ANTENNA_COMMIT)" >&2; exit 1; }

echo "==> app (Flutter)"
cd "$APP_DIR"
flutter config --no-analytics >/dev/null
flutter pub get
# A bundle left by an earlier build in this tree is re-signed by Xcode as it is, files we add afterwards included
# (Helpers/llama: "code object is not signed at all"): start from a fresh bundle.
rm -rf "$APP_DIR/build/macos/Build/Products/Release/Antenna.app"
# CFBundleShortVersionString is numbers only (0.1.0); the full version and commit are shown in the app (lib/version.dart)
flutter build macos --release --build-name "$NUMERIC" --build-number "$BUILD_NUMBER" \
  --dart-define=ANTENNA_COMMIT="$ANTENNA_COMMIT"
APP="$APP_DIR/build/macos/Build/Products/Release/Antenna.app"
[ -d "$APP" ] || { echo "missing $APP" >&2; exit 1; }

echo "==> core into the app: Contents/Helpers"
mkdir -p "$APP/Contents/Helpers"
install -m 0755 "$OUT/bin/antennad" "$APP/Contents/Helpers/antennad"
install -m 0755 "$OUT/bin/antenna" "$APP/Contents/Helpers/antenna"
# Touch ID for `antenna` in a terminal (D-131): a small Swift helper that uses the window's Secure Enclave key, built
# here with swiftc (it is not part of the Xcode project).
helper_parts=()
for t in "${TARGETS[@]}"; do
  arch="${t%%-*}"
  [ "$arch" = aarch64 ] && arch=arm64
  part="$OUT/antenna-touchid-$arch"
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" \
    -o "$part" "$APP_DIR/macos/Helper/antenna-touchid.swift"
  helper_parts+=("$part")
done
if [ "${#helper_parts[@]}" -gt 1 ]; then
  lipo -create -output "$APP/Contents/Helpers/antenna-touchid" "${helper_parts[@]}"
else
  install -m 0755 "${helper_parts[0]}" "$APP/Contents/Helpers/antenna-touchid"
fi
rm -f "${helper_parts[@]}"
# The local model runtime next to the daemon (D-104): llama.cpp's llama-server for this Mac's architecture (arm64:
# Metal with the shaders built in), from the pinned source.
"$ROOT/packaging/llama/build.sh" "$APP/Contents/Helpers"
# Contents/Helpers may hold only signed code: plain files there (the chat templates, the license, the README) break the
# bundle signature. They go to Contents/Resources/llama; the daemon looks for the templates there (local/pool.rs).
mkdir -p "$APP/Contents/Resources/llama"
mv "$APP/Contents/Helpers/llama/templates" "$APP/Contents/Helpers/llama/LICENSE-llama.cpp" \
  "$APP/Contents/Helpers/llama/README.txt" "$APP/Contents/Resources/llama/"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "==> ad-hoc signing (SIGN_IDENTITY for a Developer ID)"
  # The core gets the hardened runtime (protects the memory that holds keys; system libraries are fine with it).
  # The app itself does not: with ad-hoc signing Flutter.framework has no Team ID, and the hardened runtime's library
  # validation would refuse to load it.
  codesign --force --options runtime --sign - "$APP/Contents/Helpers/antennad" "$APP/Contents/Helpers/antenna" \
    "$APP/Contents/Helpers/antenna-touchid" "$APP/Contents/Helpers/llama/llama-server"
  codesign --force --sign - "$APP"
else
  echo "==> Developer ID signing: $SIGN_IDENTITY"
  # Notarization wants every piece of code signed by the Developer ID with the hardened runtime and a secure timestamp,
  # inside out: the code inside a bundle first, then the bundle. Xcode signed the frameworks ad hoc ("-"), so they are
  # signed again; with one Team ID on everything, library validation loads Flutter.framework.
  CS=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  [ -z "${SIGN_KEYCHAIN:-}" ] || CS+=(--keychain "$SIGN_KEYCHAIN")
  macho() { file -b "$1" | grep -q 'Mach-O'; }
  while IFS= read -r -d '' f; do
    if macho "$f"; then "${CS[@]}" "$f"; fi
  done < <(find "$APP/Contents/Helpers" "$APP/Contents/Frameworks" -type f ! -path '*.framework/*' -print0 2>/dev/null)
  while IFS= read -r -d '' fw; do
    "${CS[@]}" "$fw"
  done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 2>/dev/null)
  # The app's own entitlements (codesign --force drops what Xcode embedded): no App Sandbox, Apple events for osascript.
  "${CS[@]}" --entitlements "$APP_DIR/macos/Runner/Release.entitlements" "$APP"
  codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true
fi
codesign --verify --deep --strict --verbose=2 "$APP"
"$APP/Contents/Helpers/antenna" --version

echo "==> .dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
cp "$ROOT/packaging/macos/README-first-run.txt" "$STAGE/dmg/Read me.txt"
DMG="$OUT/Antenna-$VERSION-macos-$ARCH.dmg"
rm -f "$DMG"
hdiutil create -volname "Antenna $VERSION" -srcfolder "$STAGE/dmg" -ov -format UDZO "$DMG"
# The image carries the same signature as its contents; notarize.sh then submits and staples it (that rewrites the
# .sha256 too).
[ -z "$SIGN_IDENTITY" ] || "${CS[@]}" "$DMG"
# No AppleDouble `._*` files in the image: inside it extended attributes stay native, but a `._*` file that slipped in
# would be junk in the user's Applications folder.
MNT="$STAGE/mnt"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
junk="$(find "$MNT" -name '._*' -print 2>/dev/null || true)"
hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null
[ -z "$junk" ] || { printf 'AppleDouble files in %s:\n%s\n' "$(basename "$DMG")" "$junk" >&2; exit 1; }
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")

echo "==> command line only: the same signed antenna and antennad"
CLI="antenna-$VERSION-macos-$ARCH-cli"
mkdir -p "$STAGE/$CLI/bin"
cp -p "$APP/Contents/Helpers/antennad" "$APP/Contents/Helpers/antenna" "$STAGE/$CLI/bin/"
cp -Rp "$APP/Contents/Helpers/llama" "$STAGE/$CLI/bin/llama"
# The CLI archive keeps the plain layout: the templates next to the runtime.
cp -Rp "$APP/Contents/Resources/llama/." "$STAGE/$CLI/bin/llama/"
cp "$ROOT/LICENSE-AGPL-3.0" "$STAGE/$CLI/LICENSE"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$ANTENNA_COMMIT/g" "$ROOT/packaging/macos/README-cli.txt" \
  > "$STAGE/$CLI/README.txt"
# macOS tar stores extended attributes (quarantine, provenance) as AppleDouble `._<name>` entries, which unpack as junk
# files on Linux and next to the binaries; COPYFILE_DISABLE=1 stops that, and bsdtar's --no-mac-metadata/--no-xattrs
# (when this tar has them) keep the attributes out of the pax headers too.
TAR_FLAGS=()
for f in --no-mac-metadata --no-xattrs; do
  if COPYFILE_DISABLE=1 tar "$f" -cf - -C "$STAGE" "$CLI/README.txt" >/dev/null 2>&1; then TAR_FLAGS+=("$f"); fi
done
COPYFILE_DISABLE=1 tar ${TAR_FLAGS[@]+"${TAR_FLAGS[@]}"} -C "$STAGE" -czf "$OUT/$CLI.tar.gz" "$CLI"
junk="$(tar -tzf "$OUT/$CLI.tar.gz" | grep -E '(^|/)\._' || true)"
[ -z "$junk" ] || { printf 'AppleDouble entries in %s:\n%s\n' "$CLI.tar.gz" "$junk" >&2; exit 1; }
(cd "$OUT" && shasum -a 256 "$CLI.tar.gz" | tee "$CLI.tar.gz.sha256")
echo "done: $DMG, $OUT/$CLI.tar.gz"
