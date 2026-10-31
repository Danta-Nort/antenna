#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Installs an Antenna node on Linux (a server for an always-on agent, or a desktop without the app): no apt, no root.
#   - antennad and antenna → ~/.local/bin (or --prefix /usr/local — then run it with sudo yourself);
#   - the daemon is a systemd **user** service, antennad.service (template antennad.service next to this script;
#     restarts after a failure, starts at login);
#   - antenna init creates the device key (owner password; it cannot be recovered).
# After a reboot the keys stay locked until `antenna unlock`: the daemon runs, but links stay silent.
#
# The earlier `x` preview (before the rename to Antenna): its xd.service is stopped and removed, and its xd/x
# binaries are removed only if they really are those binaries (`--version`). antennad moves the ~/.local/share/x
# data itself on first start, once.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]
  --prefix DIR       where to install bin/ (default ~/.local; /usr/local needs sudo)
  --relay URL|n0     daemon relay (default n0, the public n0 relays)
  --no-systemd       do not install the systemd service (start the daemon yourself: antennad &)
  --no-init          do not create the device key (run antenna init later)
  --password-stdin   read the antenna init password from the first line of stdin (for scripts)
  --data-dir DIR     daemon data directory (default ~/.local/share/antenna)
  --unit-dir DIR     where to write antennad.service (default ~/.config/systemd/user)
  --no-start         write the service but do not start it (for testing)
  --dry-run          only show what would be done
EOF
}

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local"
RELAY="n0"
SYSTEMD=1
INIT=1
PW_STDIN=0
DATA_DIR=""
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
START=1
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift ;;
    --relay) RELAY="$2"; shift ;;
    --no-systemd) SYSTEMD=0 ;;
    --no-init) INIT=0 ;;
    --password-stdin) PW_STDIN=1 ;;
    --data-dir) DATA_DIR="$2"; shift ;;
    --unit-dir) UNIT_DIR="$2"; shift ;;
    --no-start) START=0 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

