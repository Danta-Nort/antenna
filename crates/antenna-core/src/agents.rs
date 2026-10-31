// SPDX-License-Identifier: AGPL-3.0-only
//! Node agents (SPEC §9, §11; Q-12a, DECISIONS D-27…D-29).
//!
//! - An agent session token is issued only by the owner (`antenna agent add`, with the password). The token is 256
//!   random bits; only its hash is stored in the DB. Biscuit with holder-of-key (D-11) is kept for capabilities between
//!   links: locally the issuer and the verifier are the same daemon, so offline verification is not needed (D-27).
//! - Process binding (`SO_PEERCRED`; on macOS the audit token, D-28): `antenna mcp` binds the token to its parent, the
//!   MCP host (Claude Code, Codex…). While the host is alive, the token is accepted only from its descendants; and any
//!   process in its tree, even without a token and even one claiming to be the owner, gets this agent's role (it has
//!   no owner commands).
//! - Session = the token's lifetime until `antenna agent reset`: taint, read links and declared local reads are stored
//!   in the DB and survive a daemon restart (D-29).

use std::sync::PoisonError;
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    time::Duration,
};

use antenna_proto::{
    LinkId,
    control::{
        AGENT_TOKEN_PREFIX, AUTHORITY_DATA, AUTHORITY_TASK, AgentContact, AgentInboxReply,
        AgentInfo, AgentMessage, ApprovalResolution, CheckReply, DeclaredRead, FileInfo, Grants,
        MessageFact, ReceiptInfo, SentReply, SessionInfo, TaintInfo, TrustInfo, UNTRUSTED_NOTICE,
        code, task_notice,
    },
};
use zeroize::Zeroizing;

use crate::{
    addressing::{self, Addr, AddrReq, Reader},
    approvals::{Continuation, Pass},
    crypto,
    error::{Error, Result},
    events::NodeEvent,
    files::ShareSource,
    node::Session,
    now_ms,
    policy::{self, Action, Label, Verdict},
    procinfo::{self, Anchor, ProcStat},
    store::{AgentRow, DeclEntry, LinkRow, TaintEntry},
};

const TOKEN_LABEL: &[u8] = b"x/agent-token/v0";
/// Agent token files in the data directory: `<data-dir>/agents/<name>.token` (directory `0700`, files `0600`).
const TOKEN_DIR: &str = "agents";
/// How many read declarations to keep (the label is the maximum; the history is for audit).
const MAX_DECLARED: usize = 64;

/// New agent token: `xat_` + base32(32 random bytes).
pub fn new_token() -> Zeroizing<String> {
    let raw = crypto::random_secret();
    Zeroizing::new(format!(
        "{AGENT_TOKEN_PREFIX}{}",
        data_encoding::BASE32_NOPAD
            .encode(raw.as_slice())
            .to_ascii_lowercase()
    ))
}

/// Token hash for the DB.
pub fn token_hash(token: &str) -> [u8; 32] {
    crypto::sha256(&[TOKEN_LABEL, token.as_bytes()])
}

/// Who talks to the daemon in the agent role.
#[derive(Debug, Clone)]
pub struct AgentCtx {
    /// Agent ID.
    pub id: i64,
    /// Name.
    pub name: String,
    /// The role was assigned by the process tree (the client claimed to be the owner).
    pub forced: bool,
}

pub(crate) fn valid_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return Err(Error::bad_request(
            "agent name: 1–64 characters of [A-Za-z0-9._-]",
        ));
    }
    // The contact sees the name (PROTOCOL §21); `owner` in receipts means the owner
    if name.eq_ignore_ascii_case("owner") {
        return Err(Error::bad_request("agent name: `owner` is reserved"));
    }
    Ok(())
}

/// A token file written next to its final name and renamed into place only when the caller commits: a reader never
/// sees a half-written file, and a failure before the commit leaves the old file (or none) as it was.
struct StagedToken {
    tmp: PathBuf,
    dest: PathBuf,
    done: bool,
}

impl StagedToken {
    /// Write `<token>\n` into a new `0600` file (`O_EXCL`, `O_NOFOLLOW`) in the `0700` directory of `dest`.
    ///
    /// Windows (D-134 WP-4, D-135): the directory is in the data folder, so the folder and the file inherit its entry
    /// for the user alone (`owner_only`); the file is made new (`CREATE_NEW`, which an existing link at the name also
    /// fails), and the CLI checks the file's owner and access list before it reads the token.
    fn write(dest: PathBuf, token: &str) -> Result<Self> {
        use crate::owner_only::OwnerOnly;
        use std::io::Write as _;
        let dir = dest
            .parent()
            .ok_or_else(|| Error::internal("token file without a directory"))?
            .to_path_buf();
        std::fs::DirBuilder::new()
            .recursive(true)
            .owner_only()
            .create(&dir)?;
        let m = std::fs::symlink_metadata(&dir)?;
        if !m.is_dir() {
            return Err(Error::internal(format!(
                "{} is not a directory",
                dir.display()
            )));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if m.permissions().mode() & 0o077 != 0 {
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
            }
        }
        let tmp = dir.join(format!(
            ".{}.{}.tmp",
            dest.file_name().unwrap_or_default().to_string_lossy(),
            data_encoding::HEXLOWER.encode(&crypto::random::<8>())
        ));
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create_new(true).owner_only();
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
        }
        let mut f = o.open(&tmp)?;
        // From here on a failure removes the temporary file (Drop)
        let staged = Self {
            tmp,
            dest,
            done: false,
        };
        let line = Zeroizing::new(format!("{token}\n"));
        f.write_all(line.as_bytes())?;
        f.sync_all()?;
        Ok(staged)
    }

    /// Rename into place (replacing an older file, never following a link at the final name).
    fn commit(mut self) -> Result<PathBuf> {
        std::fs::rename(&self.tmp, &self.dest)?;
        self.done = true;
        Ok(self.dest.clone())
    }
}

impl Drop for StagedToken {
    fn drop(&mut self) {
        if !self.done {
            let _ = std::fs::remove_file(&self.tmp);
        }
    }
}

