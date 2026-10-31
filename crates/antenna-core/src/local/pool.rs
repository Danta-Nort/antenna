// SPDX-License-Identifier: AGPL-3.0-only
//! The model runtimes (D-96 §3.4, §9): one `llama-server` per model in use, each in its own sandbox, shared by every
//! local agent on that model through parallel slots.
//!
//! - **The sandbox** ([`runtime_spec`]): the runtime's folder and the one model file read-only, its run folder
//!   writable for the socket only; [`crate::sandbox::SandboxSpec::listen`], so it makes no outgoing connection at all
//!   (Linux: seccomp refuses `connect` and every socket but a unix stream socket, proven from the inside before the
//!   `exec`; macOS: only the bind rule); no daemon socket, no token, no HOME of the owner; its own flags close its side
//!   doors (`--offline`, `--no-slots`, `--no-webui`, no tools or MCP options, no downloads) and a random API key per
//!   start, passed in its environment, never on the command line.
//! - **Placement** ([`place`], a pure function): a model loads only if it fits what local models may use now (the
//!   smaller of half the memory minus the loaded models, and the available memory minus 1 GB); otherwise idle models
//!   are unloaded, least recently used first; otherwise the turn waits (it never swaps); with nothing loaded and still
//!   no room, the turn fails at once with the numbers.
//! - **Idle:** a model nobody used for `--local-idle-secs` is unloaded.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex as StdMutex, PoisonError,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use antenna_proto::{control::code, models::CatalogModel};
use sha2::Digest;
#[cfg(unix)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zeroize::Zeroizing;

use super::{hardware, socket_dir};
use crate::{
    error::{Error, Result},
    node::Session,
    sandbox,
};

/// The socket's name in the run folder.
pub(crate) const SOCKET: &str = "llm.sock";
/// How long a model may take to load (a 6 GB file from a cold disk).
const LOAD_TIMEOUT: Duration = Duration::from_secs(300);
/// Conversations one runtime serves at once at most.
const MAX_SLOTS: u32 = 4;
/// Lines of the runtime's output kept for a failure's reason.
const TAIL_LINES: usize = 12;
/// Room left for the OS, a browser and Antenna.
const HEADROOM: u64 = 1 << 30;

#[derive(Debug, Clone, PartialEq, Eq)]
enum RtState {
    Loading,
    Ready,
    Failed(String),
}

/// A runtime with one model.
pub(crate) struct Runtime {
    pub(crate) model: String,
    /// Changes with every start: a loop started for another generation has the wrong key.
    pub(crate) generation: u64,
    /// The run folder (the loop's sandbox sees it read-only to reach the socket).
    pub(crate) dir: PathBuf,
    pub(crate) sock: PathBuf,
    pub(crate) key: Zeroizing<String>,
    pub(crate) memory: u64,
    state: tokio::sync::watch::Sender<RtState>,
    users: AtomicUsize,
    last_used: StdMutex<Instant>,
    running: tokio::sync::Mutex<Option<sandbox::Running>>,
    tail: Arc<StdMutex<std::collections::VecDeque<String>>>,
}

/// The runtimes of a node session.
#[derive(Default)]
pub(crate) struct Pool {
    runtimes: StdMutex<HashMap<String, Arc<Runtime>>>,
    changed: tokio::sync::Notify,
    generation: AtomicU64,
}

/// A turn's hold on a runtime: while it is held the model is not unloaded.
pub(crate) struct Lease {
    pub(crate) rt: Arc<Runtime>,
    pool: Arc<Session>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.rt.users.fetch_sub(1, Ordering::SeqCst);
        *self
            .rt
            .last_used
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Instant::now();
        self.pool.local.pool.changed.notify_waiters();
    }
}

impl Pool {
    /// Memory the loaded (and loading) models use.
    pub(crate) fn loaded_bytes(&self) -> u64 {
        self.runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .map(|r| r.memory)
            .sum()
    }

    pub(crate) fn is_loaded(&self, model: &str) -> bool {
        self.runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(model)
            .is_some_and(|r| *r.state.borrow() == RtState::Ready)
    }

    fn get(&self, model: &str) -> Option<Arc<Runtime>> {
        self.runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(model)
            .cloned()
    }

