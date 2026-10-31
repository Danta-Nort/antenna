// SPDX-License-Identifier: AGPL-3.0-only
//! Local models and local agents (D-96 phase 2, D-104, `docs/CONTROL.md` §24, `docs/LOCAL-ASSISTANT.md`;
//! experimental).
//!
//! - **The catalog** is this release's (`packaging/models.json`, compiled in; [`antenna_proto::models`]). A model
//!   file is downloaded by `curl` in the agent sandbox through the daemon's CONNECT proxy, which lets it reach only
//!   the hub's hosts ([`models`]); it is checked against the release's size and SHA-256 before it is ever loaded, and
//!   a file that does not match is deleted.
//! - **The runtime** (llama.cpp's `llama-server`, built by us without an HTTPS client) runs one model each, in its
//!   own sandbox: it only listens on a unix socket, connects nowhere, reads its model read-only ([`pool`]). The pool
//!   places models in the memory local models may use, unloads idle ones and makes a turn wait for room.
//! - **A local agent** is an ordinary agent of this node (an `agents` row with no links) whose program is our loop,
//!   `antenna local-agent`, in a second sandbox without network that reaches only the runtime's socket
//!   ([`session`]). The loop speaks the stream-json subset the resident machinery parses (D-93), so it can get MCP
//!   tools later without a new boundary. The conversation is kept in the encrypted database and replayed into the
//!   loop when it starts.

pub mod hardware;

mod actor;
mod db;
mod download;
mod models;
mod pool;
mod session;

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex as StdMutex, PoisonError},
    time::{Duration, Instant},
};

use antenna_proto::{
    control::{
        LocalAgentInfo, LocalHistoryReply, LocalModelInfo, LocalModelsReply, LocalRuntimeInfo, code,
    },
    models::{Catalog, CatalogModel},
};

pub use session::LocalOut;

use crate::{
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
};

/// The conversation of a local agent with its owner (the only counterpart in this release; a lead agent or a
/// contact gets a conversation of its own later).
pub(crate) const OWNER: &str = "owner";

/// Settings of the daemon for local models (`antennad` flags).
#[derive(Debug, Clone)]
pub struct LocalConfig {
    /// The runtime program (`--local-runtime`); default `<directory of antennad>/llama/llama-server`.
    pub runtime: Option<PathBuf>,
    /// TESTS ONLY (debug builds): a catalog file instead of the release's (`--local-catalog`).
    pub catalog: Option<PathBuf>,
    /// TESTS ONLY (debug builds): the hub's address instead of `https://huggingface.co` (`--local-hub`), its CA
    /// certificate (`--local-hub-cacert`); the proxy then lets the download reach that loopback address.
    pub hub: Option<String>,
    /// See [`LocalConfig::hub`].
    pub hub_cacert: Option<PathBuf>,
    /// Stop an idle local agent and unload an idle model after this long (`--local-idle-secs`; 30 minutes).
    pub idle: Duration,
    /// Only lowers what local models may use (`--local-memory-budget`, bytes): tests of the queue.
    pub memory_cap: Option<u64>,
    /// How long one turn may take before it is interrupted.
    pub turn_timeout: Duration,
    /// Threads of a runtime (`--local-threads`); default: the physical (performance) cores.
    pub threads: Option<u32>,
}

impl Default for LocalConfig {
    fn default() -> Self {
        Self {
            runtime: None,
            catalog: None,
            hub: None,
            hub_cacert: None,
            idle: Duration::from_secs(30 * 60),
            memory_cap: None,
            turn_timeout: Duration::from_secs(10 * 60),
            threads: None,
        }
    }
}

/// A model's download or check in progress, or its last failure (memory only: a restart forgets a failure and
/// resumes a download from the database's `downloading` row).
#[derive(Debug, Clone, Default)]
pub(crate) struct Progress {
    /// `downloading`, `verifying`, `failed`.
    pub state: &'static str,
    pub done: u64,
    pub speed: Option<u64>,
    pub error_code: Option<&'static str>,
    pub error: Option<String>,
    /// When the last event for it was sent (progress events at most twice a second).
    pub emitted: Option<Instant>,
}