/// Remove a token file; a missing one is fine.
fn remove_token_file(p: &Path) -> Result<()> {
    match std::fs::remove_file(p) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

/// Where the nearest of an agent's hosts is in the client's chain (D-P-10), if any.
fn position(chain: &[ProcStat], hosts: &[(Anchor, String)]) -> Option<usize> {
    hosts
        .iter()
        .filter_map(|(a, _)| procinfo::chain_position(chain, a))
        .min()
}

fn link_hex(l: &LinkId) -> String {
    l.to_hex()
}

/// What one agent may read (v6, CONTROL §20): its name, whether it reads messages to everyone, and the links whose
/// wake agent it is.
pub(crate) struct Visibility {
    name: String,
    everyone: bool,
    wake_links: Vec<LinkId>,
}

impl Visibility {
    /// For an agent row.
    pub(crate) fn of(db: &crate::store::Db, agent: &AgentRow) -> Result<Self> {
        Ok(Self {
            name: agent.name.clone(),
            everyone: agent.everyone,
            wake_links: db.wake_links_of(agent.id)?,
        })
    }

    /// Whether the agent sees an incoming message with this address (`to` from the signed `core`) on `link`.
    pub(crate) fn sees_to(&self, link: &LinkId, to: Option<&antenna_proto::To>) -> bool {
        let wake = self.wake_links.contains(link);
        // The name the contact sees (`Session::agent_public_name`): the default wake agent is `wake`
        let public_name = if wake && self.name.starts_with("wake-") {
            "wake"
        } else {
            self.name.as_str()
        };
        addressing::visible(
            &Reader {
                public_name,
                everyone: self.everyone,
                wake,
            },
            to,
        )
    }

    fn sees(&self, r: &crate::store::InboxRow) -> bool {
        self.sees_to(&r.link_id, r.to.as_ref())
    }

    /// Whether the agent sees a file offer with this address on `link` (PG-19): one addressed to an agent only that
    /// agent, one to the person only the link's wake agent (it answers for the person, as for messages); one to
    /// everyone or without an address every agent with the link, as before offers could be addressed (an older
    /// sender cannot address one).
    pub(crate) fn sees_offer(&self, link: &LinkId, to: Option<&antenna_proto::To>) -> bool {
        match to {
            Some(antenna_proto::To::Agent(_) | antenna_proto::To::Person) => self.sees_to(link, to),
            Some(antenna_proto::To::Everyone) | None => true,
        }
    }

    /// The agent's name in its own outgoing messages on `link` (`messages.agent`).
    pub(crate) fn public_name(&self, link: &LinkId) -> &str {
        if self.wake_links.contains(link) && self.name.starts_with("wake-") {
            "wake"
        } else {
            &self.name
        }
    }
}

/// A declared read of local data at `level` in agent `row`'s label (it only grows). The history is bounded, but the
/// level maximum is kept in the first entry.
pub(crate) fn declare(row: &mut AgentRow, level: u8, what: String) {
    row.declared.push(DeclEntry {
        level,
        what,
        at: now_ms(),
    });
    if row.declared.len() > MAX_DECLARED {
        let max = row.declared.iter().map(|d| d.level).max().unwrap_or(level);
        row.declared.drain(..row.declared.len() - MAX_DECLARED);
        row.declared[0].level = row.declared[0].level.max(max);
    }
}

/// Session label from a DB row.
pub(crate) fn label_of(row: &AgentRow) -> Label {
    let mut l = Label {
        local_level: row.local_level,
        ..Default::default()
    };
    for t in &row.taint {
        if let Ok(v) = data_encoding::HEXLOWER.decode(t.link.as_bytes())
            && let Ok(a) = <[u8; 32]>::try_from(v)
        {
            l.read.insert(LinkId(a));
            if t.ceiling {
                let e = l.taint.entry(LinkId(a)).or_insert(t.level);
                *e = (*e).min(t.level);
            }
        }
    }
    for d in &row.declared {
        l.local_level = l.local_level.max(d.level);
    }
    l
}

impl Session {
    // Owner commands

    /// `antenna agent add` (the caller has checked the password). Returns the token, shown once, and with `token_file`
    /// the path of the token file the daemon wrote.
    pub fn agent_add(
        &self,
        name: &str,
        links: Option<Vec<String>>,
        local_level: u8,
        everyone: bool,
        token_file: bool,
    ) -> Result<(Zeroizing<String>, Option<String>)> {
        valid_name(name)?;
        if local_level > 5 {
            return Err(Error::bad_request("local level must be 0..5"));
        }
        let file = self.token_file_path(name);
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let scope = match links {
            None => None,
            Some(ls) => Some(
                ls.iter()
                    .map(|c| db.find_link(c).map(|r| r.link_id))
                    .collect::<Result<Vec<_>>>()?,
            ),
        };
        let token = new_token();
        let staged = if token_file {
            Some(StagedToken::write(file.clone()?, &token)?)
        } else {
            None
        };
        let id = db.agent_insert(
            name,
            &token_hash(&token),
            scope.as_deref(),
            local_level,
            everyone,
            now_ms(),
        )?;
        let path = match staged {
            Some(s) => match s.commit() {
                Ok(p) => Some(p),
                Err(e) => {
                    let _ = db.agent_remove(id);
                    return Err(e);
                }
            },
            None => {
                // A file left by an earlier agent of this name would hold a token that does not work
                if let Ok(p) = &file {
                    let _ = remove_token_file(p);
                }
                None
            }
        };
        drop(db);
        tracing::info!("agent {name}: token issued");
        self.emit_agent(name, "added");
        Ok((token, path.map(|p| p.to_string_lossy().into_owned())))
    }

    /// The owner's view of one agent by name.
    pub(crate) fn agent_info_by_name(&self, name: &str) -> Result<AgentInfo> {
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent_by_name(name)?;
        Ok(self.agent_info(&row, &self.link_names()?, &self.wake_agent_ids()))
    }

    /// `antenna agent list`.
    pub fn agent_list(&self) -> Result<Vec<AgentInfo>> {
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agents()?;
        let names = self.link_names()?;
        let wake = self.wake_agent_ids();
        Ok(rows
            .iter()
            .map(|r| self.agent_info(r, &names, &wake))
            .collect())
    }

    /// `antenna agent set` (v6, CONTROL §20): whether the agent also reads messages to everyone. The caller has
    /// checked the password when `everyone` is turned on (it widens what the agent reads).
    pub fn agent_set(&self, name: &str, everyone: bool) -> Result<Vec<AgentInfo>> {
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db.agent_by_name(name)?;
            db.agent_set_everyone(row.id, everyone)?;
        }
        tracing::info!(
            "agent {name}: messages to everyone {}",
            if everyone { "allowed" } else { "not allowed" }
        );
        self.agent_list()
    }

    /// `antenna agent reset`: a new session (taint cleared, process binding cleared).
    pub fn agent_reset(&self, name: &str) -> Result<AgentInfo> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        db.agent_reset(row.id, now_ms())?;
        let row = db.agent(row.id)?;
        drop(db);
        Ok(self.agent_info(&row, &self.link_names()?, &self.wake_agent_ids()))
    }

    /// `antenna agent token`: a new token for an existing agent (the caller has checked the password); the old one
    /// stops working at once. The links, data label, session (taint) and process binding stay: a binding to a living
    /// host must not be dropped (its tree would become the owner, see `agent_reset`), so a new process can bind only
    /// after the old host has exited. The link's dedicated wake agent is refused: the daemon gives it a new token for
    /// every run, and it runs only inside the wake sandbox. An existing token file is rewritten even without
    /// `token_file`, so that it never holds a token that no longer works.
    pub fn agent_token(
        &self,
        name: &str,
        token_file: bool,
    ) -> Result<(Zeroizing<String>, Option<String>)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        if db.wake_rules()?.iter().any(|(_, id, _, _)| *id == row.id) {
            return Err(Error::new(
                code::DENIED,
                format!(
                    "agent {name} replies on wake: the daemon starts it in a sandbox with a new token for every run"
                ),
            ));
        }
        if crate::local::is_local_agent(&db, row.id) {
            return Err(Error::new(
                code::DENIED,
                format!(
                    "agent {name} runs on a local model: the daemon starts it in its sandbox with a new token every \
                     time, and the token is never shown"
                ),
            ));
        }
        // A team's worker (D-111): its token exists only inside its sandbox; nobody, the lead included, holds one.
        if crate::teams::is_worker(&db, row.id) {
            return Err(Error::new(
                code::DENIED,
                format!(
                    "agent {name} is a team's worker: the daemon starts it in its sandbox with a new token every \
                     time, and the token is never shown"
                ),
            ));
        }
        let file = self.token_file_path(name);
        let exists = file
            .as_ref()
            .is_ok_and(|p| std::fs::symlink_metadata(p).is_ok());
        let token = new_token();
        let staged = if token_file || exists {
            Some(StagedToken::write(file.clone()?, &token)?)
        } else {
            None
        };
        db.agent_set_token(row.id, &token_hash(&token))?;
        let path = match staged {
            Some(s) => match s.commit() {
                Ok(p) => Some(p),
                Err(e) => {
                    // The old file holds a token that stopped working: never leave it behind
                    if let Ok(p) = &file {
                        let _ = remove_token_file(p);
                    }
                    return Err(Error::internal(format!(
                        "the token was replaced, but its file could not be written ({}); run `antenna agent token {name}` \
                         again",
                        e.message
                    )));
                }
            },
            None => None,
        };
        drop(db);
        tracing::info!("agent {name}: new token issued");
        self.emit_agent(name, "token");
        Ok((token, path.map(|p| p.to_string_lossy().into_owned())))
    }

    /// `antenna agent remove`: the token stops working; its token file is deleted.
    pub fn agent_remove(&self, name: &str) -> Result<()> {
        // The name each contact knows it by, read while its wake rules still exist (`wake` for a link's wake agent)
        let links = self.running_links();
        let public: Vec<_> = links
            .iter()
            .map(|rt| {
                let l = rt.shared.link_id;
                (rt.clone(), self.agent_public_name(name, &l))
            })
            .collect();
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        db.agent_remove(row.id)?;
        // Its picture goes with it; contacts that saw one get initials again (PROTOCOL §25)
        crate::pictures::forget_own(db.conn(), name)?;
        drop(db);
        self.revoke_agent_keys(name, &public);
        // A local agent: its processes stop (its conversation went with the row, D-104).
        self.local_forget(row.id);
        // A team's worker or lead: its process stops; its member row went with the agent's, a team it led is led by the
        // owner now (D-111).
        self.team_forget_agent(row.id);
        self.app_hosts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forget(row.id);
        if let Ok(p) = self.token_file_path(name)
            && let Err(e) = remove_token_file(&p)
        {
            tracing::warn!("agent {name}: cannot delete {}: {}", p.display(), e.message);
        }
        self.emit_agent(name, "removed");
        self.sync_pictures_now();
        Ok(())
    }

    /// A removed agent's keys (PG-20, PROTOCOL §21): each link where it wrote gets a revocation signed by link-root,
    /// so its contacts refuse the key from now on. A link that cannot send now (a rollback, an unfinished rekey)
    /// keeps the key valid at the contact; nothing here signs with it any more, and the log says so.
    fn revoke_agent_keys(
        &self,
        name: &str,
        links: &[(std::sync::Arc<crate::node::LinkRt>, String)],
    ) {
        for (rt, public) in links {
            match rt.shared.revoke_agent(public) {
                Ok(true) => {
                    rt.shared.kick.notify_one();
                    tracing::info!(
                        "agent {name}: its key in link {} is revoked",
                        &rt.shared.link_id.to_hex()[..8]
                    );
                }
                Ok(false) => {}
                Err(e) => tracing::warn!(
                    "agent {name}: its key in link {} is not revoked at the contact: {}",
                    &rt.shared.link_id.to_hex()[..8],
                    e.message
                ),
            }
        }
    }

    /// `antenna agent tasks` (the caller has checked the password): whose messages the agent takes as tasks from the
    /// owner. `None`: the default, the contacts at trust level 5 (it follows trust changes); `[]`: nobody; a list:
    /// exactly these contacts, which must be within the agent's links. A link's wake agent is refused: its prompt is
    /// fixed and it takes every message as data (D-68).
    pub fn agent_tasks(&self, name: &str, contacts: Option<Vec<String>>) -> Result<AgentInfo> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        if db.wake_rules()?.iter().any(|(_, id, _, _)| *id == row.id) {
            return Err(Error::new(
                code::DENIED,
                format!(
                    "agent {name} replies on wake: its prompt is fixed and it takes every message as data"
                ),
            ));
        }
        let set = match contacts {
            None => None,
            Some(cs) => {
                let mut v: Vec<LinkId> = Vec::new();
                for c in &cs {
                    let l = db.find_link(c)?.link_id;
                    if row.links.as_ref().is_some_and(|s| !s.contains(&l)) {
                        return Err(Error::bad_request(format!(
                            "{c:?} is not among the links of agent {name}: it cannot take tasks from a contact it \
                             does not see"
                        )));
                    }
                    if !v.contains(&l) {
                        v.push(l);
                    }
                }
                Some(v)
            }
        };
        db.agent_set_tasks(row.id, set.as_deref())?;
        let row = db.agent(row.id)?;
        drop(db);
        tracing::info!(
            "agent {name}: takes tasks from {}",
            match &set {
                None => "contacts at trust level 5".to_string(),
                Some(v) => format!("{} contact(s)", v.len()),
            }
        );
        Ok(self.agent_info(&row, &self.link_names()?, &self.wake_agent_ids()))
    }

    // Who is on the other end of the socket

    /// Login by token. `chain` is the client and its ancestors (`/proc`, read right on connect; `None` if it could not
    /// be read). `bind_parent` binds the token to the client's parent, the MCP host (this is what `antenna mcp` does).
    /// A further MCP host of the same running app joins the agent (D-97, [`crate::app_hosts`]); any other process is
    /// refused. Anything that cannot be checked is a refusal, not a login.
    pub fn agent_login(
        &self,
        token: &str,
        chain: Option<&[ProcStat]>,
        bind_parent: bool,
    ) -> Result<AgentCtx> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db
            .agent_by_token(&token_hash(token))?
            .ok_or_else(|| Error::new(code::TOKEN_INVALID, "unknown or revoked agent token"))?;
        let ctx = AgentCtx {
            id: row.id,
            name: row.name.clone(),
            forced: false,
        };
        let hosts = self.live_hosts(&row);
        let Some(chain) = chain else {
            if !hosts.is_empty() || bind_parent {
                return Err(Error::new(
                    code::TOKEN_BOUND,
                    "cannot read the client's process chain; the token is not accepted",
                ));
            }
            return Ok(ctx); // An OS without process inspection (neither Linux nor macOS): uid only
        };
        // A process in the tree of another bound agent logs in only as that agent (no taint laundering). With nested
        // anchors the one closest to the client decides (D-P-10): our own anchor closer than a foreign one means the
        // process is ours
        let own = position(chain, &hosts);
        let nearest_other = db
            .agents()?
            .into_iter()
            .filter(|o| o.id != row.id)
            .filter_map(|o| Some((position(chain, &self.live_hosts(&o))?, o.name)))
            .min_by_key(|(pos, _)| *pos);
        if let Some((pos, name)) = nearest_other
            && own.is_none_or(|p| pos < p)
        {
            return Err(Error::new(
                code::TOKEN_BOUND,
                format!(
                    "this process belongs to agent {name:?}; only its own token is accepted here"
                ),
            ));
        }
        if bind_parent {
            let Some(parent) = chain.get(1) else {
                return Err(Error::new(
                    code::FORBIDDEN,
                    "the client has no parent process",
                ));
            };
            let cand = Anchor {
                pid: parent.pid,
                start: parent.start,
            };
            match hosts.first() {
                // The parent is a host of this agent, or the token is already bound to an ancestor of the client (the
                // wake launch sandbox, v0.2: an `antenna mcp` launched by the agent inside it): nothing to rebind
                Some(_) if own.is_some() => {}
                Some((bound, comm)) => {
                    // Another MCP host: accepted only as a process of the same running app (D-97)
                    match crate::app_hosts::same_app(chain, bound) {
                        Ok(app) => {
                            tracing::info!(
                                "agent {}: another MCP host of the same app: process {} ({}) under {} ({})",
                                row.name,
                                cand.pid,
                                parent.comm,
                                app.pid,
                                app.comm
                            );
                            self.app_hosts
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .add_host(row.id, cand, &parent.comm);
                            self.emit_agent(&row.name, "bound");
                        }
                        Err(why) => {
                            tracing::info!(
                                "agent {}: token refused for {} (bound to {} {}): {why}",
                                row.name,
                                crate::app_hosts::describe(chain),
                                bound.pid,
                                comm
                            );
                            self.note_refused(&row, parent);
                            return Err(Error::new(
                                code::TOKEN_BOUND,
                                format!(
                                    "this token is bound to another agent process ({comm:?}, pid {}), and this process \
                                     is not part of that app ({why}); one token = one agent: ask the owner for another \
                                     (`antenna agent add`)",
                                    bound.pid
                                ),
                            ));
                        }
                    }
                }
                None if !procinfo::valid_anchor(parent) => {
                    return Err(Error::new(
                        code::FORBIDDEN,
                        format!(
                            "cannot bind the token to {:?} (pid {}): `antenna mcp` must be started by the MCP host itself \
                             (not via a terminal, a session leader, systemd or the daemon's own ancestors)",
                            parent.comm, parent.pid
                        ),
                    ));
                }
                None => {
                    db.agent_set_anchor(row.id, Some((cand.pid, cand.start, &parent.comm)))?;
                    tracing::info!(
                        "agent {}: token bound to process {} ({})",
                        row.name,
                        cand.pid,
                        parent.comm
                    );
                    // The app connected: the owner's window shows it at once instead of on its next poll
                    self.emit_agent(&row.name, "bound");
                }
            }
            let mut app_hosts = self
                .app_hosts
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            app_hosts.accepted(row.id, &cand);
            if let Some(me) = chain.first() {
                app_hosts.note_client(
                    row.id,
                    Anchor {
                        pid: me.pid,
                        start: me.start,
                    },
                );
            }
        } else if let Some((a, _)) = hosts.first()
            && own.is_none()
        {
            return Err(Error::new(
                code::TOKEN_BOUND,
                format!(
                    "this token is bound to agent process {}; it is accepted only from that process tree",
                    a.pid
                ),
            ));
        }
        Ok(ctx)
    }

    /// The live MCP hosts of an agent: the one in the database first, then the further hosts of the same app (D-97).
    /// When the first one has exited, the others still hold the binding.
    pub(crate) fn live_hosts(&self, row: &AgentRow) -> Vec<(Anchor, String)> {
        let mut v: Vec<(Anchor, String)> = row
            .anchor
            .as_ref()
            .map(|(pid, start, comm)| {
                (
                    Anchor {
                        pid: *pid,
                        start: *start,
                    },
                    comm.clone(),
                )
            })
            .filter(|(a, _)| procinfo::is_alive(a))
            .into_iter()
            .collect();
        v.extend(
            self.app_hosts
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .hosts(row.id),
        );
        v
    }

    /// A process in the tree of a bound agent gets its role even if it claims to be the owner (D-28); with nested
    /// anchors, the role of the closest one (D-P-10). If the process chain could not be read while bound agents exist,
    /// it is a refusal (not the owner role).
    pub fn agent_for_process(&self, chain: Option<&[ProcStat]>) -> Result<Option<AgentCtx>> {
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agents()?;
        let live: Vec<(AgentRow, Vec<(Anchor, String)>)> = rows
            .into_iter()
            .filter_map(|r| {
                let h = self.live_hosts(&r);
                (!h.is_empty()).then_some((r, h))
            })
            .collect();
        if live.is_empty() {
            return Ok(None);
        }
        let Some(chain) = chain else {
            return Err(Error::new(
                code::FORBIDDEN,
                "cannot verify the client process while agents are bound to running hosts; retry",
            ));
        };
        // Nested anchors (an agent in the terminal of a bound GUI app): the process belongs to the agent whose anchor
        // is closer to it (D-P-10); otherwise taint and actions would go to another agent
        Ok(live
            .into_iter()
            .filter_map(|(r, h)| Some((position(chain, &h)?, r)))
            .min_by_key(|(pos, _)| *pos)
            .map(|(_, r)| AgentCtx {
                id: r.id,
                name: r.name,
                forced: true,
            }))
    }

    /// `agent_watch` (D-103, CONTROL §23): the window that started an agent may watch that agent's own facts without an
    /// owner session. Allowed only to a strict ancestor of a process the agent's token is bound to, and only when the
    /// client is not itself in any bound agent's tree; PID 1 and the service managers that adopt orphans never count.
    /// Fails closed: an unreadable process chain is a refusal.
    pub fn agent_watch(&self, name: &str, chain: Option<&[ProcStat]>) -> Result<AgentCtx> {
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent_by_name(name)?;
        let hosts = self.live_hosts(&row);
        if hosts.is_empty() {
            return Err(Error::new(
                code::FORBIDDEN,
                "the agent is not running: its token is not bound to a running process",
            ));
        }
        let Some(me) = chain.and_then(|c| c.first()) else {
            return Err(Error::new(
                code::FORBIDDEN,
                "cannot read the client process: only the app that started the agent may watch it",
            ));
        };
        if self.agent_for_process(chain)?.is_some() {
            return Err(Error::new(
                code::FORBIDDEN,
                "a process in an agent's tree cannot watch an agent",
            ));
        }
        if me.pid <= 1 || matches!(me.comm.as_str(), "systemd" | "launchd") {
            return Err(Error::new(
                code::FORBIDDEN,
                "not the app that started the agent",
            ));
        }
        let ancestor = hosts.iter().any(|(a, _)| {
            procinfo::ancestry(a.pid).is_some_and(|up| {
                up.iter()
                    .skip(1)
                    .any(|p| p.pid == me.pid && p.start == me.start)
            })
        });
        if !ancestor {
            return Err(Error::new(
                code::FORBIDDEN,
                "only the app that started the agent may watch it (an ancestor of its process)",
            ));
        }
        Ok(AgentCtx {
            id: row.id,
            name: row.name,
            forced: false,
        })
    }

    // Helpers

    /// An MCP host was refused this agent's token because the token is bound to another app (D-97): kept for the
    /// owner's `agent_list` and the doctor (D-96), and the owner's window hears of it at once (the refused app itself
    /// only says it could not start).
    fn note_refused(&self, row: &AgentRow, host: &ProcStat) {
        let tell = self
            .app_hosts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note_refused(
                row.id,
                Anchor {
                    pid: host.pid,
                    start: host.start,
                },
                &host.comm,
                now_ms(),
            );
        if tell {
            self.emit_agent(&row.name, "refused");
        }
    }

    /// Tell the owner's subscriptions that an agent changed (`added`, `token`, `bound`, `refused`, `removed`).
    pub(crate) fn emit_agent(&self, name: &str, change: &'static str) {
        let _ = self.events.send(NodeEvent::Agent {
            name: name.into(),
            change: change.into(),
            by: None,
        });
    }

    /// The agent's token file: `<data-dir>/agents/<name>.token`, absolute. Agent names are `[A-Za-z0-9._-]{1,64}`, so
    /// with the suffix the name is one plain component of that directory; `.` and `..` are refused anyway, and the
    /// result is checked to sit directly in the directory, in case the name rule ever loosens.
    fn token_file_path(&self, name: &str) -> Result<PathBuf> {
        valid_name(name)?;
        if matches!(name, "." | "..") {
            return Err(Error::bad_request(
                "agent name: `.` and `..` cannot name a token file",
            ));
        }
        let dir = std::path::absolute(self.cfg.data_dir.join(TOKEN_DIR))?;
        let p = dir.join(format!("{name}.token"));
        if p.parent() != Some(dir.as_path()) {
            return Err(Error::bad_request("agent name cannot name a token file"));
        }
        Ok(p)
    }

    /// Links whose messages this agent takes as tasks right now.
    fn agent_task_links(&self, ctx: &AgentCtx) -> Result<HashSet<LinkId>> {
        let row = self.agent_row(ctx)?;
        Ok(self.task_links(&row, &self.link_names()?, &self.wake_agent_ids()))
    }

    /// IDs of the links' dedicated wake agents.
    pub(crate) fn wake_agent_ids(&self) -> HashSet<i64> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .wake_rules()
            .map(|r| r.into_iter().map(|(_, id, _, _)| id).collect())
            .unwrap_or_default()
    }

    /// Links whose messages the agent takes as tasks right now (`agent_tasks`).
    fn task_links(
        &self,
        row: &AgentRow,
        names: &HashMap<LinkId, (String, u8)>,
        wake: &HashSet<i64>,
    ) -> HashSet<LinkId> {
        task_links(row, names, wake.contains(&row.id))
    }

    /// The owner's view of an agent: the session, plus what only the daemon knows (last request, token file, tasks)
    /// and, for the owner only, the last host refused the token (an agent's own `session` does not carry it).
    pub(crate) fn agent_info(
        &self,
        row: &AgentRow,
        names: &HashMap<LinkId, (String, u8)>,
        wake: &HashSet<i64>,
    ) -> AgentInfo {
        let mut session = self.session_view(row, names, wake);
        let refused = self
            .app_hosts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .refused(row.id);
        if let Some(r) = refused {
            session.refused_pid = u32::try_from(r.host.pid).ok();
            session.refused_comm = Some(r.comm);
            session.refused_ms = Some(r.at_ms);
            session.refused_alive = Some(procinfo::is_alive(&r.host));
        }
        AgentInfo {
            name: row.name.clone(),
            created_ms: row.created_ms,
            session,
            everyone: row.everyone,
            local_model: self.local_model_of(row.id),
        }
    }

    /// [`session_info`] with the last request time, the token file and the task contacts.
    fn session_view(
        &self,
        row: &AgentRow,
        names: &HashMap<LinkId, (String, u8)>,
        wake: &HashSet<i64>,
    ) -> SessionInfo {
        let mut s = session_info(row, names);
        s.last_seen_ms = self
            .agent_seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&row.id)
            .copied();
        s.token_file = self
            .token_file_path(&row.name)
            .ok()
            .filter(|p| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file()))
            .map(|p| p.to_string_lossy().into_owned());
        let mut tasks: Vec<String> = self
            .task_links(row, names, wake)
            .iter()
            .filter_map(|l| names.get(l).map(|(n, _)| n.clone()))
            .collect();
        tasks.sort();
        s.tasks_from = tasks;
        s.tasks_from_default = row.tasks_from.is_none();
        s.escalate_to = self.escalate_link(row.id).map(|l| {
            names
                .get(&l)
                .map(|(n, _)| n.clone())
                .unwrap_or_else(|| l.to_hex()[..8].to_string())
        });
        s.counterpart = self
            .local_counterpart_view(row)
            .or_else(|| self.counterpart_view(row));
        s.local_routes = self.local_routes_view(row);
        s.approves = self.approves_for(row);
        // D-97: when the first MCP host of the app has exited, the binding is held by another host of the same app.
        if s.bound_alive != Some(true)
            && let Some((a, comm)) = self.live_hosts(row).into_iter().next()
        {
            s.bound_to = Some(format!("{} {comm}", a.pid));
            s.bound_pid = u32::try_from(a.pid).ok();
            s.bound_comm = Some(comm);
            s.bound_alive = Some(true);
        }
        let n = self
            .app_hosts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .live_clients(row.id);
        s.mcp_processes = u32::try_from(n).ok().filter(|n| *n > 0);
        s
    }

    pub(crate) fn agent_row(&self, ctx: &AgentCtx) -> Result<AgentRow> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent(ctx.id)
    }

    /// Labels and levels of all links.
    pub(crate) fn link_names(&self) -> Result<HashMap<LinkId, (String, u8)>> {
        Ok(self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?
            .into_iter()
            .map(|r| (r.link_id, (r.label, r.trust)))
            .collect())
    }

    /// A link in the agent's scope. A foreign one is "not found" (the agent does not learn that other links exist).
    fn scoped(&self, agent: &AgentRow, contact: &str) -> Result<LinkRow> {
        let row = self.find_link(contact)?;
        if agent
            .links
            .as_ref()
            .is_some_and(|ls| !ls.contains(&row.link_id))
        {
            return Err(Error::new(
                code::NOT_FOUND,
                format!("no contact {contact:?}"),
            ));
        }
        Ok(row)
    }

    /// The same by link ID (a fresh row: the level may have changed).
    fn scoped_id(&self, agent: &AgentRow, link: &LinkId) -> Result<LinkRow> {
        if agent.links.as_ref().is_some_and(|ls| !ls.contains(link)) {
            return Err(Error::new(code::NOT_FOUND, "no such contact"));
        }
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(link)
    }

    fn ceiling(label: &Label, names: &HashMap<LinkId, (String, u8)>) -> Option<u8> {
        label.ceiling(|l| names.get(l).map(|(_, t)| *t))
    }

    /// The contact a tainted session's action relates to: the one with the lowest level.
    fn taint_source(
        &self,
        label: &Label,
        names: &HashMap<LinkId, (String, u8)>,
    ) -> Option<LinkRow> {
        let (l, _) = label
            .taint
            .iter()
            .map(|(l, at)| (l, names.get(l).map_or(*at, |(_, t)| (*t).min(*at))))
            .min_by_key(|(_, lvl)| *lvl)?;
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(l)
            .ok()
    }

    // Agent commands

    /// `list_contacts`.
    pub fn agent_contacts(&self, ctx: &AgentCtx) -> Result<Vec<AgentContact>> {
        let agent = self.agent_row(ctx)?;
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?;
        let links_dir = self.files().ok().map(|f| f.cfg.links_dir.clone());
        let folders = crate::files::folders(&rows, links_dir.as_deref());
        Ok(rows
            .into_iter()
            .zip(folders)
            .filter(|(r, _)| {
                agent
                    .links
                    .as_ref()
                    .is_none_or(|ls| ls.contains(&r.link_id))
            })
            .map(|(r, folder)| AgentContact {
                contact: r.label.clone(),
                link: r.link_id.to_hex()[..16].to_string(),
                trust: r.trust,
                rights: policy::rights(r.trust),
                presence: crate::events::presence(r.trust, self.is_connected(&r.link_id)).into(),
                folder: links_dir
                    .as_ref()
                    .map(|d| d.join(folder).to_string_lossy().into_owned()),
            })
            .collect())
    }

    /// `get_trust`.
    pub fn agent_trust(&self, ctx: &AgentCtx, contact: &str) -> Result<TrustInfo> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        let names = self.link_names()?;
        Ok(TrustInfo {
            contact: row.label.clone(),
            trust: row.trust,
            rights: policy::rights(row.trust),
            session_ceiling: Self::ceiling(&label_of(&agent), &names),
        })
    }

    /// `session`.
    pub fn agent_session(&self, ctx: &AgentCtx) -> Result<SessionInfo> {
        let agent = self.agent_row(ctx)?;
        Ok(self.session_view(&agent, &self.link_names()?, &self.wake_agent_ids()))
    }

    /// `mark_read`: the local data label only grows.
    pub fn agent_mark_read(&self, ctx: &AgentCtx, level: u8, what: &str) -> Result<SessionInfo> {
        if !(1..=5).contains(&level) {
            return Err(Error::bad_request("level must be 1..5"));
        }
        let what: String = what.chars().filter(|c| !c.is_control()).take(200).collect();
        // A file in a link folder (received from the contact or placed for it) is that link's data: taint at its
        // level, not "local data". The hook sends "<tool> <path>".
        let path = what.split_once(' ').map_or(what.as_str(), |(_, p)| p);
        if let Some(row) = self.link_of_path(path).or_else(|| self.link_of_path(&what)) {
            self.taint_link(ctx.id, &row.link_id, row.trust)?;
            return self.agent_session(ctx);
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let mut agent = db.agent(ctx.id)?;
            declare(&mut agent, level, what);
            db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
        }
        self.agent_session(ctx)
    }

    /// `send_message`: link isolation, no-write-down, secret scanner → approval; level limit → refusal. With
    /// `req.local`, or without a contact to a default counterpart of this computer: the local route (D-132).
    pub async fn agent_send(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        text: &str,
        wait: Duration,
        approval_id: Option<&str>,
        req: &AddrReq,
    ) -> Result<SentReply> {
        let agent = self.agent_row(ctx)?;
        let addressed = req.to.is_some()
            || req.to_agent.is_some()
            || req.topic.is_some()
            || req.topic_id.is_some();
        let local = match req.local.as_deref() {
            Some(l) if !contact.is_empty() || addressed || approval_id.is_some() => {
                return Err(Error::bad_request(format!(
                    "local {l:?} is an agent of this computer: no contact, to, to_agent, topic or approval_id with it"
                )));
            }
            Some(l) => Some(l.to_string()),
            None if contact.is_empty() => self.local_counterpart_name(&agent),
            None => None,
        };
        if let Some(peer) = local {
            if addressed {
                return Err(Error::bad_request(format!(
                    "your default counterpart is {peer:?}, an agent of this computer: to, to_agent and topic are for \
                     a contact"
                )));
            }
            return self.agent_send_local(ctx, &peer, text);
        }
        // Without a contact: the agent's default counterpart (CONTROL §30), its agent or person unless `to` is given
        let (row, addr) = if contact.is_empty() {
            let (row, peer) = self.counterpart_target(&agent)?;
            let row = self.scoped_id(&agent, &row.link_id)?;
            let addr = if req.to.is_none() && req.to_agent.is_none() {
                let to = AddrReq {
                    to: Some(if peer.is_some() { "agent" } else { "person" }.into()),
                    to_agent: peer,
                    ..req.clone()
                };
                self.agent_addr(ctx, &row, &to)?
            } else {
                self.agent_addr(ctx, &row, req)?
            };
            (row, addr)
        } else {
            let row = self.scoped(&agent, contact)?;
            let addr = self.agent_addr(ctx, &row, req)?;
            (row, addr)
        };
        let r = self
            .agent_send_row(ctx, &row, text, wait, approval_id, None, &addr)
            .await;
        // After approval the daemon sends exactly this, to the address resolved now (D-100)
        self.keep_for_approval(&r, || Continuation::Send {
            ctx: ctx.clone(),
            link: row.link_id,
            text: text.to_string(),
            wait,
            addr: addr.clone(),
        });
        r.map(|r| r.1)
    }

    /// The address and topic of an agent's message (v6, CONTROL §20). Without `to`, it is a reply: to whoever wrote
    /// the last message this agent read on the link with `inbox` (the contact's person or agent), continuing that
    /// message's topic; an agent that has read nothing there writes to its default counterpart when that is on this
    /// link (CONTROL §29), otherwise to the person.
    pub(crate) fn agent_addr(&self, ctx: &AgentCtx, row: &LinkRow, req: &AddrReq) -> Result<Addr> {
        let asked_to = req.parse_to()?;
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let asked_topic = req.resolve_topic(&db, &row.link_id)?;
        let answered = match db.agent_reply_to(ctx.id, &row.link_id)? {
            Some(id) => db.message_author_topic(&id)?,
            None => None,
        };
        let read_here = answered.is_some();
        let fallback = || match (!read_here)
            .then(|| crate::connections::counterpart(&db, ctx.id).ok().flatten())
            .flatten()
            .filter(|c| c.link == row.link_id)
        {
            Some(crate::connections::CounterpartRow { agent: Some(a), .. }) => {
                antenna_proto::To::Agent(a)
            }
            _ => antenna_proto::To::Person,
        };
        let to = match asked_to {
            Some(t) => t,
            None => match &answered {
                Some(crate::store::Answered {
                    incoming: true,
                    agent: Some(agent),
                    ..
                }) => antenna_proto::To::Agent(agent.clone()),
                _ => fallback(),
            },
        };
        let topic = match asked_topic {
            Some(t) => t,
            None => answered.and_then(|a| a.topic),
        };
        Ok(Addr {
            urgent: false,
            to: Some(to),
            topic,
        })
    }

    /// Approval reasons for sending from this session to contact `row` (link isolation, no-write-down, secrets in
    /// `text`). With empty text, what does not depend on the text (a streaming message decides by them whether to
    /// stream).
    pub(crate) fn agent_outflow_reasons(
        &self,
        ctx: &AgentCtx,
        row: &LinkRow,
        text: &str,
    ) -> Result<Vec<String>> {
        let agent = self.agent_row(ctx)?;
        let names = self.link_names()?;
        Ok(policy::outflow_reasons(
            &label_of(&agent),
            &row.link_id,
            row.trust,
            text,
            |l| {
                names
                    .get(l)
                    .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
            },
        ))
    }

    /// `send_message` on a link in the agent's scope; `salt` is the salt of a streaming message's final message (v0.2);
    /// `addr` the resolved address and topic (v6, [`Self::agent_addr`]).
    #[allow(
        clippy::too_many_arguments,
        reason = "the agent's `send_message` inputs plus the stream salt and the resolved address"
    )]
    pub(crate) async fn agent_send_row(
        &self,
        ctx: &AgentCtx,
        row: &LinkRow,
        text: &str,
        wait: Duration,
        approval_id: Option<&str>,
        salt: Option<[u8; 32]>,
        addr: &Addr,
    ) -> Result<(antenna_proto::MessageId, SentReply)> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped_id(&agent, &row.link_id)?;
        // Everything that can break the send after approval goes before approval: otherwise the approval is wasted
        crate::node::check_text(text)?;
        self.ensure_running(&row.link_id)?;
        let names = self.link_names()?;
        let label = label_of(&agent);
        let reasons = policy::outflow_reasons(&label, &row.link_id, row.trust, text, |l| {
            names
                .get(l)
                .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
        });
        // To the owner's own computer (level 5, D-99) a secret goes without approval; the audit log keeps it
        let reasons = self.waive_level_5(&row, row.trust, &agent.name, "send_message", reasons);
        let requester_id = format!("agent:{}", agent.id);
        let limit = policy::msgs_per_min(row.trust);
        // The slot in the limit is taken atomically before approval; if the send does not happen, it is returned
        let acquired = self
            .out_limits
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .try_acquire(row.link_id, limit, now_ms());
        if let Err(wait_ms) = acquired {
            if self.receipt_due(&row.link_id) {
                self.receipt(
                    &row.link_id,
                    &agent.name,
                    "send_message",
                    "rate_limited",
                    &format!("{limit}/min at trust {}", row.trust),
                    None,
                    None,
                );
            }
            return Err(Error::new(
                code::RATE_LIMITED,
                format!(
                    "trust {} allows {limit} messages per minute to this contact; retry in {} s",
                    row.trust,
                    wait_ms.div_ceil(1000)
                ),
            ));
        }
        let refund = || {
            self.out_limits
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .refund(row.link_id)
        };
        let mut used = None;
        if !reasons.is_empty() || approval_id.is_some() {
            let attributed = self
                .taint_source(&label, &names)
                .unwrap_or_else(|| row.clone());
            let req =
                Self::send_approval(&requester_id, &agent.name, &row, &attributed, reasons, text);
            used = match self
                .gate_pass(req, approval_id, &row.link_id, &agent.name)
                .await
            {
                Ok(Pass::Go(u)) => u,
                // The daemon already sent exactly this after the owner approved it (D-100): the same answer
                Ok(Pass::Done(o)) => {
                    refund();
                    return crate::approvals::replayed_sent(o);
                }
                Err(e) => {
                    refund();
                    return Err(e);
                }
            };
        }
        // The contact sees "owner / agent" (SPEC §5): the message is signed by the agent's key in this link
        // (PROTOCOL §21)
        let shown = self.agent_public_name(&agent.name, &row.link_id);
        let sent = self
            .send_body_as(
                &row,
                antenna_proto::MessageType::Text,
                antenna_proto::Body::Text(text.to_string()),
                wait,
                salt,
                Some(shown),
                addr,
            )
            .await;
        let (id, sent) = match sent {
            Ok(r) => r,
            Err(e) => {
                refund();
                return Err(e);
            }
        };
        self.receipt(
            &row.link_id,
            &agent.name,
            "send_message",
            if used.is_some() {
                "approved"
            } else {
                "allowed"
            },
            &format!("{} chars", text.chars().count()),
            Some(&id),
            used.as_deref(),
        );
        Ok((id, sent))
    }

    /// Agent name the contact sees (v5): the agent name, except for the link's dedicated wake agent with the default
    /// name `wake-<contact label>`, which is shown as `wake`: the label is the owner's local name for the contact, the
    /// contact has no reason to know it (SPEC §5 "names are set within a link").
    pub(crate) fn agent_public_name(&self, name: &str, link: &LinkId) -> String {
        if name.starts_with("wake-") {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let is_wake = db
                .wake_rule(link)
                .ok()
                .flatten()
                .and_then(|(id, _, _)| db.agent(id).ok())
                .is_some_and(|a| a.name == name);
            if is_wake {
                return "wake".into();
            }
        }
        name.to_string()
    }

    /// `read_inbox`: incoming messages on the agent's links (its own cursor), each in a wrapper; reading sets taint
    /// (SPEC §9, §11).
    pub async fn agent_inbox(
        &self,
        ctx: &AgentCtx,
        wait: bool,
        timeout: Option<Duration>,
        contact: Option<&str>,
    ) -> Result<AgentInboxReply> {
        let agent = self.agent_row(ctx)?;
        let only = contact
            .map(|c| self.scoped(&agent, c))
            .transpose()?
            .map(|r| r.link_id);
        let requester = format!("agent:{}", agent.id);
        let mut rx = self.inbox.subscribe();
        let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
        loop {
            if self.is_closed() {
                return Err(Error::new(code::LOCKED, "keystore was locked"));
            }
            rx.mark_unchanged();
            let more: bool;
            let names = self.link_names()?;
            let (rows, locals) = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                let mut agent = db.agent(ctx.id)?;
                let vis = Visibility::of(&db, &agent)?;
                let found = db.agent_unread_within(
                    &agent,
                    only.as_ref(),
                    100,
                    antenna_proto::control::AGENT_INBOX_CHARS,
                    &|r| vis.sees(r),
                )?;
                let rows = found.rows;
                // One transaction: the cursors, the local messages marked read and the label they taint (D-132: a
                // message is never read without its writer's taint)
                let tx = db.conn().unchecked_transaction()?;
                // Messages over a local route (D-132) after the link's, within what is left of the reply; not when
                // the agent asked for one contact
                let (locals, local_more) = if only.is_some() {
                    (Vec::new(), false)
                } else if found.more {
                    (Vec::new(), true)
                } else {
                    let used: usize = rows.iter().map(|r| r.body.chars().count()).sum();
                    crate::local_routes::take_unread(
                        &db,
                        &mut agent,
                        antenna_proto::control::AGENT_INBOX_CHARS.saturating_sub(used),
                        rows.is_empty(),
                        &names,
                        now_ms(),
                    )?
                };
                more = found.more || local_more;
                // Past messages it will never see (addressed to someone else): the cursor moves on, nothing is read
                if rows.is_empty() && !found.passed.is_empty() {
                    for (link, seq) in &found.passed {
                        db.agent_advance(agent.id, link, *seq)?;
                    }
                }
                if rows.is_empty() {
                    if !locals.is_empty() {
                        db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
                    }
                    tx.commit()?;
                } else {
                    let mut per_link: HashMap<LinkId, (i64, u8, usize)> = HashMap::new();
                    let mut read_ids: HashMap<LinkId, Vec<antenna_proto::MessageId>> =
                        HashMap::new();
                    for r in &rows {
                        let e = per_link.entry(r.link_id).or_insert((0, r.trust, 0));
                        e.0 = e.0.max(r.seq);
                        e.2 += 1;
                        read_ids.entry(r.link_id).or_default().push(r.id);
                    }
                    for (link, seq) in &found.passed {
                        db.agent_advance(agent.id, link, *seq)?;
                    }
                    // What the agent's next message answers by default (CONTROL §20): the last one it read
                    for r in &rows {
                        db.agent_set_reply_to(agent.id, &r.link_id, &r.id)?;
                    }
                    for (link, (_, trust, _)) in &per_link {
                        let hex = link_hex(link);
                        match agent.taint.iter_mut().find(|t| t.link == hex) {
                            Some(t) if t.ceiling => t.level = t.level.min(*trust),
                            Some(t) => {
                                t.ceiling = true;
                                t.level = *trust;
                            }
                            None => agent.taint.push(TaintEntry {
                                link: hex,
                                level: *trust,
                                at: now_ms(),
                                ceiling: true,
                            }),
                        }
                    }
                    db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
                    tx.commit()?;
                    drop(db);
                    for (link, (_, trust, n)) in &per_link {
                        self.receipt(
                            link,
                            &agent.name,
                            "read_inbox",
                            "allowed",
                            &format!("{n} message(s); session tainted at trust {trust}"),
                            None,
                            None,
                        );
                        // The contact sees in the shared history: the agent read its messages (SPEC §9, Q-16)
                        let ids = read_ids.remove(link).unwrap_or_default();
                        self.dag_receipt(link, &agent.name, "read_messages", "allowed", &ids);
                    }
                }
                (rows, locals)
            };
            // Decided approval requests of this agent and files saved for it also end the wait (D-100, CONTROL §14)
            if !rows.is_empty()
                || !locals.is_empty()
                || !wait
                || self.has_resolved(&requester)
                || self.has_escalation_answers(ctx.id)
                || self.has_to_answer(ctx.id)
                || self.has_file_notices(ctx.id)
            {
                // A saved file's name and path are the contact's data: the session is tainted with its link before
                // the reply carries them, as for a message
                let notices = self.take_file_notices(ctx.id);
                for n in &notices {
                    self.taint_link(ctx.id, &n.link, n.trust)?;
                }
                let files = notices.into_iter().map(|n| n.info).collect();
                let session = self.agent_session(ctx)?;
                let tasks = self.agent_task_links(ctx)?;
                return Ok(AgentInboxReply {
                    messages: rows
                        .into_iter()
                        .map(|r| {
                            // The owner's word makes a contact's messages tasks (`agent_tasks`); taint is the same
                            // either way: the text is still the contact's
                            let task = tasks.contains(&r.link_id);
                            let (to, to_agent) = addressing::to_view(r.to.as_ref());
                            AgentMessage {
                                id: r.id.to_hex(),
                                via_agent: r.agent,
                                trust: r.trust,
                                untrusted: true,
                                authority: if task { AUTHORITY_TASK } else { AUTHORITY_DATA }
                                    .into(),
                                notice: if task {
                                    task_notice(&r.label, r.trust)
                                } else {
                                    UNTRUSTED_NOTICE.into()
                                },
                                from: r.label,
                                text: r.body,
                                ts: r.ts,
                                received_ms: r.received_ms,
                                to,
                                to_agent,
                                topic: addressing::topic_view(r.topic.as_ref()),
                                local: None,
                            }
                        })
                        .chain(locals.into_iter().map(|m| {
                            AgentMessage {
                                id: m.id,
                                via_agent: None,
                                trust: m.trust,
                                untrusted: true,
                                authority: if m.task {
                                    AUTHORITY_TASK
                                } else {
                                    AUTHORITY_DATA
                                }
                                .into(),
                                notice: crate::local_routes::notice(&m.from, m.task),
                                from: m.from.clone(),
                                text: m.text,
                                ts: m.at_ms,
                                received_ms: m.at_ms,
                                to: Some("agent".into()),
                                to_agent: Some(agent.name.clone()),
                                topic: None,
                                local: Some(m.from),
                            }
                        }))
                        .collect(),
                    session,
                    approvals: self.take_resolved(&requester),
                    escalations: self.take_escalation_answers(ctx.id),
                    to_answer: self.take_to_answer(ctx.id),
                    more,
                    files,
                });
            }
            if !self.wait_changed(&mut rx, deadline).await {
                return Ok(AgentInboxReply {
                    messages: vec![],
                    session: self.agent_session(ctx)?,
                    approvals: self.take_resolved(&requester),
                    escalations: self.take_escalation_answers(ctx.id),
                    to_answer: self.take_to_answer(ctx.id),
                    more: false,
                    files: Vec::new(),
                });
            }
        }
    }

    /// Whether an incoming message (a history item of `link`, its address taken from the signed `core` on receipt) is
    /// visible to the agent (v6, CONTROL §20): its subscription gets facts only about those.
    pub(crate) fn agent_sees_item(
        &self,
        ctx: &AgentCtx,
        link: &LinkId,
        item: &antenna_proto::control::HistoryItem,
    ) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let Ok(agent) = db.agent(ctx.id) else {
            return false;
        };
        let Ok(vis) = Visibility::of(&db, &agent) else {
            return false;
        };
        let to = item
            .to
            .as_deref()
            .and_then(|k| antenna_proto::To::from_parts(k, item.to_agent.as_deref()));
        vis.sees_to(link, to.as_ref())
    }

    /// The text messages the agent may read and has not read yet (at most `limit`, oldest first), for the facts
    /// `agent_watch` sends right after it subscribes (D-108): a session or a restored window that starts watching
    /// while messages already wait still wakes its agent. Nothing is consumed: the agent's read cursor and its
    /// decided approvals stay as they are.
    pub fn agent_unread_rows(
        &self,
        ctx: &AgentCtx,
        limit: usize,
    ) -> Result<Vec<crate::store::InboxRow>> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let agent = db.agent(ctx.id)?;
        let vis = Visibility::of(&db, &agent)?;
        let rows = db.agent_unread(&agent, None, limit, &|r| vis.sees(r))?.rows;
        Ok(rows.into_iter().filter(|r| r.kind == "text").collect())
    }

    /// `wait_for_message`: facts only (who, level, length): the text does not enter the context, no taint is set.
    /// The owner's decisions on this agent's approval requests end the wait too and come with it (D-100).
    pub async fn agent_wait(
        &self,
        ctx: &AgentCtx,
        timeout: Option<Duration>,
        contact: Option<&str>,
    ) -> Result<(Vec<MessageFact>, Vec<ApprovalResolution>)> {
        let agent = self.agent_row(ctx)?;
        let only = contact
            .map(|c| self.scoped(&agent, c))
            .transpose()?
            .map(|r| r.link_id);
        let requester = format!("agent:{}", agent.id);
        let mut rx = self.inbox.subscribe();
        let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
        loop {
            if self.is_closed() {
                return Err(Error::new(code::LOCKED, "keystore was locked"));
            }
            rx.mark_unchanged();
            let rows = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                let agent = db.agent(ctx.id)?;
                let vis = Visibility::of(&db, &agent)?;
                db.agent_unread(&agent, only.as_ref(), 100, &|r| vis.sees(r))?
                    .rows
            };
            // Messages over a local route (D-132): facts too, not when the agent waits for one contact
            let locals = if only.is_none() {
                self.local_facts(ctx.id)
            } else {
                Vec::new()
            };
            if !rows.is_empty()
                || !locals.is_empty()
                || self.has_resolved(&requester)
                || self.has_team_facts(ctx.id)
                || self.has_escalation_answers(ctx.id)
                || self.has_to_answer(ctx.id)
                || self.has_file_notices(ctx.id)
            {
                let tasks = self.agent_task_links(ctx)?;
                let facts = rows
                    .into_iter()
                    .map(|r| MessageFact {
                        authority: if tasks.contains(&r.link_id) {
                            AUTHORITY_TASK
                        } else {
                            AUTHORITY_DATA
                        }
                        .into(),
                        from: r.label,
                        trust: r.trust,
                        chars: r.body.chars().count() as u64,
                        received_ms: r.received_ms,
                        local: None,
                    })
                    .chain(locals.into_iter().map(|f| {
                        MessageFact {
                            authority: if f.task {
                                AUTHORITY_TASK
                            } else {
                                AUTHORITY_DATA
                            }
                            .into(),
                            from: f.from.clone(),
                            trust: f.trust,
                            chars: f.chars,
                            received_ms: f.at_ms,
                            local: Some(f.from),
                        }
                    }))
                    .collect();
                return Ok((facts, self.take_resolved(&requester)));
            }
            if !self.wait_changed(&mut rx, deadline).await {
                return Ok((vec![], self.take_resolved(&requester)));
            }
        }
    }

    /// `check`: whether an action of class `action` is allowed under the session ceiling (for agent hooks).
    pub fn agent_check(&self, ctx: &AgentCtx, action: &str, detail: &str) -> Result<CheckReply> {
        let action = Action::parse(action)?;
        let agent = self.agent_row(ctx)?;
        let names = self.link_names()?;
        let label = label_of(&agent);
        let ceiling = Self::ceiling(&label, &names);
        let mut source = self.taint_source(&label, &names);
        // The link folder per the daemon setting (`--links-dir`); writing to the folder of link X passes data to X:
        // flow from other links and no-write-down go through approval, as with `send`
        let target = if self.files.is_some() {
            self.link_of_path(detail)
        } else {
            None
        };
        let in_links = match &self.files {
            Some(f) => crate::files::folder_in_links(&f.cfg.links_dir, detail).is_some(),
            None => policy::in_link_folder(detail),
        };
        // A team's worker (D-111): its template and its own folder first, then the ceiling as for any agent.
        let mut verdict = match self.team_check(agent.id, action, detail, ceiling) {
            Some(v) => v,
            None => policy::check_action_at(ceiling, action, detail, in_links),
        };
        if action == Action::Write
            && let Some(t) = &target
        {
            let out = policy::outflow_reasons(&label, &t.link_id, t.trust, "", |l| {
                names
                    .get(l)
                    .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
            });
            if !out.is_empty() {
                verdict = match verdict {
                    Verdict::Deny(r) => Verdict::Deny(r),
                    Verdict::Approve(mut r) => {
                        r.extend(out);
                        Verdict::Approve(r)
                    }
                    Verdict::Allow => Verdict::Approve(out),
                };
                if source.is_none() {
                    source = Some(t.clone());
                }
            }
        }
        let log = |decision: &str, reason: &str, approval: Option<&str>| {
            if let Some(src) = &source {
                let what = format!("check:{}", action.as_str());
                self.receipt(
                    &src.link_id,
                    &agent.name,
                    &what,
                    decision,
                    reason,
                    None,
                    approval,
                );
                // An action at the contact's request (its data is in the session): a receipt in the shared history,
                // without details
                self.dag_receipt(&src.link_id, &agent.name, &what, decision, &[]);
            }
        };
        match verdict {
            Verdict::Allow => {
                // Level 5, the owner's own computer (D-99): commands and writes run without confirmation, and each
                // one goes into the audit log of the contact whose task it is
                if ceiling.is_some_and(|l| l >= policy::OWN_COMPUTER)
                    && (action == Action::Exec || (action == Action::Write && !in_links))
                    && let Some(src) = &source
                {
                    self.receipt(
                        &src.link_id,
                        &agent.name,
                        &format!("check:{}", action.as_str()),
                        crate::approvals::ALLOWED_AT_5,
                        &audit_detail(detail),
                        None,
                        None,
                    );
                }
                Ok(CheckReply {
                    action: action.as_str().into(),
                    decision: "allow".into(),
                    reason: match ceiling {
                        None => "session has not read any contact's data".into(),
                        Some(l) if l >= policy::OWN_COMPUTER => format!(
                            "allowed at session ceiling {l}: the owner's own computer, no confirmation"
                        ),
                        Some(l) => format!("allowed at session ceiling {l}"),
                    },
                })
            }
            Verdict::Deny(r) => {
                log("denied", &r, None);
                Err(Error::new(
                    code::DENIED,
                    format!(
                        "{} is not allowed: {r} (the session read data of a contact with trust {}; \
                         only the owner can start a clean session: `antenna agent reset`)",
                        action.as_str(),
                        ceiling.unwrap_or(0)
                    ),
                ))
            }
            Verdict::Approve(reasons) => {
                let src = source
                    .clone()
                    .ok_or_else(|| Error::internal("tainted session without source"))?;
                let requester_id = format!("agent:{}", agent.id);
                let what = format!("check:{}", action.as_str());
                let req = policy::NewApproval {
                    requester_id: requester_id.clone(),
                    requester: agent.name.clone(),
                    contact: src.link_id,
                    contact_label: src.label.clone(),
                    contact_trust: src.trust,
                    action: what.clone(),
                    target: None,
                    target_link: None,
                    reasons,
                    grants: grants_for(action),
                    quote: detail.chars().take(2000).collect(),
                    request_hash: policy::request_hash(
                        &requester_id,
                        &what,
                        None,
                        detail.as_bytes(),
                    ),
                    // The agent's host runs the action, not the daemon: after approval the agent's next check passes
                    completes: false,
                };
                let used = self.gate(req, None, &src.link_id, &agent.name)?;
                log("approved", "owner approved", used.as_deref());
                Ok(CheckReply {
                    action: action.as_str().into(),
                    decision: "allow".into(),
                    reason: format!("approved by the owner ({})", used.unwrap_or_default()),
                })
            }
        }
    }

    /// Reading contact data by an agent session (files: names, previews, receiving): taint at the contact's level and
    /// the link marked as "read", as with `inbox` (SPEC §9 "receiving sets taint", SPEC §11).
    pub(crate) fn taint_link(&self, agent_id: i64, link: &LinkId, trust: u8) -> Result<()> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut agent = db.agent(agent_id)?;
        let hex = link_hex(link);
        match agent.taint.iter_mut().find(|t| t.link == hex) {
            Some(t) if t.ceiling => t.level = t.level.min(trust),
            Some(t) => {
                t.ceiling = true;
                t.level = trust;
            }
            None => agent.taint.push(TaintEntry {
                link: hex,
                level: trust,
                at: now_ms(),
                ceiling: true,
            }),
        }
        db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
        Ok(())
    }

    /// The level part of an agent's file sending policy: level 1 is `denied` (with receipts in the audit log and the
    /// shared history), level 2 and the session ceiling give approval reasons.
    fn agent_share_level(&self, agent: &AgentRow, row: &LinkRow) -> Result<Vec<String>> {
        let names = self.link_names()?;
        let ceiling = Self::ceiling(&label_of(agent), &names);
        match policy::share_file(ceiling, row.trust) {
            Verdict::Deny(r) => {
                self.receipt(
                    &row.link_id,
                    &agent.name,
                    "share_file",
                    "denied",
                    &r,
                    None,
                    None,
                );
                self.dag_receipt(&row.link_id, &agent.name, "share_file", "denied", &[]);
                Err(Error::new(
                    code::DENIED,
                    format!("share_file is not allowed: {r}"),
                ))
            }
            Verdict::Approve(r) => Ok(r),
            Verdict::Allow => Ok(vec![]),
        }
    }

    /// An agent's `share_file`: level (1: no, 2: approval), taint ceiling, flow between links, no-write-down, a file
    /// outside the link folder, secrets and threats in the sender-side check: owner approval.
    pub async fn agent_share_file(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        path: &str,
        name: Option<&str>,
        approval_id: Option<&str>,
        addr: &Addr,
    ) -> Result<FileInfo> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        // The level comes first: for a contact the agent may not send files to, nothing is read from disk
        self.agent_share_level(&agent, &row)?;
        let f = self.files()?.clone();
        let (file, canon, default_name) = crate::files::open_for_share(&f, path)?;
        let folder = f.cfg.links_dir.join(self.folder_for(&row));
        let folder = std::fs::canonicalize(&folder).unwrap_or(folder);
        let mut reasons = Vec::new();
        if !canon.starts_with(&folder) {
            reasons.push("file_outside_link_folder".into());
        }
        let asked_name = name;
        let name = name.map(str::to_string).unwrap_or(default_name);
        let canon = canon.to_string_lossy();
        let r = self
            .agent_share_open(
                ctx,
                &row.link_id,
                file,
                ShareSource::Path(&canon),
                &name,
                reasons,
                approval_id,
                addr,
            )
            .await;
        // After approval the daemon reads the file again and sends it if it still hashes the same (D-100)
        self.keep_for_approval(&r, || Continuation::ShareFile {
            ctx: ctx.clone(),
            contact: row.link_id.to_hex(),
            path: path.to_string(),
            name: asked_name.map(str::to_string),
            addr: addr.clone(),
        });
        r
    }

    /// An agent's `share_file_content` before the bytes arrive: the command is on, `size` is within the node's limit,
    /// the contact is in the agent's scope, the level allows files, the name is a valid file name, the link runs.
    /// Refusing here costs the agent no upload. Returns the contact's link and an empty staging file.
    pub(crate) fn agent_share_content_begin(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        name: &str,
        size: u64,
    ) -> Result<(LinkId, std::fs::File)> {
        const MIB: u64 = 1024 * 1024;
        let limit = self.cfg.share_content_max;
        if limit == 0 {
            return Err(Error::new(
                code::FORBIDDEN,
                "sending files by content is turned off on this node (antennad --share-content-max-mib 0); \
                 share_file with a local file still works",
            ));
        }
        if size > limit {
            return Err(Error::new(
                code::TOO_LARGE,
                format!(
                    "{size} bytes is over this node's limit for share_file_content: {} MiB ({limit} bytes); the \
                     owner sets it with antennad --share-content-max-mib",
                    limit / MIB
                ),
            ));
        }
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        self.agent_share_level(&agent, &row)?;
        antenna_files::names::normalize(name)?;
        let f = self.files()?;
        self.ensure_running(&row.link_id)?;
        let file = crate::files::stage_outgoing(f.data_dir(), &row.link_id)?;
        Ok((row.link_id, file))
    }

    /// An agent's `share_file_content` once all the bytes are in the staging file: the same pipeline and policy as
    /// `share_file` (level, ceiling, cross-link flow and no-write-down on the name, secrets and threats from the
    /// sender-side check, approval, receipts). The one difference is that there is no "file outside the link folder"
    /// reason: the bytes are the agent's own output, which it hands over by value like the text of `send`, not a file
    /// it picked from the owner's disk; whatever it read to produce them is covered by its session label, as for
    /// `send`.
    pub(crate) async fn agent_share_content_finish(
        &self,
        ctx: &AgentCtx,
        link: &LinkId,
        file: std::fs::File,
        name: &str,
        approval_id: Option<&str>,
        addr: &Addr,
    ) -> Result<FileInfo> {
        // The staging file has no name on disk: if the owner has to approve, the daemon keeps it open and sends exactly
        // these bytes after the approval (D-100); a refusal or expiry closes it and nothing stays on disk
        let kept = file.try_clone()?;
        let r = self
            .agent_share_open(
                ctx,
                link,
                file,
                ShareSource::Content,
                name,
                Vec::new(),
                approval_id,
                addr,
            )
            .await;
        self.keep_for_approval(&r, || Continuation::ShareContent {
            ctx: ctx.clone(),
            link: *link,
            file: kept,
            name: name.to_string(),
            addr: addr.clone(),
        });
        r
    }

    /// The common part of an agent's `share_file` and `share_file_content` on an open file: the level and the session
    /// label again (they may have changed meanwhile), the name through the outflow checks (it goes to the contact in
    /// plain text in the manifest), the sender-side check and encryption, then approval and sending.
    #[allow(
        clippy::too_many_arguments,
        reason = "shared by `share_file` and `share_file_content`: the open file, its source and the checks gathered so far"
    )]
    async fn agent_share_open(
        &self,
        ctx: &AgentCtx,
        link: &LinkId,
        file: std::fs::File,
        source: ShareSource<'_>,
        name: &str,
        mut reasons: Vec<String>,
        approval_id: Option<&str>,
        addr: &Addr,
    ) -> Result<FileInfo> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped_id(&agent, link)?;
        reasons.extend(self.agent_share_level(&agent, &row)?);
        let names = self.link_names()?;
        let label = label_of(&agent);
        // The name goes to the contact in plain text in the manifest: the same scanner as for `send`
        reasons.extend(policy::outflow_reasons(
            &label,
            &row.link_id,
            row.trust,
            name,
            |l| {
                names
                    .get(l)
                    .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
            },
        ));
        let content = matches!(source, ShareSource::Content);
        let mut out = self.prepare_outgoing(&row, file, name).await?;
        out.agent = Some(agent.name.clone());
        reasons.extend(Self::outgoing_reasons(&out, row.trust));
        reasons.sort();
        reasons.dedup();
        // To the owner's own computer (level 5, D-99): secrets, a file from outside the link folder and the
        // sender-side verdict wait for nobody; the audit log keeps what was found
        let reasons = self.waive_level_5(&row, row.trust, &agent.name, "share_file", reasons);
        let mut used = None;
        if !reasons.is_empty() || approval_id.is_some() {
            let requester_id = format!("agent:{}", agent.id);
            let attributed = self
                .taint_source(&label, &names)
                .unwrap_or_else(|| row.clone());
            let m = &out.prepared.manifest;
            let req = crate::files::share_approval(
                &requester_id,
                &agent.name,
                &row,
                &attributed,
                reasons,
                source,
                &m.name,
                m.size,
                &m.blake3,
            );
            used = match self
                .gate_pass(req, approval_id, &row.link_id, &agent.name)
                .await
            {
                Ok(Pass::Go(u)) => u,
                // The daemon already sent exactly this file after the owner approved it (D-100): the same answer
                Ok(Pass::Done(o)) => {
                    let _ = out.store.blobs.forget_outgoing(out.prepared.blob).await;
                    return crate::approvals::replayed_file(o);
                }
                Err(e) => {
                    let _ = out.store.blobs.forget_outgoing(out.prepared.blob).await;
                    return Err(e);
                }
            };
        }
        let info = self.send_outgoing(&row, out, addr).await?;
        self.receipt(
            &row.link_id,
            &agent.name,
            "share_file",
            if used.is_some() {
                "approved"
            } else {
                "allowed"
            },
            &format!(
                "{} bytes{}",
                info.size,
                if content {
                    ", content from the agent"
                } else {
                    ""
                }
            ),
            None,
            used.as_deref(),
        );
        Ok(info)
    }

    /// An agent's `request_file`: from level 3 (SPEC §9 "read-only to shared/"), session ceiling; the path is text that
    /// goes to the contact, so flow, no-write-down and secrets in it go through approval, as with `send`.
    pub async fn agent_request_file(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        path: &str,
    ) -> Result<(String, String, String)> {
        let r = self.agent_request_file_as(ctx, contact, path, None).await;
        // After approval the daemon sends exactly this request (D-100)
        self.keep_for_approval(&r, || Continuation::RequestFile {
            ctx: ctx.clone(),
            contact: self
                .agent_link(ctx, contact)
                .map_or_else(|_| contact.to_string(), |r| r.link_id.to_hex()),
            path: path.to_string(),
        });
        r
    }

    /// [`Self::agent_request_file`] under approval `approval_id` (the daemon's own run after the owner approved it).
    pub(crate) async fn agent_request_file_as(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        path: &str,
        approval_id: Option<&str>,
    ) -> Result<(String, String, String)> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        let names = self.link_names()?;
        let label = label_of(&agent);
        let ceiling = Self::ceiling(&label, &names);
        let mut reasons = match policy::request_file(ceiling, row.trust) {
            Verdict::Deny(r) => {
                self.receipt(
                    &row.link_id,
                    &agent.name,
                    "request_file",
                    "denied",
                    &r,
                    None,
                    None,
                );
                self.dag_receipt(&row.link_id, &agent.name, "request_file", "denied", &[]);
                return Err(Error::new(
                    code::DENIED,
                    format!("request_file is not allowed: {r}"),
                ));
            }
            Verdict::Approve(r) => r,
            Verdict::Allow => vec![],
        };
        reasons.extend(policy::outflow_reasons(
            &label,
            &row.link_id,
            row.trust,
            path,
            |l| {
                names
                    .get(l)
                    .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
            },
        ));
        // A secret in the path to the owner's own computer (level 5, D-99) waits for nobody; the audit log keeps it
        let reasons = self.waive_level_5(&row, row.trust, &agent.name, "request_file", reasons);
        let mut used = None;
        if !reasons.is_empty() || approval_id.is_some() {
            let requester_id = format!("agent:{}", agent.id);
            let src = self
                .taint_source(&label, &names)
                .unwrap_or_else(|| row.clone());
            let req = crate::files::request_approval(
                &requester_id,
                &agent.name,
                &row,
                &src,
                reasons,
                path,
            );
            used = match self
                .gate_pass(req, approval_id, &src.link_id, &agent.name)
                .await?
            {
                Pass::Go(u) => u,
                // The daemon already sent exactly this request after the owner approved it (D-100)
                Pass::Done(o) => return crate::approvals::replayed_request(o),
            };
        }
        let public = self.agent_public_name(&agent.name, &row.link_id);
        let (id, status) = self.send_file_request(&row, path, Some(public)).await?;
        self.receipt(
            &row.link_id,
            &agent.name,
            "request_file",
            if used.is_some() {
                "approved"
            } else {
                "allowed"
            },
            "",
            None,
            used.as_deref(),
        );
        Ok((row.label, id, status))
    }

    /// Whether agent `agent` may see the offer with this message (hex) on `link` (PG-19): by the address in the
    /// offer's signed `core`. An offer whose message cannot be read is not shown (could not verify = refuse); an item
    /// without a message (none are made today) is seen as before.
    pub(crate) fn agent_row_sees_offer(
        &self,
        agent: &AgentRow,
        link: &LinkId,
        message_id: Option<&str>,
    ) -> bool {
        let Some(hex) = message_id else {
            return true;
        };
        let Some(id) = data_encoding::HEXLOWER
            .decode(hex.as_bytes())
            .ok()
            .and_then(|v| <[u8; 32]>::try_from(v).ok())
        else {
            return false;
        };
        let Ok(to) = self.offer_to(link, &id) else {
            return false;
        };
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        Visibility::of(&db, agent).is_ok_and(|v| v.sees_offer(link, to.as_ref()))
    }

    /// The same for an agent's own event subscription.
    pub(crate) fn agent_sees_offer(
        &self,
        ctx: &AgentCtx,
        link: &LinkId,
        message_id: Option<&str>,
    ) -> bool {
        self.agent_row(ctx)
            .is_ok_and(|a| self.agent_row_sees_offer(&a, link, message_id))
    }

    /// A file in quarantine on the agent's links that the agent may see; another agent's offer is `not_found`, the
    /// same as no file at all.
    fn agent_find_file(
        &self,
        agent: &AgentRow,
        id: &str,
    ) -> Result<(antenna_files::quarantine::Item, crate::store::LinkRow)> {
        let (item, row) = self.find_file(id, agent.links.as_deref())?;
        let mid = item.message_id.map(|m| data_encoding::HEXLOWER.encode(&m));
        if !self.agent_row_sees_offer(agent, &row.link_id, mid.as_deref()) {
            return Err(Error::new(code::NOT_FOUND, "no such file in quarantine"));
        }
        Ok((item, row))
    }

    /// An agent's `files_pending`: only its links; names are contact data, so reading sets taint. With `all` (v7), the
    /// files already saved too, with where they are.
    pub fn agent_files_pending(
        &self,
        ctx: &AgentCtx,
        contact: Option<&str>,
        all: bool,
    ) -> Result<Vec<antenna_proto::control::FileInfo>> {
        let agent = self.agent_row(ctx)?;
        let only = contact
            .map(|c| self.scoped(&agent, c))
            .transpose()?
            .map(|r| r.link_id);
        let list: Vec<_> = self
            .files_list(agent.links.as_deref(), only.as_ref(), all)?
            .into_iter()
            .filter(|(i, link, _)| self.agent_row_sees_offer(&agent, link, i.message_id.as_deref()))
            .collect();
        let mut tainted: Vec<LinkId> = Vec::new();
        for (_, link, trust) in &list {
            if !tainted.contains(link) {
                self.taint_link(agent.id, link, *trust)?;
                tainted.push(*link);
            }
        }
        Ok(list.into_iter().map(|(i, _, _)| i).collect())
    }

    /// An agent's `file_preview`: a safe preview (sets taint, SPEC §10 "the agent reads the whole preview").
    pub fn agent_file_preview(
        &self,
        ctx: &AgentCtx,
        id: &str,
    ) -> Result<(
        antenna_proto::control::FileInfo,
        Option<antenna_proto::control::FilePreviewView>,
    )> {
        let agent = self.agent_row(ctx)?;
        let (item, row) = self.agent_find_file(&agent, id)?;
        self.taint_link(agent.id, &row.link_id, row.trust)?;
        let preview = self.preview_of(&item)?.map(|mut p| {
            p.notice = Some(antenna_proto::control::UNTRUSTED_NOTICE.into());
            p
        });
        self.receipt(
            &row.link_id,
            &agent.name,
            "read_file",
            "allowed",
            "preview",
            None,
            None,
        );
        Ok((crate::files::info_of(&item, &row.label), preview))
    }

    /// An agent's `file_accept` (SPEC §10 item 5): level 2, "suspicious" and special names need owner approval (not at
    /// level 5, D-99); a threat or an unchecked file is for the owner only, with `--force`. Accepting sets taint.
    pub async fn agent_file_accept(
        &self,
        ctx: &AgentCtx,
        id: &str,
        name: Option<&str>,
        approval_id: Option<&str>,
    ) -> Result<antenna_proto::control::FileInfo> {
        let r = self.agent_file_accept_as(ctx, id, name, approval_id).await;
        // After approval the daemon accepts exactly this file under exactly this name (D-100)
        self.keep_for_approval(&r, || Continuation::FileAccept {
            ctx: ctx.clone(),
            id: id.to_string(),
            name: name.map(str::to_string),
        });
        r
    }

    async fn agent_file_accept_as(
        &self,
        ctx: &AgentCtx,
        id: &str,
        name: Option<&str>,
        approval_id: Option<&str>,
    ) -> Result<antenna_proto::control::FileInfo> {
        let agent = self.agent_row(ctx)?;
        let (item, row) = self.agent_find_file(&agent, id)?;
        // A repeat of an accept the daemon carried out after the owner approved it (D-100) gets the same answer, with
        // or without the approval's ID; it is checked first, because by now the file is accepted
        if let Ok(target) = antenna_files::names::normalize(name.unwrap_or(&item.manifest.name)) {
            let requester_id = format!("agent:{}", agent.id);
            let detail = format!("{}\u{0}{}", item.id, target);
            let hash = policy::request_hash(
                &requester_id,
                "accept_file",
                Some(&row.link_id),
                detail.as_bytes(),
            );
            if let Some(o) = self.replay_of(approval_id, &requester_id, &hash).await? {
                return crate::approvals::replayed_file(o);
            }
        }
        let level = row.trust.min(item.level_at_offer);
        if level <= 1 {
            return Err(Error::new(code::DENIED, "trust level 1 exchanges no files"));
        }
        // The approval request and the reply carry the file name, which is contact data: taint before them
        self.taint_link(agent.id, &row.link_id, row.trust)?;
        let allow = self.file_allow(&row.link_id);
        // From level 3 heuristics are labels; what the rules hold (a program, an installer, a signature) is the
        // owner's to keep anyway (D-130)
        let held = item
            .report
            .as_ref()
            .and_then(|r| antenna_files::kinds::hold(r, &item.manifest.name, level, &allow));
        let verdict = match (&item.state, &item.report) {
            (antenna_files::quarantine::State::Checked, Some(r)) => {
                antenna_files::kinds::effective_verdict(r, &item.manifest.name, level, &allow)
            }
            (antenna_files::quarantine::State::Accepted { .. }, _) => {
                return Err(Error::new(
                    antenna_files::error::code::BAD_STATE,
                    "already accepted",
                ));
            }
            _ => {
                return Err(Error::new(
                    antenna_files::error::code::BAD_STATE,
                    "the file is not checked yet: wait for the check (files_pending)",
                ));
            }
        };
        if matches!(
            verdict,
            antenna_files::report::Verdict::Threat | antenna_files::report::Verdict::Failed
        ) {
            self.receipt(
                &row.link_id,
                &agent.name,
                "accept_file",
                "denied",
                verdict.as_str(),
                None,
                None,
            );
            return Err(Error::new(
                code::FORBIDDEN,
                match &held {
                    Some(h) => format!(
                        "held for the owner: {} ({}); only the owner can keep it, with --force and password",
                        h.why,
                        h.rules.join(", ")
                    ),
                    None => format!(
                        "check verdict is {}: only the owner can accept it, with --force and password",
                        verdict.as_str()
                    ),
                },
            ));
        }
        let target = antenna_files::names::normalize(name.unwrap_or(&item.manifest.name))?;
        let mut reasons = Vec::new();
        if level == 2 {
            reasons.push("trust_2:files_are_accepted_by_the_owner".to_string());
        }
        if verdict == antenna_files::report::Verdict::Suspicious {
            reasons.push("check:suspicious".into());
        }
        if antenna_files::names::is_special(&target) {
            reasons.push("special_name:dot_file_or_auto_executed".into());
        }
        // From the owner's own computer (level 5, D-99) a suspicious verdict or a dot-file name waits for nobody; a
        // threat never gets here
        let asked = reasons.len();
        let reasons = self.waive_level_5(&row, level, &agent.name, "accept_file", reasons);
        let waived = reasons.len() < asked;
        let project = self.files()?.cfg.project_dir.is_some();
        let dest = antenna_files::policy::level_files(level, None)
            .map(|r| match r.dest {
                antenna_files::policy::Destination::Inbox => "inbox",
                antenna_files::policy::Destination::Shared => "shared",
                antenna_files::policy::Destination::Project if project => "project",
                // Level 5 without a project folder saves into `shared/` (D-99)
                antenna_files::policy::Destination::Project => "shared",
            })
            .unwrap_or("inbox");
        let mut used = None;
        if !reasons.is_empty() || approval_id.is_some() {
            let requester_id = format!("agent:{}", agent.id);
            let detail = format!("{}\u{0}{}", item.id, target);
            let req = policy::NewApproval {
                requester_id: requester_id.clone(),
                requester: agent.name.clone(),
                contact: row.link_id,
                contact_label: row.label.clone(),
                contact_trust: row.trust,
                action: "accept_file".into(),
                target: None,
                target_link: None,
                reasons,
                grants: Grants {
                    read: "none".into(),
                    write: format!(
                        "save {} ({} bytes, check: {}) into {dest}/ of {}",
                        antenna_files::text::escape_visible(&target, 200),
                        item.manifest.size,
                        verdict.as_str(),
                        row.label
                    ),
                    commands: "none".into(),
                    send: "none".into(),
                },
                quote: antenna_files::text::escape_visible(&item.manifest.name, 300),
                request_hash: policy::request_hash(
                    &requester_id,
                    "accept_file",
                    Some(&row.link_id),
                    detail.as_bytes(),
                ),
                // After approval the daemon accepts the file itself (D-100)
                completes: true,
            };
            used = match self
                .gate_pass(req, approval_id, &row.link_id, &agent.name)
                .await?
            {
                Pass::Go(u) => u,
                Pass::Done(o) => return crate::approvals::replayed_file(o),
            };
        }
        let (acceptor, special_ok, decision) = if used.is_some() {
            (antenna_files::policy::Acceptor::Owner, true, "approved")
        } else if waived {
            // Level 5 (D-99): what would have needed the owner is accepted on the owner's standing word
            (
                antenna_files::policy::Acceptor::Owner,
                true,
                crate::approvals::ALLOWED_AT_5,
            )
        } else {
            (antenna_files::policy::Acceptor::Agent, false, "allowed")
        };
        self.accept_file(
            &item,
            &row,
            &acceptor,
            special_ok,
            Some(&target),
            &agent.name,
            decision,
        )
        .await
    }

    /// An agent's `file_reject`: only its own links.
    pub async fn agent_file_reject(
        &self,
        ctx: &AgentCtx,
        id: &str,
    ) -> Result<antenna_proto::control::FileInfo> {
        let agent = self.agent_row(ctx)?;
        let (item, row) = self.agent_find_file(&agent, id)?;
        // SPEC §12: `reject` for an agent from level 3; a threat or an unchecked file is decided by the owner (7 days
        // for `--force`); an accepted file can no longer be rejected
        if row.trust.min(item.level_at_offer) < 3 {
            return Err(Error::new(
                code::DENIED,
                "rejecting files of a contact below trust level 3 is up to the owner",
            ));
        }
        let ok = match (&item.state, &item.report) {
            (antenna_files::quarantine::State::Accepted { .. }, _) => false,
            (antenna_files::quarantine::State::Checked, Some(r)) => matches!(
                r.verdict,
                antenna_files::report::Verdict::Clean | antenna_files::report::Verdict::Suspicious
            ),
            _ => false,
        };
        if !ok {
            return Err(Error::new(
                code::FORBIDDEN,
                "only a checked clean or suspicious file can be rejected by an agent; the owner decides the rest",
            ));
        }
        // The reply carries the file name, which is contact data
        self.taint_link(agent.id, &row.link_id, row.trust)?;
        self.reject_file(&item, &row, &agent.name, "rejected").await
    }

    /// A link in the agent's scope (for `history_status` / `verify`).
    pub fn agent_link(&self, ctx: &AgentCtx, contact: &str) -> Result<LinkRow> {
        let agent = self.agent_row(ctx)?;
        self.scoped(&agent, contact)
    }

    /// The agent's links (`None` means all), for the subscription filter.
    pub fn agent_scope(&self, ctx: &AgentCtx) -> Result<Option<Vec<LinkId>>> {
        Ok(self.agent_row(ctx)?.links)
    }

    /// An agent's `history`: a page of its link's history; incoming messages in it set taint, as with `inbox`.
    pub fn agent_history(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        before: Option<i64>,
        limit: Option<u32>,
    ) -> Result<antenna_proto::control::HistoryReply> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        // An agent gets only the history after its creation (D-30); the contact's receipts (their fields are contact
        // data, but not messages) are never given to an agent
        let mut page = self.history(&row, agent.start_seq, before, limit)?;
        page.messages
            .retain(|m| !(m.kind == "receipt" && m.direction == "in"));
        // The visibility rule (v6, CONTROL §20): incoming messages visible to this agent (the address of an incoming
        // item comes from its signed `core`), and of this side's messages only its own: not the owner's conversation,
        // not other agents'
        {
            let vis = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                Visibility::of(&db, &agent)?
            };
            let own = vis.public_name(&row.link_id).to_string();
            page.messages.retain(|m| {
                if m.direction == "in" {
                    let to =
                        m.to.as_deref()
                            .and_then(|k| antenna_proto::To::from_parts(k, m.to_agent.as_deref()));
                    // A file offer follows the offers' rule (PG-19): one to everyone or to nobody is every agent's,
                    // as in `files_pending`, so a file the agent can accept is in its history too
                    if m.kind == "file" {
                        vis.sees_offer(&row.link_id, to.as_ref())
                    } else {
                        vis.sees_to(&row.link_id, to.as_ref())
                    }
                } else {
                    m.via_agent.as_deref() == Some(own.as_str())
                }
            });
        }
        if page.messages.is_empty() {
            return Ok(page);
        }
        let incoming = page
            .messages
            .iter()
            .filter(|m| m.direction == "in" && m.kind == "text")
            .count();
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let mut agent = db.agent(ctx.id)?;
            let hex = link_hex(&row.link_id);
            // Any history read puts link data into the session (link isolation); incoming messages also set the
            // permission ceiling
            match agent.taint.iter_mut().find(|t| t.link == hex) {
                Some(t) if incoming > 0 && t.ceiling => t.level = t.level.min(row.trust),
                Some(t) if incoming > 0 => {
                    t.ceiling = true;
                    t.level = row.trust;
                }
                Some(_) => {}
                None => agent.taint.push(TaintEntry {
                    link: hex,
                    level: row.trust,
                    at: now_ms(),
                    ceiling: incoming > 0,
                }),
            }
            db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
        }
        self.receipt(
            &row.link_id,
            &agent.name,
            "history",
            "allowed",
            &format!(
                "{} message(s), {incoming} incoming{}",
                page.messages.len(),
                if incoming > 0 {
                    format!("; session tainted at trust {}", row.trust)
                } else {
                    String::new()
                }
            ),
            None,
            None,
        );
        if incoming > 0 {
            let ids: Vec<antenna_proto::MessageId> = page
                .messages
                .iter()
                .filter(|m| m.direction == "in" && m.kind == "text")
                .filter_map(|m| {
                    data_encoding::HEXLOWER
                        .decode(m.id.as_bytes())
                        .ok()
                        .and_then(|v| <[u8; 32]>::try_from(v).ok())
                        .map(antenna_proto::MessageId)
                })
                .collect();
            self.dag_receipt(&row.link_id, &agent.name, "read_history", "allowed", &ids);
        }
        Ok(page)
    }

    /// An agent's `antenna log`: only for its own links and only its own entries (others' reasons would reveal labels
    /// of links outside its scope).
    pub fn agent_log(
        &self,
        ctx: &AgentCtx,
        contact: &str,
        limit: Option<u32>,
    ) -> Result<Vec<ReceiptInfo>> {
        let agent = self.agent_row(ctx)?;
        let row = self.scoped(&agent, contact)?;
        Ok(self
            .log(&row, Some(1000))?
            .into_iter()
            // Its own entries: local ones and its own receipts in the shared history (the contact's receipts are the
            // contact's data)
            .filter(|r| r.actor == agent.name && (r.source != "dag" || r.author == "me"))
            .rev()
            .take(limit.unwrap_or(100).min(1000) as usize)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect())
    }

    /// Wait for incoming changes until the deadline. `false` means the deadline passed.
    pub(crate) async fn wait_changed(
        &self,
        rx: &mut tokio::sync::watch::Receiver<u64>,
        deadline: Option<tokio::time::Instant>,
    ) -> bool {
        match deadline {
            Some(d) => tokio::time::timeout_at(d, rx.changed()).await.is_ok(),
            None => {
                let _ = rx.changed().await;
                true
            }
        }
    }
}

