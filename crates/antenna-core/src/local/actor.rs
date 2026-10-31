// SPDX-License-Identifier: AGPL-3.0-only
//! The actor of one local agent conversation (`session.rs` is its interface): it owns the loop's process, the queue
//! of turns and the timers. Nothing polls: it waits on its command channel, the loop's stdout and at most one timer.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex as StdMutex, PoisonError},
    time::Duration,
};

use antenna_proto::control::{LocalTurn, LocalUsage, code};
use serde_json::Value;
use tokio::{
    io::BufReader,
    sync::mpsc,
    time::{Instant, sleep_until},
};

use super::{
    db,
    pool::Lease,
    session::{Cmd, LocalOut, SayReq, View},
};
use crate::{
    agents::{AgentCtx, new_token, token_hash},
    error::{Error, Result},
    node::Session,
    now_ms, sandbox,
    wake::{ClaudeAction, ClaudeParser, read_line_limited, read_tail},
};

/// The counterpart prefix of a conversation a local agent has for a team (D-111).
pub(crate) const TEAM_PREFIX: &str = "team:";
/// After an interrupt, how long the loop may take to end the turn before it is stopped.
const INTERRUPT_GRACE: Duration = Duration::from_secs(10);
/// Earlier messages replayed into a new loop (the loop keeps what fits its context).
const REPLAY: u32 = 200;
/// Crashes within 10 minutes after which the agent waits for the next turn instead of starting again.
const MAX_CRASHES: usize = 3;
const CRASH_WINDOW_MS: u64 = 10 * 60 * 1000;
/// CPU time of a loop process: it lives for hours but does little.
const LOOP_CPU_SECS: u64 = 6 * 3600;

/// The fixed instructions of a local agent in this release (no tools, no network). A conversation for a team
/// (`team:<name>`, D-111) says that its counterpart is the team's lead and that a reply is the task's result.
fn system_prompt(name: &str, model: &str, counterpart: &str) -> String {
    if let Some(team) = counterpart.strip_prefix(TEAM_PREFIX) {
        return format!(
            "You are {name}, a local AI worker of the team {team} inside Antenna, a messenger for people and AI \
             agents. You run entirely on your owner's own computer, on the open model {model}, with no internet \
             access and no tools in this version: you cannot browse, run commands, read files or send messages. Each \
             turn brings a task from your team's lead, another agent (not your owner): its text is the lead's \
             request. Your whole reply is your result for that task: write only the result, complete, in the \
             language of the task. If the task asks for something you cannot do without tools, say so in one line."
        );
    }
    format!(
        "You are {name}, a local AI assistant inside Antenna, a messenger for people and AI agents. You run entirely \
         on your owner's own computer, on the open model {model}, with no internet access and no tools in this \
         version: you cannot browse, run commands, read files or send messages. You are talking with your owner, the \
         person who uses this computer. Answer in the language your owner writes in. Be helpful and concise. If you \
         do not know something, say so instead of guessing."
    )
}

/// Model text without control characters, except line breaks and tabs (R9: no terminal sequences, no hidden text).
pub(crate) fn clean(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect()
}

fn line(v: &Value) -> Vec<u8> {
    let mut l = v.to_string().into_bytes();
    l.push(b'\n');
    l
}

struct Live {
    running: sandbox::Running,
    lines: mpsc::Receiver<Value>,
    log_task: tokio::task::JoinHandle<Vec<u8>>,
    agent: AgentCtx,
    /// The runtime generation the loop's key belongs to.
    generation: u64,
}

struct Turn {
    n: u64,
    out: mpsc::UnboundedSender<LocalOut>,
    parser: ClaudeParser,
    text: String,
    deadline: Instant,
    interrupt_sent: Option<Instant>,
    /// Why the turn was interrupted, for the stored reply.
    interrupt_why: Option<&'static str>,
    _lease: Lease,
}

struct Actor {
    s: Arc<Session>,
    agent_id: i64,
    counterpart: String,
    rx: mpsc::UnboundedReceiver<Cmd>,
    view: Arc<StdMutex<View>>,
    live: Option<Live>,
    queue: VecDeque<SayReq>,
    busy: Option<Turn>,
    idle_since: Option<Instant>,
    crashes: VecDeque<u64>,
    failed: Option<String>,
    ending: bool,
    /// A reset asked for while a turn waited for its runtime: done once that turn has ended.
    pending_reset: Option<tokio::sync::oneshot::Sender<()>>,
}

