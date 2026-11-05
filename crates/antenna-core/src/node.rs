// SPDX-License-Identifier: AGPL-3.0-only
//! Node: daemon state (not created / locked / unlocked), links and their pairwise endpoints, delivery with a queue and
//! retries (SPEC §4 v1), receiving messages, the inbox.
//!
//! Locking (`antenna lock`, Q-4) stops the link network and wipes the keys from memory: without the password the node
//! neither receives nor sends. Messages addressed to a locked node wait in the sender's queue.

use std::sync::PoisonError;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicU8, AtomicU16, Ordering},
    },
    time::{Duration, Instant},
};

use antenna_proto::control::{ContactSummary, HistoryItem, LanReply, ReceiptView, TopicView};
use antenna_proto::{
    Body, LinkId, MessageId, MessageType, ReceiptBody, RoutingBlob, To,
    control::{
        ContactInfo, ContactsReply, E2eInfo, InboxMessage, InboxReply, ReceiptInfo, SentReply,
        StatusReply, TransportInfo, code,
    },
    link::{ALPN_LINK, LinkRequest, LinkResponse, MAX_FRAME},
};
use iroh::{
    Endpoint, EndpointId, SecretKey,
    endpoint::Connection,
    protocol::{AcceptError, ProtocolHandler, Router},
};
use tokio::sync::{Mutex, Notify, broadcast, watch};
use zeroize::Zeroizing;

use crate::{
    addressing::{Addr, AddrReq, to_view, topic_view},
    e2e,
    error::{Error, Result},
    events::{self, NodeEvent},
    invites::InviteEntry,
    keystore::{self, KdfParams},
    linksync::{HistState, RekeyState},
    now_ms,
    owner::OwnerSessions,
    pairing::{Paired, PeerSlot, SlotGuard},
    policy,
    statefile::{Loaded, StateFile},
    store::{Db, LinkRow, NetMode, NewReceipt},
    transport::{self, EpMode, EpParams, NetConfig},
};

mod own_devices;
mod owner_proof;
mod text_limit;

pub(crate) use text_limit::{check_text, check_text_len};

use owner_proof::counts_as_failed_attempt;

/// Node settings.
#[derive(Debug, Clone)]
pub struct NodeConfig {
    /// Data directory (0700).
    pub data_dir: PathBuf,
    /// Network.
    pub net: NetConfig,
    /// Minimum pause between delivery retries.
    pub retry_min: Duration,
    /// Maximum pause between retries (exponential growth, SPEC §4).
    pub retry_max: Duration,
    /// Link connection establishment timeout.
    pub dial_timeout: Duration,
    /// Allow `antenna invite --confirm` (confirmation at A without asking the owner). Tests only: it removes the
    /// protection of SPEC §6 item 9 (PROTOCOL §9).
    pub allow_auto_confirm: bool,
    /// Idle time of a level 1–2 link connection after which it is closed (presence, SPEC §4, Q-8).
    pub presence_idle: Duration,
    /// Files (slice 4): links folders, check worker, antivirus.
    pub files: crate::files::FilesConfig,
    /// Daemon version for `status` and `hello_ok` (`antennad` appends the build commit).
    pub daemon_version: String,
    /// Path of the control socket (for an agent the daemon wakes, v0.2).
    pub control_socket: PathBuf,
    /// TESTS ONLY: the wake sandbox uses only Landlock even if bwrap is present (to test the fallback mode on a machine
    /// with bwrap). Nothing can weaken it to "no sandbox".
    pub wake_landlock_only: bool,
    /// Lifetime of an approval request (SPEC §9: 10 minutes). Tests shorten it to see a request expire; it is never
    /// longer than [`policy::APPROVAL_TTL_MS`].
    pub approval_ttl: Duration,
    /// Largest `share_file_content` an agent may send, decoded bytes (`antennad --share-content-max-mib`); 0 turns the
    /// command off.
    pub share_content_max: u64,
    /// Local models and local agents (D-104).
    pub local: crate::local::LocalConfig,
    /// Updates that install by themselves (D-103): timings and what the daemon knows about itself.
    pub update: crate::autoupdate::AutoConfig,
    /// How long an owner challenge is valid (v7: 60 s). Tests shorten it to see one expire; never longer.
    pub owner_challenge_ttl: Duration,
    /// How long after the last correct password owner proofs and unlock slots are accepted (v7, D-102: 14 days).
    /// Tests shorten it to see the password asked again; never longer.
    pub owner_password_every: Duration,
    /// How often the node looks at what to tell its own devices (PROTOCOL §24: 2 s; a status goes only when it
    /// changed, or every minute).
    pub device_tick: Duration,
}

impl NodeConfig {
    /// Default values for a directory.
    pub fn new(data_dir: PathBuf, net: NetConfig) -> Self {
        // SPEC §10: `~/Antenna/links/<contact>/`; without $HOME, next to the daemon data
        let links_dir = default_links_dir().unwrap_or_else(|| data_dir.join("links"));
        Self {
            control_socket: data_dir.join(antenna_proto::local::SOCKET_NAME),
            wake_landlock_only: false,
            approval_ttl: Duration::from_millis(policy::APPROVAL_TTL_MS),
            share_content_max: crate::files::SHARE_CONTENT_MAX_DEFAULT,
            local: crate::local::LocalConfig::default(),
            update: crate::autoupdate::AutoConfig::default(),
            owner_challenge_ttl: Duration::from_millis(
                antenna_proto::control::owner_keys::CHALLENGE_TTL_MS,
            ),
            owner_password_every: Duration::from_millis(
                antenna_proto::control::owner_keys::PASSWORD_EVERY_MS,
            ),
            device_tick: own_devices::TICK,
            data_dir,
            net,
            retry_min: Duration::from_millis(250),
            retry_max: Duration::from_secs(30),
            dial_timeout: Duration::from_secs(10),
            allow_auto_confirm: false,
            presence_idle: PRESENCE_IDLE,
            files: crate::files::FilesConfig::new(links_dir),
            daemon_version: format!("antennad {}", env!("CARGO_PKG_VERSION")),
        }
    }
}

/// Default links folder: `$HOME/Antenna/links` (SPEC §10; before the rename it was `~/X/links`, which `antennad`
/// moves on startup). `None` if there is no `$HOME`.
pub fn default_links_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join("Antenna").join("links"))
}

/// Links folder of pre-release `x` builds: `$HOME/X/links`.
pub fn legacy_links_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join("X").join("links"))
}

/// Service requests from a contact per minute (verification, `chain`, `conflict`, `want`, `resend`, rekey).
const CTL_PER_MIN: u32 = 120;
/// Pause after the last activity after which the link re-verifies the history (if there were new messages).
const RESYNC_AFTER: Duration = Duration::from_millis(1500);
/// Idle time of a level 1–2 connection before it is closed (Q-8).
pub const PRESENCE_IDLE: Duration = Duration::from_secs(30);
/// Window of a batch of agent check receipts for contacts of levels 1–2 (Q-22).
const CHECK_BATCH_MS: u64 = 10 * 60 * 1000;
/// Key of a check receipt batch: link, agent, action, decision.
pub(crate) type CheckKey = (LinkId, String, String, String);

/// A receipt's optional fields, each written only to a contact whose node takes it.
#[derive(Debug, Default)]
struct ReceiptExtra {
    /// `name_number` (`file-saved-as/0`, D-128).
    name_number: u32,
    /// `why` (`file-fate/0`, D-130); empty: none.
    why: String,
    /// `rules` with `why`.
    rules: Vec<String>,
}
/// How long the daemon holds back an incoming message above the level limit before not answering at all (the sender
/// retries).
const INCOMING_BACKPRESSURE: Duration = Duration::from_secs(10);
/// How long a `send` to an agent the contact never announced waits for its node's `no_such_agent` answer (PROTOCOL
/// §23): the answer follows the message at once on the same connection.
const NO_AGENT_WAIT: Duration = Duration::from_millis(1500);

enum State {
    Uninitialized,
    Locked,
    Unlocked(Arc<Session>),
}

/// Node.
pub struct Node {
    cfg: Arc<NodeConfig>,
    state: Mutex<State>,
    inbox: watch::Sender<u64>,
    /// Consecutive wrong passwords and until when no checks are made (online guessing through the daemon).
    pw_fail: StdMutex<(u32, u64)>,
    /// Password checks run one at a time: Argon2id with 64 MiB each; in parallel they would exhaust memory and bypass
    /// the pause.
    pw_gate: tokio::sync::Semaphore,
    /// The keystore remembered at unlock and the root key fingerprint: the owner password is checked against them,
    /// not against the file on disk (an agent with the same uid can replace the file).
    pw_ref: StdMutex<Option<PwRef>>,
    /// Owner sessions (Q-14b): terminal, parent, the window's connection.
    pub(crate) owner_sessions: StdMutex<OwnerSessions>,
    /// When each agent (by ID) last reached the daemon; in memory, kept across `lock`/`unlock`.
    agent_seen: Arc<StdMutex<HashMap<i64, u64>>>,
    /// Updates that install by themselves (D-103): the key kept for the restart, the handover, `status.updated`.
    pub(crate) auto: Arc<crate::autoupdate::NodeAuto>,
    /// Owner proofs (v7, D-102): outstanding challenges and failed proofs in a row; in memory only.
    proofs: StdMutex<crate::owner_keys::ProofState>,
}

struct PwRef {
    keystore: Vec<u8>,
    fingerprint: crate::crypto::Secret32,
}

/// Unlocked session: DB, running links, invites, approval requests and limits.
pub struct Session {
    pub(crate) cfg: Arc<NodeConfig>,
    pub(crate) db: Arc<StdMutex<Db>>,
    links: StdMutex<HashMap<LinkId, Arc<LinkRt>>>,
    closed: AtomicBool,
    closed_notify: Notify,
    pub(crate) inbox: watch::Sender<u64>,
    /// Invites in the daemon (Q-7).
    pub(crate) invites: StdMutex<HashMap<String, Arc<InviteEntry>>>,
    /// Counter of invite changes (for `antenna pairing --wait`).
    pub(crate) invites_changed: watch::Sender<u64>,
    /// Approval requests (in memory).
    pub(crate) approvals: StdMutex<policy::Approvals>,
    /// Limits on outgoing messages from agents per link.
    pub(crate) out_limits: StdMutex<policy::RateLimiter>,
    /// Events for subscribers (`subscribe`, v1).
    pub(crate) events: broadcast::Sender<NodeEvent>,
    /// When a limit refusal was last written to the audit log (per link).
    pub(crate) rl_receipts: StdMutex<HashMap<LinkId, u64>>,
    /// Link state counters outside the DB (rollback protection, SPEC §8).
    pub(crate) statefile: Arc<StateFile>,
    /// When an identical receipt was last written to the shared history (merging, at most once a minute).
    pub(crate) dag_rl: StdMutex<HashMap<String, u64>>,
    /// Files and the quarantine (slice 4); `None` if the quarantine did not open.
    pub(crate) files: Option<Arc<crate::files::Files>>,
    /// Agent check receipts for contacts of levels 1–2, batched over 10 minutes (Q-22):
    /// (link, who, action, decision) → (first, how many).
    pub(crate) check_batch: StdMutex<HashMap<CheckKey, (u64, u32)>>,
    /// Our own running streaming messages (v0.2): for `streams`.
    pub(crate) streams_out: StdMutex<HashMap<[u8; 16], crate::stream::OutEntry>>,
    /// Requests the daemon carries out itself once the owner approves them (D-70, D-100): approval ID → the request.
    pub(crate) continuations: StdMutex<HashMap<String, crate::approvals::Continuation>>,
    /// Decided approval requests not yet seen by the agent that made them (its next `wait`/`inbox`, D-100): requester
    /// ID (`agent:<id>`) → resolutions.
    pub(crate) resolved: StdMutex<
        HashMap<String, std::collections::VecDeque<antenna_proto::control::ApprovalResolution>>,
    >,
    /// Woken when an approved request the daemon carries out finishes (a repeat of it waits for the result).
    pub(crate) approvals_changed: Notify,
    /// Files saved for each agent, until its next `inbox` (v7, CONTROL §14).
    pub(crate) file_notices: crate::file_notices::FileNotices,
    /// Agent wakes (v0.2): running launches, queue, limits.
    pub(crate) wake: crate::wake::WakeState,
    /// Wake queue: the link on which a new text message arrived (and the agent an honoured urgent one is for).
    wake_tx: tokio::sync::mpsc::UnboundedSender<crate::wake::WakeKick>,
    /// LAN via mDNS (v5, SPEC §4, §18): off by default.
    pub(crate) lan: Arc<crate::lan::Lan>,
    /// When each agent (by ID) last reached the daemon (the node's map, shared with later sessions).
    pub(crate) agent_seen: Arc<StdMutex<HashMap<i64, u64>>>,
    /// Further MCP hosts of the same app per agent, and the running `antenna mcp` processes (D-97). Lock order: after
    /// the DB.
    pub(crate) app_hosts: StdMutex<crate::app_hosts::AppHosts>,
    /// Local models and local agents (D-104): downloads, runtimes, conversations.
    pub(crate) local: crate::local::LocalState,
    /// Teams of agents (D-111): worker processes, members' facts, one change per team at a time.
    pub(crate) teams: crate::teams::TeamsState,
    /// Updates that install by themselves (D-103): the staged release and the running install.
    pub(crate) auto: crate::autoupdate::SessionAuto,
    /// The node's part of it (shared with later sessions).
    pub(crate) node_auto: Arc<crate::autoupdate::NodeAuto>,
    /// Own devices (PROTOCOL §24, D-106): requests of the owner's other computers, challenges, their statuses.
    pub(crate) devices: own_devices::DeviceState,
    /// Approver agents (PG-57): level changes, requests offered to approvers, challenges for their answers.
    pub(crate) delegation: crate::delegation::DelegationState,
    /// The owner's urgent messages (PG-58): at most one honoured per agent per 30 s, node-wide.
    pub(crate) urgent: Arc<crate::urgent::Gate>,
    /// The stop switch (PG-58): the terminal sessions clients started agents in, the stops own computers asked for.
    pub(crate) stops: crate::agent_stop::StopState,
    /// Local routes between agents of this computer (D-132): the per-direction rate limit.
    pub(crate) local_routes: crate::local_routes::LocalRouteState,
}

impl Node {
    /// New node (the keystore is read from disk lazily).
    pub fn new(cfg: NodeConfig) -> Arc<Self> {
        let state = if keystore::exists(&cfg.data_dir) {
            State::Locked
        } else {
            State::Uninitialized
        };
        Arc::new(Self {
            cfg: Arc::new(cfg),
            state: Mutex::new(state),
            inbox: watch::channel(0).0,
            pw_fail: StdMutex::new((0, 0)),
            pw_gate: tokio::sync::Semaphore::new(1),
            pw_ref: StdMutex::new(None),
            owner_sessions: StdMutex::new(OwnerSessions::default()),
            agent_seen: Arc::default(),
            auto: Arc::default(),
            proofs: StdMutex::default(),
        })
    }

