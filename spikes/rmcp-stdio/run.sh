#!/usr/bin/env bash
# Feeds JSON-RPC into the binary's stdin and prints the replies (one line per message).
BIN=${1:-../target/debug/spike-rmcp-stdio}
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"spike","version":"0"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_trust","arguments":{"contact":"bob"}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"trust","arguments":{"contact":"bob","level":5}}}'
  sleep 1
} | timeout 10 "$BIN"