async fn next_line(live: &mut Option<Live>) -> Option<Value> {
    match live {
        Some(l) => l.lines.recv().await,
        None => std::future::pending().await,
    }
}

async fn sleep_opt(at: Option<Instant>) {
    match at {
        Some(t) => sleep_until(t).await,
        None => std::future::pending().await,
    }
}

/// Start the actor of a conversation.
pub(super) fn spawn(
    s: Arc<Session>,
    agent_id: i64,
    counterpart: &str,
    rx: mpsc::UnboundedReceiver<Cmd>,
    view: Arc<StdMutex<View>>,
) {
    let actor = Actor {
        s,
        agent_id,
        counterpart: counterpart.to_string(),
        rx,
        view,
        live: None,
        queue: VecDeque::new(),
        busy: None,
        idle_since: None,
        crashes: VecDeque::new(),
        failed: None,
        ending: false,
        pending_reset: None,
    };
    tokio::spawn(actor.run());
}

impl Actor {
    async fn run(mut self) {
        loop {
            if self.busy.is_none() && !self.ending {
                self.next_turn().await;
            }
            if self.ending {
                break;
            }
            self.publish();
            let at = self.next_deadline();
            tokio::select! {
                cmd = self.rx.recv() => match cmd {
                    Some(c) => self.on_cmd(c).await,
                    None => break,
                },
                v = next_line(&mut self.live) => match v {
                    Some(v) => self.on_line(v).await,
                    None => self.on_exit().await,
                },
                _ = sleep_opt(at) => self.on_timer().await,
                _ = self.s.closed_wait() => break,
            }
        }
        self.stop_live("the session ended").await;
        self.fail_queue("the local agent's session ended");
        self.set_view("sleeping", String::new());
    }

    fn name(&self) -> String {
        self.s
            .local_agent_info(self.agent_id)
            .map(|a| a.name)
            .unwrap_or_default()
    }

    fn set_view(&self, state: &'static str, detail: String) {
        let changed = {
            let mut v = self.view.lock().unwrap_or_else(PoisonError::into_inner);
            let changed = v.state != state || v.detail != detail;
            *v = View { state, detail };
            changed
        };
        if changed && let Ok(info) = self.s.local_agent_info(self.agent_id) {
            self.s.emit_local_agent(info);
        }
        // A team's conversation is that worker's state for the team (D-111).
        if changed && self.counterpart.starts_with(TEAM_PREFIX) {
            self.s.worker_state_changed(self.agent_id);
        }
    }