    /// A request authenticated as this agent reached the daemon (`last_seen_ms` in `agent_list`).
    pub(crate) fn note_agent_seen(&self, id: i64) {
        self.agent_seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, now_ms());
    }

    /// Current session, if the node is unlocked.
    pub async fn session_opt(&self) -> Option<Arc<Session>> {
        match &*self.state.lock().await {
            State::Unlocked(s) => Some(s.clone()),
            _ => None,
        }
    }

    /// Owner password check for commands that change trust and links (SPEC §6 item 1, §9; Q-12a): Argon2id over the
    /// keystore anew on every call. After 3 wrong ones in a row, a pause of 1, 2, 4 … 60 s (online guessing).
    pub async fn verify_password(&self, password: &str) -> Result<()> {
        let (bytes, fp) = {
            let g = self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner);
            match g.as_ref() {
                Some(r) => (r.keystore.clone(), Zeroizing::new(*r.fingerprint)),
                None => {
                    return Err(Error::new(
                        code::LOCKED,
                        "keystore is locked: run `antenna unlock`",
                    ));
                }
            }
        };
        if keystore::read(&self.cfg.data_dir).ok().as_deref() != Some(bytes.as_slice()) {
            tracing::warn!(
                "keystore file on disk differs from the one unlocked; the owner password is checked against the unlocked one"
            );
        }
        let pw = Zeroizing::new(password.to_string());
        self.with_password_limit(move || {
            let root = keystore::unlock_bytes(&bytes, pw.as_bytes())?;
            if crate::crypto::ct_eq(root.fingerprint().as_slice(), fp.as_slice()) {
                Ok(())
            } else {
                Err(Error::new(code::WRONG_PASSWORD, "wrong password"))
            }
        })
        .await?;
        self.note_password().await;
        Ok(())
    }

    /// A correct owner password: the 14-day clock of owner proofs starts again and failed proofs are forgotten (v7,
    /// D-102). A failure to record it only makes proofs ask for the password sooner.
    async fn note_password(&self) {
        self.proofs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .fails = 0;
        if let Some(s) = self.session_opt().await {
            let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
            if let Err(e) = crate::owner_keys::note_password(&db, now_ms()) {
                tracing::warn!("owner keys: cannot record the password check: {e}");
            }
        }
    }

    async fn with_password_limit<T: Send + 'static>(
        &self,
        f: impl FnOnce() -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let _one = self
            .pw_gate
            .acquire()
            .await
            .map_err(|_| Error::internal("password gate closed"))?;
        self.limit_pause()?;
        let r = tokio::task::spawn_blocking(f)
            .await
            .map_err(|e| Error::internal(e.to_string()))?;
        self.limit_record(&r);
        r
    }

    /// The D-37 pause after wrong passwords (and, v7, failed owner proofs and unlock slots).
    fn limit_pause(&self) -> Result<()> {
        let now = now_ms();
        let g = self.pw_fail.lock().unwrap_or_else(PoisonError::into_inner);
        if now < g.1 {
            return Err(Error::new(
                code::RATE_LIMITED,
                format!(
                    "too many wrong passwords; try again in {} s",
                    (g.1 - now).div_ceil(1000)
                ),
            ));
        }
        Ok(())
    }

    /// Counts a failed attempt (a pause of 1, 2, 4 … 60 s from the third in a row) or forgets them after a success.
    fn limit_record<T>(&self, r: &Result<T>) {
        let mut g = self.pw_fail.lock().unwrap_or_else(PoisonError::into_inner);
        match r {
            Ok(_) => *g = (0, 0),
            Err(e) if counts_as_failed_attempt(e.code) => {
                g.0 += 1;
                if g.0 >= 3 {
                    let pause = 1000u64 << (g.0 - 3).min(6);
                    g.1 = now_ms() + pause.min(60_000);
                }
            }
            Err(_) => {}
        }
    }

    /// Configuration.
    pub fn config(&self) -> &NodeConfig {
        &self.cfg
    }

    /// Daemon version (`NodeConfig::daemon_version`).
    pub fn daemon_version(&self) -> &str {
        &self.cfg.daemon_version
    }

    /// State name.
    pub async fn state_name(&self) -> &'static str {
        match &*self.state.lock().await {
            State::Uninitialized => "uninitialized",
            State::Locked => "locked",
            State::Unlocked(_) => "unlocked",
        }
    }

    /// Current session or a `locked` / `not_initialized` error.
    pub async fn session(&self) -> Result<Arc<Session>> {
        match &*self.state.lock().await {
            State::Unlocked(s) => Ok(s.clone()),
            State::Locked => Err(Error::new(
                code::LOCKED,
                "keystore is locked: run `antenna unlock`",
            )),
            State::Uninitialized => Err(Error::new(
                code::NOT_INITIALIZED,
                "node is not initialized: run `antenna init`",
            )),
        }
    }

    /// `antenna status`.
    pub async fn status(&self) -> StatusReply {
        let state = self.state.lock().await;
        let (name, links) = match &*state {
            State::Uninitialized => ("uninitialized", None),
            State::Locked => ("locked", None),
            State::Unlocked(s) => (
                "unlocked",
                Some(s.links.lock().unwrap_or_else(PoisonError::into_inner).len() as u64),
            ),
        };
        StatusReply {
            state: name.into(),
            daemon: self.cfg.daemon_version.clone(),
            protocol: crate::PROTOCOL_VERSION.to_string(),
            relay: self.cfg.net.relay.describe(),
            links,
            updated: self
                .auto
                .updated
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone(),
        }
    }

    /// `antenna init`: create the root key (password → Argon2id) and open an empty DB.
    pub async fn init(&self, password: Zeroizing<String>) -> Result<()> {
        let mut state = self.state.lock().await;
        if !matches!(*state, State::Uninitialized) {
            return Err(Error::new(code::ALREADY_INITIALIZED, "already initialized"));
        }
        let dir = self.cfg.data_dir.clone();
        let root = tokio::task::spawn_blocking(move || {
            keystore::create(&dir, password.as_bytes(), KdfParams::DEFAULT)
        })
        .await
        .map_err(|e| Error::internal(e.to_string()))??;
        let bytes = keystore::read(&self.cfg.data_dir)?;
        let fp_root = root.fingerprint();
        let s = self.open_session(root, None).await?;
        s.note_password();
        *self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner) = Some(PwRef {
            keystore: bytes,
            fingerprint: fp_root,
        });
        *state = State::Unlocked(s);
        Ok(())
    }

    /// `antenna unlock`.
    pub async fn unlock(&self, password: Zeroizing<String>) -> Result<()> {
        let mut state = self.state.lock().await;
        match *state {
            State::Unlocked(_) => return Ok(()),
            State::Uninitialized => {
                return Err(Error::new(
                    code::NOT_INITIALIZED,
                    "run `antenna init` first",
                ));
            }
            State::Locked => {}
        }
        let bytes = keystore::read(&self.cfg.data_dir)?;
        let b2 = bytes.clone();
        let root = self
            .with_password_limit(move || keystore::unlock_bytes(&b2, password.as_bytes()))
            .await?;
        let fp_root = root.fingerprint();
        let s = self.open_session(root, None).await?;
        s.note_password();
        self.proofs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .fails = 0;
        // Remember the keystore only after the session has opened successfully
        *self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner) = Some(PwRef {
            keystore: bytes,
            fingerprint: fp_root,
        });
        *state = State::Unlocked(s);
        Ok(())
    }

    /// The new daemon after an automatic update (D-103, R2): the root key came over the handover pipe. The database must
    /// open with it (a wrong key does not); then the node is unlocked without the password. The owner password is
    /// checked against the keystore read now and the fingerprint of this key, as after `unlock`.
    pub async fn unlock_handover(&self, root: Zeroizing<[u8; 32]>) -> Result<()> {
        let mut state = self.state.lock().await;
        if !matches!(*state, State::Locked) {
            return Err(Error::new(
                code::BAD_REQUEST,
                "the node is not locked: nothing to hand over",
            ));
        }
        let bytes = keystore::read(&self.cfg.data_dir)?;
        let root = keystore::RootKey::from_handover(&root);
        let fp_root = root.fingerprint();
        self.auto.came_by_handover.store(true, Ordering::SeqCst);
        let s = match self.open_session(root, None).await {
            Ok(s) => s,
            Err(e) => {
                self.auto.came_by_handover.store(false, Ordering::SeqCst);
                return Err(e);
            }
        };
        *self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner) = Some(PwRef {
            keystore: bytes,
            fingerprint: fp_root,
        });
        *state = State::Unlocked(s);
        Ok(())
    }

    /// Waits until an automatic install asks the daemon to replace itself (`antennad` then shuts down and `exec`s the
    /// new binary, D-103).
    pub async fn wait_handover(&self) -> crate::autoupdate::Handover {
        self.auto.wait_handover().await
    }

    /// The owner turned automatic installs on with the password: keep the root key for the update's restart (the
    /// password unwraps it from the keystore remembered at unlock, under the same back-off as every password check).
    pub(crate) async fn keep_root_with_password(&self, password: &str) -> Result<()> {
        let bytes = {
            let g = self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner);
            match g.as_ref() {
                Some(r) => r.keystore.clone(),
                None => return Err(Error::new(code::LOCKED, "keystore is locked")),
            }
        };
        let pw = Zeroizing::new(password.to_string());
        let root = self
            .with_password_limit(move || keystore::unlock_bytes(&bytes, pw.as_bytes()))
            .await?;
        self.auto.keep_root(Some(root.handover_bytes()));
        Ok(())
    }

    /// Opens the database and starts everything. With `slot` (v7, an unlock by an owner key's slot), the database is
    /// checked before anything starts: the key must still be enrolled with its slot and the password not due
    /// (`owner_proof::check_slot_unlock`).
    async fn open_session(
        &self,
        root: keystore::RootKey,
        slot: Option<&str>,
    ) -> Result<Arc<Session>> {
        let key = root.db_key();
        let state_key = root.state_key();
        let files_key = root.files_key();
        // Kept only if the owner turned automatic installs on (read below, once the database is open, D-103).
        let keep = root.handover_bytes();
        drop(root);
        let path = self.cfg.data_dir.join(crate::store::FILE_NAME);
        let db = tokio::task::spawn_blocking(move || Db::open(&path, &key))
            .await
            .map_err(|e| Error::internal(e.to_string()))??;
        if let Some(key_id) = slot {
            let every =
                u64::try_from(self.cfg.owner_password_every.as_millis()).unwrap_or(u64::MAX);
            owner_proof::check_slot_unlock(&db, key_id, now_ms(), every)?;
        }
        let statefile = Arc::new(StateFile::load(&self.cfg.data_dir, state_key));
        check_rollback(&db, &statefile)?;
        let (files, files_rx) =
            match crate::files::Files::new(&self.cfg.data_dir, self.cfg.files.clone(), files_key) {
                Ok((f, rx)) => (Some(f), Some(rx)),
                Err(e) => {
                    tracing::warn!("files: quarantine is unavailable: {e}");
                    (None, None)
                }
            };
        let (wake_tx, wake_rx) = tokio::sync::mpsc::unbounded_channel();
        let s = Arc::new(Session {
            cfg: self.cfg.clone(),
            db: Arc::new(StdMutex::new(db)),
            links: StdMutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
            closed_notify: Notify::new(),
            inbox: self.inbox.clone(),
            invites: StdMutex::new(HashMap::new()),
            invites_changed: watch::channel(0).0,
            approvals: StdMutex::new(policy::Approvals::with_ttl(
                u64::try_from(self.cfg.approval_ttl.as_millis()).unwrap_or(u64::MAX),
            )),
            out_limits: StdMutex::new(policy::RateLimiter::default()),
            events: broadcast::channel(events::CAPACITY).0,
            rl_receipts: StdMutex::new(HashMap::new()),
            statefile,
            dag_rl: StdMutex::new(HashMap::new()),
            files,
            check_batch: StdMutex::new(HashMap::new()),
            streams_out: StdMutex::new(HashMap::new()),
            continuations: StdMutex::new(HashMap::new()),
            resolved: StdMutex::new(HashMap::new()),
            approvals_changed: Notify::new(),
            file_notices: Default::default(),
            wake: Default::default(),
            wake_tx,
            lan: Arc::new(crate::lan::Lan::default()),
            agent_seen: self.agent_seen.clone(),
            app_hosts: StdMutex::default(),
            local: crate::local::LocalState::new(&self.cfg.local),
            teams: Default::default(),
            auto: Default::default(),
            node_auto: self.auto.clone(),
            devices: Default::default(),
            delegation: Default::default(),
            urgent: Arc::default(),
            stops: Default::default(),
            local_routes: Default::default(),
        });
        self.auto.keep_root(s.auto_enabled().then_some(keep));
        let rows =
            s.db.lock()
                .unwrap_or_else(PoisonError::into_inner)
                .links()?;
        // Links come up in parallel: without internet each one waits up to 2 s for the relay (`transport::bind_saved`)
        let started =
            futures::future::join_all(rows.iter().map(|row| s.start_saved_link(row))).await;
        for (row, r) in rows.iter().zip(started) {
            if let Err(e) = r {
                tracing::warn!("link {}: cannot start: {e}", &row.link_id.to_hex()[..8]);
            }
        }
        if let Some(rx) = files_rx {
            tokio::spawn(s.clone().files_loop(rx));
        }
        // Uploads of `share_file_content` left by a crash (a staged file is unlinked as soon as it is created, so this
        // finds something only if the daemon died in between)
        crate::files::sweep_staged(&self.cfg.data_dir);
        // Resident sessions a dead daemon left on disk in plain text go into the encrypted database (PG-24)
        s.resident_park_leftovers();
        tokio::spawn(s.clone().files_maintenance());
        tokio::spawn(s.clone().approvals_maintenance());
        tokio::spawn(s.clone().wake_loop(wake_rx));
        tokio::spawn(s.clone().devices_loop());
        tokio::spawn(s.clone().devices_announcer());
        // LAN only if the owner turned it on (`antenna lan on`)
        let lan_on =
            s.db.lock()
                .unwrap_or_else(PoisonError::into_inner)
                .meta_get(crate::lan::META_KEY)?
                .as_deref()
                == Some("on");
        if lan_on {
            s.lan.start(Arc::downgrade(&s));
        }
        tokio::spawn(crate::lan::maintenance(Arc::downgrade(&s)));
        s.local_start();
        s.teams_start();
        crate::autoupdate::start(&s);
        Ok(s)
    }

    /// `antenna lock`: stop the links, close the DB, wipe the keys from memory.
    pub async fn lock(&self) -> Result<()> {
        let mut state = self.state.lock().await;
        if let State::Unlocked(s) = &*state {
            s.shutdown().await;
            *state = State::Locked;
            *self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner) = None;
            self.auto.keep_root(None);
            self.proofs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clear();
            self.owner_sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clear();
            self.inbox.send_modify(|v| *v += 1); // Wake up those waiting in inbox --wait
            Ok(())
        } else if matches!(*state, State::Locked) {
            Ok(())
        } else {
            Err(Error::new(
                code::NOT_INITIALIZED,
                "run `antenna init` first",
            ))
        }
    }
}

impl Session {
    /// DB.
    pub fn db(&self) -> &Arc<StdMutex<Db>> {
        &self.db
    }

    /// The session is closed (`antenna lock`).
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Wait for `antenna lock` (to cancel long operations such as pairing).
    pub async fn closed_wait(&self) {
        let notified = self.closed_notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if self.is_closed() {
            return;
        }
        notified.await;
    }

    async fn shutdown(&self) {
        // Check receipt batches (Q-22) go into the history before the links stop: they are delivered after the next
        // unlock
        self.flush_check_batches(true);
        self.closed.store(true, Ordering::SeqCst);
        self.closed_notify.notify_waiters();
        self.lan.stop();
        let links: Vec<_> = self
            .links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .drain()
            .collect();
        for (_, rt) in links {
            rt.stop().await;
        }
        if let Some(f) = &self.files {
            f.shutdown().await;
        }
        // Downloads stop (their `downloading` rows resume them after the next unlock); runtimes and loops stop.
        for (_, tx) in self
            .local
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .drain()
        {
            let _ = tx.send(true);
        }
        self.local.pool.unload_all().await;
    }

    /// Save a new link (called from pairing at activation).
    pub fn persist_link(&self, rec: &crate::store::NewLink) -> Result<String> {
        if self.is_closed() {
            return Err(Error::new(code::LOCKED, "node was locked during pairing"));
        }
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert_link(rec, now_ms())
    }