/// A command or a path for the audit log (D-99): one line of at most 200 characters, and only its length when the
/// scanner sees a secret in it (the log shows what ran, not the secrets it carried).
fn audit_detail(detail: &str) -> String {
    let kinds = policy::scan_secrets(detail);
    let n = detail.chars().count();
    if !kinds.is_empty() {
        return format!("[{n} characters with secret:{}]", kinds.join(","));
    }
    let mut s: String = detail
        .chars()
        .take(200)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    if n > 200 {
        s.push('…');
    }
    s
}

fn grants_for(action: Action) -> Grants {
    let none = || "none".to_string();
    match action {
        Action::Read => Grants {
            read: "local files / read-only tools".into(),
            write: none(),
            commands: none(),
            send: none(),
        },
        Action::Write => Grants {
            read: none(),
            write: "local files".into(),
            commands: none(),
            send: none(),
        },
        Action::Exec => Grants {
            read: none(),
            write: none(),
            commands: "run a command (no sandbox yet)".into(),
            send: none(),
        },
    }
}

/// Links whose messages the agent takes as tasks: by default (`tasks_from` NULL) the links at trust level 5 in its
/// scope, evaluated now, so a trust change moves the set; otherwise exactly the listed links that still exist and are
/// in its scope. A link's wake agent takes none: its prompt is fixed and every message is data for it (D-68).
pub(crate) fn task_links(
    row: &AgentRow,
    names: &HashMap<LinkId, (String, u8)>,
    is_wake: bool,
) -> HashSet<LinkId> {
    if is_wake {
        return HashSet::new();
    }
    let in_scope = |l: &LinkId| row.links.as_ref().is_none_or(|s| s.contains(l));
    match &row.tasks_from {
        None => names
            .iter()
            .filter(|(l, (_, t))| *t == 5 && in_scope(l))
            .map(|(l, _)| *l)
            .collect(),
        Some(ls) => ls
            .iter()
            .filter(|l| names.contains_key(l) && in_scope(l))
            .copied()
            .collect(),
    }
}

