#!/usr/bin/env bash
# Two processes on one machine: listen (allow-list = the dialer's id) and dial through the n0 relay by EndpointId.
# Then a dial with an unpaired key: no reply is expected (timeout).
set -u
BIN=${BIN:-../target/debug/spike-iroh-conn}
LOG=$(mktemp)
SEC=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
DID=$($BIN id "$SEC")
ALLOW=$DID timeout 45 "$BIN" listen >"$LOG" 2>&1 &
for _ in $(seq 1 60); do grep -q "LISTEN direct" "$LOG" 2>/dev/null && break; sleep 0.5; done
grep LISTEN "$LOG"
LID=$(grep -o 'id=[0-9a-f]*' "$LOG" | head -1 | cut -d= -f2)
LREL=$(grep -o 'relay=[^ ]*' "$LOG" | cut -d= -f2)
echo "--- paired dialer (relay URL only, no IPs given):"
DIAL_SECRET_HEX=$SEC timeout 30 "$BIN" dial "$LID" "$LREL" 2>&1 | grep DIAL
echo "--- unpaired dialer:"
timeout 30 "$BIN" dial "$LID" "$LREL" 2>&1 | grep -E "DIAL|^Error" | sed 's/\x1b\[[0-9;]*m//g'
kill %1 2>/dev/null; rm -f "$LOG"