    /// Start a link just created by pairing (the endpoint is already up).
    pub async fn start_paired_link(&self, p: Paired) -> Result<()> {
        if self.is_closed() {
            p.endpoint.close().await;
            return Err(Error::new(code::LOCKED, "node was locked during pairing"));
        }
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&p.link_id);
        let row = match row {
            Ok(r) => r,
            Err(e) => {
                p.endpoint.close().await;
                return Err(e);
            }
        };
        let mode = ep_mode(row.net_mode);
        if let Some(port) = transport::bound_port(&p.endpoint) {
            let _ = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .set_local_port(&p.link_id, port);
        }
        self.spawn_link(&row, p.endpoint, mode, p.slot, p.peer_endpoint)
            .await
    }

    async fn start_saved_link(&self, row: &LinkRow) -> Result<()> {
        let peer = iroh::PublicKey::from_bytes(&row.peer_endpoint)
            .map_err(|_| Error::internal("bad peer endpoint in db"))?;
        let mode = ep_mode(row.net_mode);
        let slot = PeerSlot::default();
        slot.set(peer);
        let params = |port| EpParams {
            secret: SecretKey::from_bytes(&row.local_secret),
            mode,
            port,
            hooks: SlotGuard(slot.clone()),
            alpns: vec![ALPN_LINK.to_vec()],
        };
        // Without a relay (no internet, LAN) the link comes up anyway: the relay endpoint catches up on its own
        let ep = match transport::bind_saved(&self.cfg.net, params(row.local_port)).await {
            Ok(ep) => ep,
            Err(e) if row.local_port.is_some() => {
                tracing::warn!("saved port unavailable ({e}); binding a random port");
                transport::bind_saved(&self.cfg.net, params(None)).await?
            }
            Err(e) => return Err(e),
        };
        if let Some(port) = transport::bound_port(&ep)
            && Some(port) != row.local_port
        {
            let _ = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .set_local_port(&row.link_id, port);
        }
        self.spawn_link(row, ep, mode, slot, peer).await?;
        // Presence is allowed only from level 3 (SPEC §4): only those contacts are told the node is back online
        if row.trust >= 3
            && let Some(rt) = self
                .links
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&row.link_id)
        {
            rt.shared.announce.store(true, Ordering::SeqCst);
            rt.shared.kick.notify_one();
        }
        Ok(())
    }

    async fn spawn_link(
        &self,
        row: &LinkRow,
        endpoint: Endpoint,
        mode: EpMode,
        slot: PeerSlot,
        peer: EndpointId,
    ) -> Result<()> {
        let (note, rekey_pending, feat) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            (
                db.hist_note(&row.link_id)?,
                Db::rekey_pending(db.conn(), &row.link_id)?,
                features_code(db.peer_features(&row.link_id)?.as_deref()),
            )
        };
        let shared = Arc::new(LinkShared {
            link_id: row.link_id,
            peer,
            endpoint: endpoint.clone(),
            mode,
            db: self.db.clone(),
            sig_local: row.sig_local_addr.clone(),
            sig_remote: row.sig_remote_addr.clone(),
            peer_root: row.peer_root_ed25519,
            own_root: row.root_ed25519_pk,
            hist: StdMutex::new(HistState::load(note.as_deref())),
            blocked: StdMutex::new(row.blocked.clone()),
            statefile: self.statefile.clone(),
            rekey: StdMutex::new(RekeyState::load(rekey_pending.as_deref())),
            sync_lock: Mutex::new(()),
            conn: StdMutex::new(None),
            kick: Notify::new(),
            delivered: broadcast::channel(64).0,
            inbox: self.inbox.clone(),
            events: self.events.clone(),
            label: row.label.clone(),
            cfg: self.cfg.clone(),
            announce: AtomicBool::new(false),
            sync_requested: AtomicBool::new(false),
            trust: AtomicU8::new(row.trust),
            last_active: StdMutex::new(Instant::now()),
            in_limit: StdMutex::new(policy::RateLimiter::default()),
            ctl_limit: StdMutex::new(policy::RateLimiter::default()),
            want_gate: tokio::sync::Semaphore::new(1),
            files_tx: self.files.as_ref().map(|f| f.jobs.clone()),
            streams_in: StdMutex::new(Default::default()),
            wake_tx: self.wake_tx.clone(),
            urgent: self.urgent.clone(),
            devices_tx: self.devices.tx.clone(),
            peer_feat: AtomicU16::new(feat),
            last_kind: StdMutex::new(String::new()),
            kind_flags: StdMutex::new(None),
            lan: self.lan.clone(),
            _slot: slot,
        });
        let mut router = Router::builder(endpoint)
            .incoming_filter(transport::link_filter(peer))
            .accept(ALPN_LINK, LinkHandler(shared.clone()));
        // Link files: ciphertext blobs are served only to this link's contact and only those sent in it (SPEC §10)
        if let Some(f) = &self.files {
            router = router.accept(
                iroh_blobs::ALPN,
                crate::files::BlobsHandler {
                    files: f.clone(),
                    link: row.link_id,
                    peer,
                },
            );
        }
        let router = router.spawn();
        let worker = tokio::spawn(delivery_worker(shared.clone()));
        let idle = tokio::spawn(idle_watcher(shared.clone()));
        shared.kick.notify_one();
        let rt = Arc::new(LinkRt {
            shared,
            router,
            worker,
            idle,
        });
        self.links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(row.link_id, rt.clone());
        // `antenna lock` may have happened while the link was coming up (for example, `antenna trust` changes the
        // network mode): do not leave a running endpoint in a closed session
        if self.is_closed() {
            self.links
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&row.link_id);
            rt.stop().await;
            return Err(Error::new(code::LOCKED, "node was locked"));
        }
        rt.shared.emit_contact();
        Ok(())
    }

    /// The link is running (otherwise sending will not happen).
    pub(crate) fn ensure_running(&self, id: &LinkId) -> Result<()> {
        self.rt(id).map(drop)
    }

    /// Running links.
    pub(crate) fn running_links(&self) -> Vec<Arc<LinkRt>> {
        self.links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect()
    }

    pub(crate) fn rt(&self, id: &LinkId) -> Result<Arc<LinkRt>> {
        self.links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()
            .ok_or_else(|| Error::internal("link is not running"))
    }

    /// Link by label or ID prefix.
    pub fn find_link(&self, contact: &str) -> Result<LinkRow> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .find_link(contact)
    }

    /// The owner's `antenna send`: the secret scanner applies here too (SPEC §9 "at any level"), approval is via
    /// `antenna approve`.
    pub async fn owner_send(
        &self,
        contact: &str,
        text: &str,
        wait: Duration,
        approval_id: Option<&str>,
        req: &AddrReq,
        urgent: bool,
    ) -> Result<SentReply> {
        let row = self.find_link(contact)?;
        let mut addr = self.owner_addr(&row, req)?;
        if urgent {
            // The owner's "interrupt now" (PG-58): for one agent, of an own computer. The recipient checks the same
            // itself; refusing here tells the owner at once instead of sending a flag nobody honours
            if !matches!(addr.to, Some(To::Agent(_))) {
                return Err(Error::bad_request(
                    "an urgent message is for one agent: address it to the agent",
                ));
            }
            if row.trust < 5 {
                return Err(Error::new(
                    code::FORBIDDEN,
                    "urgent messages go only to agents of your own computers (level 5, ∞)",
                ));
            }
            addr.urgent = true;
        }
        self.owner_send_row(&row, text, wait, approval_id, None, &addr)
            .await
            .map(|r| r.1)
    }

    /// The address and topic of the owner's message (v6, CONTROL §20): the person by default, no topic unless asked.
    pub(crate) fn owner_addr(&self, row: &LinkRow, req: &AddrReq) -> Result<Addr> {
        let to = req.parse_to()?.unwrap_or(To::Person);
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let topic = req.resolve_topic(&db, &row.link_id)?.flatten();
        Ok(Addr {
            to: Some(to),
            topic,
            urgent: false,
        })
    }

    /// The owner's `send` on a found link; `salt` is the salt of a streaming message's final message (v0.2).
    pub(crate) async fn owner_send_row(
        &self,
        row: &LinkRow,
        text: &str,
        wait: Duration,
        approval_id: Option<&str>,
        salt: Option<[u8; 32]>,
        addr: &Addr,
    ) -> Result<(MessageId, SentReply)> {
        check_text(text)?;
        let row = row.clone();
        let reasons: Vec<String> = policy::scan_secrets(text)
            .into_iter()
            .map(|k| format!("secret:{k}"))
            .collect();
        // To the owner's own computer (level 5, D-99) a secret goes without approval; the audit log keeps it
        let reasons = self.waive_level_5(&row, row.trust, "owner", "send_message", reasons);
        let mut used = None;
        if !reasons.is_empty() {
            used = self.gate(
                Self::send_approval("owner", "owner", &row, &row, reasons, text),
                approval_id,
                &row.link_id,
                "owner",
            )?;
        }
        let sent = self
            .send_body_as(
                &row,
                MessageType::Text,
                Body::Text(text.to_string()),
                wait,
                salt,
                None,
                addr,
            )
            .await?;
        if let Some(a) = used {
            self.receipt(
                &row.link_id,
                "owner",
                "send_message",
                "approved",
                "secret scanner: owner approved",
                Some(&sent.0),
                Some(&a),
            );
        }
        Ok(sent)
    }

    /// Sending a message of any type on a link (the caller has already checked the policy), by the owner or on behalf
    /// of our own agent (`agent` is the name the contact will see, v5, PROTOCOL §21): if the contact's node understands
    /// agent announcements, the message is signed with the agent's key in this link. `salt`: a streaming message's
    /// final message (v0.2). `addr`: the address and topic (v6, PROTOCOL §23), on the wire only to a node with
    /// `addr/0` (a file offer's address with `file-addr/0`).
    #[allow(
        clippy::too_many_arguments,
        reason = "the send inputs plus the stream salt, the agent's name and the address"
    )]
    pub(crate) async fn send_body_as(
        &self,
        row: &LinkRow,
        kind: MessageType,
        body: Body,
        wait: Duration,
        salt: Option<[u8; 32]>,
        agent: Option<String>,
        addr: &Addr,
    ) -> Result<(MessageId, SentReply)> {
        let rt = self.rt(&row.link_id)?;
        if let Some(e) = rt.shared.send_block() {
            return Err(e);
        }
        // The contact's features are not known yet (the link was just created, or there was no connection after an
        // update): find them out now, otherwise the agent's first message would go out on behalf of the owner
        // The same for an address: without the contact's features it would stay local only
        if (agent.is_some() || addr.to.is_some()) && rt.shared.peer_feat.load(Ordering::SeqCst) == 0
        {
            let _ = tokio::time::timeout(Duration::from_secs(3), rt.shared.connect_raw()).await;
        }
        let addressed = rt.shared.peer_supports_addr();
        let mut delivered = rt.shared.delivered.subscribe();
        // The `no_agent` answer comes as an event; subscribed before sending, so it cannot be missed
        let mut verdicts = self.events.subscribe();
        let sh = rt.shared.clone();
        let addr2 = addr.clone();
        let a = tokio::task::spawn_blocking(move || {
            sh.append_as(kind, body, salt, agent.as_deref(), &addr2)
        })
        .await
        .map_err(|e| Error::internal(e.to_string()))??;
        let (id, lamport, parents) = (a.id, a.lamport, a.parents);
        let _ = self.events.send(NodeEvent::Message {
            link: row.link_id,
            contact: row.label.clone(),
            trust: row.trust,
            item: Box::new(a.item),
        });
        rt.shared.kick.notify_one();
        let mut status = "queued";
        if !wait.is_zero() {
            let deadline = Instant::now() + wait;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match tokio::time::timeout(left, delivered.recv()).await {
                    Ok(Ok(m)) if m == id => {
                        status = "delivered";
                        break;
                    }
                    Ok(Ok(_)) | Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                    _ => break,
                }
            }
        }
        // To an agent the contact never announced: its node answers at once when nobody there has that name
        // (`no-agent/0`, PROTOCOL §23). Wait a moment for that answer, so the sender is told, not shown "delivered";
        // an announced agent is there (an answer about it still arrives later as an event)
        let mut no_agent = false;
        if status == "delivered"
            && rt.shared.peer_supports_no_agent()
            && let Some(antenna_proto::To::Agent(name)) = &addr.to
            && !self.peer_agents(&row.link_id).contains(name)
        {
            let hex_id = id.to_hex();
            let deadline = Instant::now() + NO_AGENT_WAIT;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match tokio::time::timeout(left, verdicts.recv()).await {
                    Ok(Ok(NodeEvent::Status {
                        id: m, status: s, ..
                    })) if m == hex_id && s == "no_agent" => {
                        no_agent = true;
                        break;
                    }
                    Ok(Ok(_)) | Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                    _ => break,
                }
            }
        }
        Ok((
            id,
            SentReply {
                id: id.to_hex(),
                status: status.into(),
                lamport,
                parents: parents.iter().map(MessageId::to_hex).collect(),
                to: to_view(addr.to.as_ref()).0,
                to_agent: to_view(addr.to.as_ref()).1,
                topic: topic_view(addr.topic.as_ref()),
                addressed: (kind == MessageType::Text).then_some(addressed),
                no_agent,
                peer_agents: if no_agent {
                    self.peer_agents(&row.link_id)
                } else {
                    Vec::new()
                },
                urgent: addr.urgent.then(|| rt.shared.peer_supports_urgent()),
                local: false,
            },
        ))
    }

    /// The agents the contact announced in this link and did not revoke: the names one can address there (§21).
    pub(crate) fn peer_agents(&self, link: &LinkId) -> Vec<String> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        crate::agentid::all(db.conn(), link)
            .map(|keys| {
                keys.into_iter()
                    .filter(|k| !k.mine && k.revoked_n.is_none())
                    .map(|k| k.name)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// A receipt of an action at the contact's request: a signed `receipt` message in the link's shared history
    /// (SPEC §9, Q-16). Without text, trust level or labels of other links. If sending on the link is currently
    /// blocked (rollback, divergence) or the link is not running, only the local audit log entry remains.
    pub(crate) fn dag_receipt(
        &self,
        link: &LinkId,
        actor: &str,
        action: &str,
        decision: &str,
        refs: &[MessageId],
    ) {
        self.dag_receipt_numbered(link, actor, action, decision, refs, 0);
    }

    /// [`Session::dag_receipt`] with the number a received file's name got (`name_number`, D-128): it goes only to a
    /// contact whose node has `file-saved-as/0`; an older one gets the receipt without it, as before.
    pub(crate) fn dag_receipt_numbered(
        &self,
        link: &LinkId,
        actor: &str,
        action: &str,
        decision: &str,
        refs: &[MessageId],
        name_number: u32,
    ) {
        self.dag_receipt_with(
            link,
            actor,
            action,
            decision,
            refs,
            ReceiptExtra {
                name_number,
                ..Default::default()
            },
        );
    }

    /// A file's fate for its sender (D-130, `file-fate/0`): `check_file` / `held` with why and the rules goes only to
    /// a contact whose node has the feature (an older one would refuse the unknown action and the histories would
    /// differ); on `reject_file` / `denied` the reason rides only to such a node, an older one gets the receipt as
    /// before.
    pub(crate) fn dag_receipt_fate(
        &self,
        link: &LinkId,
        action: &str,
        decision: &str,
        refs: &[MessageId],
        why: &str,
        rules: &[String],
    ) {
        if action == "check_file"
            && !self
                .rt(link)
                .is_ok_and(|rt| rt.shared.peer_supports_file_fate())
        {
            return;
        }
        self.dag_receipt_with(
            link,
            "owner",
            action,
            decision,
            refs,
            ReceiptExtra {
                name_number: 0,
                why: why.to_string(),
                rules: rules.to_vec(),
            },
        );
    }

    /// The receipt with its optional fields, each gated by the contact's features here, in one place.
    fn dag_receipt_with(
        &self,
        link: &LinkId,
        actor: &str,
        action: &str,
        decision: &str,
        refs: &[MessageId],
        extra: ReceiptExtra,
    ) {
        let Ok(rt) = self.rt(link) else {
            return;
        };
        if rt.shared.send_block().is_some() {
            return;
        }
        let name_number = if rt.shared.peer_supports_file_saved_as() {
            extra.name_number
        } else {
            0
        };
        let (why, rules) = if rt.shared.peer_supports_file_fate() && !extra.why.is_empty() {
            (
                extra.why,
                antenna_proto::files::fate::wire_rules(extra.rules.iter().map(String::as_str)),
            )
        } else {
            (String::new(), Vec::new())
        };
        // An agent appears under the same name as in its messages to the contact (the wake agent as `wake`, without
        // the contact label); also before a batch of check receipts (D-78, item 2)
        let actor = if actor == "owner" {
            actor.to_string()
        } else {
            self.agent_public_name(actor, link)
        };
        let actor = actor.as_str();
        // SPEC §4: "read" goes only to contacts of level 3+
        if action.starts_with("read_") && rt.shared.trust.load(Ordering::SeqCst) < 3 {
            return;
        }
        // Agent tool checks for contacts of levels 1–2 are batched over 10 minutes (Q-22): details stay in the local
        // audit log, so the contact does not bloat the shared history with its requests
        if action.starts_with("check:")
            && refs.is_empty()
            && rt.shared.trust.load(Ordering::SeqCst) <= 2
        {
            let mut g = self
                .check_batch
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if g.len() < 4096 {
                let e = g
                    .entry((*link, actor.into(), action.into(), decision.into()))
                    .or_insert((now_ms(), 0));
                // The recipient accepts `count` ≤ 10⁶ (linksync `check_body`)
                e.1 = e.1.saturating_add(1).min(1_000_000);
            }
            return;
        }
        // Identical receipts without references (agent hooks call `check` for every tool): at most once a minute
        if refs.is_empty() {
            let key = format!("{}:{action}:{decision}", link.to_hex());
            let now = now_ms();
            let mut g = self.dag_rl.lock().unwrap_or_else(PoisonError::into_inner);
            if g.get(&key)
                .is_some_and(|t| now.saturating_sub(*t) < policy::RATE_WINDOW_MS)
            {
                return;
            }
            if g.len() > 4096 {
                g.clear();
            }
            g.insert(key, now);
        }
        let clip = |s: &str| {
            s.chars()
                .take(antenna_proto::ReceiptBody::MAX_FIELD)
                .collect::<String>()
        };
        let body = Body::Receipt(ReceiptBody {
            actor: clip(actor),
            action: clip(action),
            decision: clip(decision),
            refs: refs
                .iter()
                .take(antenna_proto::ReceiptBody::MAX_REFS)
                .copied()
                .collect(),
            count: 0,
            name_number,
            why,
            rules,
        });
        match rt.shared.append(MessageType::Receipt, body) {
            Ok(a) => {
                let _ = self.events.send(NodeEvent::Message {
                    link: *link,
                    contact: rt.shared.label.clone(),
                    trust: rt.shared.trust.load(Ordering::SeqCst),
                    item: Box::new(a.item),
                });
                rt.shared.kick.notify_one();
            }
            Err(e) => tracing::warn!("receipt into the shared history: {e}"),
        }
    }

    /// Write the accumulated batches of check receipts (Q-22): those older than 10 minutes or all (`all`).
    pub(crate) fn flush_check_batches(&self, all: bool) {
        let now = now_ms();
        let due: Vec<(CheckKey, u32)> = {
            let mut g = self
                .check_batch
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let keys: Vec<_> = g
                .iter()
                .filter(|(_, (first, _))| all || now.saturating_sub(*first) >= CHECK_BATCH_MS)
                .map(|(k, _)| k.clone())
                .collect();
            keys.into_iter()
                .filter_map(|k| g.remove(&k).map(|(_, n)| (k, n)))
                .collect()
        };
        for ((link, actor, action, decision), n) in due {
            let Ok(rt) = self.rt(&link) else { continue };
            if rt.shared.send_block().is_some() {
                continue;
            }
            let body = Body::Receipt(ReceiptBody {
                actor: actor
                    .chars()
                    .take(antenna_proto::ReceiptBody::MAX_FIELD)
                    .collect(),
                action,
                decision,
                refs: vec![],
                count: n,
                name_number: 0,
                why: String::new(),
                rules: vec![],
            });
            match rt.shared.append(MessageType::Receipt, body) {
                Ok(a) => {
                    let _ = self.events.send(NodeEvent::Message {
                        link,
                        contact: rt.shared.label.clone(),
                        trust: rt.shared.trust.load(Ordering::SeqCst),
                        item: Box::new(a.item),
                    });
                    rt.shared.kick.notify_one();
                }
                Err(e) => tracing::warn!("receipt batch into the shared history: {e}"),
            }
        }
    }

    /// `antenna inbox [--wait]`: the owner's unread incoming messages (marked as read); `contact`: only from that
    /// contact.
    pub async fn inbox(
        &self,
        wait: bool,
        timeout: Option<Duration>,
        contact: Option<&str>,
    ) -> Result<InboxReply> {
        let only = contact
            .map(|c| self.find_link(c))
            .transpose()?
            .map(|r| r.link_id);
        let mut rx = self.inbox.subscribe();
        let deadline = timeout.map(|t| Instant::now() + t);
        loop {
            if self.is_closed() {
                return Err(Error::new(code::LOCKED, "keystore was locked"));
            }
            rx.mark_unchanged();
            let rows = {
                let mut db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                let rows: Vec<_> = db
                    .unread()?
                    .into_iter()
                    .filter(|r| only.is_none_or(|l| l == r.link_id))
                    .collect();
                let seqs: Vec<i64> = rows.iter().map(|r| r.seq).collect();
                db.mark_read(&seqs)?;
                rows
            };
            if !rows.is_empty() || !wait {
                return Ok(InboxReply {
                    messages: rows
                        .into_iter()
                        .map(|r| InboxMessage {
                            id: r.id.to_hex(),
                            contact: r.label,
                            link_id: r.link_id.to_hex(),
                            trust: r.trust,
                            kind: r.kind,
                            text: r.body,
                            ts: r.ts,
                            received_ms: r.received_ms,
                            lamport: r.lamport,
                            parents: r.parents.iter().map(MessageId::to_hex).collect(),
                            via_agent: r.agent,
                            to: to_view(r.to.as_ref()).0,
                            to_agent: to_view(r.to.as_ref()).1,
                            topic: topic_view(r.topic.as_ref()),
                        })
                        .collect(),
                });
            }
            let changed = rx.changed();
            match deadline {
                Some(d) => {
                    let left = d.saturating_duration_since(Instant::now());
                    if tokio::time::timeout(left, changed).await.is_err() {
                        return Ok(InboxReply { messages: vec![] });
                    }
                }
                None => {
                    let _ = changed.await;
                }
            }
        }
    }

    /// `antenna contacts`.
    pub async fn contacts(&self) -> Result<ContactsReply> {
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?;
        let mut out = Vec::new();
        for row in rows {
            let (session_version, pq_ratchet, outbox, failed, heads) = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                let (v, pq) = e2e::session_info(db.conn(), &row.link_id, &row.sig_remote_addr)?;
                let outbox = db.outbox_len(&row.link_id)?;
                let failed = db.failed_len(&row.link_id)?;
                let heads = Db::heads(db.conn(), &row.link_id)?;
                (v, pq, outbox, failed, heads)
            };
            let rt = self
                .links
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&row.link_id)
                .cloned();
            let (local_endpoint, local_addrs, connected, live_paths) = match &rt {
                Some(rt) => {
                    let h = transport::addr_hints(&rt.shared.endpoint, rt.shared.mode);
                    let mut addrs: Vec<String> =
                        h.relay.into_iter().map(|r| format!("relay:{r}")).collect();
                    addrs.extend(h.direct.into_iter().map(|d| format!("ip:{d}")));
                    let conn = rt.shared.live_conn();
                    (
                        hex(rt.shared.endpoint.id().as_bytes()),
                        addrs,
                        conn.is_some(),
                        conn.map(|c| transport::describe_paths(&c)),
                    )
                }
                None => (String::new(), Vec::new(), false, None),
            };
            let relay = rt
                .as_ref()
                .filter(|rt| self.cfg.net.relay.enabled() && !rt.shared.endpoint.is_closed())
                .map(|rt| transport::home_relay(&rt.shared.endpoint));
            // Separately: the DB lock must not be held while the verification state takes it again
            let unread = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .unread_count(&row.link_id)?;
            let history = rt.as_ref().map(|rt| rt.shared.status());
            // The contact's agents (v5): sub-identities it announced in this link
            let peer_kind = match &rt {
                Some(rt) => rt.shared.peer_kind(),
                None => peer_kind_name(
                    self.db
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .peer_kind_flags(&row.link_id)?,
                    false,
                )
                .into(),
            };
            let agents = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                crate::agentid::all(db.conn(), &row.link_id)?
                    .into_iter()
                    .filter(|k| !k.mine)
                    .map(|k| antenna_proto::control::PeerAgent {
                        name: k.name,
                        state: if k.revoked_n.is_some() {
                            antenna_proto::AgentAnnounce::REVOKED
                        } else {
                            antenna_proto::AgentAnnounce::ACTIVE
                        }
                        .into(),
                        since_ms: k.announced_ms,
                    })
                    .collect::<Vec<_>>()
            };
            out.push(ContactInfo {
                label: row.label.clone(),
                link_id: row.link_id.to_hex(),
                trust: row.trust,
                net_mode: row.net_mode.as_str().into(),
                role: row.role.as_str().into(),
                created_ms: row.created_ms,
                peer_endpoint: hex(&row.peer_endpoint),
                local_endpoint,
                local_addrs,
                e2e: E2eInfo {
                    session_version,
                    pq_ratchet,
                    last_rx_version: row.last_rx_version,
                    last_rx_pq_len: row.last_rx_pq_len,
                },
                transport: TransportInfo {
                    pairing_kx_group: row.pairing_kx.clone(),
                    last_kx_group: row.last_kx.clone(),
                    connected,
                    last_paths: live_paths.unwrap_or(row.last_paths.clone()),
                    relay,
                },
                outbox,
                failed,
                heads: heads.iter().map(MessageId::to_hex).collect(),
                lamport: row.lamport,
                presence: events::presence(row.trust, connected).into(),
                peer_kind,
                agents,
                peer_addressing: rt.as_ref().is_some_and(|rt| rt.shared.peer_supports_addr()),
                peer_file_withdraw: rt
                    .as_ref()
                    .is_some_and(|rt| rt.shared.peer_supports_file_withdraw()),
                peer_urgent: rt
                    .as_ref()
                    .is_some_and(|rt| rt.shared.peer_supports_urgent()),
                unread,
                rights: Some(policy::rights(row.trust)),
                history,
                file_allow: self.file_allow_entries(&row.link_id),
                save_dirs: self.save_dirs(&row.link_id),
            });
        }
        Ok(ContactsReply { contacts: out })
    }
}