    /// Stop the model's runtime now (removal, idle, room for another model).
    pub(crate) async fn unload(&self, model: &str) {
        let rt = self
            .runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(model);
        if let Some(rt) = rt {
            stop(&rt).await;
            tracing::info!("local model {model}: unloaded");
        }
        self.changed.notify_waiters();
    }

    /// Stop every runtime (lock, the session ends).
    pub(crate) async fn unload_all(&self) {
        let all: Vec<Arc<Runtime>> = self
            .runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .drain()
            .map(|(_, r)| r)
            .collect();
        for rt in all {
            stop(&rt).await;
        }
    }
}

impl Runtime {
    /// Its process has exited.
    async fn exited(&self) -> bool {
        let mut g = self.running.lock().await;
        match g.as_mut() {
            Some(r) => !matches!(r.child.try_wait(), Ok(None)),
            None => true,
        }
    }
}

async fn stop(rt: &Runtime) {
    let running = rt.running.lock().await.take();
    if let Some(mut r) = running {
        r.stop(Duration::from_secs(3)).await;
    }
    let _ = std::fs::remove_file(&rt.sock);
    rt.state.send_replace(RtState::Failed("unloaded".into()));
}

/// What to do for a model that is not loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Placement {
    /// It fits: load it.
    Load,
    /// Unload this idle model first, then look again.
    Evict(String),
    /// Wait until a turn on another model ends.
    Wait,
    /// It will not fit even with nothing else loaded.
    Never(String),
}

/// A loaded model as placement sees it: (model, memory, in use, last used).
pub(crate) type Loaded = (String, u64, bool, Instant);

/// Where a model of `need` bytes goes, given the machine and what is loaded. Pure, so it is tested on made-up
/// numbers; the memory available now already reflects what the loaded models use.
pub(crate) fn place(need: u64, memory: u64, available: u64, loaded: &[Loaded]) -> Placement {
    let in_use: u64 = loaded.iter().map(|l| l.1).sum();
    let cap = (memory / 2).saturating_sub(in_use);
    let free = available.saturating_sub(HEADROOM);
    if need <= cap.min(free) {
        return Placement::Load;
    }
    if loaded.is_empty() {
        return Placement::Never(format!(
            "needs {} of memory; local models may use {} now",
            hardware::gb(need),
            hardware::gb((memory / 2).min(free))
        ));
    }
    match loaded
        .iter()
        .filter(|l| !l.2)
        .min_by_key(|l| l.3)
        .map(|l| l.0.clone())
    {
        Some(idle) => Placement::Evict(idle),
        None => Placement::Wait,
    }
}

/// A plain HTTP/1.1 GET over the runtime's unix socket: its status and body (bounded), for the health check.
#[cfg(unix)]
async fn http_get(sock: &Path, path: &str) -> Option<(u16, String)> {
    let mut s = tokio::net::UnixStream::connect(sock).await.ok()?;
    let req = format!("GET {path} HTTP/1.1\r\nHost: llm\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).await.ok()?;
    let mut buf = Vec::new();
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        (&mut s).take(64 * 1024).read_to_end(&mut buf),
    )
    .await;
    let text = String::from_utf8_lossy(&buf).into_owned();
    let status = text.split_whitespace().nth(1)?.parse().ok()?;
    let body = text
        .split_once("\r\n\r\n")
        .map(|(_, b)| b.to_string())
        .unwrap_or_default();
    Some((status, body))
}

/// Windows: no runtime answers there yet (loopback TCP, D-134, WP-27), so it is never healthy.
#[cfg(windows)]
async fn http_get(_sock: &Path, _path: &str) -> Option<(u16, String)> {
    None
}

/// The runtime's sandbox (see the module comment).
pub(crate) struct RuntimeLaunch<'a> {
    pub prog: &'a Path,
    pub model: &'a CatalogModel,
    pub model_path: &'a Path,
    pub template: &'a Path,
    pub dir: &'a Path,
    pub key: &'a str,
    pub slots: u32,
    pub threads: u32,
    pub need: u64,
    pub kind: sandbox::SandboxKind,
    pub metal: bool,
}