    fn publish(&self) {
        if let Some(why) = &self.failed {
            self.set_view("failed", why.clone());
        } else if self.busy.is_some() {
            self.set_view("busy", String::new());
        } else if self.live.is_some() {
            self.set_view("idle", String::new());
        } else {
            self.set_view("sleeping", String::new());
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        if let Some(t) = &self.busy {
            return Some(match t.interrupt_sent {
                Some(at) => at + INTERRUPT_GRACE,
                None => t.deadline,
            });
        }
        self.idle_since.map(|t| t + self.s.cfg.local.idle)
    }

    async fn on_timer(&mut self) {
        let now = Instant::now();
        if let Some(t) = &mut self.busy {
            match t.interrupt_sent {
                Some(at) if now >= at + INTERRUPT_GRACE => {
                    self.stop_live("the turn did not end after an interrupt")
                        .await;
                }
                None if now >= t.deadline => self.interrupt("the turn's time limit").await,
                _ => {}
            }
            return;
        }
        if self
            .idle_since
            .is_some_and(|t| now >= t + self.s.cfg.local.idle)
        {
            self.stop_live("idle").await;
        }
    }

    async fn on_cmd(&mut self, c: Cmd) {
        match c {
            Cmd::Say(req) => {
                self.failed = None;
                let interrupt = req.interrupt;
                self.queue.push_back(req);
                if interrupt {
                    self.interrupt("interrupted by the owner's next message")
                        .await;
                }
            }
            Cmd::Interrupt => self.interrupt("stopped by the owner").await,
            Cmd::Stop => self.stop_live("stopped by the owner").await,
            Cmd::Reset(done) => {
                self.stop_live("a new conversation").await;
                self.fail_queue("the conversation was reset");
                self.failed = None;
                self.crashes.clear();
                {
                    let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
                    let _ = db::conversation_delete(&db, self.agent_id, &self.counterpart);
                }
                let _ = done.send(());
            }
            Cmd::Shutdown => self.ending = true,
        }
    }

    async fn interrupt(&mut self, why: &'static str) {
        let Some(t) = &mut self.busy else {
            return;
        };
        if t.interrupt_sent.is_some() {
            return;
        }
        t.interrupt_sent = Some(Instant::now());
        t.interrupt_why = Some(why);
        let v = serde_json::json!({
            "type": "control_request",
            "request_id": format!("antenna-interrupt-{}", t.n),
            "request": {"subtype": "interrupt"},
        });
        if let Some(l) = &mut self.live {
            let _ = l.running.agent_input(&line(&v)).await;
        }
    }

    fn fail_queue(&mut self, why: &str) {
        let name = self.name();
        for req in self.queue.drain(..) {
            let _ = req.out.send(LocalOut::Done(LocalTurn {
                agent: name.clone(),
                turn: 0,
                outcome: "failed".into(),
                text: String::new(),
                detail: why.into(),
                usage: None,
            }));
        }
    }

    /// The agent's model and the conversation so far.
    fn load(&self) -> Option<(String, String)> {
        let info = self.s.local_agent_info(self.agent_id).ok()?;
        Some((info.name, info.model))
    }

    /// Start the next queued turn: store the owner's message, get the runtime, start the loop, write the turn.
    async fn next_turn(&mut self) {
        let Some(req) = self.queue.pop_front() else {
            return;
        };
        let Some((name, model)) = self.load() else {
            let _ = req.out.send(LocalOut::Done(LocalTurn {
                agent: String::new(),
                turn: 0,
                outcome: "failed".into(),
                text: String::new(),
                detail: "the local agent is gone".into(),
                usage: None,
            }));
            return;
        };
        let n = {
            let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
            let n = db::turn_counts(&db, self.agent_id, &self.counterpart)
                .map(|(last, _)| last + 1)
                .unwrap_or(1);
            if let Err(e) = db::item_insert(
                &db,
                &db::NewItem {
                    agent_id: self.agent_id,
                    counterpart: &self.counterpart,
                    turn: n,
                    role: "owner",
                    text: &req.text,
                    ts_ms: now_ms(),
                    outcome: None,
                    detail: None,
                    usage: None,
                },
            ) {
                drop(db);
                self.finish_early(&req, &name, 0, "failed", e.message);
                return;
            }
            n
        };
        self.set_view("busy", String::new());
        // The runtime: loading it or waiting for memory can take a while; the owner's commands are still heard.
        let lease = {
            let out = req.out.clone();
            let view = self.view.clone();
            let s2 = self.s.clone();
            let agent_id = self.agent_id;
            let for_team = self.counterpart.starts_with(TEAM_PREFIX);
            let activity = move |a: &'static str| {
                let _ = out.send(LocalOut::Delta {
                    turn: n,
                    delta: String::new(),
                    activity: Some(a.into()),
                });
                let state = if a == "waiting" { "waiting" } else { "loading" };
                let changed = {
                    let mut v = view.lock().unwrap_or_else(PoisonError::into_inner);
                    let ch = v.state != state;
                    v.state = state;
                    ch
                };
                if changed && let Ok(info) = s2.local_agent_info(agent_id) {
                    s2.emit_local_agent(info);
                }
                if changed && for_team {
                    s2.worker_state_changed(agent_id);
                }
            };
            let s = self.s.clone();
            let model2 = model.clone();
            let mut acq = Box::pin(async move { s.runtime_acquire(&model2, &activity).await });
            loop {
                tokio::select! {
                    r = &mut acq => break r,
                    cmd = self.rx.recv() => match cmd {
                        Some(Cmd::Say(r)) => {
                            let int = r.interrupt;
                            self.queue.push_back(r);
                            if int {
                                break Err(Error::new(code::TIMEOUT, "interrupted"));
                            }
                        }
                        Some(Cmd::Interrupt) | Some(Cmd::Stop) => {
                            break Err(Error::new(code::TIMEOUT, "interrupted"));
                        }
                        Some(Cmd::Reset(done)) => {
                            // Done once this turn has ended.
                            self.pending_reset = Some(done);
                            break Err(Error::new(code::TIMEOUT, "interrupted"));
                        }
                        Some(Cmd::Shutdown) | None => {
                            self.ending = true;
                            break Err(Error::new(code::TIMEOUT, "interrupted"));
                        }
                    },
                }
            }
        };
        let lease = match lease {
            Ok(l) => l,
            Err(e) if e.code == code::TIMEOUT && e.message == "interrupted" => {
                self.finish_early(
                    &req,
                    &name,
                    n,
                    "interrupted",
                    "interrupted by the owner".into(),
                );
                if let Some(done) = self.pending_reset.take() {
                    self.on_cmd(Cmd::Reset(done)).await;
                }
                return;
            }
            Err(e) => {
                let why = format!("{}: {}", e.code, e.message);
                self.finish_early(&req, &name, n, "failed", why);
                return;
            }
        };
        if self
            .live
            .as_ref()
            .is_some_and(|l| l.generation != lease.rt.generation)
        {
            // The runtime was restarted since the loop started: the loop holds the old key.
            self.stop_live("the model was loaded again").await;
        }
        if self.live.is_none()
            && let Err(e) = self.start_live(&lease, &name, &model, n).await
        {
            let why = format!("{}: {}", e.code, e.message);
            self.record_crash();
            self.finish_early(&req, &name, n, "failed", why);
            return;
        }
        let v = serde_json::json!({
            "type": "user",
            "message": {"role": "user", "content": req.text},
            "parent_tool_use_id": null,
        });
        let wrote = match &mut self.live {
            Some(l) => {
                tokio::time::timeout(Duration::from_secs(10), l.running.agent_input(&line(&v)))
                    .await
                    .map_err(|_| Error::internal("the local agent does not read its input"))
                    .and_then(|r| r)
            }
            None => Err(Error::internal("no process")),
        };
        if let Err(e) = wrote {
            self.stop_live("the local agent did not take the turn")
                .await;
            self.record_crash();
            self.finish_early(&req, &name, n, "failed", e.message);
            return;
        }
        self.idle_since = None;
        self.busy = Some(Turn {
            n,
            out: req.out,
            parser: ClaudeParser::default(),
            text: String::new(),
            deadline: Instant::now() + self.s.cfg.local.turn_timeout,
            interrupt_sent: None,
            interrupt_why: None,
            _lease: lease,
        });
    }

