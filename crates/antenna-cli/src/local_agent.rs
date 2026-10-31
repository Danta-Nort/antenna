// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna local-agent`: the loop of a local agent (D-96 §3.3, D-104; experimental). The daemon starts it in the
//! agent sandbox without network, with the runtime's run folder as the only thing it can reach; it is not a client of
//! the control socket in this release (no tools yet), and it never sees an owner command.
//!
//! **Input** (JSON lines on stdin, from the daemon through the sandbox's lifeline):
//! - `{"type":"antenna_context","system":"…","messages":[{"role":"user"|"assistant","content":"…"}]}`: the
//!   instructions and the conversation so far (the daemon keeps the conversation; the loop only holds it in memory);
//! - `{"type":"user","message":{"role":"user","content":"…"}}`: a turn (Claude Code's stream-json input);
//! - `{"type":"control_request","request":{"subtype":"interrupt"}}`: end the turn in progress.
//!
//! **Output** (JSON lines on stdout): the subset of Claude Code's stream-json the daemon's resident parser reads
//! (D-93): `system/init`, `stream_event` text deltas, the whole `assistant` message, and a `result` with
//! `subtype` `success`, `interrupted` or `error` and the runtime's numbers in `antenna_usage`.
//!
//! **The runtime** is llama.cpp's `llama-server` on `ANTENNA_LLM_SOCKET`, with the key `ANTENNA_LLM_KEY`: one
//! OpenAI-style `POST /v1/chat/completions` with `stream: true` per turn, over HTTP/1.1 on the unix socket; its
//! server-sent events are parsed with bounded sizes, and the reply is plain text.

#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::{
    io::{BufRead, Read, Write},
    sync::mpsc,
    time::Duration,
};

use serde_json::{Value, json};

/// The connection to the runtime: its unix socket.
#[cfg(unix)]
type RuntimeStream = UnixStream;
/// Windows: the runtime there listens on loopback TCP with its per-start key (D-134, WP-27, phase W5).
#[cfg(windows)]
type RuntimeStream = std::net::TcpStream;

/// Connects to the runtime's socket.
#[cfg(unix)]
fn connect_runtime(sock: &str) -> std::io::Result<RuntimeStream> {
    UnixStream::connect(sock)
}

/// Windows: refused until the built-in runtime is there (WP-27); the turn ends with that error.
#[cfg(windows)]
fn connect_runtime(_sock: &str) -> std::io::Result<RuntimeStream> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "local models are not available on Windows yet",
    ))
}

/// The longest input line (the replayed conversation).
const MAX_INPUT: usize = 8 << 20;
/// The longest server-sent event line.
const MAX_EVENT: usize = 1 << 20;
/// A reply's tokens at most.
const MAX_TOKENS: u32 = 1024;

struct Cfg {
    sock: String,
    key: String,
    model: String,
    context: u32,
    thinking: bool,
}