fn session_info(row: &AgentRow, names: &HashMap<LinkId, (String, u8)>) -> SessionInfo {
    let label = label_of(row);
    let bound = row.anchor.as_ref().map(|(pid, start, comm)| {
        let alive = procinfo::is_alive(&Anchor {
            pid: *pid,
            start: *start,
        });
        (*pid, comm.clone(), alive)
    });
    let name_of = |hex: &str| {
        data_encoding::HEXLOWER
            .decode(hex.as_bytes())
            .ok()
            .and_then(|v| <[u8; 32]>::try_from(v).ok())
            .and_then(|a| names.get(&LinkId(a)).map(|(n, _)| n.clone()))
            .unwrap_or_else(|| hex.get(..8).unwrap_or("?").to_string())
    };
    SessionInfo {
        agent: row.name.clone(),
        started_ms: row.session_started_ms,
        ceiling: label.ceiling(|l| names.get(l).map(|(_, t)| *t)),
        tainted_by: row
            .taint
            .iter()
            .filter(|t| t.ceiling)
            .map(|t| TaintInfo {
                contact: name_of(&t.link),
                level: t.level,
                at_ms: t.at,
            })
            .collect(),
        read_links: row.taint.iter().map(|t| name_of(&t.link)).collect(),
        local_level: label.local_level,
        baseline_level: row.local_level,
        declared: row
            .declared
            .iter()
            .map(|d| DeclaredRead {
                level: d.level,
                what: d.what.clone(),
                at_ms: d.at,
            })
            .collect(),
        links: row.links.as_ref().map(|ls| {
            ls.iter()
                .map(|l| {
                    names
                        .get(l)
                        .map_or_else(|| link_hex(l)[..8].to_string(), |(n, _)| n.clone())
                })
                .collect()
        }),
        bound_to: bound.as_ref().map(|(pid, comm, alive)| {
            format!("{pid} {comm}{}", if *alive { "" } else { " (ended)" })
        }),
        bound_pid: bound
            .as_ref()
            .and_then(|(pid, _, _)| u32::try_from(*pid).ok()),
        bound_comm: bound.as_ref().map(|(_, comm, _)| comm.clone()),
        bound_alive: bound.as_ref().map(|(_, _, alive)| *alive),
        last_seen_ms: None,
        mcp_processes: None,
        refused_pid: None,
        refused_comm: None,
        refused_ms: None,
        refused_alive: None,
        token_file: None,
        tasks_from: Vec::new(),
        tasks_from_default: row.tasks_from.is_none(),
        escalate_to: None,
        counterpart: None,
        approves: Vec::new(),
        local_routes: Vec::new(),
    }
}