    /// A turn that ended before the model said anything: the reply (empty) is stored with its outcome.
    fn finish_early(&mut self, req: &SayReq, name: &str, n: u64, outcome: &str, detail: String) {
        if n > 0 {
            let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = db::item_insert(
                &db,
                &db::NewItem {
                    agent_id: self.agent_id,
                    counterpart: &self.counterpart,
                    turn: n,
                    role: "agent",
                    text: "",
                    ts_ms: now_ms(),
                    outcome: Some(outcome),
                    detail: Some(&detail),
                    usage: None,
                },
            );
        }
        if outcome == "failed" {
            tracing::warn!("local agent {name}: turn {n} failed: {detail}");
        }
        let _ = req.out.send(LocalOut::Done(LocalTurn {
            agent: name.into(),
            turn: n,
            outcome: outcome.into(),
            text: String::new(),
            detail,
            usage: None,
        }));
        self.publish();
    }

    async fn start_live(&mut self, lease: &Lease, name: &str, model: &str, n: u64) -> Result<()> {
        let support = self.s.wake_support();
        let kind = support.kind.ok_or_else(|| {
            Error::new(
                code::SANDBOX_UNAVAILABLE,
                format!("local agents run only in a sandbox: {}", support.detail),
            )
        })?;
        let cm = self.s.catalog_model(model)?;
        let me = std::env::current_exe()?;
        let bin_dir = me
            .parent()
            .map(std::path::Path::to_path_buf)
            .ok_or_else(|| Error::internal("no directory of antennad"))?;
        let antenna = bin_dir.join("antenna");
        let dir = self
            .s
            .local_dir()
            .join("agents")
            .join(self.agent_id.to_string());
        let (work, home, tmp) = (dir.join("work"), dir.join("home"), dir.join("tmp"));
        for d in [&work, &home, &tmp] {
            use crate::owner_only::OwnerOnly;
            std::fs::DirBuilder::new()
                .recursive(true)
                .owner_only()
                .create(d)?;
        }
        let rt = &lease.rt;
        let spec = sandbox::SandboxSpec {
            argv: vec![antenna.to_string_lossy().into_owned(), "local-agent".into()],
            env: vec![
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("LC_ALL".into(), "C.UTF-8".into()),
                (
                    "ANTENNA_LLM_SOCKET".into(),
                    rt.sock.to_string_lossy().into_owned(),
                ),
                ("ANTENNA_LLM_KEY".into(), rt.key.to_string()),
                ("ANTENNA_LLM_MODEL".into(), model.into()),
                ("ANTENNA_LLM_CONTEXT".into(), cm.context.to_string()),
                (
                    "ANTENNA_LLM_THINKING".into(),
                    if cm.thinking { "1" } else { "0" }.into(),
                ),
            ],
            cwd: work,
            home,
            tmp,
            rw: vec![],
            ro: vec![bin_dir, rt.dir.clone()],
            ro_binds: vec![],
            // The runtime's socket is the one thing the loop may connect to (on macOS the profile allows connecting
            // only to the spec's sockets; on Linux the run folder above makes it visible too).
            sockets: vec![rt.sock.clone()],
            proxy: None,
            limits: sandbox::Limits {
                nofile: 256,
                fsize_bytes: 16 << 20,
                cpu_secs: LOOP_CPU_SECS,
                data_bytes: 1 << 30,
            },
            kind,
            start_gate: true,
            agent_stdin: true,
            listen: None,
            gpu: false,
        };
        let ctx = AgentCtx {
            id: self.agent_id,
            name: name.into(),
            forced: false,
        };
        // A fresh token, never shown: the binding to the sandbox root is what makes the loop's tree this agent.
        let token = new_token();
        let mut running = self.s.agent_start(&ctx, &spec, &token).await?;
        let stdout = running
            .stdout
            .take()
            .ok_or_else(|| Error::internal("sandbox: no stdout"))?;
        let log_task = match running.stderr.take() {
            Some(e) => tokio::spawn(read_tail(e)),
            None => tokio::spawn(async { Vec::new() }),
        };
        let (tx, lines) = mpsc::channel(1024);
        tokio::spawn(async move {
            let mut r = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match read_line_limited(&mut r, &mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                if let Ok(v) = serde_json::from_slice::<Value>(&buf)
                    && tx.send(v).await.is_err()
                {
                    break;
                }
            }
        });
        // The conversation so far (not the owner's message of this turn, which comes as the turn itself).
        let history = {
            let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::items(&db, self.agent_id, &self.counterpart, REPLAY, None)?.0
        };
        let messages: Vec<Value> = history
            .iter()
            .filter(|i| i.turn < n && !i.text.is_empty())
            .map(|i| {
                serde_json::json!({
                    "role": if i.role == "owner" { "user" } else { "assistant" },
                    "content": i.text,
                })
            })
            .collect();
        let ctx_line = serde_json::json!({
            "type": "antenna_context",
            "system": system_prompt(name, &cm.name, &self.counterpart),
            "messages": messages,
        });
        if let Err(e) = running.agent_input(&line(&ctx_line)).await {
            running.stop(Duration::from_secs(2)).await;
            return Err(e);
        }
        self.live = Some(Live {
            running,
            lines,
            log_task,
            agent: ctx,
            generation: rt.generation,
        });
        tracing::info!(
            "local agent {name}: started on {model} ({} sandbox, {} earlier messages)",
            kind.as_str(),
            messages.len()
        );
        Ok(())
    }