impl Session {
    /// Links for LAN: level 3+ (link, pseudonym key, the contact's EndpointId).
    pub(crate) fn lan_eligible(&self) -> Vec<(LinkId, crate::crypto::Secret32, [u8; 32])> {
        self.running_links()
            .into_iter()
            .filter(|rt| rt.shared.lan_eligible())
            .map(|rt| {
                (
                    rt.shared.link_id,
                    rt.shared.lan_key(),
                    *rt.shared.peer.as_bytes(),
                )
            })
            .collect()
    }

    /// Links whose contact is connected right now (no reason to announce for them).
    pub(crate) fn lan_connected_links(&self) -> Vec<LinkId> {
        self.running_links()
            .into_iter()
            .filter(|rt| rt.shared.live_conn().is_some())
            .map(|rt| rt.shared.link_id)
            .collect()
    }

    /// The contact was found on the local network: connect (the addresses are hints, TLS checks the key) and deliver
    /// the queue.
    pub(crate) fn lan_connect(&self, link: &LinkId) {
        let Ok(rt) = self.rt(link) else { return };
        let sh = rt.shared.clone();
        if sh.live_conn().is_some() || !sh.lan_eligible() {
            return;
        }
        tokio::spawn(async move {
            match sh.connect_raw().await {
                Ok(_) => {
                    tracing::info!("link {}: connected over the local network", sh.short());
                    sh.kick.notify_one();
                }
                Err(e) => tracing::debug!("link {}: lan connect: {e}", sh.short()),
            }
        });
    }

    /// `antenna lan on|off` (the caller has checked the password for turning it on).
    pub fn lan_set(self: &Arc<Self>, enabled: bool) -> Result<LanReply> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .meta_set(crate::lan::META_KEY, if enabled { "on" } else { "off" })?;
        if enabled {
            self.lan.start(Arc::downgrade(self));
            // Links waiting for delivery without a connection: announce right away (delivery may be waiting for a
            // timeout on old addresses) and try again
            for rt in self.running_links() {
                rt.shared.lan_on_failure();
                rt.shared.kick.notify_one();
            }
        } else {
            self.lan.stop();
        }
        Ok(self.lan_status())
    }

    /// `antenna lan`.
    pub fn lan_status(&self) -> LanReply {
        let links: Vec<(String, LinkId)> = self
            .running_links()
            .into_iter()
            .filter(|rt| rt.shared.lan_eligible())
            .map(|rt| (rt.shared.label.clone(), rt.shared.link_id))
            .collect();
        self.lan.status(&links)
    }

    /// `antenna trust <contact> <level>` (the caller has checked the password). Switching 1–2 ↔ 3–5 changes the link's
    /// network mode (SPEC §4): the link is restarted with the same endpoint key.
    pub async fn set_trust(&self, contact: &str, level: u8) -> Result<ContactsReply> {
        if !(1..=5).contains(&level) {
            return Err(Error::bad_request("trust must be 1..5"));
        }
        let row = self.find_link(contact)?;
        let new_mode = NetMode::for_trust(level);
        if new_mode == NetMode::RelayOnly && !self.cfg.net.relay.enabled() {
            return Err(Error::bad_request(
                "trust 1–2 means relay-only, and this node runs with relay disabled",
            ));
        }
        let old = row.trust;
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set_trust(&row.link_id, level)?;
        // Below ∞ the contact is not an own device: its keys no longer answer approvals here, also after a raise
        // back to 5 (the owner confirms them again)
        if old == 5 && level < 5 {
            self.device_keys_forget(&row.link_id, &[])?;
        }
        // A request made before this trust change is the person's to answer; approvers on a computer below ∞ are gone
        // (PG-57)
        self.delegation_trust_changed(&row.link_id, old, level);
        if new_mode != row.net_mode {
            let rt = self
                .links
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&row.link_id);
            if let Some(rt) = rt {
                rt.stop().await;
            }
            let fresh = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .link(&row.link_id)?;
            self.start_saved_link(&fresh).await?;
        } else if let Some(rt) = self
            .links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&row.link_id)
        {
            rt.shared.trust.store(level, Ordering::SeqCst);
            rt.shared.emit_contact();
        }
        self.receipt(
            &row.link_id,
            "owner",
            "trust",
            "changed",
            &format!("{old} -> {level}"),
            None,
            None,
        );
        let all = self.contacts().await?;
        Ok(ContactsReply {
            contacts: all
                .contacts
                .into_iter()
                .filter(|c| c.link_id == row.link_id.to_hex())
                .collect(),
        })
    }

    /// An entry in the link's audit log (a write error does not fail the action, but goes to the daemon log).
    #[allow(
        clippy::too_many_arguments,
        reason = "one argument per column of the audit log entry"
    )]
    pub(crate) fn receipt(
        &self,
        link: &LinkId,
        actor: &str,
        action: &str,
        decision: &str,
        reason: &str,
        msg_id: Option<&MessageId>,
        approval_id: Option<&str>,
    ) {
        let r = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .receipt_add(
                &NewReceipt {
                    link,
                    actor,
                    action,
                    decision,
                    reason,
                    msg_id,
                    approval_id,
                },
                now_ms(),
            );
        if let Err(e) = r {
            tracing::warn!("audit log: {e}");
        }
    }

    /// Limit refusal entries: at most once a minute per link (otherwise an agent floods the audit log).
    pub(crate) fn receipt_due(&self, link: &LinkId) -> bool {
        let now = now_ms();
        let mut g = self
            .rl_receipts
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match g.get(link) {
            Some(t) if now.saturating_sub(*t) < policy::RATE_WINDOW_MS => false,
            _ => {
                g.insert(*link, now);
                true
            }
        }
    }

    /// `antenna log <contact>`: receipts from the link's shared history (signed, visible to both sides, SPEC §9, Q-16)
    /// and this node's local entries (level changes, limits, policy details), by time.
    pub fn log(&self, row: &LinkRow, limit: Option<u32>) -> Result<Vec<ReceiptInfo>> {
        let limit = limit.unwrap_or(100).min(1000);
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut out: Vec<ReceiptInfo> = db
            .receipts(&row.link_id, limit)?
            .into_iter()
            .map(|r| ReceiptInfo {
                seq: r.seq,
                ts: r.ts,
                actor: r.actor,
                action: r.action,
                decision: r.decision,
                reason: r.reason,
                message_id: r.msg_id.map(|m| m.to_hex()),
                approval_id: r.approval_id,
                source: "local".into(),
                author: String::new(),
                refs: vec![],
            })
            .collect();
        out.extend(
            db.dag_receipts(&row.link_id, limit)?
                .iter()
                .filter_map(|m| crate::linksync::dag_receipt_info(m, &row.root_ed25519_pk)),
        );
        out.sort_by_key(|r| (r.ts, r.source == "dag"));
        let skip = out.len().saturating_sub(limit as usize);
        Ok(out.into_iter().skip(skip).collect())
    }
}

impl Session {
    /// `history`: a page of the link history (v1).
    pub fn history(
        &self,
        row: &LinkRow,
        after: i64,
        before: Option<i64>,
        limit: Option<u32>,
    ) -> Result<antenna_proto::control::HistoryReply> {
        self.history_of(row, after, before, limit, None)
    }