run() {
  if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

say() { printf '==> %s\n' "$*"; }

for b in antennad antenna; do
  [ -x "$HERE/bin/$b" ] || { echo "missing $HERE/bin/$b: run install.sh from the unpacked archive" >&2; exit 1; }
done
[ -f "$HERE/antennad.service" ] || { echo "missing $HERE/antennad.service next to install.sh" >&2; exit 1; }

BIN="$PREFIX/bin"

# --- the earlier `x` preview: service and binaries --------------------------------------------------------------
OLD_UNIT="$UNIT_DIR/xd.service"
if [ -f "$OLD_UNIT" ]; then
  say "earlier x preview: stopping and removing xd.service (antennad moves the data itself)"
  if [ "$SYSTEMD" = 0 ]; then
    echo "    ! --no-systemd: leaving the service alone; if xd is still running, stop it: systemctl --user disable --now xd"
  elif [ "$DRY" = 0 ] && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now xd.service || true
  else
    printf '  [dry-run] systemctl --user disable --now xd.service\n'
  fi
  run rm -f "$OLD_UNIT"
  [ "$DRY" = 0 ] && [ "$SYSTEMD" = 1 ] && { systemctl --user daemon-reload 2>/dev/null || true; }
fi
for old in xd x; do
  # only our old binary: `xd --version` → "xd 0.0.1…", `x --version` → "x 0.0.1…"
  if [ -x "$BIN/$old" ] && "$BIN/$old" --version 2>/dev/null | grep -Eq "^$old 0\.0\."; then
    say "removing $BIN/$old from the earlier preview"
    run rm -f "$BIN/$old"
  fi
done

say "binaries → $BIN"
run mkdir -p "$BIN"
run install -m 0755 "$HERE/bin/antennad" "$BIN/antennad"
run install -m 0755 "$HERE/bin/antenna" "$BIN/antenna"
# The local model runtime (D-104): the daemon looks for it in llama/ next to itself. Replaced as a whole folder.
if [ -d "$HERE/bin/llama" ]; then
  say "local model runtime → $BIN/llama"
  run rm -rf "$BIN/llama.new"
  run cp -a "$HERE/bin/llama" "$BIN/llama.new"
  run rm -rf "$BIN/llama"
  run mv "$BIN/llama.new" "$BIN/llama"
fi
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "    ! $BIN is not in PATH: add this line to ~/.profile:  export PATH=\"$BIN:\$PATH\"" ;;
esac

D_ARGS=(--relay "$RELAY")
[ -n "$DATA_DIR" ] && D_ARGS+=(--data-dir "$DATA_DIR")
A_ARGS=()
[ -n "$DATA_DIR" ] && A_ARGS+=(--data-dir "$DATA_DIR")
SOCK="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/antenna}/antennad.sock"

if [ "$SYSTEMD" = 1 ]; then
  if [ "$START" = 1 ] && [ "$DRY" = 0 ] && ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "the systemd user session is not available (no user login?). Re-run with --no-systemd and start antennad yourself," >&2
    echo "or enable it: sudo loginctl enable-linger $USER" >&2
    exit 1
  fi
  UNIT="$UNIT_DIR/antennad.service"
  say "service → $UNIT"
  run mkdir -p "$UNIT_DIR"
  sed_esc() { printf '%s' "$1" | sed -e 's/[#&\\]/\\&/g'; }
  UNIT_TEXT="$(sed -e "s#@ANTENNAD@#$(sed_esc "$BIN/antennad")#" -e "s#@ARGS@#$(sed_esc "${D_ARGS[*]}")#" \
    "$HERE/antennad.service")"
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$UNIT_TEXT" | sed 's/^/  [dry-run] | /'
  else
    printf '%s\n' "$UNIT_TEXT" > "$UNIT"
  fi
  if [ "$START" = 1 ]; then
    run systemctl --user daemon-reload
    run systemctl --user enable --now antennad.service
    if [ "$DRY" = 0 ] && command -v loginctl >/dev/null && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
      echo "    ! to keep the daemon running without a login session (server), enable: sudo loginctl enable-linger $USER"
    fi
  fi
else
  say "systemd not used: start the daemon yourself:  $BIN/antennad ${D_ARGS[*]} &"
  # A daemon the person already started gets its key below; with none running there is nothing to wait for, and
  # init is their next step once it runs.
  if [ "$INIT" = 1 ] && [ ! -S "$SOCK" ]; then
    say "then create the device key:  $BIN/antenna ${A_ARGS[*]:+${A_ARGS[*]} }init"
    INIT=0
  fi
fi

if [ "$INIT" = 1 ] && [ "$DRY" = 0 ]; then
  say "waiting for the daemon ($SOCK)"
  for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
  if [ ! -S "$SOCK" ]; then
    echo "    ! the daemon is not responding: check  systemctl --user status antennad  /  journalctl --user -u antennad" >&2
    exit 1
  fi
  STATE="$("$BIN/antenna" "${A_ARGS[@]}" --json status | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')"
  case "$STATE" in
    uninitialized)
      say "creating the device key (antenna init). The password cannot be recovered: keep it somewhere safe."
      if [ "$PW_STDIN" = 1 ]; then
        "$BIN/antenna" "${A_ARGS[@]}" init --password-stdin
      else
        "$BIN/antenna" "${A_ARGS[@]}" init
      fi
      ;;
    locked) say "the node already exists and its keys are locked: antenna unlock" ;;
    unlocked) say "the node already exists and is unlocked" ;;
    *) echo "    ! unexpected daemon state: '$STATE'" >&2 ;;
  esac
fi

cat <<EOF

Done. Next:
  antenna status                       — node status
  antenna unlock                       — after every server reboot (keys stay locked until the password)
  antenna invite --trust 3 --label mac — an invite for your Mac (or the other way round: antenna join <link> here)
  antenna agent add jarvis --local-level 5   — a token for an agent on this server
Guide: https://github.com/Danta-Nort/antenna/blob/main/docs/guide/add-a-server.md
EOF