fn cfg() -> Result<Cfg, String> {
    let var = |k: &str| std::env::var(k).map_err(|_| format!("{k} is not set"));
    Ok(Cfg {
        sock: var("ANTENNA_LLM_SOCKET")?,
        key: var("ANTENNA_LLM_KEY")?,
        model: std::env::var("ANTENNA_LLM_MODEL").unwrap_or_else(|_| "local".into()),
        context: std::env::var("ANTENNA_LLM_CONTEXT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8192),
        thinking: std::env::var("ANTENNA_LLM_THINKING").is_ok_and(|v| v == "1"),
    })
}

fn emit(v: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

/// Messages that fit the context: the instructions, then as many of the latest messages as fit next to a reply
/// (about three characters per token, a few tokens per message of overhead).
fn fit(system: &str, history: &[(String, String)], context: u32, reply: u32) -> Vec<Value> {
    let budget = (context as usize).saturating_sub(reply as usize + 64);
    let cost = |s: &str| s.chars().count() / 3 + 4;
    let mut used = cost(system);
    let mut keep = Vec::new();
    for (role, content) in history.iter().rev() {
        let c = cost(content);
        if used + c > budget {
            break;
        }
        used += c;
        keep.push(json!({"role": role, "content": content}));
    }
    keep.reverse();
    let mut v = vec![json!({"role": "system", "content": system})];
    v.extend(keep);
    v
}

/// Removes complete chunks of a chunked body from `raw` into `out`; `true` when the last chunk was seen.
fn dechunk(raw: &mut Vec<u8>, out: &mut Vec<u8>) -> Result<bool, String> {
    loop {
        let Some(eol) = raw.windows(2).position(|w| w == b"\r\n") else {
            if raw.len() > 64 {
                return Err("a bad chunk header".into());
            }
            return Ok(false);
        };
        let line = std::str::from_utf8(&raw[..eol]).map_err(|_| "a bad chunk header")?;
        let size = usize::from_str_radix(line.split(';').next().unwrap_or("").trim(), 16)
            .map_err(|_| "a bad chunk size")?;
        if size > MAX_EVENT {
            return Err("a chunk is too large".into());
        }
        let need = eol + 2 + size + 2;
        if raw.len() < need {
            return Ok(false);
        }
        out.extend_from_slice(&raw[eol + 2..eol + 2 + size]);
        raw.drain(..need);
        if size == 0 {
            return Ok(true);
        }
    }
}

/// What one turn produced.
#[derive(Debug, Default)]
struct Reply {
    text: String,
    usage: Value,
    interrupted: bool,
    error: Option<String>,
}

/// Inputs that arrive during a turn: an interrupt ends it; anything else waits.
struct Inbox {
    rx: mpsc::Receiver<Value>,
    later: std::collections::VecDeque<Value>,
}

impl Inbox {
    fn next(&mut self) -> Option<Value> {
        self.later.pop_front().or_else(|| self.rx.recv().ok())
    }

    /// An interrupt came (other inputs are kept for later).
    fn interrupted(&mut self) -> bool {
        let mut hit = false;
        while let Ok(v) = self.rx.try_recv() {
            if v["type"] == "control_request" && v["request"]["subtype"] == "interrupt" {
                hit = true;
            } else {
                self.later.push_back(v);
            }
        }
        hit
    }
}

/// One turn: the request, then the events until `[DONE]`, an interrupt or an error. `on_text` gets each piece.
fn turn(
    cfg: &Cfg,
    messages: Vec<Value>,
    inbox: &mut Inbox,
    on_text: &mut dyn FnMut(&str),
) -> Reply {
    let mut r = Reply::default();
    let body = json!({
        "messages": messages,
        "stream": true,
        "stream_options": {"include_usage": true},
        "max_tokens": MAX_TOKENS.min(cfg.context / 4),
        "cache_prompt": true,
        "chat_template_kwargs": {"enable_thinking": cfg.thinking},
        // Qwen's recommendation for answers without thinking.
        "temperature": 0.7,
        "top_p": 0.8,
        "top_k": 20,
    })
    .to_string();
    let mut s = match connect_runtime(&cfg.sock) {
        Ok(s) => s,
        Err(e) => {
            r.error = Some(format!("cannot reach the model runtime: {e}"));
            return r;
        }
    };
    let _ = s.set_read_timeout(Some(Duration::from_millis(200)));
    let head = format!(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: llm\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        cfg.key,
        body.len()
    );
    if let Err(e) = s
        .write_all(head.as_bytes())
        .and_then(|()| s.write_all(body.as_bytes()))
    {
        r.error = Some(format!("cannot send the request: {e}"));
        return r;
    }
    let mut raw: Vec<u8> = Vec::new();
    let mut buf = [0u8; 16 * 1024];
    let mut headers: Option<(u16, bool)> = None;
    let mut data: Vec<u8> = Vec::new();
    let mut done = false;
    loop {
        if inbox.interrupted() {
            let _ = s.shutdown(std::net::Shutdown::Both);
            r.interrupted = true;
            return r;
        }
        let n = match s.read(&mut buf) {
            Ok(0) => {
                done = true;
                0
            }
            Ok(n) => n,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(e) => {
                r.error = Some(format!("the runtime's connection broke: {e}"));
                return r;
            }
        };
        raw.extend_from_slice(&buf[..n]);
        if headers.is_none() {
            let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
                if raw.len() > 16 * 1024 || done {
                    r.error = Some("the runtime sent no valid HTTP answer".into());
                    return r;
                }
                continue;
            };
            let text = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
            let status: u16 = text
                .split_whitespace()
                .nth(1)
                .and_then(|c| c.parse().ok())
                .unwrap_or(0);
            let chunked = text.contains("transfer-encoding: chunked");
            raw.drain(..end + 4);
            headers = Some((status, chunked));
        }
        let Some((status, chunked)) = headers else {
            continue;
        };
        let mut finished = done;
        if chunked {
            match dechunk(&mut raw, &mut data) {
                Ok(last) => finished |= last,
                Err(e) => {
                    r.error = Some(format!("the runtime's answer: {e}"));
                    return r;
                }
            }
        } else {
            data.append(&mut raw);
        }
        if status != 200 {
            if finished || data.len() > 64 * 1024 {
                let v: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
                let msg = v["error"]["message"]
                    .as_str()
                    .map(String::from)
                    .unwrap_or_else(|| {
                        String::from_utf8_lossy(&data[..data.len().min(300)]).into_owned()
                    });
                r.error = Some(format!("the runtime answered {status}: {msg}"));
                return r;
            }
            continue;
        }
        // Server-sent events: `data: {…}` lines, `data: [DONE]` at the end.
        while let Some(eol) = data.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = data.drain(..=eol).collect();
            let line = String::from_utf8_lossy(&line);
            let Some(payload) = line.trim_end().strip_prefix("data: ") else {
                continue;
            };
            if payload == "[DONE]" {
                return r;
            }
            let Ok(v) = serde_json::from_str::<Value>(payload) else {
                continue;
            };
            if let Some(e) = v["error"]["message"].as_str() {
                r.error = Some(e.to_string());
                return r;
            }
            if let Some(t) = v["choices"][0]["delta"]["content"].as_str()
                && !t.is_empty()
            {
                r.text.push_str(t);
                on_text(t);
            }
            if v.get("timings").is_some() {
                let t = &v["timings"];
                let n = |k: &str| t[k].as_f64().unwrap_or(0.0);
                r.usage = json!({
                    "prompt_tokens": n("prompt_n") as u64,
                    "cached_tokens": n("cache_n") as u64,
                    "output_tokens": n("predicted_n") as u64,
                    "prompt_ms": n("prompt_ms").round() as u64,
                    "output_ms": n("predicted_ms").round() as u64,
                });
            }
        }
        if data.len() > MAX_EVENT {
            r.error = Some("the runtime sent an event that is too long".into());
            return r;
        }
        if finished {
            // The end of the body before `[DONE]`: the runtime went away in the middle of the reply.
            if r.error.is_none() {
                r.error =
                    Some("the runtime closed the connection before the end of the reply".into());
            }
            return r;
        }
    }
}