    async fn on_line(&mut self, v: Value) {
        let Some(t) = &mut self.busy else {
            return;
        };
        if v["type"] == "result" {
            let outcome = match v["subtype"].as_str() {
                Some("success") => "done",
                Some("interrupted") => "interrupted",
                _ => "failed",
            };
            let detail = match v["error"].as_str() {
                Some(e) => clean(e).chars().take(300).collect(),
                None if outcome == "interrupted" => t.interrupt_why.unwrap_or("interrupted").into(),
                None => String::new(),
            };
            let usage: Option<LocalUsage> = serde_json::from_value(v["antenna_usage"].clone()).ok();
            self.end_turn(outcome, detail, usage);
            return;
        }
        for a in t.parser.feed(&v) {
            if let ClaudeAction::Text(s) = a {
                let s = clean(&s);
                if s.is_empty() {
                    continue;
                }
                t.text.push_str(&s);
                let _ = t.out.send(LocalOut::Delta {
                    turn: t.n,
                    delta: s,
                    activity: None,
                });
            }
        }
    }

    /// The turn ended: store the reply and answer the owner's connection.
    fn end_turn(&mut self, outcome: &str, detail: String, usage: Option<LocalUsage>) {
        let Some(t) = self.busy.take() else {
            return;
        };
        let name = self.name();
        {
            let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
            if let Err(e) = db::item_insert(
                &db,
                &db::NewItem {
                    agent_id: self.agent_id,
                    counterpart: &self.counterpart,
                    turn: t.n,
                    role: "agent",
                    text: &t.text,
                    ts_ms: now_ms(),
                    outcome: Some(outcome),
                    detail: Some(&detail),
                    usage: usage.as_ref(),
                },
            ) {
                tracing::warn!("local agent {name}: cannot store the reply: {}", e.message);
            }
        }
        if outcome == "failed" {
            tracing::warn!("local agent {name}: turn {} failed: {detail}", t.n);
        }
        let _ = t.out.send(LocalOut::Done(LocalTurn {
            agent: name,
            turn: t.n,
            outcome: outcome.into(),
            text: t.text,
            detail,
            usage,
        }));
        self.idle_since = self.live.as_ref().map(|_| Instant::now());
        // The lease goes with the turn: the model may now be unloaded when idle.
        self.publish();
    }