/// The node session's local model state.
pub(crate) struct LocalState {
    catalog: std::result::Result<Catalog, String>,
    pub(crate) progress: StdMutex<HashMap<String, Progress>>,
    /// Running downloads and checks: setting the flag cancels one.
    pub(crate) jobs: StdMutex<HashMap<String, tokio::sync::watch::Sender<bool>>>,
    pub(crate) pool: pool::Pool,
    pub(crate) sessions: StdMutex<HashMap<(i64, String), session::Handle>>,
    machine: StdMutex<Option<(Instant, hardware::Machine)>>,
}

impl LocalState {
    pub(crate) fn new(cfg: &LocalConfig) -> Self {
        let catalog = match &cfg.catalog {
            None => Catalog::builtin().map_err(|e| e.to_string()),
            Some(p) => std::fs::read_to_string(p)
                .map_err(|e| format!("model catalog {}: {e}", p.display()))
                .and_then(|j| Catalog::parse(&j).map_err(|e| e.to_string())),
        };
        if let Err(e) = &catalog {
            tracing::error!("local models: {e}");
        }
        Self {
            catalog,
            progress: StdMutex::default(),
            jobs: StdMutex::default(),
            pool: pool::Pool::default(),
            sessions: StdMutex::default(),
            machine: StdMutex::default(),
        }
    }
}

fn not_in_catalog(id: &str) -> Error {
    Error::new(
        code::NOT_FOUND,
        format!("{id:?} is not in this release's model catalog"),
    )
}

impl Session {
    pub(crate) fn local_catalog(&self) -> Result<&Catalog> {
        self.local
            .catalog
            .as_ref()
            .map_err(|e| Error::new(code::RUNTIME_UNAVAILABLE, e.clone()))
    }

    pub(crate) fn catalog_model(&self, id: &str) -> Result<CatalogModel> {
        self.local_catalog()?
            .get(id)
            .cloned()
            .ok_or_else(|| not_in_catalog(id))
    }

    /// `<data>/local`: models, run folders, the loops' scratch folders (0700).
    pub(crate) fn local_dir(&self) -> PathBuf {
        self.cfg.data_dir.join("local")
    }

    pub(crate) fn models_dir(&self) -> PathBuf {
        self.local_dir().join("models")
    }

    /// The machine, read at most every 2 seconds (`local_models` is asked for often while a download runs).
    pub(crate) fn machine(&self) -> hardware::Machine {
        let mut g = self
            .local
            .machine
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some((at, m)) = g.as_ref()
            && at.elapsed() < Duration::from_secs(2)
        {
            return m.clone();
        }
        let mut m = hardware::read(&self.models_dir());
        if let Some(cap) = self.cfg.local.memory_cap {
            m.memory = m.memory.min(cap.saturating_mul(2));
            m.available = m.available.min(cap.saturating_add(1 << 30));
        }
        *g = Some((Instant::now(), m.clone()));
        m
    }

    /// The runtime program: `--local-runtime`, or `llama/llama-server` next to `antennad`.
    pub(crate) fn runtime_program(&self) -> Option<PathBuf> {
        if let Some(p) = &self.cfg.local.runtime {
            return Some(p.clone());
        }
        let me = std::env::current_exe().ok()?;
        Some(me.parent()?.join("llama").join("llama-server"))
    }

    pub(crate) fn runtime_info(&self) -> LocalRuntimeInfo {
        let support = self.wake_support();
        let version = self
            .local_catalog()
            .map(|c| format!("llama.cpp {}", c.runtime.tag))
            .unwrap_or_default();
        let sandbox = support.kind.map_or("none", |k| k.as_str()).to_string();
        let prog = self.runtime_program();
        let present = prog.as_ref().is_some_and(|p| executable(p));
        let (available, detail) = if self.local.catalog.is_err() {
            (
                false,
                "the model catalog of this build is not readable".into(),
            )
        } else if !present {
            (
                false,
                format!(
                    "this build has no local model runtime ({} is missing)",
                    prog.map(|p| p.display().to_string()).unwrap_or_default()
                ),
            )
        } else if support.kind.is_none() {
            (
                false,
                format!(
                    "local models run only in a sandbox, and this system has none: {}",
                    support.detail
                ),
            )
        } else {
            (true, support.detail)
        };
        LocalRuntimeInfo {
            available,
            version: if present { version } else { String::new() },
            sandbox,
            detail,
        }
    }