    /// `history` of one chat of the link (v7, CONTROL §26): `chat` is the contact's agent, `""` the person chat;
    /// `None` is the whole link.
    pub fn history_of(
        &self,
        row: &LinkRow,
        after: i64,
        before: Option<i64>,
        limit: Option<u32>,
        chat: Option<&str>,
    ) -> Result<antenna_proto::control::HistoryReply> {
        let limit = limit.unwrap_or(50).clamp(1, 500);
        let filter = crate::store::HistoryFilter {
            chat,
            messages_only: false,
        };
        let (rows, more) = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .history_in(&row.link_id, after, before, limit, &filter)?;
        let next_before = if more {
            rows.first().map(|r| r.seq)
        } else {
            None
        };
        Ok(antenna_proto::control::HistoryReply {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            messages: rows.into_iter().map(history_item).collect(),
            next_before,
        })
    }

    /// Whether the link has a connection right now.
    pub(crate) fn is_connected(&self, link: &LinkId) -> bool {
        self.links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(link)
            .is_some_and(|rt| rt.shared.live_conn().is_some())
    }
}

/// A stored history row as the control protocol shows it (`history`, the latest message of a chat).
pub(crate) fn history_item(r: crate::store::HistoryRow) -> HistoryItem {
    HistoryItem {
        seq: r.seq,
        id: r.id.to_hex(),
        direction: if r.incoming { "in" } else { "out" }.into(),
        kind: r.kind,
        text: r.body,
        ts: r.ts,
        local_ms: r.local_ms,
        lamport: r.lamport,
        status: r.status.into(),
        receipt: r.receipt.map(|x| ReceiptView {
            actor: x.actor,
            action: x.action,
            decision: x.decision,
            refs: x.refs.iter().map(MessageId::to_hex).collect(),
            name_number: Some(x.name_number).filter(|n| *n != 0),
            why: Some(x.why).filter(|w| !w.is_empty()),
            rules: x.rules,
        }),
        via_agent: r.agent,
        to: r.to.as_ref().map(|t| t.0.clone()),
        to_agent: r.to.and_then(|t| t.1),
        topic: r.topic.map(|(id, title)| TopicView {
            id: data_encoding::HEXLOWER.encode(&id),
            title,
        }),
        unread: r.unread,
        no_agent: r.no_agent,
        urgent: r.urgent,
    }
}

// Slice 3: history verification, rekey, revoke, rename, read state

impl Session {
    /// `history_status`: the link's history verification state.
    pub fn history_status(
        &self,
        row: &LinkRow,
    ) -> Result<antenna_proto::control::HistoryStatusReply> {
        let rt = self.rt(&row.link_id)?;
        Ok(antenna_proto::control::HistoryStatusReply {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            status: rt.shared.status(),
        })
    }

    /// `antenna verify`: verify the history now (connect, exchange summaries, resend, locate the place). `accept` is
    /// the owner's decision on a divergence: lift read-only mode. `repair` restores our own damaged copy from the
    /// contact's copy (the author's signature is checked). The caller has checked the password for `accept`.
    pub async fn verify(
        &self,
        row: &LinkRow,
        accept: bool,
        repair: bool,
    ) -> Result<antenna_proto::control::HistoryStatusReply> {
        let rt = self.rt(&row.link_id)?;
        let sh = rt.shared.clone();
        if accept {
            let had = {
                let mut h = sh.hist.lock().unwrap_or_else(PoisonError::into_inner);
                match h.conflict.as_mut() {
                    Some(c) => {
                        c.accepted = true;
                        true
                    }
                    None => false,
                }
            };
            if !had {
                return Err(Error::bad_request(
                    "there is no history divergence to accept on this link",
                ));
            }
            sh.save_note();
            self.receipt(
                &row.link_id,
                "owner",
                "history",
                "divergence_accepted",
                "the owner accepted the divergence; the link is writable again",
                None,
                None,
            );
            sh.emit_history();
            sh.kick.notify_one();
        }
        if repair {
            let id = {
                let mut h = sh.hist.lock().unwrap_or_else(PoisonError::into_inner);
                let id = h
                    .conflict
                    .as_ref()
                    .filter(|c| c.reason == "local_copy_damaged")
                    .and_then(|c| c.my_id.clone());
                if let Some(id) = &id
                    && let Ok(v) = data_encoding::HEXLOWER.decode(id.as_bytes())
                    && let Ok(a) = <[u8; 32]>::try_from(v)
                {
                    h.repair_ids.insert(MessageId(a));
                }
                id
            };
            let Some(id) = id else {
                return Err(Error::bad_request(
                    "nothing to repair: only a locally damaged copy (same message ID) can be restored from                      the contact's copy",
                ));
            };
            let ids: Vec<MessageId> = data_encoding::HEXLOWER
                .decode(id.as_bytes())
                .ok()
                .and_then(|v| <[u8; 32]>::try_from(v).ok())
                .map(MessageId)
                .into_iter()
                .collect();
            let conn = sh.connect_raw().await?;
            match request(&conn, &LinkRequest::Want { ids }).await? {
                LinkResponse::Ok => {}
                other => return Err(Error::network(format!("repair refused: {other:?}"))),
            }
            // The resend arrives as a separate request; the copy is rechecked at the next verification
            let t = Instant::now();
            while t.elapsed() < Duration::from_secs(5)
                && !sh
                    .hist
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .repair_ids
                    .is_empty()
            {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        // Verify now: anew, even if it already happened on this connection
        let conn = sh.connect_raw().await?;
        {
            let _g = sh.sync_lock.lock().await;
            sh.hist
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .synced_conn = None;
            sh.sync_on(&conn).await?;
            sh.hist
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .synced_conn = Some(conn.stable_id());
        }
        // The contact may resend in reply: wait until verification converges (≤ 3 s)
        let t = Instant::now();
        while t.elapsed() < Duration::from_secs(3) && sh.status().state == "syncing" {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _g = sh.sync_lock.lock().await;
            let _ = sh.sync_on(&conn).await;
        }
        sh.kick.notify_one();
        self.history_status(row)
    }

    /// `antenna rekey` (password checked): link rekey after a rollback (SPEC §8, PROTOCOL §17). Both owners type the
    /// other's code: the rolled-back side offers a fresh bundle and reads out the first code; the other side types it,
    /// answers with the first message of the new session and reads out the second code; the rolled-back side types the
    /// second code, and only then is the session created and the block lifted (the answer could have been sent by
    /// someone who stole a copy of the contact's keys).
    pub async fn rekey(
        &self,
        row: &LinkRow,
        code: Option<&str>,
    ) -> Result<(String, &'static str, Option<String>)> {
        let rt = self.rt(&row.link_id)?;
        let sh = rt.shared.clone();
        if let Some(code) = code {
            let got = antenna_proto::sas::parse_input(code).unwrap_or_default();
            let matches = |want: &str| crate::crypto::ct_eq(got.as_bytes(), want.as_bytes());
            // Second code: I offered, the contact answered, its owner read out the answer's code
            let init_code = sh.init_code();
            if let Some(want) = &init_code
                && matches(want)
            {
                let sh2 = sh.clone();
                let typed = got.clone();
                let ack = tokio::task::spawn_blocking(move || sh2.confirm_rekey_init(&typed))
                    .await
                    .map_err(|e| Error::internal(e.to_string()))??;
                self.send_rekey_ack(&sh, ack).await;
                return Ok((row.label.clone(), "done", None));
            }
            // First code: accept the contact's offer
            let (offer, pending) = {
                let r = sh.rekey.lock().unwrap_or_else(PoisonError::into_inner);
                (r.offer.clone(), r.awaiting_ack.clone())
            };
            let fresh = |at: u64| at + 10 * 60 * 1000 > now_ms();
            // A repeat (dropped connection, restart): the offer is already accepted, so send the same answer, not a new
            // one (the contact would treat two different answers as a conflict)
            if let Some((hash, init, at)) = pending
                && fresh(at)
                && matches(&crate::history::rekey_code(&row.link_id, &hash))
            {
                return self.finish_rekey_as_acceptor(&sh, hash, init).await;
            }
            if let Some((bundle, hash, _)) = offer.filter(|(_, _, at)| fresh(*at)) {
                if !matches(&crate::history::rekey_code(&row.link_id, &hash)) {
                    return Err(Error::new(
                        code::SAS_MISMATCH,
                        "this is not the code of the contact's re-keying request: type the code they read out",
                    ));
                }
                let sh2 = sh.clone();
                let init = tokio::task::spawn_blocking(move || sh2.accept_offer(&bundle, &hash))
                    .await
                    .map_err(|e| Error::internal(e.to_string()))??;
                return self.finish_rekey_as_acceptor(&sh, hash, init).await;
            }
            if init_code.is_some() {
                return Err(Error::new(
                    code::SAS_MISMATCH,
                    "this is not the code the contact read out after accepting your re-keying: type their code",
                ));
            }
            if sh.rekey_code_known(&got) {
                return Err(Error::new(
                    code::NOT_FOUND,
                    "the re-keying request with this code expired or was discarded (two different requests came from \
                     the contact's keys): ask the contact to start again with `antenna rekey` and read out the new code",
                ));
            }
            return Err(Error::new(
                code::NOT_FOUND,
                "no re-keying request from this contact (or it expired): ask them to run `antenna rekey`",
            ));
        }
        // Without a code: offer a fresh bundle; only the rolled-back side can do that
        if !sh.rolled_back() {
            return Err(Error::new(
                code::BAD_REQUEST,
                "this side was not rolled back: the side with the rollback offers re-keying and reads out its code; \
                 confirm it here with `antenna rekey <contact> --code <code>`",
            ));
        }
        if sh.init_code().is_some() {
            return Err(Error::new(
                code::BAD_REQUEST,
                "the contact already accepted your re-keying: type the code they read out with \
                 `antenna rekey <contact> --code <code>`",
            ));
        }
        let sh2 = sh.clone();
        let offer = tokio::task::spawn_blocking(move || sh2.make_offer())
            .await
            .map_err(|e| Error::internal(e.to_string()))??;
        let my_code =
            crate::history::rekey_code(&row.link_id, &crate::crypto::sha256(&[&offer.bundle]));
        let conn = sh.connect_raw().await?;
        match request(&conn, &LinkRequest::RekeyOffer(offer)).await? {
            LinkResponse::Pending => {
                let _ = self.events.send(NodeEvent::Rekey {
                    link: row.link_id,
                    contact: row.label.clone(),
                    state: "waiting_for_contact",
                });
                Ok((row.label.clone(), "waiting_for_contact", Some(my_code)))
            }
            LinkResponse::Rejected { reason } => Err(Error::new(
                code::PAIRING_FAILED,
                format!("the contact refused the re-keying offer: {reason}"),
            )),
            other => Err(Error::network(format!("unexpected answer: {other:?}"))),
        }
    }

    /// The side that accepted the offer: send the answer (the first message of the new session). A `pending` reply
    /// means the contact's owner has not typed the second code yet: show it to our owner; `rekey_ack` means the contact
    /// has already confirmed (a repeat).
    async fn finish_rekey_as_acceptor(
        &self,
        sh: &Arc<LinkShared>,
        bundle_hash: [u8; 32],
        init: RoutingBlob,
    ) -> Result<(String, &'static str, Option<String>)> {
        let init_hash = crate::history::rekey_init_hash(&init)?;
        let conn = sh.connect_raw().await?;
        match request(&conn, &LinkRequest::RekeyInit { blob: init }).await? {
            LinkResponse::Pending => {
                let _ = self.events.send(NodeEvent::Rekey {
                    link: sh.link_id,
                    contact: sh.label.clone(),
                    state: "waiting_for_contact",
                });
                Ok((
                    sh.label.clone(),
                    "waiting_for_contact",
                    Some(crate::history::rekey_confirm_code(
                        &sh.link_id,
                        &bundle_hash,
                        &init_hash,
                    )),
                ))
            }
            LinkResponse::RekeyAck { blob } => {
                let sh2 = sh.clone();
                tokio::task::spawn_blocking(move || sh2.on_rekey_ack(&blob))
                    .await
                    .map_err(|e| Error::internal(e.to_string()))??;
                Ok((sh.label.clone(), "done", None))
            }
            LinkResponse::Rejected { reason } => Err(Error::new(
                code::PAIRING_FAILED,
                format!("the contact refused the re-keying: {reason}"),
            )),
            other => Err(Error::network(format!("unexpected answer: {other:?}"))),
        }
    }

    /// The rolled-back side confirmed the contact's answer: deliver the new session confirmation. If the contact is
    /// unreachable, retry in the background until the window ends (and a repeat of the contact's answer gets the same
    /// confirmation).
    async fn send_rekey_ack(&self, sh: &Arc<LinkShared>, ack: RoutingBlob) {
        async fn once(sh: &Arc<LinkShared>, ack: &RoutingBlob) -> Option<bool> {
            let conn = sh.connect_raw().await.ok()?;
            match request(&conn, &LinkRequest::RekeyAck { blob: ack.clone() }).await {
                Ok(LinkResponse::Ok) => Some(true),
                Ok(LinkResponse::Rejected { reason }) => {
                    tracing::warn!(
                        "link: the contact rejected the re-keying confirmation: {reason}"
                    );
                    Some(false)
                }
                _ => None,
            }
        }
        if once(sh, &ack).await.is_some() {
            return;
        }
        let sh = sh.clone();
        tokio::spawn(async move {
            let t = Instant::now();
            while t.elapsed() < Duration::from_secs(600) {
                tokio::time::sleep(Duration::from_secs(3)).await;
                if once(&sh, &ack).await.is_some() {
                    return;
                }
            }
        });
    }

    /// `antenna revoke` (password checked): the link stops, its keys are wiped, the channel is closed (SPEC §5, §13).
    pub async fn revoke(&self, row: &LinkRow, delete_history: bool) -> Result<()> {
        // This link's wake and its dedicated agent are no longer needed
        self.wake_off_link(&row.link_id);
        // Nothing about that computer as an own device stays (its confirmed keys first of all)
        self.devices_forget(&row.link_id);
        let rt = self
            .links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&row.link_id);
        if let Some(rt) = rt {
            rt.stop().await;
        }
        if let Some(f) = &self.files {
            f.purge_link(&row.link_id).await;
        }
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .revoke(&row.link_id, delete_history)?;
        if let Err(e) = self.statefile.remove(&row.link_id) {
            tracing::warn!("state counters: {e}");
        }
        tracing::info!("link {}: revoked", &row.link_id.to_hex()[..8]);
        Ok(())
    }

    /// Rename a contact.
    pub async fn rename(&self, row: &LinkRow, label: &str) -> Result<ContactsReply> {
        let label = label.trim();
        if label.is_empty() || label.chars().count() > 64 || label.chars().any(char::is_control) {
            return Err(Error::bad_request(
                "label: 1–64 characters, no control characters",
            ));
        }
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .rename(&row.link_id, label)?;
        // The label also lives in the running link (events, receipts): restart it with the new label
        let rt = self
            .links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&row.link_id);
        if let Some(rt) = rt {
            rt.stop().await;
        }
        let fresh = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&row.link_id)?;
        self.start_saved_link(&fresh).await?;
        let all = self.contacts().await?;
        Ok(ContactsReply {
            contacts: all
                .contacts
                .into_iter()
                .filter(|c| c.link_id == row.link_id.to_hex())
                .collect(),
        })
    }

    /// `topics` (v6): the link's topics, most recent first.
    pub fn topics(&self, row: &LinkRow) -> Result<Vec<antenna_proto::control::TopicInfo>> {
        Ok(self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .topics(&row.link_id)?
            .into_iter()
            .map(|t| antenna_proto::control::TopicInfo {
                id: data_encoding::HEXLOWER.encode(&t.id),
                title: t.title,
                count: t.count,
                last_seq: t.last_seq,
                last_ms: t.last_ms,
            })
            .collect())
    }

    /// `mark_read`: the link's incoming messages are read by the owner up to and including `seq`, and (v6) exactly the
    /// messages `ids` (a client that shows threads marks the thread it shows). With `chat` (v7, CONTROL §26; `""` is
    /// the person chat) only that chat's messages up to `seq` are marked, none of the link's other chats.
    pub async fn mark_read(
        &self,
        row: &LinkRow,
        up_to_seq: i64,
        ids: &[String],
        chat: Option<&str>,
    ) -> Result<ContactsReply> {
        if ids.len() > 500 {
            return Err(Error::bad_request("mark_read: at most 500 ids"));
        }
        let ids = ids
            .iter()
            .map(|h| {
                data_encoding::HEXLOWER_PERMISSIVE
                    .decode(h.as_bytes())
                    .ok()
                    .and_then(|v| <[u8; 32]>::try_from(v).ok())
                    .map(MessageId)
                    .ok_or_else(|| Error::bad_request("mark_read: ids are 64 hex characters"))
            })
            .collect::<Result<Vec<_>>>()?;
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            match chat {
                Some(chat) => {
                    crate::chats::mark_read(db.conn(), &row.link_id, chat, up_to_seq)?;
                }
                None => {
                    db.mark_read_upto(&row.link_id, up_to_seq)?;
                }
            }
            db.mark_read_ids(&row.link_id, &ids)?;
        }
        let all = self.contacts().await?;
        Ok(ContactsReply {
            contacts: all
                .contacts
                .into_iter()
                .filter(|c| c.link_id == row.link_id.to_hex())
                .collect(),
        })
    }
}

