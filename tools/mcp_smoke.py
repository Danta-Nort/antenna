#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Check of `antenna mcp` against a live daemon, for CI on macOS (release.yml, job `core`); works on Linux too.

Scenario: our own `antennad` in a temporary directory → `antenna init` → `antenna agent add` → an MCP host
(`sh -c '… antenna mcp …'`, as in tests/agents.rs) → `initialize` (server name `antenna`, per-agent instructions
that mention Antenna and the agent), `tools/list`,
`tools/call get_session` → the owner sees in `antenna agent list` that the token
is bound to the host process (D-28: on macOS this is the proof that procinfo works through proc_pidinfo, PORTABILITY
M-3…M-6); MCP has no owner commands (SPEC §9). Prints a JSON summary; exit code 0 means everything checks out.

Run: python3 tools/mcp_smoke.py [directory with antennad and antenna, default target/debug]
"""

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PASSWORD = "smoke-password-123\n"
# Owner commands (SPEC §9) must not appear among the MCP tool names.
OWNER_WORDS = ("init", "invite", "join", "trust_set", "set_trust", "approve", "rotate", "revoke",
               "update", "lock", "agent_add", "pairing", "rekey")


def fail(msg, log_path=None):
    print(f"FAIL: {msg}", file=sys.stderr)
    if log_path and os.path.exists(log_path):
        print("---- antennad log ----", file=sys.stderr)
        with open(log_path, encoding="utf-8", errors="replace") as f:
            print(f.read()[-4000:], file=sys.stderr)
    sys.exit(1)


def last_json(out):
    for line in reversed(out.decode(errors="replace").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def ppid_of(pid):
    out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
    return int(out.stdout.strip()) if out.stdout.strip() else None


class Rpc:
    """JSON-RPC 2.0 over stdio: one line per message."""

    def __init__(self, proc):
        self.proc = proc
        self.lines = queue.Queue()
        self.next_id = 1
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, msg):
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params, timeout=60):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = self.lines.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if line is None:
                raise RuntimeError(f"x mcp exited while waiting for {method}")
            try:
                v = json.loads(line)
            except json.JSONDecodeError:
                continue
            if v.get("id") == rid:
                return v
        raise RuntimeError(f"timeout waiting for {method}")


def main():
    bindir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "target/debug")
    xd, x = os.path.join(bindir, "antennad"), os.path.join(bindir, "antenna")
    for b in (xd, x):
        if not os.access(b, os.X_OK):
            fail(f"no executable {b}")
    # A short path: sun_path on macOS is 104 bytes (PORTABILITY M-14).
    root = tempfile.mkdtemp(prefix="amcp-", dir="/tmp")
    data = os.path.join(root, "d")
    log_path = os.path.join(root, "antennad.log")
    env = dict(os.environ, ANTENNA_DATA_DIR=data)
    for k in ("ANTENNA_AGENT_TOKEN", "X_AGENT_TOKEN", "ANTENNA_SOCKET", "X_SOCKET", "X_DATA_DIR"):
        env.pop(k, None)
    log = open(log_path, "wb")
    daemon = subprocess.Popen(
        [xd, "--data-dir", data, "--relay", "disabled", "--bind-ip", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=log, env=dict(env, ANTENNAD_LOG="warn,antenna_core=debug,antennad=info"))
    host = None
    try:
        sock = os.path.join(data, "antennad.sock")
        t = time.time()
        while not os.path.exists(sock):
            if time.time() - t > 30 or daemon.poll() is not None:
                fail("antennad did not start", log_path)
            time.sleep(0.05)

        def xrun(args, stdin=None):
            r = subprocess.run([x, *args], input=stdin.encode() if stdin else None,
                               capture_output=True, env=env, timeout=60)
            return r.returncode, last_json(r.stdout), r

        for args in (["init", "--password-stdin"], ["--json", "login", "--password-stdin"]):
            code, _, r = xrun(args, PASSWORD)
            if code != 0:
                fail(f"antenna {' '.join(args)}: {code} {r.stderr.decode(errors='replace')}", log_path)
        code, added, r = xrun(["--json", "agent", "add", "smoke", "--local-level", "5", "--password-stdin"],
                              PASSWORD)
        if code != 0 or not added or not str(added.get("token", "")).startswith("xat_"):
            fail(f"antenna agent add: {code} {added} {r.stderr.decode(errors='replace')}", log_path)
        token = added["token"]

        # The MCP host is a separate process (`sh`), as in tests/agents.rs: the parent of `antenna mcp`, which the daemon
        # binds the token to.
        host = subprocess.Popen(
            ["/bin/sh", "-c", '"$X_BIN" --data-dir "$X_DIR" mcp; e=$?; exit $e'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            env=dict(env, X_BIN=x, X_DIR=data, ANTENNA_AGENT_TOKEN=token))
        rpc = Rpc(host)
        t0 = time.time()
        init = rpc.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "antenna-smoke", "version": "0"}})
        init_ms = round((time.time() - t0) * 1000)
        if "error" in init or not isinstance(init.get("result", {}).get("capabilities", {}).get("tools"), dict):
            fail(f"initialize: {init}", log_path)
        server = init["result"].get("serverInfo", {}).get("name")
        if server != "antenna":
            fail(f"MCP server name: {server!r}, expected 'antenna'", log_path)
        # The instructions are made per agent at startup (whose messages are tasks, the rest is data).
        instructions = init["result"].get("instructions") or ""
        if "Antenna" not in instructions or '"smoke"' not in instructions:
            fail(f"initialize.instructions: {instructions!r}", log_path)
        rpc.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        listed = rpc.request("tools/list", {})
        names = [t["name"] for t in listed.get("result", {}).get("tools", [])]
        if not {"list_contacts", "send_message", "read_inbox", "get_session", "share_file_content"} <= set(names):
            fail(f"tools/list: {names}", log_path)
        owner = [n for n in names if any(w in n for w in OWNER_WORDS)]
        if owner:
            fail(f"owner commands in MCP: {owner}", log_path)
        sess = rpc.request("tools/call", {"name": "get_session", "arguments": {}})
        res = sess.get("result", {})
        if "error" in sess or res.get("isError"):
            fail(f"get_session: {sess}", log_path)

        # The owner (outside the host tree) sees the token bound to the host process.
        code, agents, r = xrun(["--json", "agent", "list"])
        if code != 0 or not agents:
            fail(f"antenna agent list: {code} {r.stderr.decode(errors='replace')}", log_path)
        bound = next((a["session"].get("bound_to") for a in agents.get("agents", []) if a.get("name") == "smoke"),
                     None)
        if not bound:
            fail(f"token is not bound to the MCP host (D-28): {agents}", log_path)
        bound_pid = int(bound.split()[0])
        # /bin/sh on macOS is a shim: if it does not exec, the host would be its child.
        if bound_pid != host.pid and ppid_of(bound_pid) != host.pid:
            fail(f"bound to {bound}, MCP host is pid {host.pid}", log_path)

        host.stdin.close()
        host.wait(timeout=15)
        print(json.dumps({"ok": True, "platform": sys.platform, "initialize_ms": init_ms, "tools": names,
                          "bound_to": bound, "host_pid": host.pid}, ensure_ascii=False))
    finally:
        if host and host.poll() is None:
            host.kill()
        daemon.terminate()
        try:
            daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            daemon.kill()
        log.close()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