pub(crate) fn runtime_spec(l: &RuntimeLaunch<'_>) -> sandbox::SandboxSpec {
    let prog_dir = l
        .prog
        .canonicalize()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .or_else(|| l.prog.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("/"));
    let sock = l.dir.join(SOCKET);
    let ctx = u64::from(l.model.context) * u64::from(l.slots);
    let s = |x: &str| x.to_string();
    let argv = vec![
        l.prog.to_string_lossy().into_owned(),
        s("-m"),
        l.model_path.to_string_lossy().into_owned(),
        s("--host"),
        sock.to_string_lossy().into_owned(),
        s("--offline"),
        s("--no-slots"),
        s("--no-webui"),
        s("--alias"),
        l.model.id.clone(),
        s("--ctx-size"),
        ctx.to_string(),
        s("--parallel"),
        l.slots.to_string(),
        s("--threads"),
        l.threads.to_string(),
        s("--jinja"),
        s("--chat-template-file"),
        l.template.to_string_lossy().into_owned(),
        s("--reasoning"),
        s(if l.model.thinking { "on" } else { "off" }),
    ];
    sandbox::SandboxSpec {
        argv,
        // Only the key: no `LLAMA_ARG_*` variable can reach it from the daemon's environment (`--clearenv`).
        env: vec![
            ("LLAMA_API_KEY".into(), l.key.to_string()),
            ("LC_ALL".into(), "C".into()),
        ],
        cwd: l.dir.to_path_buf(),
        home: l.dir.join("home"),
        tmp: l.dir.join("tmp"),
        rw: vec![],
        // The template is read by the runtime itself; inside the macOS app it is outside the runtime's folder.
        ro: vec![
            prog_dir,
            l.model_path.to_path_buf(),
            l.template.to_path_buf(),
        ],
        ro_binds: vec![],
        sockets: vec![],
        proxy: None,
        limits: sandbox::Limits {
            nofile: 1024,
            fsize_bytes: 64 << 20,
            // No CPU limit: `RLIMIT_CPU` counts every thread's time, and a runtime at full power on 8 cores would use an
            // hour of it in under 8 minutes of answers (D-96 §9: full power by default). It is unloaded when idle.
            cpu_secs: 0,
            // The heap and buffers (the mapped model file does not count): what the model needs plus room.
            data_bytes: l.need.saturating_add(2 << 30),
        },
        kind: l.kind,
        start_gate: false,
        agent_stdin: false,
        listen: Some(sock),
        gpu: l.metal,
    }
}

/// Where the chat templates are for a runtime in `dir`: `<dir>/templates` (the Linux archives, the macOS CLI archive,
/// a development build), or, inside the macOS app, `Contents/Resources/llama/templates`: `Contents/Helpers` may hold
/// only signed code, and plain files there break the bundle's signature (codesign: "code object is not signed").
fn templates_dir(dir: &Path) -> PathBuf {
    let next_to = dir.join("templates");
    if next_to.is_dir() {
        return next_to;
    }
    match dir.parent() {
        Some(helpers) if dir.ends_with("Contents/Helpers/llama") => helpers
            .with_file_name("Resources")
            .join("llama")
            .join("templates"),
        _ => next_to,
    }
}

/// The official chat template next to the runtime, checked against the catalog (design §2.2): a missing or changed
/// file refuses the start, so the quantizer's embedded template is never used instead.
fn template_for(prog: &Path, cm: &CatalogModel) -> Result<PathBuf> {
    let dir = prog
        .canonicalize()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_default();
    let path = templates_dir(&dir).join(&cm.chat_template.file);
    let bytes = std::fs::read(&path).map_err(|e| {
        Error::new(
            code::RUNTIME_UNAVAILABLE,
            format!("the chat template {}: {e}", path.display()),
        )
    })?;
    let got = data_encoding::HEXLOWER.encode(&sha2::Sha256::digest(&bytes));
    if got != cm.chat_template.sha256 {
        return Err(Error::new(
            code::RUNTIME_UNAVAILABLE,
            format!(
                "the chat template {} does not match this release",
                path.display()
            ),
        ));
    }
    Ok(path)
}

