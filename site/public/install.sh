#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Antenna for Linux in one line:
#
#   curl -fsSL https://antenna.contact/install.sh | sh
#   curl -fsSL https://antenna.contact/install.sh | sh -s -- --no-systemd     # options go to install.sh (--help)
#
# Finds the newest release in the signed release manifest on the update host (the address the installed Antenna
# checks too), downloads the node archive for this machine, checks its SHA-256 against the manifest, and runs the
# archive's own install.sh: ~/.local/bin, a systemd user service, `antenna init`. No root. Then the installed
# `antenna` verifies the manifest's signature with the release keys built into it, and says so.
# On a Mac, download the app instead: https://antenna.contact/download/mac
set -eu

HOST="https://updates.stillbyte.dev/antenna"
say() { printf '==> %s\n' "$*"; }
die() { printf 'antenna install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux) ;;
  Darwin) die "on a Mac, download the app: https://antenna.contact/download/mac" ;;
  *) die "this system ($(uname -s)) has no Antenna build yet: see https://github.com/Danta-Nort/antenna" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH=x86_64 ;;
  *) die "this processor ($(uname -m)) has no Linux build yet (x86_64 only): see https://github.com/Danta-Nort/antenna" ;;
esac
for t in curl tar sha256sum awk mktemp; do
  command -v "$t" >/dev/null 2>&1 || die "needs $t"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Stable first; until the first stable release exists, the newest preview.
MANIFEST_URL=""
for ch in stable preview; do
  if curl -fsSL --proto '=https' --tlsv1.2 "$HOST/antenna-$ch-manifest.json" -o "$TMP/manifest.json" 2>/dev/null; then
    MANIFEST_URL="$HOST/antenna-$ch-manifest.json"
    break
  fi
done
[ -n "$MANIFEST_URL" ] || die "could not reach $HOST (check the internet connection)"

# The node archive for this machine: os linux, kind cli, this arch. The manifest is written by our release tool, one
# field per line; the signature over it is checked after the install, below.
PICK="$(awk -v arch="$ARCH" '
  /"name":/   { gsub(/[",]/, "", $2); name = $2 }
  /"os":/     { gsub(/[",]/, "", $2); os = $2 }
  /"arch":/   { gsub(/[",]/, "", $2); ar = $2 }
  /"kind":/   { gsub(/[",]/, "", $2); kind = $2 }
  /"sha256":/ { gsub(/[",]/, "", $2); sha = $2 }
  /^ *}/      { if (os == "linux" && kind == "cli" && ar == arch && name != "") { print name, sha; exit } }
' "$TMP/manifest.json")"
NAME="${PICK% *}"
SHA="${PICK#* }"
case "$NAME" in
  antenna-*-linux-"$ARCH".tar.gz) ;;
  *) die "the release manifest names no Linux archive for $ARCH" ;;
esac
printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || die "the release manifest has no SHA-256 for $NAME"

say "downloading $NAME"
curl -fSL --proto '=https' --tlsv1.2 --progress-bar "$HOST/$NAME" -o "$TMP/$NAME" || die "download failed"
printf '%s  %s\n' "$SHA" "$TMP/$NAME" | sha256sum -c --quiet - || die "$NAME does not match the release manifest: nothing installed"
tar -xzf "$TMP/$NAME" -C "$TMP"
DIR="$TMP/${NAME%.tar.gz}"
[ -x "$DIR/install.sh" ] || die "no install.sh in $NAME"

# install.sh asks for the owner password on the terminal: give it the terminal, not this pipe.
if [ -t 0 ]; then
  "$DIR/install.sh" "$@"
elif [ -r /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
  "$DIR/install.sh" "$@" < /dev/tty
else
  "$DIR/install.sh" "$@"
fi

BIN="$HOME/.local/bin"
prev=""
for a in "$@"; do
  [ "$prev" = "--prefix" ] && BIN="$a/bin"
  prev="$a"
done
if [ -x "$BIN/antenna" ]; then
  if "$BIN/antenna" update --check --url "$MANIFEST_URL" >/dev/null 2>&1; then
    say "release signature: valid (checked with the keys built into antenna)"
  else
    printf '!! antenna could not verify the release signature of %s: run  antenna update --check  to see why\n' \
      "$MANIFEST_URL" >&2
  fi
fi