    /// The runtime, or why models cannot run here (`runtime_unavailable`, `sandbox_unavailable`).
    pub(crate) fn runtime_ready(&self) -> Result<(PathBuf, crate::sandbox::SandboxKind)> {
        let info = self.runtime_info();
        if !info.available {
            let c = if info.sandbox == "none" {
                code::SANDBOX_UNAVAILABLE
            } else {
                code::RUNTIME_UNAVAILABLE
            };
            return Err(Error::new(c, info.detail));
        }
        let prog = self
            .runtime_program()
            .ok_or_else(|| Error::new(code::RUNTIME_UNAVAILABLE, "no runtime"))?;
        let kind = self
            .wake_support()
            .kind
            .ok_or_else(|| Error::new(code::SANDBOX_UNAVAILABLE, "no sandbox"))?;
        Ok((prog, kind))
    }

    fn emit_local_model(&self, info: LocalModelInfo) {
        let _ = self.events.send(NodeEvent::LocalModel(Box::new(info)));
    }

    fn emit_local_agent(&self, info: LocalAgentInfo) {
        let _ = self.events.send(NodeEvent::LocalAgent(Box::new(info)));
    }

    /// `local_models`.
    pub fn local_models(&self) -> Result<LocalModelsReply> {
        let machine = self.machine();
        let loaded = self.local.pool.loaded_bytes();
        let runtime = self.runtime_info();
        let models = self.model_infos(&machine)?;
        let agents = self.local_agent_infos()?;
        Ok(LocalModelsReply {
            hardware: machine.info(loaded),
            runtime,
            models,
            agents,
        })
    }

    /// The window's rows of the catalog, with each model's state and fit here.
    fn model_infos(&self, machine: &hardware::Machine) -> Result<Vec<LocalModelInfo>> {
        let catalog = self.local_catalog()?;
        let rows = db::models(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        let agents = self.local_agent_infos()?;
        let mut out: Vec<LocalModelInfo> = catalog
            .models
            .iter()
            .map(|cm| self.model_info_with(cm, &rows, &agents, machine))
            .collect();
        let fits = hardware::assess(
            machine,
            &catalog.models.iter().collect::<Vec<_>>(),
            self.local.pool.loaded_bytes(),
        );
        hardware::apply(&mut out, fits);
        Ok(out)
    }

    /// One model's row (without the fit, which depends on the whole catalog; see [`Session::model_infos`]).
    fn model_info_with(
        &self,
        cm: &CatalogModel,
        rows: &[db::ModelRow],
        agents: &[LocalAgentInfo],
        machine: &hardware::Machine,
    ) -> LocalModelInfo {
        let row = rows.iter().find(|r| r.id == cm.id);
        let p = self
            .local
            .progress
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&cm.id)
            .cloned();
        let path = self.model_path(&cm.id);
        let (state, done) = match (&p, row) {
            (Some(p), _) => (p.state, p.done),
            (None, Some(r)) if r.state == "ready" && path.is_file() => ("ready", cm.size),
            (None, Some(r)) if r.state == "downloading" => {
                ("downloading", file_len(&self.part_path(&cm.id)))
            }
            _ => ("available", 0),
        };
        LocalModelInfo {
            id: cm.id.clone(),
            name: cm.name.clone(),
            maker: cm.maker.clone(),
            license: cm.license.clone(),
            license_url: cm.license_url.clone(),
            languages: cm.languages.clone(),
            params: cm.params.clone(),
            quant: cm.quant.clone(),
            size_bytes: cm.size,
            memory_bytes: cm.memory_for(1, machine.metal()),
            context: cm.context,
            source: format!(
                "huggingface.co/{}@{}/{}",
                cm.repo,
                &cm.commit[..12.min(cm.commit.len())],
                cm.file
            ),
            fit: String::new(),
            fit_detail: String::new(),
            est_tokens_per_s: None,
            state: state.into(),
            done_bytes: done,
            speed_bytes_per_s: p.as_ref().and_then(|p| p.speed),
            error_code: p.as_ref().and_then(|p| p.error_code).map(String::from),
            error: p.as_ref().and_then(|p| p.error.clone()),
            loaded: self.local.pool.is_loaded(&cm.id),
            agents: agents
                .iter()
                .filter(|a| a.model == cm.id)
                .map(|a| a.name.clone())
                .collect(),
        }
    }