/// Lines of the runtime's output, control characters removed, for a failure's reason; nothing of it is logged
/// otherwise.
fn keep_tail(
    r: impl tokio::io::AsyncRead + Unpin + Send + 'static,
    tail: Arc<StdMutex<std::collections::VecDeque<String>>>,
) {
    tokio::spawn(async move {
        use tokio::io::AsyncBufReadExt;
        let mut lines = tokio::io::BufReader::new(r).lines();
        while let Ok(Some(l)) = lines.next_line().await {
            let clean: String = l.chars().filter(|c| !c.is_control()).take(300).collect();
            let mut g = tail.lock().unwrap_or_else(PoisonError::into_inner);
            if g.len() >= TAIL_LINES {
                g.pop_front();
            }
            g.push_back(clean);
        }
    });
}

impl Session {
    /// Slots for a model: one per local agent on it, 1–4 (each further slot costs `slot_memory`).
    fn slots_for(&self, model: &str) -> u32 {
        let n = self
            .local_agent_infos()
            .map(|v| v.iter().filter(|a| a.model == model).count() as u32)
            .unwrap_or(1);
        n.clamp(1, MAX_SLOTS)
    }

    /// A lease on the model's runtime: loads it when needed, makes room by unloading idle models, waits while other
    /// turns hold the memory. `activity` hears `loading` and `waiting`.
    pub(crate) async fn runtime_acquire(
        self: &Arc<Self>,
        model: &str,
        activity: &(dyn Fn(&'static str) + Send + Sync),
    ) -> Result<Lease> {
        let cm = self.catalog_model(model)?;
        loop {
            if self.is_closed() {
                return Err(Error::new(code::LOCKED, "the node was locked"));
            }
            if let Some(rt) = self.local.pool.get(model) {
                let mut st = rt.state.subscribe();
                let now = st.borrow().clone();
                match now {
                    // A runtime that exited (a crash, the OS's memory killer) is started again.
                    RtState::Ready if rt.exited().await => {
                        tracing::warn!(
                            "local model {model}: the runtime exited; starting it again"
                        );
                        rt.state.send_replace(RtState::Failed("unloaded".into()));
                        continue;
                    }
                    RtState::Ready => {
                        rt.users.fetch_add(1, Ordering::SeqCst);
                        return Ok(Lease {
                            rt,
                            pool: self.clone(),
                        });
                    }
                    RtState::Loading => {
                        activity("loading");
                        let _ = tokio::time::timeout(LOAD_TIMEOUT, st.changed()).await;
                        continue;
                    }
                    RtState::Failed(why) => {
                        let mut g = self
                            .local
                            .pool
                            .runtimes
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner);
                        if g.get(model).is_some_and(|r| Arc::ptr_eq(r, &rt)) {
                            g.remove(model);
                        }
                        drop(g);
                        if why != "unloaded" {
                            return Err(Error::new(code::RUNTIME_UNAVAILABLE, why));
                        }
                        continue;
                    }
                }
            }
            let machine = self.machine_fresh();
            let slots = self.slots_for(model);
            let need = cm.memory_for(slots, machine.metal());
            let loaded: Vec<Loaded> = self
                .local
                .pool
                .runtimes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .values()
                .map(|r| {
                    (
                        r.model.clone(),
                        r.memory,
                        r.users.load(Ordering::SeqCst) > 0 || *r.state.borrow() == RtState::Loading,
                        *r.last_used.lock().unwrap_or_else(PoisonError::into_inner),
                    )
                })
                .collect();
            match place(need, machine.memory, machine.available, &loaded) {
                Placement::Load => {
                    activity("loading");
                    return self.runtime_start(&cm, slots, need, &machine).await;
                }
                Placement::Evict(idle) => {
                    tracing::info!("local model {idle}: unloaded to make room for {model}");
                    self.local.pool.unload(&idle).await;
                    self.publish_model(&idle, true);
                    // The memory comes back to the OS after the process has gone.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
                Placement::Wait => {
                    activity("waiting");
                    let wake = self.local.pool.changed.notified();
                    let _ = tokio::time::timeout(Duration::from_secs(2), wake).await;
                }
                Placement::Never(why) => {
                    return Err(Error::new(code::NO_MEMORY, format!("{}: {why}", cm.name)));
                }
            }
        }
    }

    /// The machine read again now (placement needs the memory available at this moment).
    fn machine_fresh(&self) -> hardware::Machine {
        *self
            .local
            .machine
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        self.machine()
    }

    async fn runtime_start(
        self: &Arc<Self>,
        cm: &CatalogModel,
        slots: u32,
        need: u64,
        machine: &hardware::Machine,
    ) -> Result<Lease> {
        let (prog, kind) = self.runtime_ready()?;
        let model_path = self.model_checked(&cm.id).await?;
        let template = template_for(&prog, cm)?;
        let dir = socket_dir(&self.local_dir().join("run").join(&cm.id), SOCKET)?;
        let _ = std::fs::remove_file(dir.join(SOCKET));
        let key = Zeroizing::new(data_encoding::HEXLOWER.encode(&crate::crypto::random::<24>()));
        let generation = self.local.pool.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, _) = tokio::sync::watch::channel(RtState::Loading);
        let rt = Arc::new(Runtime {
            model: cm.id.clone(),
            generation,
            dir: dir.clone(),
            sock: dir.join(SOCKET),
            key: key.clone(),
            memory: need,
            state: tx,
            users: AtomicUsize::new(1),
            last_used: StdMutex::new(Instant::now()),
            running: tokio::sync::Mutex::new(None),
            tail: Arc::default(),
        });
        self.local
            .pool
            .runtimes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(cm.id.clone(), rt.clone());
        self.publish_model(&cm.id, true);
        let lease = Lease {
            rt: rt.clone(),
            pool: self.clone(),
        };
        let spec = runtime_spec(&RuntimeLaunch {
            prog: &prog,
            model: cm,
            model_path: &model_path,
            template: &template,
            dir: &dir,
            key: &key,
            slots,
            threads: self
                .cfg
                .local
                .threads
                .unwrap_or_else(|| default_threads(machine))
                .clamp(1, 64),
            need,
            kind,
            metal: machine.metal(),
        });
        let t0 = Instant::now();
        let started = async {
            let me = std::env::current_exe()?;
            let mut running = sandbox::launch(&spec, &me).await?;
            if let Some(e) = running.stderr.take() {
                keep_tail(e, rt.tail.clone());
            }
            if let Some(o) = running.stdout.take() {
                keep_tail(o, rt.tail.clone());
            }
            loop {
                if let Ok(Some(st)) = running.child.try_wait() {
                    let tail: Vec<String> = rt
                        .tail
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .iter()
                        .cloned()
                        .collect();
                    let why = tail
                        .iter()
                        .rev()
                        .find(|l| l.contains("error") || l.starts_with(sandbox::NOTE_PREFIX))
                        .or(tail.last())
                        .cloned()
                        .unwrap_or_default();
                    let c = if st.code() == Some(sandbox::EXIT_SANDBOX_FAILED) {
                        code::SANDBOX_UNAVAILABLE
                    } else {
                        code::RUNTIME_UNAVAILABLE
                    };
                    return Err(Error::new(c, format!("the runtime exited ({st}): {why}")));
                }
                if let Some((200, body)) = http_get(&dir.join(SOCKET), "/health").await
                    && body.contains("ok")
                {
                    break;
                }
                if t0.elapsed() > LOAD_TIMEOUT {
                    running.stop(Duration::from_secs(2)).await;
                    return Err(Error::new(
                        code::TIMEOUT,
                        "the model did not load within 5 minutes",
                    ));
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Ok::<_, Error>(running)
        }
        .await;
        match started {
            Ok(running) => {
                *rt.running.lock().await = Some(running);
                rt.state.send_replace(RtState::Ready);
                tracing::info!(
                    "local model {}: loaded in {:.1} s ({} slot(s), {} sandbox)",
                    cm.id,
                    t0.elapsed().as_secs_f64(),
                    slots,
                    kind.as_str()
                );
                self.publish_model(&cm.id, true);
                Ok(lease)
            }
            Err(e) => {
                tracing::warn!("local model {}: {}", cm.id, e.message);
                rt.state.send_replace(RtState::Failed(e.message.clone()));
                self.local
                    .pool
                    .runtimes
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(&cm.id);
                drop(lease);
                self.publish_model(&cm.id, true);
                Err(e)
            }
        }
    }
}

/// Threads of a runtime: the physical (on Apple silicon, performance) cores, so the model runs at full power (D-96
/// §9). A machine whose every thread is its own core reports no SMT at all, which is most often a virtual machine
/// shared with other work: there half of them, because llama.cpp's threads wait by spinning and a busy host makes an
/// oversubscribed runtime several times slower (measured on the build server: 4.5 tokens/s with 16 threads at load
/// 11, 30 with 8; `docs/LOCAL-ASSISTANT.md` §10). `--local-threads` overrides it.
pub(crate) fn default_threads(m: &hardware::Machine) -> u32 {
    if !m.metal() && m.cores == m.threads && m.threads > 4 {
        m.threads / 2
    } else {
        m.cores
    }
}

/// Unload models nobody used for `--local-idle-secs`; everything when the node locks.
pub(crate) fn spawn_reaper(s: Arc<Session>) {
    tokio::spawn(async move {
        let tick =
            (s.cfg.local.idle / 4).clamp(Duration::from_millis(200), Duration::from_secs(15));
        loop {
            tokio::select! {
                _ = s.closed_wait() => {
                    s.local.pool.unload_all().await;
                    return;
                }
                _ = tokio::time::sleep(tick) => {}
            }
            let idle: Vec<String> = s
                .local
                .pool
                .runtimes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .values()
                .filter(|r| {
                    r.users.load(Ordering::SeqCst) == 0
                        && *r.state.borrow() == RtState::Ready
                        && r.last_used
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .elapsed()
                            >= s.cfg.local.idle
                })
                .map(|r| r.model.clone())
                .collect();
            for m in idle {
                s.local.pool.unload(&m).await;
                s.publish_model(&m, true);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The templates next to the runtime win; inside the macOS app (`Contents/Helpers/llama`) they are found in
    /// `Contents/Resources/llama/templates`, where codesign allows plain files.
    #[test]
    fn templates_next_to_the_runtime_or_in_the_app_resources() {
        let root = tempfile::tempdir().expect("temp dir");
        let plain = root.path().join("bin/llama");
        std::fs::create_dir_all(plain.join("templates")).expect("mkdir");
        assert_eq!(templates_dir(&plain), plain.join("templates"));

        let app = root.path().join("Antenna.app/Contents");
        let helpers = app.join("Helpers/llama");
        std::fs::create_dir_all(&helpers).expect("mkdir");
        std::fs::create_dir_all(app.join("Resources/llama/templates")).expect("mkdir");
        assert_eq!(
            templates_dir(&helpers),
            app.join("Resources/llama/templates")
        );

        let elsewhere = root.path().join("other/llama");
        std::fs::create_dir_all(&elsewhere).expect("mkdir");
        assert_eq!(templates_dir(&elsewhere), elsewhere.join("templates"));
    }

    const GIB: u64 = 1 << 30;

    #[test]
    fn placement_never_swaps() {
        let now = Instant::now();
        let earlier = now - Duration::from_secs(60);
        // 32 GB with 20 GB available: a 5 GB model loads.
        assert_eq!(place(5 * GIB, 32 * GIB, 20 * GIB, &[]), Placement::Load);
        // Half of the memory is the cap for local models together: 10 + 5 > 16 − … no; with 10 loaded, 7 more does not
        // fit, and the idle one goes first.
        let loaded = vec![("big".to_string(), 10 * GIB, false, earlier)];
        assert_eq!(
            place(7 * GIB, 32 * GIB, 20 * GIB, &loaded),
            Placement::Evict("big".into())
        );
        // The same, but the loaded model is in use: wait.
        let busy = vec![("big".to_string(), 10 * GIB, true, earlier)];
        assert_eq!(place(7 * GIB, 32 * GIB, 20 * GIB, &busy), Placement::Wait);
        // Two fit together.
        assert_eq!(place(5 * GIB, 32 * GIB, 20 * GIB, &busy), Placement::Load);
        // The least recently used idle model is unloaded first.
        let two = vec![
            ("a".to_string(), 6 * GIB, false, now),
            ("b".to_string(), 6 * GIB, false, earlier),
        ];
        assert_eq!(
            place(8 * GIB, 32 * GIB, 30 * GIB, &two),
            Placement::Evict("b".into())
        );
        // Available memory counts even below the cap: 3 GB available leaves 2 GB for models.
        assert_eq!(
            place(4 * GIB, 32 * GIB, 3 * GIB, &[]),
            Placement::Never("needs 4.3 GB of memory; local models may use 2.1 GB now".into())
        );
    }

    #[test]
    fn threads_follow_the_cores_but_not_on_a_shared_vm() {
        let m = |os: &str, arch: &str, cores: u32, threads: u32| hardware::Machine {
            os: os.into(),
            arch: arch.into(),
            cpu: String::new(),
            cores,
            threads,
            avx2: true,
            memory: 16 * GIB,
            available: 8 * GIB,
            disk_free: 0,
        };
        // A laptop with SMT: its physical cores.
        assert_eq!(default_threads(&m("linux", "x86_64", 8, 16)), 8);
        // Apple silicon: its performance cores.
        assert_eq!(default_threads(&m("macos", "aarch64", 8, 10)), 8);
        // Every thread its own core (a VM such as the build server): half.
        assert_eq!(default_threads(&m("linux", "x86_64", 16, 16)), 8);
        assert_eq!(default_threads(&m("linux", "x86_64", 4, 4)), 4);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "WP-27 (W5): the built-in runtime on Windows (loopback TCP, not a unix socket)"
    )]
    fn the_runtime_is_started_with_its_side_doors_closed() {
        let cm = antenna_proto::models::Catalog::builtin().unwrap().models[0].clone();
        let spec = runtime_spec(&RuntimeLaunch {
            prog: Path::new("/opt/antenna/llama/llama-server"),
            model: &cm,
            model_path: Path::new("/data/local/models/qwen3.5-2b.gguf"),
            template: Path::new("/opt/antenna/llama/templates/t.jinja"),
            dir: Path::new("/data/local/run/qwen3.5-2b"),
            key: "k3y",
            slots: 2,
            threads: 8,
            need: 2 * GIB,
            kind: sandbox::SandboxKind::Bwrap,
            metal: false,
        });
        let a = spec.argv.join(" ");
        for want in [
            "--offline",
            "--no-slots",
            "--no-webui",
            "--host /data/local/run/qwen3.5-2b/llm.sock",
            "--ctx-size 16384",
            "--parallel 2",
            "--chat-template-file /opt/antenna/llama/templates/t.jinja",
            "--reasoning off",
        ] {
            assert!(a.contains(want), "{want} not in {a}");
        }
        // Never its own downloads, tools, MCP or slot dumps; the key is not on the command line.
        for never in [
            "-hf",
            "--hf-repo",
            "-mu",
            "--model-url",
            "--tools",
            "--mcp",
            "--ui-mcp-proxy",
            "--slot-save-path",
            "k3y",
            "--api-key",
        ] {
            assert!(
                !spec.argv.iter().any(|x| x == never || x.contains("k3y")),
                "{never} in {a}"
            );
        }
        assert_eq!(spec.env[0], ("LLAMA_API_KEY".into(), "k3y".into()));
        assert_eq!(
            spec.listen.as_deref(),
            Some(Path::new("/data/local/run/qwen3.5-2b/llm.sock"))
        );
        assert!(spec.proxy.is_none() && spec.sockets.is_empty() && spec.rw.is_empty());
        // The model is read-only: it is among `ro`, and nothing writable contains it.
        assert!(spec.ro.iter().any(|p| p.ends_with("qwen3.5-2b.gguf")));
        let model = Path::new("/data/local/models/qwen3.5-2b.gguf");
        assert!(
            ![&spec.cwd, &spec.home, &spec.tmp]
                .iter()
                .any(|d| model.starts_with(d))
        );
        assert_eq!(spec.limits.cpu_secs, 0);
        assert_eq!(spec.limits.data_bytes, 4 * GIB);
    }
}
