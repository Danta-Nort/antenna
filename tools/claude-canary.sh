#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The Claude Code canary: the window's Code mode wake against the real Claude Code installed on this computer
# (apps/antenna_desktop/test/protocol/live_code_real_claude_test.dart), then the same wake without a window, in a tmux
# session started by `antenna session start` (crates/antenna-cli/tests/session.rs,
# real_claude_code_in_a_session_is_woken; D-108). Claude Code updates itself; a daily run says within a day when a new
# release breaks the wake, and where (docs/TROUBLESHOOTING.md, "Claude Code changed: how to read a canary failure").
# Prints one line on standard output:
#   claude-canary <UTC time> claude <version> PASS|FAIL <short reason>
# and exits with 0 on PASS, 1 on FAIL, 2 on bad usage. On FAIL, or with --verbose, the test's own output (the hook
# events, the screen rows) goes to standard error first.
#   tools/claude-canary.sh [--verbose]
# Needs: a signed-in Claude Code (the first `claude` on PATH, or where the window finds it; put another installation's
# folder first in PATH to check that one), cargo ($CARGO, PATH or ~/.cargo/bin), Flutter ($FLUTTER, PATH or
# ~/flutter/bin), a C compiler, tmux and python3. Builds `antennad` and `antenna` (debug) unless ANTENNAD_BIN names a built
# `antennad` with `antenna` next to it. Costs a few Haiku turns of the signed-in account.
# Writes into a temporary directory (removed at the end, also used as TMPDIR) and the repository's build output
# (target/; .dart_tool/ and build/ of the window), besides the package caches of cargo and Flutter. Claude Code itself
# records the throwaway project folder in its own files under HOME; the test removes that folder's transcripts.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/apps/antenna_desktop"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
verbose=0
for a in "$@"; do
  case "$a" in
    -v|--verbose) verbose=1 ;;
    *) echo "usage: $0 [--verbose]" >&2; exit 2 ;;
  esac
done

version=unknown
finish() {
  printf 'claude-canary %s claude %s %s %s\n' "$started" "$version" "$1" "$2"
  [ "$1" = PASS ]
  exit $?
}

# The canary talks only to its own test daemons: never to the daemon or with the agent token of whatever session
# runs it (an agent's terminal has these set).
unset ANTENNA_SOCKET ANTENNA_DATA_DIR ANTENNA_AGENT_TOKEN ANTENNA_AGENT_TOKEN_FILE

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-canary.XXXXXX")" || finish FAIL "cannot create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"

if claude_bin="$(command -v claude)"; then
  v="$("$claude_bin" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -n 1)"
  [ -z "$v" ] || version="$v"
fi

pick() {
  local p
  for p in "$@"; do
    case "$p" in
      '') ;;
      */*) if [ -x "$p" ]; then echo "$p"; return 0; fi ;;
      *) if command -v "$p" >/dev/null 2>&1; then command -v "$p"; return 0; fi ;;
    esac
  done
  return 1
}

if [ -z "${ANTENNAD_BIN:-}" ]; then
  cargo="$(pick "${CARGO:-}" cargo "$HOME/.cargo/bin/cargo")" || finish FAIL "cargo not found"
  if ! (cd "$root" && PATH="$(dirname "$cargo"):$PATH" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}" \
    nice -n 10 "$cargo" build --locked -q -p antennad -p antenna-cli) >"$tmp/build.log" 2>&1; then
    cat "$tmp/build.log" >&2
    finish FAIL "building antennad and antenna failed"
  fi
  export ANTENNAD_BIN="$root/target/debug/antennad"
fi
[ -x "$ANTENNAD_BIN" ] && [ -x "$(dirname "$ANTENNAD_BIN")/antenna" ] ||
  finish FAIL "no antennad and antenna at $(dirname "$ANTENNAD_BIN")"
flutter="$(pick "${FLUTTER:-}" flutter "$HOME/flutter/bin/flutter")" || finish FAIL "flutter not found"

log="$tmp/test.log"
(cd "$app" && ANTENNA_REAL_CLAUDE=1 nice -n 10 "$flutter" test --tags real-cli --reporter expanded \
  test/protocol/live_code_real_claude_test.dart) >"$log" 2>&1
code=$?

v="$(sed -n 's/^CANARY version \([^ ]*\).*/\1/p' "$log" | head -n 1)"
[ -z "$v" ] || version="$v"
if [ "$code" -eq 0 ] && grep -q '^CANARY PASS' "$log"; then
  [ "$verbose" -eq 0 ] || cat "$log" >&2
  window="$(sed -n 's/^CANARY PASS //p' "$log" | head -n 1)"
  # The second stage: `antenna session` in tmux, the same real Claude Code (its own test daemons and tmux server).
  cargo="$(pick "${CARGO:-}" cargo "$HOME/.cargo/bin/cargo")" || finish FAIL "session: cargo not found"
  slog="$tmp/session.log"
  (cd "$root" && PATH="$(dirname "$cargo"):$PATH" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}" ANTENNA_REAL_CLAUDE=1 \
    nice -n 10 "$cargo" test --locked -q -p antenna-cli --test session -- --ignored --nocapture \
    real_claude_code_in_a_session_is_woken) >"$slog" 2>&1
  scode=$?
  if [ "$scode" -eq 0 ] && grep -q '^CANARY PASS session' "$slog"; then
    [ "$verbose" -eq 0 ] || cat "$slog" >&2
    finish PASS "$window; $(sed -n 's/^CANARY PASS //p' "$slog" | head -n 1)"
  fi
  cat "$slog" >&2
  sreason="$(grep -m 1 -A 2 'panicked at' "$slog" | tail -n 2 | tr '\n' ' ')"
  [ -n "$sreason" ] || sreason="no result from the test (cargo test exited with $scode; its output is above)"
  finish FAIL "$(printf 'session: %s' "$sreason" | tr -d '\r' | cut -c 1-240)"
fi
cat "$log" >&2
reason="$(sed -n 's/^CANARY FAIL //p' "$log" | head -n 1)"
if [ -z "$reason" ]; then
  # No verdict from the test itself: it did not run (skipped, did not compile) or was stopped by its timeout.
  reason="no result from the test (flutter test exited with $code; its output is above)"
fi
finish FAIL "$(printf '%s' "$reason" | tr -d '\r' | cut -c 1-240)"