    /// One model's current row with its fit (for replies and events).
    pub(crate) fn model_info(&self, id: &str) -> Result<LocalModelInfo> {
        let machine = self.machine();
        self.model_infos(&machine)?
            .into_iter()
            .find(|m| m.id == id)
            .ok_or_else(|| not_in_catalog(id))
    }

    /// Send the model's state to subscribers; progress at most twice a second unless `force`.
    pub(crate) fn publish_model(&self, id: &str, force: bool) {
        {
            let mut g = self
                .local
                .progress
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if let Some(p) = g.get_mut(id) {
                if !force
                    && p.emitted
                        .is_some_and(|t| t.elapsed() < Duration::from_millis(500))
                {
                    return;
                }
                p.emitted = Some(Instant::now());
            }
        }
        if let Ok(info) = self.model_info(id) {
            self.emit_local_model(info);
        }
    }

    /// `<data>/local/models/<id>.gguf`: a checked file, read-only.
    pub(crate) fn model_path(&self, id: &str) -> PathBuf {
        self.models_dir().join(format!("{id}.gguf"))
    }

    /// `<data>/local/models/<id>.gguf.part`: a download or copy in progress.
    pub(crate) fn part_path(&self, id: &str) -> PathBuf {
        self.models_dir().join(format!("{id}.gguf.part"))
    }

    /// `local_agent_add` (the caller has checked the password): an agent with no links, no token file and no tools,
    /// whose program the daemon runs with this model.
    pub fn local_agent_add(&self, name: &str, model: &str) -> Result<LocalAgentInfo> {
        crate::agents::valid_name(name)?;
        self.catalog_model(model)?;
        let id = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            // The token is never shown to anyone: the daemon gives the loop a fresh one at every start (D-28 binds
            // it to the loop's sandbox).
            let token = crate::agents::new_token();
            let id = db.agent_insert(
                name,
                &crate::agents::token_hash(&token),
                Some(&[]),
                0,
                false,
                crate::now_ms(),
            )?;
            if let Err(e) = db::agent_insert(&db, id, model, crate::now_ms()) {
                let _ = db.agent_remove(id);
                return Err(e);
            }
            id
        };
        tracing::info!("local agent {name}: created on {model}");
        self.emit_agent(name, "added");
        let info = self.local_agent_info(id)?;
        self.emit_local_agent(info.clone());
        self.publish_model(model, true);
        Ok(info)
    }

    /// The local agents with their state.
    pub(crate) fn local_agent_infos(&self) -> Result<Vec<LocalAgentInfo>> {
        let rows = db::agents(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        rows.iter()
            .map(|(id, name, model, created)| self.agent_info_of(*id, name, model, *created))
            .collect()
    }

    pub(crate) fn local_agent_info(&self, agent_id: i64) -> Result<LocalAgentInfo> {
        let rows = db::agents(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        let (id, name, model, created) = rows
            .into_iter()
            .find(|r| r.0 == agent_id)
            .ok_or_else(|| Error::new(code::NOT_FOUND, "no such local agent"))?;
        self.agent_info_of(id, &name, &model, created)
    }

    fn agent_info_of(
        &self,
        id: i64,
        name: &str,
        model: &str,
        created_ms: u64,
    ) -> Result<LocalAgentInfo> {
        let (turns, last) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let (_, turns) = db::turn_counts(&db, id, OWNER)?;
            (turns, db::last_turn(&db, id)?)
        };
        let live = self.local_session_state(id);
        let (state, detail) = match live {
            Some((s, d)) if s != "sleeping" => (s, d),
            _ if !self.model_path(model).is_file() => (
                "no_model",
                format!("{model} is not on this computer: install it in Local models"),
            ),
            _ => ("sleeping", String::new()),
        };
        Ok(LocalAgentInfo {
            name: name.into(),
            model: model.into(),
            runtime: "local".into(),
            state: state.into(),
            detail,
            turns,
            last_turn_ms: last.as_ref().map(|(t, _)| *t),
            last_usage: last.and_then(|(_, u)| u),
            created_ms,
        })
    }

    /// The local agent by name: its ID and model.
    pub(crate) fn local_agent(&self, name: &str) -> Result<(i64, String)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        let model = db::agent_model(&db, row.id)?.ok_or_else(|| {
            Error::new(
                code::NOT_FOUND,
                format!("{name} is not a local agent (it does not run on a local model)"),
            )
        })?;
        Ok((row.id, model))
    }

    /// The model of a local agent, for `agent_list`; `None` for other agents.
    pub(crate) fn local_model_of(&self, agent_id: i64) -> Option<String> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db::agent_model(&db, agent_id).ok().flatten()
    }

    /// `local_history`.
    pub fn local_history(
        &self,
        agent: &str,
        limit: Option<u32>,
        before: Option<i64>,
    ) -> Result<LocalHistoryReply> {
        let (id, _) = self.local_agent(agent)?;
        let limit = limit.unwrap_or(100).clamp(1, 500);
        let (items, more) = db::items(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            id,
            OWNER,
            limit,
            before,
        )?;
        Ok(LocalHistoryReply {
            agent: agent.into(),
            items,
            more,
        })
    }

    /// `agent_remove` of a local agent: its processes stop; its conversation went with the agent's row.
    pub(crate) fn local_forget(&self, agent_id: i64) {
        let handles: Vec<session::Handle> = {
            let mut g = self
                .local
                .sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let keys: Vec<(i64, String)> = g.keys().filter(|k| k.0 == agent_id).cloned().collect();
            keys.iter().filter_map(|k| g.remove(k)).collect()
        };
        for h in handles {
            h.shutdown();
        }
        let _ = std::fs::remove_dir_all(self.local_dir().join("agents").join(agent_id.to_string()));
    }

    /// After unlock: downloads that a restart interrupted go on; the pool's idle timer starts.
    pub(crate) fn local_start(self: &Arc<Self>) {
        let rows = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::models(&db)
        };
        let rows = match rows {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("local models: {}", e.message);
                return;
            }
        };
        for r in rows.into_iter().filter(|r| r.state == "downloading") {
            tracing::info!("local model {}: resuming the download", r.id);
            if let Err(e) = self.model_install(&r.id, None) {
                tracing::warn!("local model {}: {}", r.id, e.message);
            }
        }
        pool::spawn_reaper(self.clone());
    }
}