    fn record_crash(&mut self) {
        let now = now_ms();
        self.crashes.push_back(now);
        while self
            .crashes
            .front()
            .is_some_and(|t| now.saturating_sub(*t) > CRASH_WINDOW_MS)
        {
            self.crashes.pop_front();
        }
        if self.crashes.len() >= MAX_CRASHES {
            self.failed =
                Some("it stopped 3 times in 10 minutes; the next message tries again".into());
        }
    }

    /// The process is gone: its binding and token are dropped; the stderr tail says why.
    async fn finish_process(&mut self, l: Live) -> String {
        let Live {
            mut running,
            log_task,
            agent,
            ..
        } = l;
        let status = tokio::time::timeout(Duration::from_secs(10), running.wait())
            .await
            .ok()
            .and_then(|r| r.ok());
        drop(running);
        {
            let db = self.s.db.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = db.agent_set_anchor(agent.id, None);
            let _ = db.agent_set_token(agent.id, &token_hash(&new_token()));
        }
        let tail = tokio::time::timeout(Duration::from_secs(3), log_task)
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_default();
        let text = String::from_utf8_lossy(&tail);
        let last = text
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .map(|l| clean(l).chars().take(200).collect::<String>())
            .unwrap_or_default();
        match status {
            Some(s) => format!(
                "exit {s}{}",
                if last.is_empty() {
                    String::new()
                } else {
                    format!(": {last}")
                }
            ),
            None => last,
        }
    }

    async fn stop_live(&mut self, why: &str) {
        let Some(mut l) = self.live.take() else {
            if self.busy.is_some() {
                self.end_turn("interrupted", why.into(), None);
            }
            return;
        };
        l.running.stop(Duration::from_secs(3)).await;
        let _ = self.finish_process(l).await;
        if self.busy.is_some() {
            self.end_turn("interrupted", why.into(), None);
        }
        self.idle_since = None;
    }

    async fn on_exit(&mut self) {
        let Some(l) = self.live.take() else {
            return;
        };
        let why = self.finish_process(l).await;
        if self.busy.is_some() {
            self.record_crash();
            self.end_turn("failed", format!("the local agent stopped ({why})"), None);
        }
        self.idle_since = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_text_loses_control_characters_but_keeps_lines() {
        assert_eq!(
            clean("a\u{1b}]52;c;Zm9v\u{7}b\nc\td\r"),
            "a]52;c;Zm9vb\nc\td"
        );
        assert_eq!(clean("\u{9b}31m"), "31m");
    }

    #[test]
    fn the_system_prompt_states_what_the_agent_cannot_do() {
        let p = system_prompt("helper", "Qwen3.5 2B", super::super::OWNER);
        assert!(p.contains("helper") && p.contains("Qwen3.5 2B"));
        assert!(p.contains("no internet access and no tools"));
        assert!(p.contains("talking with your owner"));
        // A team's conversation: the counterpart is the lead, not the owner (D-111).
        let t = system_prompt("web.docs-1", "Qwen3.5 9B", "team:web");
        assert!(
            t.contains("worker of the team web") && t.contains("not your owner"),
            "{t}"
        );
        assert!(t.contains("no internet access and no tools"), "{t}");
    }
}