/// Compares the link state counters in the DB with the file outside the DB (SPEC §8): if the database has fallen
/// behind, the link is blocked until a rekey. A missing or damaged file with non-empty counters is also a rollback (the
/// safe side, D-45).
fn check_rollback(db: &Db, sf: &StateFile) -> Result<()> {
    let counters = db.state_counters()?;
    match sf.loaded() {
        Loaded::Ok => {
            for (link, c) in &counters {
                let f = sf.get(link);
                if *c < f {
                    tracing::warn!(
                        "link {}: database state counter {c} is behind the counter file ({f}): the database was \
                         restored from an older copy; sending is blocked until re-keying",
                        &link.to_hex()[..8]
                    );
                    db.set_blocked(link, Some("rolled_back:local_counter"))?;
                } else if *c > f {
                    sf.record(link, *c)?;
                }
            }
        }
        Loaded::Missing | Loaded::Damaged => {
            let why = if sf.loaded() == Loaded::Missing {
                "counter_file_missing"
            } else {
                "counter_file_damaged"
            };
            for (link, c) in &counters {
                if *c > 0 {
                    tracing::warn!(
                        "link {}: {why}: the link is blocked until re-keying",
                        &link.to_hex()[..8]
                    );
                    db.set_blocked(link, Some(&format!("rolled_back:{why}")))?;
                }
            }
            for (link, c) in &counters {
                sf.record(link, *c)?;
            }
            sf.flush()?;
        }
    }
    Ok(())
}

/// `peer_kind` from the facts: whether the contact announced agents, whether its owner wrote, whether the node
/// understands announcements.
fn peer_kind_name((agents, owner): (bool, bool), supports_agents: bool) -> &'static str {
    match (agents, owner) {
        (true, true) => "mixed",
        (true, false) => "agent",
        (false, true) if supports_agents => "human",
        _ => "unknown",
    }
}

/// Contact features from the DB → the [`LinkShared::peer_feat`] bits: [`FEAT_KNOWN`], [`FEAT_AGENTS`],
/// [`FEAT_ADDR`]; 0 means not known yet.
fn features_code(list: Option<&[String]>) -> u16 {
    match list {
        None => 0,
        Some(l) => {
            let has = |f: &str| l.iter().any(|x| x == f);
            FEAT_KNOWN
                | if has(antenna_proto::link::FEATURE_AGENTS) {
                    FEAT_AGENTS
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_ADDR) {
                    FEAT_ADDR
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_FILE_WITHDRAW) {
                    FEAT_FILE_WITHDRAW
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_DEVICE) {
                    FEAT_DEVICE
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_NO_AGENT) {
                    FEAT_NO_AGENT
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_STREAM_AGENT) {
                    FEAT_STREAM_AGENT
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_FILE_ADDR) {
                    FEAT_FILE_ADDR
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_PICTURE) {
                    FEAT_PICTURE
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_AGENT_CONNECT) {
                    FEAT_AGENT_CONNECT
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_AGENT_APPROVE) {
                    FEAT_AGENT_APPROVE
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_FILE_SAVED_AS) {
                    FEAT_FILE_SAVED_AS
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_FILE_FATE) {
                    FEAT_FILE_FATE
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_URGENT) {
                    FEAT_URGENT
                } else {
                    0
                }
                | if has(antenna_proto::link::FEATURE_AGENT_STOP) {
                    FEAT_AGENT_STOP
                } else {
                    0
                }
        }
    }
}

/// [`LinkShared::peer_feat`]: the contact's features are known (a `features` exchange happened).
const FEAT_KNOWN: u16 = 1;
/// The contact's node understands agent announcements (`agents/0`, PROTOCOL §21).
const FEAT_AGENTS: u16 = 2;
/// The contact's node understands addressing and topics (`addr/0`, PROTOCOL §23).
const FEAT_ADDR: u16 = 4;
/// The contact's node takes a file offer back on a `withdraw_file` receipt (`file-withdraw/0`, PROTOCOL §19).
const FEAT_FILE_WITHDRAW: u16 = 8;
/// The contact's node speaks own devices (`device/0`, PROTOCOL §24).
const FEAT_DEVICE: u16 = 32;
/// The contact's node understands a `deliver` / `no_such_agent` receipt (`no-agent/0`, PROTOCOL §23).
const FEAT_NO_AGENT: u16 = 16;
/// The contact's node understands profile pictures (`picture/0`, PROTOCOL §25).
const FEAT_PICTURE: u16 = 64;
/// The contact's node takes the writing agent's name in a stream opening (`stream-agent/0`, PROTOCOL §20).
const FEAT_STREAM_AGENT: u16 = 128;
/// The contact's node takes an address on a file offer (`file-addr/0`, PROTOCOL §19).
const FEAT_FILE_ADDR: u16 = 256;
/// The contact's node takes connections between agents inside `device` (`agent-connect/0`, PROTOCOL §24).
const FEAT_AGENT_CONNECT: u16 = 512;
/// The contact's node takes approver agents' answers and the approver fields inside `device` (`agent-approve/0`,
/// PROTOCOL §24, PG-57).
const FEAT_AGENT_APPROVE: u16 = 1024;
/// The contact's node takes `name_number` in an `accept_file` receipt (`file-saved-as/0`, PROTOCOL §19, D-128).
const FEAT_FILE_SAVED_AS: u16 = 2048;
/// The contact's node takes a file's fate: `check_file` / `held` and `why` with `rules` (`file-fate/0`, PROTOCOL §19,
/// D-130).
const FEAT_FILE_FATE: u16 = 4096;
/// The contact's node takes the owner's urgent flag in `core` (`urgent/0`, PROTOCOL §23, PG-58).
const FEAT_URGENT: u16 = 8192;
/// The contact's node stops its agents at its owner's request from an own computer (`agent-stop/0`, PROTOCOL §24,
/// PG-58).
pub(crate) const FEAT_AGENT_STOP: u16 = 16384;

fn ep_mode(m: NetMode) -> EpMode {
    match m {
        NetMode::RelayOnly => EpMode::RelayOnly,
        NetMode::Direct => EpMode::Direct,
    }
}

fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

// Link: endpoint, connection, delivery, receiving

pub(crate) struct LinkRt {
    pub(crate) shared: Arc<LinkShared>,
    router: Router,
    worker: tokio::task::JoinHandle<()>,
    idle: tokio::task::JoinHandle<()>,
}

impl LinkRt {
    async fn stop(&self) {
        self.worker.abort();
        self.idle.abort();
        let conn = self
            .shared
            .conn
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(c) = conn {
            c.close(0u32.into(), b"");
        }
        let _ = self.router.shutdown().await;
    }
}

pub(crate) struct LinkShared {
    pub(crate) link_id: LinkId,
    peer: EndpointId,
    endpoint: Endpoint,
    mode: EpMode,
    pub(crate) db: Arc<StdMutex<Db>>,
    pub(crate) sig_local: String,
    pub(crate) sig_remote: String,
    /// The contact's Ed25519 link-root (author of its messages, recipient of mine).
    pub(crate) peer_root: [u8; 32],
    /// Our own Ed25519 link-root (author of my messages).
    pub(crate) own_root: [u8; 32],
    /// History verification (slice 3).
    pub(crate) hist: StdMutex<HistState>,
    /// Link block (`rolled_back:<source>`), a mirror of `links.blocked`.
    pub(crate) blocked: StdMutex<Option<String>>,
    /// State counters outside the DB.
    pub(crate) statefile: Arc<StateFile>,
    /// Rekey after a rollback.
    pub(crate) rekey: StdMutex<RekeyState>,
    /// Verifications on a link run one at a time.
    pub(crate) sync_lock: Mutex<()>,
    conn: StdMutex<Option<Connection>>,
    pub(crate) kick: Notify,
    delivered: broadcast::Sender<MessageId>,
    pub(crate) inbox: watch::Sender<u64>,
    pub(crate) events: broadcast::Sender<NodeEvent>,
    pub(crate) label: String,
    cfg: Arc<NodeConfig>,
    announce: AtomicBool,
    /// History verification is needed (after a rekey), even if the queue is empty.
    pub(crate) sync_requested: AtomicBool,
    /// Current trust level for the contact (limits, presence).
    pub(crate) trust: AtomicU8,
    /// The last application activity on the connection (presence of levels 1–2, Q-8).
    last_active: StdMutex<Instant>,
    /// Incoming limit of the level (SPEC §9).
    in_limit: StdMutex<policy::RateLimiter>,
    /// Limit on the contact's verification and rekey service requests.
    ctl_limit: StdMutex<policy::RateLimiter>,
    /// Resend on `want`: at most one at a time.
    pub(crate) want_gate: tokio::sync::Semaphore,
    /// Queue of the session's file pipeline (file offers and requests).
    files_tx: Option<tokio::sync::mpsc::UnboundedSender<crate::files::Job>>,
    /// The contact's incoming streaming messages (v0.2): running and recently cut ones (the final message is
    /// recognized by salt).
    pub(crate) streams_in: StdMutex<crate::stream::InStreams>,
    /// The session's wake queue (v0.2): a new text message from the contact.
    wake_tx: tokio::sync::mpsc::UnboundedSender<crate::wake::WakeKick>,
    /// The node's rate limit of honoured urgent messages (PG-58).
    pub(crate) urgent: Arc<crate::urgent::Gate>,
    /// Requests of the contact's node as one of the owner's own devices (PROTOCOL §24), for the session.
    devices_tx: tokio::sync::mpsc::UnboundedSender<own_devices::Job>,
    /// The contact node's features (PROTOCOL §21, §23): bits [`FEAT_KNOWN`], [`FEAT_AGENTS`], [`FEAT_ADDR`]; 0 means
    /// not known yet (`FEAT_KNOWN` alone: a node without features, `0.1.0-preview.1`).
    pub(crate) peer_feat: AtomicU16,
    /// The last `peer_kind` sent to subscribers: a `contact` event when it changes.
    last_kind: StdMutex<String>,
    /// `peer_kind` cache: (the contact announced agents, the contact's owner wrote); `None` means not computed yet
    /// (D-78, item 12: without the cache, a pass over the messages under the DB lock for every incoming message).
    kind_flags: StdMutex<Option<(bool, bool)>>,
    /// The session's LAN (v5): contact addresses found on the local network and announcements when needed.
    lan: Arc<crate::lan::Lan>,
    _slot: PeerSlot,
}

impl std::fmt::Debug for LinkShared {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Link({})", &self.link_id.to_hex()[..8])
    }
}

impl LinkShared {
    pub(crate) fn short(&self) -> String {
        self.link_id.to_hex()[..8].to_string()
    }

    /// Application activity (presence of levels 1–2): for modules outside `node`.
    pub(crate) fn touch_pub(&self) {
        self.touch();
    }

    /// The level's incoming limit as back pressure (for modules outside `node`).
    pub(crate) async fn admit_incoming_pub(&self) -> bool {
        self.admit_incoming().await
    }

    fn touch(&self) {
        *self
            .last_active
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    /// The level's incoming limit (SPEC §9) as back pressure: wait for room in the window up to 10 s; if there is none,
    /// do not answer, and the sender retries from its queue (nothing is lost, the link format does not change).
    async fn admit_incoming(&self) -> bool {
        let deadline = Instant::now() + INCOMING_BACKPRESSURE;
        loop {
            let limit = policy::msgs_per_min(self.trust.load(Ordering::SeqCst));
            let r = self
                .in_limit
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .try_acquire(self.link_id, limit, now_ms());
            match r {
                Ok(()) => return true,
                Err(wait_ms) => {
                    let wait = Duration::from_millis(wait_ms);
                    if Instant::now() + wait > deadline {
                        tracing::info!(
                            "link {}: incoming over the level limit ({limit}/min), deferring the sender",
                            self.short()
                        );
                        return false;
                    }
                    tokio::time::sleep(wait).await;
                }
            }
        }
    }

    /// The contact's service requests (verification, locating the place, resend, rekey): at most [`CTL_PER_MIN`] per
    /// minute.
    fn admit_control(&self) -> bool {
        self.ctl_limit
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .try_acquire(self.link_id, CTL_PER_MIN, now_ms())
            .is_ok()
    }

    fn live_conn(&self) -> Option<Connection> {
        let g = self.conn.lock().unwrap_or_else(PoisonError::into_inner);
        g.as_ref().filter(|c| c.close_reason().is_none()).cloned()
    }

    /// A new connection (incoming or outgoing): transport facts, cache, serving incoming streams.
    fn adopt(self: &Arc<Self>, conn: Connection) {
        let kx = transport::kx_group(&conn).unwrap_or_else(|| "unknown".into());
        let paths = transport::describe_paths(&conn);
        let saved = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set_transport_facts(&self.link_id, &kx, &paths);
        if let Err(e) = saved {
            tracing::warn!("link {}: {e}", self.short());
        }
        *self.conn.lock().unwrap_or_else(PoisonError::into_inner) = Some(conn);
        self.touch();
        self.emit_contact();
    }

    /// Contact summary for subscribers.
    fn summary(&self) -> ContactSummary {
        let trust = self.trust.load(Ordering::SeqCst);
        ContactSummary {
            contact: self.label.clone(),
            link_id: self.link_id.to_hex(),
            trust,
            net_mode: match self.mode {
                EpMode::RelayOnly => "relay_only".into(),
                EpMode::Direct => "direct".into(),
            },
            presence: events::presence(trust, self.live_conn().is_some()).into(),
            peer_kind: self.peer_kind(),
        }
    }

    /// The contact's node understands agent announcements (v5): then this side's agents write with their own keys.
    pub(crate) fn peer_supports_agents(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_AGENTS != 0
    }

    /// The contact's node takes the writing agent's name in a stream opening (`stream-agent/0`, PROTOCOL §20).
    pub(crate) fn peer_supports_stream_agent(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_STREAM_AGENT != 0
    }

    /// The contact's node takes an address on a file offer (`file-addr/0`, PROTOCOL §19): only then does `to` go into
    /// the offer's `core` (a node without it refuses an address on anything but text).
    pub(crate) fn peer_supports_file_addr(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_FILE_ADDR != 0
    }

    /// The contact's node understands addressing and topics (v6, PROTOCOL §23): only then do `to` and `topic` go
    /// into `core` (a node without it refuses unknown fields).
    pub(crate) fn peer_supports_addr(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_ADDR != 0
    }

    /// The contact's node takes a file offer back on a `withdraw_file` receipt (PROTOCOL §19): only then is that receipt
    /// sent (a node without it refuses the receipt's unknown action).
    pub(crate) fn peer_supports_file_withdraw(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_FILE_WITHDRAW != 0
    }

    /// The contact's node takes `name_number` in an `accept_file` receipt (`file-saved-as/0`, D-128): only then does
    /// the number go into the receipt (a node without it parses receipts strictly).
    pub(crate) fn peer_supports_file_saved_as(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_FILE_SAVED_AS != 0
    }

    /// The contact's node takes a file's fate (`file-fate/0`, D-130): only then is a `check_file` / `held` receipt
    /// written, and `why` and `rules` ride on a blocking one (a node without it parses receipts strictly).
    pub(crate) fn peer_supports_file_fate(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_FILE_FATE != 0
    }

    /// The contact's node takes the owner's urgent flag (`urgent/0`, PG-58): only then does it go into `core` (a node
    /// without it parses `core` strictly).
    pub(crate) fn peer_supports_urgent(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_URGENT != 0
    }

    /// The contact's node stops its agents when this node's owner asks (`agent-stop/0`, PG-58).
    pub(crate) fn peer_supports_agent_stop(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_AGENT_STOP != 0
    }

    /// The contact's node understands a `deliver` / `no_such_agent` receipt (PROTOCOL §23): only then is that receipt
    /// written (a node without it refuses the receipt's unknown action).
    pub(crate) fn peer_supports_no_agent(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_NO_AGENT != 0
    }

    /// The contact's node understands profile pictures (PROTOCOL §25): only then is a picture message written (a node
    /// without it refuses the unknown body).
    pub(crate) fn peer_supports_picture(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_PICTURE != 0
    }

    /// Queue the picture messages the contact needs (PROTOCOL §25) and kick the delivery, off the async threads.
    fn spawn_picture_sync(self: &Arc<Self>) {
        if !self.peer_supports_picture() {
            return;
        }
        let me = self.clone();
        tokio::task::spawn_blocking(move || match me.sync_pictures() {
            Ok(0) => {}
            Ok(_) => me.kick.notify_one(),
            Err(e) => tracing::warn!("link {}: pictures: {e}", me.short()),
        });
    }

    /// The contact's node takes connections between agents (`agent-connect/0`, PROTOCOL §24): only then do
    /// `device.connect` and the connection fields of a status go to it (a node without it parses `device` strictly).
    pub(crate) fn peer_supports_agent_connect(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_AGENT_CONNECT != 0
    }

    /// The contact's node takes approver agents' answers (`agent-approve/0`, PG-57): only then do the approver fields
    /// of a status and `device.agent_challenge` / `agent_decide` go to it.
    pub(crate) fn peer_supports_agent_approve(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & FEAT_AGENT_APPROVE != 0
    }

    /// The contact's features are known (a `features` exchange happened on some connection).
    pub(crate) fn peer_features_known(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) != 0
    }