/// Whether the agent runs on a local model (its token is never handed out).
pub(crate) fn is_local_agent(db: &crate::store::Db, agent_id: i64) -> bool {
    db::agent_model(db, agent_id).ok().flatten().is_some()
}

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// A file with an execute bit.
#[cfg(unix)]
fn executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Windows: the runtime there is `llama-server.exe` built with CUDA (D-134, WP-27, phase W5); this build has none.
#[cfg(windows)]
fn executable(_p: &Path) -> bool {
    false
}

/// A folder for unix sockets: `dir` itself when a socket in it fits `sun_path`, otherwise a private folder in
/// `/tmp/antenna-<uid>` named after it (as the proxy does, D-93 amendment).
#[cfg(unix)]
pub(crate) fn socket_dir(dir: &Path, sock_name: &str) -> Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    if dir.join(sock_name).as_os_str().len() <= crate::control::MAX_SOCKET_PATH {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        return Ok(dir.to_path_buf());
    }
    let base = crate::sandbox::private_tmp_dir()?;
    let name = data_encoding::HEXLOWER.encode(
        &crate::crypto::blake3_dk(
            "antenna local socket dir",
            dir.as_os_str().as_encoded_bytes(),
        )[..6],
    );
    let d = base.join(format!("lm-{name}"));
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&d)?;
    Ok(d)
}

/// Windows: refused. The built-in runtime there listens on loopback TCP with a per-start key, not on a unix socket
/// (D-134, WP-27, phase W5).
#[cfg(windows)]
pub(crate) fn socket_dir(_dir: &Path, _sock_name: &str) -> Result<PathBuf> {
    Err(Error::new(
        antenna_proto::control::code::NOT_IMPLEMENTED,
        "local models are not available on Windows yet",
    ))
}
