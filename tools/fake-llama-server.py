#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""A stand-in for llama.cpp's llama-server in tests of local models (docs/LOCAL-ASSISTANT.md, CONTROL §24).

It speaks the part of llama-server's HTTP API the daemon and `antenna local-agent` use, on the unix socket given by
`--host <path>.sock`: `GET /health`, and `POST /v1/chat/completions` with `stream: true` (server-sent events in a
chunked body, a final chunk with `usage` and `timings`, then `data: [DONE]`). Requests need `Authorization: Bearer
$LLAMA_API_KEY`, as with the real server.

Before it listens it probes what its sandbox lets it do and keeps the answers; a user message `probe` is answered with
them (`write_model=denied tcp=denied …`), so a test sees the sandbox from the inside through the whole chat path.
Everything else is answered with `Echo: <the last user message>`, one word per event.

Settings come from `fake-llama-server.json` next to this script (the runtime's folder is read-only in the sandbox,
and the sandbox passes no environment): `probe_tcp_port` (a loopback port the test listens on), `probe_paths` (files
the runtime must not read), `probe_socket` (a unix socket it must not reach), `delay_ms` (between words),
`exit_after_words` (crash in the middle of a reply), `reply` (a fixed reply instead of the echo).
"""

import json
import os
import socket
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler

HERE = os.path.dirname(os.path.realpath(__file__))


def load_settings():
    try:
        with open(os.path.join(HERE, "fake-llama-server.json")) as f:
            return json.load(f)
    except OSError:
        return {}


def arg(name, default=None):
    a = sys.argv[1:]
    for i, x in enumerate(a):
        if x == name and i + 1 < len(a):
            return a[i + 1]
    return default


def probe(settings, model):
    out = {}
    try:
        with open(model, "r+b"):
            out["write_model"] = "allowed"
    except OSError as e:
        out["write_model"] = "denied(%s)" % e.__class__.__name__
    try:
        with open(model, "rb") as f:
            f.read(4)
        out["read_model"] = "ok"
    except OSError as e:
        out["read_model"] = "failed(%s)" % e.__class__.__name__
    port = settings.get("probe_tcp_port")
    if port:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(("127.0.0.1", int(port)))
            s.close()
            out["tcp"] = "allowed"
        except OSError as e:
            out["tcp"] = "denied(%s)" % (e.strerror or e.__class__.__name__)
    for p in settings.get("probe_paths", []):
        try:
            with open(p, "rb") as f:
                f.read(1)
            out["read:" + os.path.basename(p)] = "allowed"
        except OSError as e:
            out["read:" + os.path.basename(p)] = "denied(%s)" % e.__class__.__name__
    sp = settings.get("probe_socket")
    if sp:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(sp)
            s.close()
            out["unix"] = "allowed"
        except OSError as e:
            out["unix"] = "denied(%s)" % (e.strerror or e.__class__.__name__)
    return out


SETTINGS = load_settings()
MODEL = arg("-m", "")
PROBES = probe(SETTINGS, MODEL)
KEY = os.environ.get("LLAMA_API_KEY", "")
ALIAS = arg("--alias", "fake")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fake-llama-server: " + (fmt % args) + "\n")

    def _authorized(self):
        return self.headers.get("Authorization", "") == "Bearer " + KEY and KEY != ""

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def _chunk(self, data):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def _event(self, obj):
        self._chunk(b"data: " + json.dumps(obj).encode() + b"\n\n")

    def do_POST(self):
        if not self._authorized():
            self._json(401, {"error": {"message": "Invalid API Key", "type": "authentication_error"}})
            return
        if self.path != "/v1/chat/completions":
            self._json(404, {"error": {"message": "not found"}})
            return
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        msgs = req.get("messages", [])
        last = next((m.get("content", "") for m in reversed(msgs) if m.get("role") == "user"), "")
        if last.strip() == "probe":
            text = " ".join("%s=%s" % kv for kv in sorted(PROBES.items()))
        elif last.strip() == "context":
            text = "I see %d messages: %s" % (
                len(msgs),
                " | ".join("%s:%s" % (m.get("role"), m.get("content", "")[:40]) for m in msgs),
            )
        elif SETTINGS.get("reply"):
            text = SETTINGS["reply"]
        else:
            text = "Echo: " + last
        words = text.split(" ")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        base = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": ALIAS, "created": int(time.time())}
        self._event(dict(base, choices=[{"index": 0, "delta": {"role": "assistant", "content": None}}]))
        delay = SETTINGS.get("delay_ms", 0) / 1000.0
        crash = SETTINGS.get("exit_after_words")
        t0 = time.time()
        try:
            for i, w in enumerate(words):
                if crash is not None and i >= crash:
                    os._exit(3)
                piece = w if i == 0 else " " + w
                self._event(dict(base, choices=[{"index": 0, "delta": {"content": piece}}]))
                if delay:
                    time.sleep(delay)
            ms = max(1.0, (time.time() - t0) * 1000)
            prompt = sum(len(m.get("content", "").split()) for m in msgs)
            self._event(dict(base, choices=[{"index": 0, "finish_reason": "stop", "delta": {}}]))
            self._event(
                dict(
                    base,
                    choices=[],
                    usage={"completion_tokens": len(words), "prompt_tokens": prompt, "total_tokens": prompt + len(words)},
                    timings={
                        "cache_n": 0,
                        "prompt_n": prompt,
                        "prompt_ms": 1.0,
                        "predicted_n": len(words),
                        "predicted_ms": ms,
                    },
                )
            )
            self._chunk(b"data: [DONE]\n\n")
            self._chunk(b"")
        except (BrokenPipeError, ConnectionResetError):
            # The client went away (an interrupt): stop generating, as the real server does.
            return


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    host = arg("--host", "")
    if not host.endswith(".sock"):
        sys.stderr.write("fake-llama-server: --host must be a unix socket path ending in .sock\n")
        return 2
    try:
        os.unlink(host)
    except OSError:
        pass
    sys.stderr.write("fake-llama-server: probes " + json.dumps(PROBES, sort_keys=True) + "\n")
    srv = Server(host, Handler)
    sys.stderr.write("fake-llama-server: listening on " + host + "\n")
    sys.stderr.flush()
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