    /// Remember the contact's features (a `features` reply or request; `rejected` means a node without them).
    fn set_peer_features(&self, list: &[String]) {
        let list = antenna_proto::link::known_features(list);
        let code = features_code(Some(&list));
        if self.peer_feat.swap(code, Ordering::SeqCst) != code {
            tracing::debug!("link {}: contact features {:?}", self.short(), list);
            let _ = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .set_peer_features(&self.link_id, &list);
            self.emit_contact();
        }
    }

    /// Exchange features on a new connection (PROTOCOL §21). A `0.1.0-preview.1` node answers `rejected`.
    async fn exchange_features(self: &Arc<Self>, conn: &Connection) {
        let req = LinkRequest::Features {
            list: antenna_proto::link::FEATURES
                .iter()
                .map(|f| f.to_string())
                .collect(),
        };
        match request(conn, &req).await {
            Ok(LinkResponse::Features { list }) => {
                self.set_peer_features(&list);
                self.spawn_picture_sync();
            }
            Ok(LinkResponse::Rejected { reason }) if reason == "malformed" => {
                self.set_peer_features(&[])
            }
            // The service request limit, the network: we will find out on the next connection
            _ => {}
        }
    }

    /// The link is usable for LAN: our level for the contact is 3+ (direct mode, SPEC §4); levels 1–2 are relay only.
    pub(crate) fn lan_eligible(&self) -> bool {
        self.mode == EpMode::Direct && self.trust.load(Ordering::SeqCst) >= 3
    }

    /// The link's LAN pseudonym key (`lan::lan_key`).
    pub(crate) fn lan_key(&self) -> crate::crypto::Secret32 {
        crate::lan::lan_key(&self.link_id, &self.own_root, &self.peer_root)
    }

    /// The queue has messages but there is no connection (or delivery failed): if LAN is on and the link is usable,
    /// announce on the local network for another [`crate::lan::BEACON_FOR`].
    fn lan_on_failure(&self) {
        if !self.lan.enabled() || !self.lan_eligible() || self.live_conn().is_some() {
            return;
        }
        // Only when there is something to deliver, not for presence after unlock: otherwise every unlock would announce
        // all level 3+ links on the network, and a neighbor could count the contacts (D-78, item 8)
        let waiting = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .outbox_len(&self.link_id)
            .unwrap_or(0)
            > 0;
        if !waiting {
            return;
        }
        let addrs: Vec<std::net::SocketAddr> = transport::addr_hints(&self.endpoint, self.mode)
            .direct
            .iter()
            .filter_map(|a| a.parse().ok())
            .filter(|a: &std::net::SocketAddr| crate::lan::addr_ok(&a.ip()))
            .collect();
        self.lan.want_beacon(
            self.link_id,
            crate::lan::BeaconSpec {
                key: self.lan_key(),
                endpoint: *self.endpoint.id().as_bytes(),
                addrs,
            },
        );
    }

    /// Who writes from the other side (v5): `agent` / `mixed` means the contact announced agents (without and with the
    /// owner's messages), `human` means only the owner wrote and the node understands announcements, `unknown`
    /// otherwise.
    pub(crate) fn peer_kind(&self) -> String {
        let cached = *self
            .kind_flags
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let flags = match cached {
            Some(f) => f,
            None => {
                let f = self
                    .db
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .peer_kind_flags(&self.link_id)
                    .unwrap_or((false, false));
                *self
                    .kind_flags
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(f);
                f
            }
        };
        peer_kind_name(flags, self.peer_supports_agents()).into()
    }

    /// Update the `peer_kind` cache from what was received: the contact's agent announcements, its owner's messages.
    fn note_peer_kind(&self, rcv: &crate::linksync::Received) {
        let owner = rcv.items.iter().any(|i| {
            i.direction == "in"
                && matches!(i.kind.as_str(), "text" | "file" | "request")
                && i.via_agent.is_none()
        });
        let mut g = self
            .kind_flags
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some((agents, own)) = g.as_mut() {
            *agents |= rcv.agents;
            *own |= owner;
        }
    }