/// Runs the loop until stdin closes. Returns the process exit code.
pub(crate) fn main() -> i32 {
    let cfg = match cfg() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("antenna local-agent: {e}");
            return 2;
        }
    };
    let (tx, rx) = mpsc::channel::<Value>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut r = stdin.lock();
        let mut line = Vec::new();
        loop {
            line.clear();
            match (&mut r)
                .take(MAX_INPUT as u64 + 1)
                .read_until(b'\n', &mut line)
            {
                Ok(0) | Err(_) => break,
                Ok(_) if line.len() > MAX_INPUT => {
                    eprintln!("antenna local-agent: an input line is too long");
                    break;
                }
                Ok(_) => {}
            }
            if let Ok(v) = serde_json::from_slice::<Value>(&line)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    let mut inbox = Inbox {
        rx,
        later: Default::default(),
    };
    emit(&json!({"type": "system", "subtype": "init", "model": cfg.model, "tools": []}));
    let mut system = String::new();
    let mut history: Vec<(String, String)> = Vec::new();
    let mut n = 0u64;
    while let Some(v) = inbox.next() {
        match v["type"].as_str() {
            Some("antenna_context") => {
                system = v["system"].as_str().unwrap_or_default().to_string();
                history = v["messages"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|m| {
                        let role = m["role"].as_str()?;
                        let content = m["content"].as_str()?;
                        matches!(role, "user" | "assistant")
                            .then(|| (role.to_string(), content.to_string()))
                    })
                    .collect();
            }
            Some("user") => {
                let Some(text) = v["message"]["content"].as_str() else {
                    continue;
                };
                n += 1;
                let id = format!("msg_local_{n}");
                history.push(("user".into(), text.to_string()));
                emit(
                    &json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": id}}}),
                );
                let reply_tokens = MAX_TOKENS.min(cfg.context / 4);
                let messages = fit(&system, &history, cfg.context, reply_tokens);
                let r = turn(&cfg, messages, &mut inbox, &mut |t| {
                    emit(
                        &json!({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                        "delta": {"type": "text_delta", "text": t}}}),
                    );
                });
                if !r.text.is_empty() {
                    history.push(("assistant".into(), r.text.clone()));
                    emit(
                        &json!({"type": "assistant", "message": {"id": id, "role": "assistant",
                        "content": [{"type": "text", "text": r.text}]}}),
                    );
                }
                let subtype = if r.interrupted {
                    "interrupted"
                } else if r.error.is_some() {
                    "error"
                } else {
                    "success"
                };
                let mut res = json!({
                    "type": "result",
                    "subtype": subtype,
                    "is_error": r.error.is_some(),
                    "result": r.text,
                    "usage": {
                        "input_tokens": r.usage["prompt_tokens"],
                        "output_tokens": r.usage["output_tokens"],
                        "cache_read_input_tokens": r.usage["cached_tokens"],
                    },
                });
                if !r.usage.is_null() {
                    res["antenna_usage"] = r.usage;
                }
                if let Some(e) = r.error {
                    res["error"] = Value::String(e);
                }
                emit(&res);
            }
            // An interrupt with no turn in progress: nothing to end.
            _ => {}
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunked_bodies_are_decoded_across_reads() {
        let mut raw = b"5\r\nhel".to_vec();
        let mut out = Vec::new();
        assert!(!dechunk(&mut raw, &mut out).unwrap());
        assert!(out.is_empty());
        raw.extend_from_slice(b"lo\r\n6\r\n world\r\n0\r\n\r\n");
        assert!(dechunk(&mut raw, &mut out).unwrap());
        assert_eq!(out, b"hello world");
        let mut bad = b"zz\r\n".to_vec();
        assert!(dechunk(&mut bad, &mut Vec::new()).is_err());
        let mut huge = format!("{:x}\r\n", MAX_EVENT + 1).into_bytes();
        assert!(dechunk(&mut huge, &mut Vec::new()).is_err());
    }

    #[test]
    fn the_context_keeps_the_instructions_and_the_latest_messages() {
        let history: Vec<(String, String)> = (0..100)
            .map(|i| {
                (
                    "user".to_string(),
                    format!("message {i} {}", "x".repeat(300)),
                )
            })
            .collect();
        let v = fit("be brief", &history, 8192, 1024);
        assert_eq!(v[0]["role"], "system");
        assert_eq!(
            v.last().unwrap()["content"].as_str().unwrap(),
            history[99].1
        );
        assert!(v.len() > 10 && v.len() < 100, "{}", v.len());
        // Everything fits a short conversation.
        assert_eq!(fit("s", &history[..3], 8192, 1024).len(), 4);
    }
}