    fn picture_events(&self, subjects: &[String]) {
        if subjects.is_empty() {
            return;
        }
        let trust = self.trust.load(Ordering::SeqCst);
        let entries: Vec<_> = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            subjects
                .iter()
                .map(|s| {
                    crate::pictures::peer_entry_of(&db, &self.link_id, &self.label, trust, s)
                        .unwrap_or_else(|| antenna_proto::control::PictureEntry {
                            contact: Some(self.label.clone()),
                            link_id: Some(self.link_id.to_hex()),
                            agent: (!s.is_empty()).then(|| s.clone()),
                            ..Default::default()
                        })
                })
                .collect()
        };
        for e in entries {
            let _ = self.events.send(NodeEvent::Picture(Box::new(e)));
        }
    }

    fn emit_contact(&self) {
        let _ = self.events.send(NodeEvent::Contact {
            link: self.link_id,
            summary: self.summary(),
        });
    }

    fn emit_status(&self, id: &MessageId, status: &'static str) {
        let _ = self.events.send(NodeEvent::Status {
            link: self.link_id,
            contact: self.label.clone(),
            id: id.to_hex(),
            status,
        });
    }

    async fn serve(self: Arc<Self>, conn: Connection) {
        while let Ok((mut send, mut recv)) = conn.accept_bi().await {
            let me = self.clone();
            me.touch();
            let c2 = conn.clone();
            tokio::spawn(async move {
                let resp = match transport::read_frame(&mut recv, MAX_FRAME).await {
                    Ok(b) => match antenna_proto::from_cbor::<LinkRequest>(&b) {
                        // A streaming message (v0.2): chunk frames follow on the same QUIC stream
                        Ok(LinkRequest::StreamOpen { blob }) => {
                            me.serve_stream(blob, send, recv).await;
                            return;
                        }
                        Ok(LinkRequest::Deliver { .. }) if !me.admit_incoming().await => return,
                        Ok(req)
                            if !matches!(
                                req,
                                LinkRequest::Deliver { .. } | LinkRequest::Hello { .. }
                            ) && !me.admit_control() =>
                        {
                            LinkResponse::Rejected {
                                reason: code::RATE_LIMITED.into(),
                            }
                        }
                        Ok(req) => me.handle(req, &c2).await,
                        Err(_) => LinkResponse::Rejected {
                            reason: "malformed".into(),
                        },
                    },
                    Err(_) => return,
                };
                me.touch();
                if let Ok(b) = antenna_proto::to_cbor(&resp) {
                    let _ = transport::write_frame(&mut send, &b).await;
                    let _ = send.finish();
                }
            });
        }
        // The connection is closed (the contact left, idle, network): presence for level 3+ subscribers
        let current = self.live_conn().map(|c| c.stable_id());
        if current.is_none() || current == Some(conn.stable_id()) {
            self.conn
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            self.emit_contact();
        }
    }

    async fn handle(self: &Arc<Self>, req: LinkRequest, conn: &Connection) -> LinkResponse {
        match req {
            LinkRequest::Hello { mut addrs } => {
                // The contact's address may have changed (a new relay, a new port). A `hello` without a relay (the
                // contact brought the link up without internet, LAN) does not erase the old relay: otherwise after a
                // LAN session the contact could not be reached via relay until it connects itself (D-78, item 7)
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                if addrs.relay.is_none()
                    && let Ok(old) = db.link(&self.link_id)
                {
                    addrs.relay = old.peer_addrs.relay;
                }
                let _ = db.set_peer_addrs(&self.link_id, &addrs);
                drop(db);
                self.kick.notify_one();
                LinkResponse::Ok
            }
            LinkRequest::Deliver { blob } => {
                let me = self.clone();
                let r = tokio::task::spawn_blocking(move || me.receive_deliver(&blob)).await;
                self.after_receive(r, conn, true)
            }
            LinkRequest::Resend { blob } => {
                let me = self.clone();
                let r = tokio::task::spawn_blocking(move || me.receive_resend(&blob)).await;
                self.after_receive(r, conn, false)
            }
            LinkRequest::Sync(peer) => self.on_sync(conn, peer).await,
            LinkRequest::Chain(q) => {
                let me = self.clone();
                tokio::task::spawn_blocking(move || me.on_chain(&q))
                    .await
                    .unwrap_or(LinkResponse::Rejected {
                        reason: "internal".into(),
                    })
            }
            LinkRequest::Conflict(note) => {
                let me = self.clone();
                let (resp, want) = tokio::task::spawn_blocking(move || me.on_conflict(&note))
                    .await
                    .unwrap_or((
                        LinkResponse::Rejected {
                            reason: "internal".into(),
                        },
                        None,
                    ));
                // The contact's copy as evidence: check its signature here
                if let Some(id) = want {
                    let conn = conn.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                        want_with_retry(&conn, vec![id]).await;
                    });
                }
                resp
            }
            LinkRequest::Want { ids } => {
                // Resend what the contact asks for by ID (missing parents, divergence evidence, restoring its copy).
                // Only existing messages of this link, in read-only mode too.
                if ids.len() > antenna_proto::link::MAX_CHAIN_POINTS {
                    return LinkResponse::Rejected {
                        reason: code::BAD_REQUEST.into(),
                    };
                }
                if self.rolled_back() {
                    return LinkResponse::Rejected {
                        reason: code::REKEY_REQUIRED.into(),
                    };
                }
                let Ok(permit) = self.clone().want_gate_owned() else {
                    return LinkResponse::Rejected {
                        reason: code::RATE_LIMITED.into(),
                    };
                };
                let me = self.clone();
                let conn = conn.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    let msgs = match me.msgs_by_ids(&ids) {
                        Ok(m) => m,
                        Err(e) => return tracing::debug!("want: {e}"),
                    };
                    if let Err(e) = me.push_msgs(&conn, msgs, true).await {
                        tracing::debug!("link {}: want: {e}", me.short());
                    }
                });
                LinkResponse::Ok
            }
            LinkRequest::RekeyOffer(offer) => {
                let me = self.clone();
                tokio::task::spawn_blocking(move || me.on_rekey_offer(&offer))
                    .await
                    .unwrap_or_else(|_| LinkResponse::Rejected {
                        reason: "internal".into(),
                    })
            }
            LinkRequest::RekeyInit { blob } => {
                let me = self.clone();
                tokio::task::spawn_blocking(move || me.on_rekey_init(&blob))
                    .await
                    .unwrap_or_else(|_| LinkResponse::Rejected {
                        reason: "internal".into(),
                    })
            }
            // Parsed in `serve` (chunk frames come on the same QUIC stream)
            LinkRequest::StreamOpen { .. } => LinkResponse::Rejected {
                reason: "malformed".into(),
            },
            LinkRequest::Features { list } => {
                self.set_peer_features(&list);
                self.spawn_picture_sync();
                LinkResponse::Features {
                    list: antenna_proto::link::FEATURES
                        .iter()
                        .map(|f| f.to_string())
                        .collect(),
                }
            }
            LinkRequest::Device { blob } => self.serve_device(blob).await,
            LinkRequest::RekeyAck { blob } => {
                let me = self.clone();
                match tokio::task::spawn_blocking(move || me.on_rekey_ack(&blob)).await {
                    Ok(Ok(())) => LinkResponse::Ok,
                    Ok(Err(e)) => LinkResponse::Rejected {
                        reason: e.code.into(),
                    },
                    Err(_) => LinkResponse::Rejected {
                        reason: "internal".into(),
                    },
                }
            }
        }
    }

    /// Result of receiving: events to subscribers, `inbox`, missing parents, displaced own messages. [`deliver`] is a
    /// new message (`deliver`), not history sent again during verification (`resend`).
    fn after_receive(
        self: &Arc<Self>,
        r: std::result::Result<Result<crate::linksync::Received>, tokio::task::JoinError>,
        conn: &Connection,
        deliver: bool,
    ) -> LinkResponse {
        match r {
            Ok(Ok(rcv)) => {
                self.note_peer_kind(&rcv);
                self.no_agent_answers(&rcv.items, deliver);
                // An honoured urgent message (PG-58) for the link's wake agent interrupts its turn first
                let urgent = rcv
                    .items
                    .iter()
                    .find(|i| i.urgent && i.direction == "in")
                    .and_then(|i| i.to_agent.clone());
                for item in rcv.items {
                    let _ = self.events.send(NodeEvent::Message {
                        link: self.link_id,
                        contact: self.label.clone(),
                        trust: self.trust.load(Ordering::SeqCst),
                        item: Box::new(item),
                    });
                }
                if rcv.text {
                    self.inbox.send_modify(|v| *v += 1);
                    // The link's wake rule (SPEC §11): launch the agent
                    let _ = self.wake_tx.send(crate::wake::WakeKick {
                        link: self.link_id,
                        urgent,
                    });
                }
                // A streaming message's final message: recognize it by salt (v0.2)
                self.stream_finals(&rcv.salts);
                if let Some(tx) = &self.files_tx {
                    for (msg, body) in rcv.files {
                        let _ = tx.send(crate::files::Job::Incoming {
                            link: self.link_id,
                            msg,
                            body: Box::new(body),
                        });
                    }
                }
                if !rcv.missing.is_empty() {
                    let conn = conn.clone();
                    let ids = rcv.missing;
                    tokio::spawn(async move { want_with_retry(&conn, ids).await });
                }
                if !rcv.requeue.is_empty() {
                    let me = self.clone();
                    tokio::spawn(async move { me.requeue(rcv.requeue).await });
                }
                // A contact's picture changed (PROTOCOL §25): owner subscribers ask `pictures`, which checks a photo
                self.picture_events(&rcv.pictures);
                if rcv.resync_pictures {
                    self.spawn_picture_sync();
                }
                // The contact's agents (v5): an announcement or the owner's first message changes `peer_kind`
                if rcv.agents || rcv.text {
                    let kind = self.peer_kind();
                    let changed = {
                        let mut g = self
                            .last_kind
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner);
                        let c = *g != kind;
                        *g = kind;
                        c
                    };
                    if changed || rcv.agents {
                        self.emit_contact();
                    }
                }
                self.emit_history();
                rcv.resp
            }
            Ok(Err(e)) => {
                tracing::warn!(
                    "link {}: rejected incoming message: {}",
                    self.short(),
                    e.code
                );
                LinkResponse::Rejected {
                    reason: e.code.into(),
                }
            }
            Err(_) => LinkResponse::Rejected {
                reason: "internal".into(),
            },
        }
    }

    /// Messages addressed to an agent (PROTOCOL §23, `no-agent/0`). As the recipient: a new message for an agent name
    /// nobody here has for this link is answered with a signed `deliver` / `no_such_agent` receipt, so the sender
    /// learns that nobody will read it instead of seeing "delivered"; only to a node with the feature (older nodes
    /// keep today's behaviour) and only at trust level 3+ (levels 1–2 cannot probe which agent names exist here). As
    /// the sender: such a receipt about one of our messages marks it, and the owner's subscriptions hear `no_agent`.
    fn no_agent_answers(self: &Arc<Self>, items: &[HistoryItem], deliver: bool) {
        let mut unknown = Vec::new();
        for item in items {
            if item.direction != "in" {
                continue;
            }
            if let Some(r) = item.receipt.as_ref()
                && r.action == "deliver"
                && r.decision == "no_such_agent"
            {
                for id in &r.refs {
                    let marked = {
                        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                        db.mark_no_agent(&self.link_id, id).unwrap_or(false)
                    };
                    if marked {
                        let _ = self.events.send(NodeEvent::Status {
                            link: self.link_id,
                            contact: self.label.clone(),
                            id: id.clone(),
                            status: "no_agent",
                        });
                    }
                }
                continue;
            }
            if deliver
                && item.kind == "text"
                && item.to.as_deref() == Some("agent")
                && let Some(name) = &item.to_agent
                && let Some(id) = data_encoding::HEXLOWER
                    .decode(item.id.as_bytes())
                    .ok()
                    .and_then(|v| <[u8; 32]>::try_from(v).ok())
            {
                unknown.push((MessageId(id), name.clone()));
            }
        }
        if unknown.is_empty()
            || !self.peer_supports_no_agent()
            || self.trust.load(Ordering::SeqCst) < 3
        {
            return;
        }
        let missing: Vec<MessageId> = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            unknown
                .into_iter()
                .filter(|(_, name)| {
                    !crate::addressing::agent_here(&db, &self.link_id, name).unwrap_or(true)
                })
                .map(|(id, _)| id)
                .collect()
        };
        if missing.is_empty() {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            let body = Body::Receipt(ReceiptBody {
                actor: "owner".into(),
                action: "deliver".into(),
                decision: "no_such_agent".into(),
                refs: missing.into_iter().take(ReceiptBody::MAX_REFS).collect(),
                count: 0,
                name_number: 0,
                why: String::new(),
                rules: vec![],
            });
            let me2 = me.clone();
            match tokio::task::spawn_blocking(move || me2.append(MessageType::Receipt, body)).await
            {
                Ok(Ok(a)) => {
                    let _ = me.events.send(NodeEvent::Message {
                        link: me.link_id,
                        contact: me.label.clone(),
                        trust: me.trust.load(Ordering::SeqCst),
                        item: Box::new(a.item),
                    });
                    me.kick.notify_one();
                }
                Ok(Err(e)) => tracing::warn!("link {}: no-agent receipt: {e}", me.short()),
                Err(_) => {}
            }
        });
    }

    /// Our own undelivered messages displaced when restoring history: sent again with the next counters.
    async fn requeue(self: Arc<Self>, bodies: Vec<(Body, Option<String>, Addr)>) {
        for (body, agent, addr) in bodies {
            let kind = match &body {
                Body::Agent(_) | Body::Picture(_) => MessageType::Control,
                Body::Receipt(_) => MessageType::Receipt,
                Body::File(_) => MessageType::File,
                Body::FileRequest(_) => MessageType::Request,
                _ => MessageType::Text,
            };
            let me = self.clone();
            match tokio::task::spawn_blocking(move || {
                me.append_as(kind, body, None, agent.as_deref(), &addr)
            })
            .await
            {
                Ok(Ok(a)) => {
                    let _ = self.events.send(NodeEvent::Message {
                        link: self.link_id,
                        contact: self.label.clone(),
                        trust: self.trust.load(Ordering::SeqCst),
                        item: Box::new(a.item),
                    });
                }
                Ok(Err(e)) => tracing::warn!("link {}: requeue: {e}", self.short()),
                Err(_) => {}
            }
        }
        self.kick.notify_one();
    }

    /// A rekey offer from the contact: check it; if the owner has already agreed, accept it right away.
    fn on_rekey_offer(&self, offer: &antenna_proto::link::RekeyOffer) -> LinkResponse {
        let (bundle, hash) = match self.check_offer(offer) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("link {}: rekey offer rejected: {e}", self.short());
                return LinkResponse::Rejected {
                    reason: e.code.into(),
                };
            }
        };
        // The offer is accepted only by this side's owner and only with the code the contact's owner read out (the
        // confirmation names exactly this offer). The code has no commitment, so a bundle chosen to match an
        // overheard code (10⁶ attempts) must not take the place of the real one: a second, different offer within
        // the window burns both and closes the window for 10 minutes, and a code already seen on another bundle is
        // not accepted for a day, neither after a conflict nor after the real offer expired
        {
            let mut r = self.rekey.lock().unwrap_or_else(PoisonError::into_inner);
            let now = now_ms();
            let code = crate::history::rekey_code(&self.link_id, &hash);
            // Already accepted (the answer waits for the second code): a repeat of the same offer changes nothing
            if r.awaiting_ack.as_ref().is_some_and(|(h, _, _)| *h == hash) {
                return LinkResponse::Pending;
            }
            // A repeat of the same offer: the receipt time is not updated (the window is 10 minutes from the first
            // receipt)
            if r.offer.as_ref().is_some_and(|(_, h, _)| *h == hash) {
                return LinkResponse::Pending;
            }
            let conflict = r.burn_active(now)
                || r.code_reused(&code, &hash, now)
                || r.offer.as_ref().is_some_and(|(_, h, at)| {
                    *h != hash && now.saturating_sub(*at) < 10 * 60 * 1000
                });
            if conflict {
                let fresh_conflict = !r.burn_active(now);
                r.remember(code, hash, now);
                r.offer = None;
                r.start_burn(now);
                drop(r);
                tracing::warn!(
                    "link {}: re-keying offer refused: two different offers (or a reused code) from the contact's keys \
                     — discarded",
                    self.short()
                );
                if fresh_conflict {
                    let _ = self.events.send(NodeEvent::Rekey {
                        link: self.link_id,
                        contact: self.label.clone(),
                        state: "conflicting_offers",
                    });
                }
                return LinkResponse::Rejected {
                    reason: "conflicting_offers".into(),
                };
            }
            r.remember(code, hash, now);
            r.offer = Some((bundle, hash, now));
        }
        let _ = self.events.send(NodeEvent::Rekey {
            link: self.link_id,
            contact: self.label.clone(),
            state: "requested_by_contact",
        });
        tracing::warn!(
            "link {}: the contact asks to re-key the link; the owner confirms with `antenna rekey <contact> --code <code \
             the contact reads out>`",
            self.short()
        );
        LinkResponse::Pending
    }

    /// A live connection or a new one (dial by address hints) with `hello`.
    pub(crate) async fn connection(self: &Arc<Self>) -> Result<Connection> {
        let conn = self.connect_raw().await?;
        // History verification: once per connection, before delivering the queue (SPEC §8)
        self.ensure_synced(&conn).await?;
        Ok(conn)
    }

    /// A live connection or a new one, without verification.
    pub(crate) async fn connect_raw(self: &Arc<Self>) -> Result<Connection> {
        if let Some(c) = self.live_conn() {
            return Ok(c);
        }
        let mut hints = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&self.link_id)?
            .peer_addrs;
        // Contact addresses found on the local network (LAN, level 3+): hints in addition to the saved ones
        if self.mode == EpMode::Direct {
            for a in self.lan.found_addrs(&self.link_id) {
                let a = a.to_string();
                if !hints.direct.contains(&a) {
                    hints.direct.push(a);
                }
            }
        }
        let addr = transport::link_dial_addr(self.peer, &hints, self.mode, &self.cfg.net)?;
        let conn = match tokio::time::timeout(
            self.cfg.dial_timeout,
            self.endpoint.connect(addr, ALPN_LINK),
        )
        .await
        {
            Ok(Ok(c)) => c,
            Ok(Err(e)) => return Err(Error::network(format!("connect: {e}"))),
            Err(_) => return Err(Error::network("connect: timeout")),
        };
        // The hook has already checked the contact's key and the PQ group; check once more explicitly
        if conn.remote_id() != self.peer || !transport::is_pq(&conn) {
            conn.close(antenna_proto::link::CLOSE_NOT_PAIRED.into(), b"");
            return Err(Error::network("peer failed transport checks"));
        }
        self.adopt(conn.clone());
        tokio::spawn(self.clone().serve(conn.clone()));
        let hello = LinkRequest::Hello {
            addrs: transport::addr_hints(&self.endpoint, self.mode),
        };
        let _ = request(&conn, &hello).await;
        self.exchange_features(&conn).await;
        Ok(conn)
    }

    /// A separate connection to the contact via the iroh-blobs ALPN (file download): the same key and PQ group check.
    pub(crate) async fn blob_conn(self: &Arc<Self>) -> Result<Connection> {
        let hints = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&self.link_id)?
            .peer_addrs;
        let addr = transport::link_dial_addr(self.peer, &hints, self.mode, &self.cfg.net)?;
        let conn = match tokio::time::timeout(
            self.cfg.dial_timeout,
            self.endpoint.connect(addr, iroh_blobs::ALPN),
        )
        .await
        {
            Ok(Ok(c)) => c,
            Ok(Err(e)) => return Err(Error::network(format!("connect: {e}"))),
            Err(_) => return Err(Error::network("connect: timeout")),
        };
        if conn.remote_id() != self.peer || !transport::is_pq(&conn) {
            conn.close(antenna_proto::link::CLOSE_NOT_PAIRED.into(), b"");
            return Err(Error::network("peer failed transport checks"));
        }
        self.touch();
        Ok(conn)
    }

    async fn deliver_all(self: &Arc<Self>) -> Result<bool> {
        let items = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .outbox(&self.link_id)?;
        let announce = self.announce.swap(false, Ordering::SeqCst);
        let sync_req = self.sync_requested.swap(false, Ordering::SeqCst);
        if items.is_empty() && !announce && !sync_req {
            return Ok(false);
        }
        // Something to deliver but no connection: announce on the LAN right away, without waiting for a timeout on old
        // addresses
        if self.live_conn().is_none() {
            self.lan_on_failure();
        }
        let conn = self.connection().await?;
        if self.delivery_paused() {
            return Ok(false);
        }
        for it in items {
            let blob: RoutingBlob = antenna_proto::from_cbor(&it.blob)?;
            self.touch();
            let r = request(&conn, &LinkRequest::Deliver { blob }).await;
            self.touch();
            match r {
                Ok(LinkResponse::Ok) | Ok(LinkResponse::Duplicate) => {
                    self.db
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .outbox_remove(it.seq)?;
                    let _ = self.delivered.send(it.msg_id);
                    self.emit_status(&it.msg_id, "delivered");
                }
                Ok(LinkResponse::Rejected { reason }) => {
                    tracing::warn!("link {}: peer rejected a message: {reason}", self.short());
                    if reason == code::REKEY_REQUIRED {
                        // The contact rolled back: delivery waits for a rekey, attempts are not spent
                        self.hist
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .peer_rolled_back = true;
                        self.emit_history();
                        return Err(Error::network("contact needs re-keying"));
                    }
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    // `internal`, `read_only` at the recipient are temporary (retry forever with backoff);
                    // the rest are permanent: after 5 refusals the message is taken off the queue and marked failed
                    let temporary = reason == "internal"
                        || reason == code::READ_ONLY
                        || reason == code::RECOVERING;
                    if !temporary && it.attempts + 1 >= 5 {
                        db.outbox_fail(it.seq, &it.msg_id)?;
                        crate::agentid::forget_if_announcement(
                            db.conn(),
                            &self.link_id,
                            &it.msg_id,
                        )?;
                        self.emit_status(&it.msg_id, "failed");
                    } else {
                        db.outbox_bump(it.seq)?;
                    }
                    return Err(Error::network("message rejected by peer"));
                }
                Ok(other) => {
                    return Err(Error::network(format!(
                        "unexpected answer to deliver: {other:?}"
                    )));
                }
                Err(e) => {
                    self.conn
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take();
                    return Err(e);
                }
            }
        }
        Ok(true)
    }

    /// Re-verification after a batch of messages: "History verified" refers to the current heads.
    async fn resync_if_dirty(self: &Arc<Self>) {
        if !self
            .hist
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .dirty
        {
            return;
        }
        let Some(conn) = self.live_conn() else {
            return;
        };
        let _g = self.sync_lock.lock().await;
        if let Err(e) = self.sync_on(&conn).await {
            tracing::debug!("link {}: resync: {e}", self.short());
        }
    }
}

/// `want` with a retry: the contact may have another resend in progress (one at a time), and then the reply is
/// `rate_limited`.
pub(crate) async fn want_with_retry(conn: &Connection, ids: Vec<MessageId>) {
    for attempt in 0..10u32 {
        match request(conn, &LinkRequest::Want { ids: ids.clone() }).await {
            Ok(LinkResponse::Rejected { reason }) if reason == code::RATE_LIMITED => {
                tokio::time::sleep(Duration::from_millis(300 * u64::from(attempt + 1))).await;
            }
            _ => return,
        }
    }
}

/// One request on a link: a separate bi-stream, a request frame, a reply frame.
pub(crate) async fn request(conn: &Connection, req: &LinkRequest) -> Result<LinkResponse> {
    let fut = async {
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|e| Error::network(format!("open stream: {e}")))?;
        transport::write_frame(&mut send, &antenna_proto::to_cbor(req)?).await?;
        let _ = send.finish();
        let b = transport::read_frame(&mut recv, MAX_FRAME).await?;
        Ok::<_, Error>(antenna_proto::from_cbor::<LinkResponse>(&b)?)
    };
    tokio::time::timeout(Duration::from_secs(15), fut)
        .await
        .map_err(|_| Error::network("request timeout"))?
}

/// Presence of levels 1–2 (SPEC §4, Q-8): the link connection is closed after `presence_idle` without application
/// activity, so that the contact does not see "online" from a live keep-alive. Levels 3+ keep the connection.
async fn idle_watcher(link: Arc<LinkShared>) {
    let idle_max = link.cfg.presence_idle;
    let tick = (idle_max / 30).clamp(Duration::from_millis(50), Duration::from_secs(1));
    loop {
        tokio::time::sleep(tick).await;
        if link.trust.load(Ordering::SeqCst) > 2 {
            continue;
        }
        let idle = link
            .last_active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .elapsed();
        if idle < idle_max {
            continue;
        }
        let conn = link
            .conn
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(c) = conn
            && c.close_reason().is_none()
        {
            tracing::debug!(
                "link {}: closing idle connection (trust ≤ 2, presence)",
                link.short()
            );
            c.close(0u32.into(), b"idle");
            link.emit_contact();
        }
    }
}

async fn delivery_worker(link: Arc<LinkShared>) {
    let min = link.cfg.retry_min;
    let max = link.cfg.retry_max;
    let mut backoff = min;
    loop {
        match link.deliver_all().await {
            Ok(true) => {
                backoff = min;
                continue; // New ones may have appeared
            }
            Ok(false) => {
                backoff = min;
                // After a batch of messages and a pause: re-verify the heads (one summary, no messages sent)
                tokio::select! {
                    _ = link.kick.notified() => {}
                    _ = tokio::time::sleep(RESYNC_AFTER) => {
                        link.resync_if_dirty().await;
                        link.kick.notified().await;
                    }
                }
            }
            Err(e) => {
                tracing::debug!("link {}: delivery deferred: {e}", link.short());
                // The contact does not answer at its known addresses: announce on the local network (if LAN is on)
                link.lan_on_failure();
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = link.kick.notified() => {}
                }
                backoff = (backoff * 2).min(max);
            }
        }
    }
}

#[derive(Debug, Clone)]
struct LinkHandler(Arc<LinkShared>);

impl ProtocolHandler for LinkHandler {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        if conn.remote_id() != self.0.peer {
            conn.close(antenna_proto::link::CLOSE_NOT_PAIRED.into(), b"");
            return Ok(());
        }
        self.0.adopt(conn.clone());
        // The contact is online: try to deliver the queue right away
        self.0.kick.notify_one();
        self.0.clone().serve(conn).await;
        Ok(())
    }
}
