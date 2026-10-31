// SPDX-License-Identifier: AGPL-3.0-only
//! Local store (SPEC §8, §13): SQLCipher, raw key from the keystore (D-10).
//!
//! Tables: contacts, links (link keys live inside the encrypted DB), libsignal state (identity, sessions), messages
//! with hash-DAG fields (`parents`, `lamport`, heads, author counter `n`, signature), the send queue (outbox), agents,
//! the local audit log. History verification is in `sync.rs`; the rollback counter is in `statefile.rs`.

use std::path::Path;

use antenna_proto::{LinkId, MessageId, control::code, pairing::AddrHints};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use zeroize::Zeroizing;

use crate::{
    crypto::Secret32,
    error::{Error, Result},
};

/// DB file name in the data directory.
pub const FILE_NAME: &str = "antenna.db";
/// DB file name of pre-release `x` builds: on startup `antennad` renames it (with `-wal` and `-shm`) to
/// [`FILE_NAME`].
pub const LEGACY_FILE_NAME: &str = "x.db";

/// Link network mode (SPEC §4): set by the trust level this side gave the contact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetMode {
    /// Relay only: the contact does not see the IP (levels 1–2).
    RelayOnly,
    /// Direct: relay + IP (levels 3–5).
    Direct,
}

impl NetMode {
    /// By trust level.
    pub fn for_trust(trust: u8) -> Self {
        if trust <= 2 {
            NetMode::RelayOnly
        } else {
            NetMode::Direct
        }
    }

    /// Name in the DB and in JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            NetMode::RelayOnly => "relay_only",
            NetMode::Direct => "direct",
        }
    }

    fn parse(s: &str) -> Result<Self> {
        match s {
            "relay_only" => Ok(NetMode::RelayOnly),
            "direct" => Ok(NetMode::Direct),
            _ => Err(Error::internal("bad net_mode in db")),
        }
    }
}

/// Side's role in pairing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairRole {
    /// Inviter (A).
    Inviter,
    /// Joiner (B).
    Joiner,
}

impl PairRole {
    /// Name in the DB and in JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            PairRole::Inviter => "inviter",
            PairRole::Joiner => "joiner",
        }
    }

    fn parse(s: &str) -> Result<Self> {
        match s {
            "inviter" => Ok(PairRole::Inviter),
            "joiner" => Ok(PairRole::Joiner),
            _ => Err(Error::internal("bad role in db")),
        }
    }
}

/// Everything pairing hands over for saving (atomically, in one transaction).
pub struct NewLink {
    /// Link ID.
    pub link_id: LinkId,
    /// Role.
    pub role: PairRole,
    /// Contact label (or an automatic one).
    pub label: Option<String>,
    /// Trust level.
    pub trust: u8,
    /// Transcript hash pairing.
    pub transcript_hash: [u8; 32],
    /// TLS group during pairing.
    pub pairing_kx: String,
    /// Secret of our own pairwise endpoint.
    pub local_secret: Secret32,
    /// EndpointId of the contact's pairwise endpoint.
    pub peer_endpoint: [u8; 32],
    /// The contact's address hints.
    pub peer_addrs: AddrHints,
    /// Seed link-root Ed25519.
    pub root_ed25519_seed: Secret32,
    /// Public Ed25519 link-root.
    pub root_ed25519_pk: [u8; 32],
    /// Seed link-root ML-DSA-65.
    pub root_mldsa_seed: Secret32,
    /// Public ML-DSA-65 link-root.
    pub root_mldsa_vk: Vec<u8>,
    /// The contact's Ed25519 link-root.
    pub peer_root_ed25519: [u8; 32],
    /// The contact's ML-DSA-65 link-root.
    pub peer_root_mldsa: Vec<u8>,
    /// Our own libsignal address.
    pub sig_local_addr: String,
    /// The contact's libsignal address.
    pub sig_remote_addr: String,
    /// Serialized `IdentityKeyPair` of the link.
    pub sig_identity_keypair: Zeroizing<Vec<u8>>,
    /// Registration id.
    pub sig_registration_id: u32,
    /// The contact's pinned `IdentityKey`.
    pub sig_remote_identity: Vec<u8>,
    /// Serialized `SessionRecord`.
    pub sig_session_record: Zeroizing<Vec<u8>>,
}

/// A link from the DB.
#[derive(Clone)]
pub struct LinkRow {
    /// Link ID.
    pub link_id: LinkId,
    /// Contact label.
    pub label: String,
    /// Trust level.
    pub trust: u8,
    /// Role.
    pub role: PairRole,
    /// Network mode.
    pub net_mode: NetMode,
    /// When it was created.
    pub created_ms: u64,
    /// TLS group during pairing.
    pub pairing_kx: String,
    /// Secret of our own pairwise endpoint.
    pub local_secret: Secret32,
    /// Saved UDP port.
    pub local_port: Option<u16>,
    /// The contact's EndpointId.
    pub peer_endpoint: [u8; 32],
    /// The contact's address hints.
    pub peer_addrs: AddrHints,
    /// Our own Ed25519 link-root (author of our messages).
    pub root_ed25519_pk: [u8; 32],
    /// The contact's Ed25519 link-root (author of its messages).
    pub peer_root_ed25519: [u8; 32],
    /// Our own libsignal address.
    pub sig_local_addr: String,
    /// The contact's libsignal address.
    pub sig_remote_addr: String,
    /// Maximum lamport.
    pub lamport: u64,
    /// TLS group of the last connection.
    pub last_kx: Option<String>,
    /// Version of the last accepted libsignal message.
    pub last_rx_version: Option<u32>,
    /// SPQR part length of the last accepted message.
    pub last_rx_pq_len: Option<u32>,
    /// Paths of the last connection.
    pub last_paths: Vec<String>,
    /// Link block: `rolled_back:<source>` (rollback, sending blocked until a rekey) or `read_only` (history divergence
    /// until the owner decides); `None` means it works.
    pub blocked: Option<String>,
}

impl std::fmt::Debug for LinkRow {
    // The endpoint secret is not printed (SPEC §13)
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkRow")
            .field("link_id", &&self.link_id.to_hex()[..8])
            .field("label", &self.label)
            .field("trust", &self.trust)
            .field("net_mode", &self.net_mode)
            .field("local_secret", &"<redacted>")
            .finish_non_exhaustive()
    }
}

/// An unread incoming message.
#[derive(Debug, Clone)]
pub struct InboxRow {
    /// Sequence number in the DB.
    pub seq: i64,
    /// ID.
    pub id: MessageId,
    /// Link.
    pub link_id: LinkId,
    /// Contact label.
    pub label: String,
    /// Trust.
    pub trust: u8,
    /// Type.
    pub kind: String,
    /// Text.
    pub body: String,
    /// Author time.
    pub ts: u64,
    /// When it was received.
    pub received_ms: u64,
    /// Lamport.
    pub lamport: u64,
    /// Parents.
    pub parents: Vec<MessageId>,
    /// The contact's agent that wrote it (v5): the name from its announcement.
    pub agent: Option<String>,
    /// Who it is for (v6, PROTOCOL §23), read from the signed `core` itself (not from a derived column): the
    /// agents' visibility rule decides by it.
    pub to: Option<antenna_proto::To>,
    /// The topic (v6), from `core`.
    pub topic: Option<antenna_proto::Topic>,
}

/// What [`Db::agent_unread`] found.
#[derive(Debug, Default)]
pub struct AgentUnread {
    /// Messages visible to the agent.
    pub rows: Vec<InboxRow>,
    /// Per link, the highest `seq` examined (visible or not).
    pub passed: std::collections::HashMap<LinkId, i64>,
    /// A visible message did not fit (the count or the character budget): it and the ones after it stay unread.
    pub more: bool,
}

/// A send queue item.
#[derive(Debug, Clone)]
pub struct OutboxItem {
    /// Sequence number.
    pub seq: i64,
    /// Message ID.
    pub msg_id: MessageId,
    /// Ready `RoutingBlob` (CBOR).
    pub blob: Vec<u8>,
    /// How many attempts there were.
    pub attempts: u32,
}

/// A message to record.
pub struct MessageRecord<'a> {
    /// ID.
    pub id: MessageId,
    /// Link.
    pub link_id: LinkId,
    /// `in` / `out`.
    pub incoming: bool,
    /// Author.
    pub author: [u8; 32],
    /// Lamport.
    pub lamport: u64,
    /// Author time.
    pub ts: u64,
    /// Type.
    pub kind: &'a str,
    /// Text.
    pub body: &'a str,
    /// `core` bytes.
    pub core: &'a [u8],
    /// Parents.
    pub parents: &'a [MessageId],
    /// Author counter.
    pub n: u64,
    /// Author signature.
    pub sig: &'a [u8],
    /// `live`: delivered as new; `recovered`: a history resend during verification (not "unread").
    pub origin: &'a str,
    /// Author agent (v5): the display name (ours: local; the contact's: from its announcement) and the key, if the
    /// message is signed with an agent key (`core.author`); `author` is then the side's link-root.
    pub agent: Option<(&'a str, Option<[u8; 32]>)>,
    /// Who it is for (v6): from `core`, or, for our own message to a node without `addr/0`, kept only here.
    pub to: Option<&'a antenna_proto::To>,
    /// The topic (v6), the same way.
    pub topic: Option<&'a antenna_proto::Topic>,
}

/// A whole message from the DB (for resending, verification and the copy check).
#[derive(Debug, Clone)]
pub struct StoredMsg {
    /// `seq`.
    pub seq: i64,
    /// ID.
    pub id: MessageId,
    /// Author.
    pub author: [u8; 32],
    /// Author counter.
    pub n: u64,
    /// Lamport.
    pub lamport: u64,
    /// Author time.
    pub ts: u64,
    /// Type.
    pub kind: String,
    /// Displayed text.
    pub body: String,
    /// `core` bytes.
    pub core: Vec<u8>,
    /// Signature.
    pub sig: Vec<u8>,
    /// The agent key that signed the message (v5; `core.author`), if an agent of side `author` wrote it.
    pub agent_key: Option<[u8; 32]>,
}

impl StoredMsg {
    /// The key that signed the message: an agent key or the side's link-root (`core.author`).
    pub fn signer(&self) -> [u8; 32] {
        self.agent_key.unwrap_or(self.author)
    }
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS contacts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL UNIQUE,
  trust INTEGER NOT NULL CHECK (trust BETWEEN 1 AND 5),
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS links(
  link_id BLOB PRIMARY KEY,
  contact_id INTEGER NOT NULL REFERENCES contacts(id),
  role TEXT NOT NULL,
  net_mode TEXT NOT NULL,
  state TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  transcript_hash BLOB NOT NULL,
  pairing_kx TEXT NOT NULL,
  local_secret BLOB NOT NULL,
  local_port INTEGER,
  peer_endpoint BLOB NOT NULL,
  peer_addrs BLOB NOT NULL,
  root_ed25519_seed BLOB NOT NULL,
  root_ed25519_pk BLOB NOT NULL,
  root_mldsa_seed BLOB NOT NULL,
  root_mldsa_vk BLOB NOT NULL,
  peer_root_ed25519 BLOB NOT NULL,
  peer_root_mldsa BLOB NOT NULL,
  sig_local_addr TEXT NOT NULL,
  sig_remote_addr TEXT NOT NULL,
  lamport INTEGER NOT NULL DEFAULT 0,
  last_kx TEXT,
  last_rx_version INTEGER,
  last_rx_pq_len INTEGER,
  last_paths TEXT,
  state_counter INTEGER NOT NULL DEFAULT 0,
  blocked TEXT,
  hist_note TEXT,
  verified_ms INTEGER,
  rekey_pending BLOB
);
CREATE TABLE IF NOT EXISTS sig_identity(
  link_id BLOB PRIMARY KEY REFERENCES links(link_id),
  keypair BLOB NOT NULL,
  registration_id INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sig_remote_identity(
  link_id BLOB NOT NULL REFERENCES links(link_id),
  address TEXT NOT NULL,
  identity BLOB NOT NULL,
  PRIMARY KEY(link_id, address)
);
CREATE TABLE IF NOT EXISTS sig_session(
  link_id BLOB NOT NULL REFERENCES links(link_id),
  address TEXT NOT NULL,
  record BLOB NOT NULL,
  PRIMARY KEY(link_id, address)
);
CREATE TABLE IF NOT EXISTS messages(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id BLOB NOT NULL UNIQUE,
  link_id BLOB NOT NULL REFERENCES links(link_id),
  direction TEXT NOT NULL,
  author BLOB NOT NULL,
  lamport INTEGER NOT NULL,
  ts INTEGER NOT NULL,
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  core BLOB NOT NULL,
  received_ms INTEGER NOT NULL,
  read INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  n INTEGER NOT NULL DEFAULT 0,
  sig BLOB,
  origin TEXT NOT NULL DEFAULT 'live'
);
CREATE INDEX IF NOT EXISTS messages_unread ON messages(direction, read);
CREATE TABLE IF NOT EXISTS message_parents(
  link_id BLOB NOT NULL,
  msg_id BLOB NOT NULL,
  parent_id BLOB NOT NULL,
  PRIMARY KEY(msg_id, parent_id)
);
CREATE INDEX IF NOT EXISTS message_parents_by_parent ON message_parents(link_id, parent_id);
CREATE TABLE IF NOT EXISTS heads(
  link_id BLOB NOT NULL,
  msg_id BLOB NOT NULL,
  PRIMARY KEY(link_id, msg_id)
);
CREATE TABLE IF NOT EXISTS outbox(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  link_id BLOB NOT NULL REFERENCES links(link_id),
  msg_id BLOB NOT NULL,
  blob BLOB NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS agents(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  token_hash BLOB NOT NULL UNIQUE,
  links TEXT,
  local_level INTEGER NOT NULL DEFAULT 0 CHECK (local_level BETWEEN 0 AND 5),
  created_ms INTEGER NOT NULL,
  start_seq INTEGER NOT NULL DEFAULT 0,
  session_started_ms INTEGER NOT NULL,
  anchor_pid INTEGER,
  anchor_start INTEGER,
  anchor_comm TEXT,
  taint TEXT NOT NULL DEFAULT '[]',
  declared TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS agent_cursor(
  agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  link_id BLOB NOT NULL,
  last_seq INTEGER NOT NULL,
  PRIMARY KEY(agent_id, link_id)
);
CREATE TABLE IF NOT EXISTS receipts(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  link_id BLOB NOT NULL REFERENCES links(link_id),
  ts INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  decision TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  msg_id BLOB,
  approval_id TEXT
);
CREATE INDEX IF NOT EXISTS receipts_by_link ON receipts(link_id, seq);
CREATE TABLE IF NOT EXISTS link_agents(
  link_id BLOB NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('me', 'peer')),
  key BLOB NOT NULL,
  name TEXT NOT NULL,
  seed BLOB,
  announced_n INTEGER NOT NULL,
  announced_ms INTEGER NOT NULL,
  revoked_n INTEGER,
  PRIMARY KEY(link_id, key)
);
CREATE TABLE IF NOT EXISTS wake_rules(
  link_id BLOB PRIMARY KEY REFERENCES links(link_id) ON DELETE CASCADE,
  agent_id INTEGER NOT NULL,
  rule TEXT NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS local_models(
  id TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  size INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  verified TEXT,
  added_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS local_agents(
  agent_id INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS local_turns(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  counterpart TEXT NOT NULL,
  turn INTEGER NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'agent')),
  text TEXT NOT NULL,
  ts INTEGER NOT NULL,
  outcome TEXT,
  detail TEXT,
  usage TEXT
);
CREATE INDEX IF NOT EXISTS local_turns_by_agent ON local_turns(agent_id, counterpart, seq);
CREATE TABLE IF NOT EXISTS teams(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  project TEXT NOT NULL,
  git_dir TEXT NOT NULL,
  lead_id INTEGER REFERENCES agents(id) ON DELETE SET NULL,
  target TEXT NOT NULL,
  integration TEXT NOT NULL,
  cfg TEXT NOT NULL,
  state TEXT NOT NULL,
  apply_request TEXT,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS team_members(
  agent_id INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
  team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  kind TEXT NOT NULL,
  spec TEXT NOT NULL,
  spawned_by TEXT NOT NULL,
  state TEXT NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS team_tasks(
  id TEXT PRIMARY KEY,
  team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  state TEXT NOT NULL,
  assignee INTEGER,
  rec TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS team_tasks_by_team ON team_tasks(team_id, created_ms);
CREATE TABLE IF NOT EXISTS team_log(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  ts INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  task TEXT,
  decision TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS agent_counterparts(
  agent_id INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
  link_id BLOB NOT NULL REFERENCES links(link_id),
  agent TEXT,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS chats(
  link_id BLOB NOT NULL REFERENCES links(link_id) ON DELETE CASCADE,
  agent TEXT NOT NULL,
  name TEXT,
  notify TEXT CHECK (notify IN ('all', 'asks', 'off')),
  archived_ms INTEGER,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY(link_id, agent)
);
CREATE TABLE IF NOT EXISTS own_pictures(
  subject TEXT PRIMARY KEY,
  drawn TEXT,
  photo BLOB,
  updated_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS peer_pictures(
  link_id BLOB NOT NULL REFERENCES links(link_id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  n INTEGER NOT NULL,
  drawn TEXT,
  photo BLOB,
  photo_mime TEXT,
  shown BLOB,
  state TEXT CHECK (state IN ('unchecked', 'ok', 'refused')),
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY(link_id, subject)
);
-- Where an agent's questions go (D-118): a supervisor contact; no row means the owner
CREATE TABLE IF NOT EXISTS agent_escalation(
  agent_id INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
  link_id BLOB NOT NULL REFERENCES links(link_id) ON DELETE CASCADE
);
-- The agents' questions (D-118): the agent's text, kept encrypted like the messages; the owner's answer
CREATE TABLE IF NOT EXISTS escalations(
  id TEXT PRIMARY KEY,
  agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  link_id BLOB,
  question TEXT NOT NULL,
  read_from TEXT NOT NULL DEFAULT '[]',
  state TEXT NOT NULL CHECK (state IN ('open', 'answered', 'dismissed', 'sent')),
  answer TEXT,
  created_ms INTEGER NOT NULL,
  answered_ms INTEGER,
  message_id TEXT,
  delivered INTEGER NOT NULL DEFAULT 0
);
-- A sleeping resident session's files (D-121, PG-24): the transcript and notes, encrypted with the database instead
-- of lying on disk in plain text
CREATE TABLE IF NOT EXISTS resident_park(
  link_id BLOB PRIMARY KEY REFERENCES links(link_id) ON DELETE CASCADE,
  data BLOB NOT NULL,
  files INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  parked_ms INTEGER NOT NULL
);
-- Approver agents (PG-57): an agent of this computer (`agent_id`) or of an own computer (`link_id`, the name and the
-- key it announced there) that may answer other agents' approval requests in the owner's place; the scope as JSON
-- (`agents`: agent IDs, `kinds`; NULL means all)
CREATE TABLE IF NOT EXISTS approvers(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_id INTEGER UNIQUE REFERENCES agents(id) ON DELETE CASCADE,
  link_id BLOB REFERENCES links(link_id) ON DELETE CASCADE,
  peer_agent TEXT,
  peer_key BLOB,
  agents TEXT,
  kinds TEXT,
  created_ms INTEGER NOT NULL,
  CHECK ((agent_id IS NOT NULL AND link_id IS NULL)
    OR (agent_id IS NULL AND link_id IS NOT NULL AND peer_agent IS NOT NULL AND peer_key IS NOT NULL)),
  UNIQUE(link_id, peer_agent)
);
-- What approvers answered in the owner's place, and answers that did not count (PG-57): for the owner's list
CREATE TABLE IF NOT EXISTS delegated_answers(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  approval_id TEXT NOT NULL,
  action TEXT NOT NULL,
  requester TEXT NOT NULL,
  contact TEXT NOT NULL,
  target TEXT,
  approver TEXT NOT NULL,
  device TEXT,
  decision TEXT NOT NULL CHECK (decision IN ('approved', 'denied', 'refused')),
  reason TEXT NOT NULL,
  why TEXT,
  summary TEXT NOT NULL,
  at_ms INTEGER NOT NULL
);
-- The kinds of files the owner allowed from a contact (D-130): `code`, `executables`, `installers` or `.ext`
CREATE TABLE IF NOT EXISTS file_allow(
  link_id BLOB NOT NULL REFERENCES links(link_id) ON DELETE CASCADE,
  entry TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY(link_id, entry)
);
-- Where files from an own computer, or from one of its agents (by its name on the link), are saved (D-130); agent ''
-- is the contact itself
CREATE TABLE IF NOT EXISTS file_save_dirs(
  link_id BLOB NOT NULL REFERENCES links(link_id) ON DELETE CASCADE,
  agent TEXT NOT NULL,
  path TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY(link_id, agent)
);
-- Local routes between two agents of this computer (D-132, CONTROL §32; experimental): the owner's connection, both
-- ways; `a_tasks`: agent a takes b's messages as tasks, `b_tasks` the other way
CREATE TABLE IF NOT EXISTS local_routes(
  a_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  b_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  a_tasks INTEGER NOT NULL DEFAULT 0,
  b_tasks INTEGER NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY (a_id, b_id),
  CHECK (a_id < b_id)
);
-- An agent's default counterpart on this computer (instead of one on a link, `agent_counterparts`)
CREATE TABLE IF NOT EXISTS agent_local_counterparts(
  agent_id INTEGER PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
  peer_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  created_ms INTEGER NOT NULL
);
-- Messages over a local route: the text, what its writer had read when it wrote (`carried`, its taint entries, and
-- `local_level`), its place in a chain (`hop`); read once by the recipient
CREATE TABLE IF NOT EXISTS local_messages(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  from_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  to_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  carried TEXT NOT NULL,
  local_level INTEGER NOT NULL,
  hop INTEGER NOT NULL,
  created_ms INTEGER NOT NULL,
  read_ms INTEGER
);
"#;

/// Indexes on columns that are added to old DBs by migration (created after it).
const INDEXES: &str = r#"
CREATE UNIQUE INDEX IF NOT EXISTS messages_author_n ON messages(link_id, author, n) WHERE n > 0;
CREATE INDEX IF NOT EXISTS messages_link_kind ON messages(link_id, kind, seq);
CREATE INDEX IF NOT EXISTS messages_audit ON messages(link_id, author, n, seq);
CREATE INDEX IF NOT EXISTS messages_topic ON messages(link_id, topic_id, seq) WHERE topic_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS local_messages_to ON local_messages(to_id, read_ms, seq);
"#;

/// Slice 3 columns that DBs of slices 1–2 lack: `(table, column, definition)`.
const MIGRATIONS_V3: &[(&str, &str, &str)] = &[
    ("messages", "n", "INTEGER NOT NULL DEFAULT 0"),
    ("messages", "sig", "BLOB"),
    ("messages", "origin", "TEXT NOT NULL DEFAULT 'live'"),
    ("links", "state_counter", "INTEGER NOT NULL DEFAULT 0"),
    ("links", "blocked", "TEXT"),
    ("links", "hist_note", "TEXT"),
    ("links", "verified_ms", "INTEGER"),
    ("links", "rekey_pending", "BLOB"),
    // Boot ID of the OS boot in which the agent was bound to a process (D-P-9); NULL in old records means the binding
    // counts as removed and is redone on the next `antenna mcp` call
    ("agents", "anchor_boot", "TEXT"),
    // The contact's agents (v5, PROTOCOL §21): the contact node's features (`agents/0`, …; NULL: not known yet,
    // '': a node without features, `0.1.0-preview.1`), the agent as message author (display name and its link key)
    ("links", "peer_features", "TEXT"),
    ("messages", "agent", "TEXT"),
    ("messages", "agent_key", "BLOB"),
    // Addressing and topics (v6, PROTOCOL §23): for display and topic lists; the agents' visibility rule reads the
    // address from `core`. An outgoing message to a node without `addr/0` keeps its address only here.
    ("messages", "to_kind", "TEXT"),
    ("messages", "to_agent", "TEXT"),
    ("messages", "topic_id", "BLOB"),
    ("messages", "topic_title", "TEXT"),
    // What an agent reads (v6, CONTROL §20): 1 = also messages to everyone and unaddressed ones. Agents created
    // before v6 keep seeing what they saw (the default fills existing rows); new agents are inserted with 0
    ("agents", "everyone", "INTEGER NOT NULL DEFAULT 1"),
    // The message an agent's reply answers by default (v6): the last one it read with `inbox` on the link
    ("agent_cursor", "reply_to", "BLOB"),
    // Our message addressed to an agent the contact's node does not have (PROTOCOL §23, `no-agent/0`): `no_agent`
    // once its `deliver` / `no_such_agent` receipt came; for display only, the receipt in the history is the record
    ("messages", "undelivered", "TEXT"),
    // Whose messages the agent takes as tasks (schema 6, `agent_tasks`): NULL is the default (contacts at trust level
    // 5, evaluated live), otherwise a JSON list of link IDs (hex); `[]` means nobody
    ("agents", "tasks_from", "TEXT"),
    // The owner's urgent message (schema 16, PG-58): ours, sent with the flag; the contact's, the flag honoured here
    // (an own computer at level 5, fresh, live). For display only: the flag itself is in the signed `core`
    ("messages", "urgent", "INTEGER NOT NULL DEFAULT 0"),
];

/// Counter of changes to agent session labels (taint, declarations, reset) in this process: an agent's streaming
/// message rechecks the policy along the way only when it has moved (v0.2).
pub static LABEL_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Schema version: 1 is slice 1; 2 adds agents, their read cursors and the audit log (slice 2); 3 adds the author
/// counter, signature, link state counter, blocks and verification notes (slice 3); 4 adds agent wake rules (v0.2);
/// 5 adds the agents of link sides (`link_agents`, `messages.agent`/`agent_key`, `links.peer_features`); 6 adds
/// addressing and topics (`messages.to_kind`/`to_agent`/`topic_id`/`topic_title`, `agents.everyone`,
/// `agent_cursor.reply_to`) and `agents.tasks_from`; 7 adds local models and local agents (`local_models`,
/// `local_agents`, the conversations in `local_turns`, D-104); 8 adds teams of agents (`teams`, `team_members`,
/// `team_tasks`, `team_log`, D-111); 9 adds the owner's local settings of chats (`chats`) and `messages.undelivered`
/// (D-113: the chats themselves are derived from the messages, so nothing of an older DB is migrated); 10 adds profile
/// pictures (`own_pictures`, the owner's choices; `peer_pictures`, the newest picture each contact announced, its
/// photo as received and the JPEG rebuilt from it; PROTOCOL §25); 11 adds the agents' questions and where they go
/// (`escalations`, `agent_escalation`, D-118) and sleeping resident sessions (`resident_park`, D-121); 12 adds the agents' default
/// counterparts (`agent_counterparts`, the agent map, D-123); 13 adds approver agents and their answers
/// (`approvers`, `delegated_answers`, PG-57); 14 adds the owner's file allowlist per contact (`file_allow`) and the
/// save folders of own computers and their agents (`file_save_dirs`, D-130); 15 adds local routes between two agents
/// of this computer (`local_routes`, `agent_local_counterparts`, `local_messages`, D-132); 16 adds `messages.urgent`
/// (the owner's urgent messages, PG-58). New tables are
/// created with `CREATE TABLE IF NOT EXISTS`, new columns of old tables with `ALTER TABLE ADD COLUMN`. Messages of
/// format v0 (no signature, `n = 0`) are not part of the author chains: links of slices 1–2 do not work with v1 nodes
/// (a different `RoutingBlob.v`), they are created anew.
const SCHEMA_VERSION: i64 = 16;

/// An open DB.
pub struct Db {
    conn: Connection,
}

impl std::fmt::Debug for Db {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Db")
    }
}

fn arr32(v: Vec<u8>, what: &str) -> Result<[u8; 32]> {
    v.try_into()
        .map_err(|_| Error::internal(format!("db: {what} is not 32 bytes")))
}

fn ids_to_cbor(ids: &[MessageId]) -> Result<Vec<u8>> {
    Ok(antenna_proto::to_cbor(&ids.to_vec())?)
}

impl Db {
    /// Opens (or creates) the DB with a raw key. A wrong key is an error, not an empty DB.
    pub fn open(path: &Path, key: &Secret32) -> Result<Db> {
        let conn = Connection::open(path)?;
        // SQLCipher logs must not reach the daemon's stderr (TROUBLESHOOTING: "SQLCipher writes errors to stderr")
        let _ = conn.pragma_update(None, "cipher_log_level", "NONE");
        let hex = Zeroizing::new(format!(
            "x'{}'",
            data_encoding::HEXLOWER.encode(key.as_slice())
        ));
        conn.pragma_update(None, "key", hex.as_str())?;
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|_| Error::internal("database key mismatch or database is corrupt"))?;
        conn.execute_batch(
            "PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;",
        )?;
        // macOS: `fsync` does not flush the disk cache, so a commit may be lost on power loss (ratchet rollback,
        // SPEC §7); `F_FULLFSYNC` on every commit and checkpoint (PORTABILITY M-11)
        #[cfg(target_vendor = "apple")]
        conn.execute_batch("PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON;")?;
        conn.execute_batch(SCHEMA)?;
        for (table, col, def) in MIGRATIONS_V3 {
            let exists = conn
                .prepare(&format!(
                    "SELECT 1 FROM pragma_table_info('{table}') WHERE name = ?1"
                ))?
                .exists(params![col])?;
            if !exists {
                conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {col} {def}"))?;
            }
        }
        conn.execute_batch(INDEXES)?;
        conn.execute(
            "INSERT INTO meta(key, value) VALUES ('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = max(value, excluded.value)",
            params![SCHEMA_VERSION],
        )?;
        let _ = crate::owner_only::owner_only_file(path);
        Ok(Db { conn })
    }

    /// Connection (for the libsignal stores).
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// New transaction (IMMEDIATE).
    pub fn tx(&mut self) -> Result<Transaction<'_>> {
        Ok(self
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?)
    }

    /// Saves the link, the contact and the libsignal state atomically. Returns the final contact label.
    pub fn insert_link(&mut self, l: &NewLink, now_ms: u64) -> Result<String> {
        let tx = self.tx()?;
        let base = l
            .label
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("contact-{}", &l.link_id.to_hex()[..8]));
        let mut label = base.clone();
        let mut n = 2;
        while tx
            .query_row(
                "SELECT 1 FROM contacts WHERE label = ?1",
                params![label],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            label = format!("{base}-{n}");
            n += 1;
        }
        tx.execute(
            "INSERT INTO contacts(label, trust, created_ms) VALUES (?1, ?2, ?3)",
            params![label, l.trust, now_ms as i64],
        )?;
        let contact_id = tx.last_insert_rowid();
        let net_mode = NetMode::for_trust(l.trust);
        tx.execute(
            "INSERT INTO links(link_id, contact_id, role, net_mode, state, created_ms, transcript_hash, pairing_kx,
               local_secret, peer_endpoint, peer_addrs, root_ed25519_seed, root_ed25519_pk, root_mldsa_seed,
               root_mldsa_vk, peer_root_ed25519, peer_root_mldsa, sig_local_addr, sig_remote_addr)
             VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            params![
                &l.link_id.0[..],
                contact_id,
                l.role.as_str(),
                net_mode.as_str(),
                now_ms as i64,
                &l.transcript_hash[..],
                l.pairing_kx,
                &l.local_secret[..],
                &l.peer_endpoint[..],
                antenna_proto::to_cbor(&l.peer_addrs)?,
                &l.root_ed25519_seed[..],
                &l.root_ed25519_pk[..],
                &l.root_mldsa_seed[..],
                l.root_mldsa_vk,
                &l.peer_root_ed25519[..],
                l.peer_root_mldsa,
                l.sig_local_addr,
                l.sig_remote_addr,
            ],
        )?;
        tx.execute(
            "INSERT INTO sig_identity(link_id, keypair, registration_id) VALUES (?1, ?2, ?3)",
            params![
                &l.link_id.0[..],
                l.sig_identity_keypair.as_slice(),
                l.sig_registration_id
            ],
        )?;
        tx.execute(
            "INSERT INTO sig_remote_identity(link_id, address, identity) VALUES (?1, ?2, ?3)",
            params![&l.link_id.0[..], l.sig_remote_addr, l.sig_remote_identity],
        )?;
        tx.execute(
            "INSERT INTO sig_session(link_id, address, record) VALUES (?1, ?2, ?3)",
            params![
                &l.link_id.0[..],
                l.sig_remote_addr,
                l.sig_session_record.as_slice()
            ],
        )?;
        tx.commit()?;
        Ok(label)
    }

    fn link_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<RawLink> {
        Ok(RawLink {
            link_id: r.get(0)?,
            label: r.get(1)?,
            trust: r.get(2)?,
            role: r.get(3)?,
            net_mode: r.get(4)?,
            created_ms: r.get(5)?,
            pairing_kx: r.get(6)?,
            local_secret: r.get(7)?,
            local_port: r.get(8)?,
            peer_endpoint: r.get(9)?,
            peer_addrs: r.get(10)?,
            root_ed25519_pk: r.get(11)?,
            sig_local_addr: r.get(12)?,
            sig_remote_addr: r.get(13)?,
            lamport: r.get(14)?,
            last_kx: r.get(15)?,
            last_rx_version: r.get(16)?,
            last_rx_pq_len: r.get(17)?,
            last_paths: r.get(18)?,
            peer_root_ed25519: r.get(19)?,
            blocked: r.get(20)?,
        })
    }

    const LINK_SELECT: &'static str = "SELECT l.link_id, c.label, c.trust, l.role, l.net_mode, l.created_ms, l.pairing_kx,
        l.local_secret, l.local_port, l.peer_endpoint, l.peer_addrs, l.root_ed25519_pk, l.sig_local_addr,
        l.sig_remote_addr, l.lamport, l.last_kx, l.last_rx_version, l.last_rx_pq_len, l.last_paths,
        l.peer_root_ed25519, l.blocked
        FROM links l JOIN contacts c ON c.id = l.contact_id WHERE l.state = 'active'";

    /// All active links.
    pub fn links(&self) -> Result<Vec<LinkRow>> {
        let mut st = self
            .conn
            .prepare(&format!("{} ORDER BY l.created_ms", Self::LINK_SELECT))?;
        let rows = st.query_map([], Self::link_from_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?.into_row()?);
        }
        Ok(out)
    }

    /// Link by ID.
    pub fn link(&self, id: &LinkId) -> Result<LinkRow> {
        let raw = self
            .conn
            .query_row(
                &format!("{} AND l.link_id = ?1", Self::LINK_SELECT),
                params![&id.0[..]],
                Self::link_from_row,
            )
            .optional()?
            .ok_or_else(|| Error::new(code::NOT_FOUND, "no such link"))?;
        raw.into_row()
    }

    /// Finds a link by contact label (exact) or by a hex link_id prefix (≥ 8 characters).
    pub fn find_link(&self, query: &str) -> Result<LinkRow> {
        let links = self.links()?;
        if let Some(l) = links.iter().find(|l| l.label == query) {
            return Ok(l.clone());
        }
        let q = query.to_ascii_lowercase();
        if q.len() >= 8 {
            let m: Vec<_> = links
                .iter()
                .filter(|l| l.link_id.to_hex().starts_with(&q))
                .collect();
            if m.len() == 1 {
                return Ok(m[0].clone());
            }
        }
        Err(Error::new(code::NOT_FOUND, format!("no contact {query:?}")))
    }

    /// Saves the pairwise endpoint port.
    pub fn set_local_port(&self, id: &LinkId, port: u16) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET local_port = ?2 WHERE link_id = ?1",
            params![&id.0[..], port],
        )?;
        Ok(())
    }

    /// Updates the contact's address hints.
    pub fn set_peer_addrs(&self, id: &LinkId, addrs: &AddrHints) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET peer_addrs = ?2 WHERE link_id = ?1",
            params![&id.0[..], antenna_proto::to_cbor(addrs)?],
        )?;
        Ok(())
    }

    /// Node setting from `meta` (string).
    pub fn meta_get(&self, key: &str) -> Result<Option<String>> {
        let v: Option<Vec<u8>> = self
            .conn
            .query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(v.map(|v| String::from_utf8_lossy(&v).into_owned()))
    }

    /// Write a node setting to `meta`.
    pub fn meta_set(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value.as_bytes()],
        )?;
        Ok(())
    }

    /// The contact node's features (v5, PROTOCOL §21): `None` means not known yet; an empty list means a node without
    /// features.
    pub fn peer_features(&self, id: &LinkId) -> Result<Option<Vec<String>>> {
        let v: Option<String> = self.conn.query_row(
            "SELECT peer_features FROM links WHERE link_id = ?1",
            params![&id.0[..]],
            |r| r.get(0),
        )?;
        Ok(v.map(|v| {
            v.split(',')
                .filter(|f| !f.is_empty())
                .map(str::to_string)
                .collect()
        }))
    }

    /// Remember the contact node's features.
    pub fn set_peer_features(&self, id: &LinkId, list: &[String]) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET peer_features = ?2 WHERE link_id = ?1",
            params![&id.0[..], list.join(",")],
        )?;
        Ok(())
    }

    /// Facts about the last connection (TLS group, paths).
    pub fn set_transport_facts(&self, id: &LinkId, kx: &str, paths: &[String]) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET last_kx = ?2, last_paths = ?3 WHERE link_id = ?1",
            params![&id.0[..], kx, paths.join(" ")],
        )?;
        Ok(())
    }

    /// Current heads of the link (in ascending byte order).
    pub fn heads(conn: &Connection, id: &LinkId) -> Result<Vec<MessageId>> {
        let mut st = conn.prepare("SELECT msg_id FROM heads WHERE link_id = ?1 ORDER BY msg_id")?;
        let rows = st.query_map(params![&id.0[..]], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(MessageId(arr32(r?, "head")?));
        }
        Ok(out)
    }

    /// Maximum lamport of the link.
    pub fn lamport(conn: &Connection, id: &LinkId) -> Result<u64> {
        let v: i64 = conn.query_row(
            "SELECT lamport FROM links WHERE link_id = ?1",
            params![&id.0[..]],
            |r| r.get(0),
        )?;
        Ok(v as u64)
    }

    /// Whether the message exists.
    pub fn has_message(conn: &Connection, id: &MessageId) -> Result<bool> {
        Ok(conn
            .query_row(
                "SELECT 1 FROM messages WHERE id = ?1",
                params![&id.0[..]],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Mark a message as the owner's urgent one (PG-58), inside the caller's transaction: ours sent with the flag, or the
    /// contact's whose flag this node honoured.
    pub fn mark_urgent(conn: &Connection, id: &MessageId) -> Result<()> {
        conn.execute(
            "UPDATE messages SET urgent = 1 WHERE id = ?1",
            params![&id.0[..]],
        )?;
        Ok(())
    }

    /// Records a message and updates the heads and lamport (inside the caller's transaction). Returns `seq`.
    /// Another message of the same author with the same counter is a `history_conflict` error (history divergence).
    pub fn insert_message(conn: &Connection, m: &MessageRecord<'_>, now_ms: u64) -> Result<i64> {
        let r = conn.execute(
            "INSERT INTO messages(id, link_id, direction, author, lamport, ts, kind, body, core, received_ms, read,
               n, sig, origin, agent, agent_key, to_kind, to_agent, topic_id, topic_title)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
            params![
                &m.id.0[..],
                &m.link_id.0[..],
                if m.incoming { "in" } else { "out" },
                &m.author[..],
                m.lamport as i64,
                m.ts as i64,
                m.kind,
                m.body,
                m.core,
                now_ms as i64,
                if m.incoming && m.origin == "live" { 0 } else { 1 },
                m.n as i64,
                m.sig,
                m.origin,
                m.agent.map(|a| a.0),
                m.agent.and_then(|a| a.1).map(|k| k.to_vec()),
                m.to.map(|t| t.kind()),
                m.to.and_then(|t| t.agent()),
                m.topic.map(|t| t.id.to_vec()),
                m.topic.map(|t| t.title.as_str()),
            ],
        );
        if let Err(rusqlite::Error::SqliteFailure(e, msg)) = &r
            && e.code == rusqlite::ErrorCode::ConstraintViolation
            && msg
                .as_deref()
                .is_some_and(|s| s.contains("messages.n") || s.contains("author"))
        {
            return Err(Error::new(
                code::HISTORY_CONFLICT,
                "another message of this author with the same counter is already in the history",
            ));
        }
        r?;
        let seq = conn.last_insert_rowid();
        for p in m.parents {
            conn.execute(
                "INSERT OR IGNORE INTO message_parents(link_id, msg_id, parent_id) VALUES (?1, ?2, ?3)",
                params![&m.link_id.0[..], &m.id.0[..], &p.0[..]],
            )?;
            conn.execute(
                "DELETE FROM heads WHERE link_id = ?1 AND msg_id = ?2",
                params![&m.link_id.0[..], &p.0[..]],
            )?;
        }
        // A new message is a head if none of the already known ones refers to it (out-of-order delivery)
        let referenced = conn
            .query_row(
                "SELECT 1 FROM message_parents WHERE link_id = ?1 AND parent_id = ?2",
                params![&m.link_id.0[..], &m.id.0[..]],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !referenced {
            conn.execute(
                "INSERT OR IGNORE INTO heads(link_id, msg_id) VALUES (?1, ?2)",
                params![&m.link_id.0[..], &m.id.0[..]],
            )?;
        }
        conn.execute(
            "UPDATE links SET lamport = max(lamport, ?2) WHERE link_id = ?1",
            params![&m.link_id.0[..], m.lamport as i64],
        )?;
        Ok(seq)
    }

    /// Facts about the last accepted libsignal message.
    pub fn set_rx_facts(conn: &Connection, id: &LinkId, version: u32, pq_len: u32) -> Result<()> {
        conn.execute(
            "UPDATE links SET last_rx_version = ?2, last_rx_pq_len = ?3 WHERE link_id = ?1",
            params![&id.0[..], version, pq_len],
        )?;
        Ok(())
    }

    /// Puts a ready blob into the send queue.
    pub fn outbox_push(
        conn: &Connection,
        id: &LinkId,
        msg: &MessageId,
        blob: &[u8],
        now_ms: u64,
    ) -> Result<()> {
        conn.execute(
            "INSERT INTO outbox(link_id, msg_id, blob, created_ms) VALUES (?1, ?2, ?3, ?4)",
            params![&id.0[..], &msg.0[..], blob, now_ms as i64],
        )?;
        Ok(())
    }

    /// The link's send queue, in order.
    pub fn outbox(&self, id: &LinkId) -> Result<Vec<OutboxItem>> {
        let mut st = self.conn.prepare(
            "SELECT seq, msg_id, blob, attempts FROM outbox WHERE link_id = ?1 ORDER BY seq",
        )?;
        let rows = st.query_map(params![&id.0[..]], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Vec<u8>>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (seq, msg, blob, attempts) = r?;
            out.push(OutboxItem {
                seq,
                msg_id: MessageId(arr32(msg, "outbox msg_id")?),
                blob,
                attempts: attempts as u32,
            });
        }
        Ok(out)
    }

    /// Queue length.
    pub fn outbox_len(&self, id: &LinkId) -> Result<u64> {
        let n: i64 = self.conn.query_row(
            "SELECT count(*) FROM outbox WHERE link_id = ?1",
            params![&id.0[..]],
            |r| r.get(0),
        )?;
        Ok(n as u64)
    }

    /// Removes a delivered item.
    pub fn outbox_remove(&self, seq: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM outbox WHERE seq = ?1", params![seq])?;
        Ok(())
    }

    /// Takes a message off the queue as undeliverable and marks it `failed` (it is not silently lost).
    pub fn outbox_fail(&self, seq: i64, msg: &MessageId) -> Result<()> {
        self.conn
            .execute("DELETE FROM outbox WHERE seq = ?1", params![seq])?;
        self.conn.execute(
            "UPDATE messages SET failed = 1 WHERE id = ?1",
            params![&msg.0[..]],
        )?;
        Ok(())
    }

    /// Number of outgoing messages that could not be delivered.
    pub fn failed_len(&self, id: &LinkId) -> Result<u64> {
        let n: i64 = self.conn.query_row(
            "SELECT count(*) FROM messages WHERE link_id = ?1 AND direction = 'out' AND failed = 1",
            params![&id.0[..]],
            |r| r.get(0),
        )?;
        Ok(n as u64)
    }

    /// Counts a failed attempt.
    pub fn outbox_bump(&self, seq: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE outbox SET attempts = attempts + 1 WHERE seq = ?1",
            params![seq],
        )?;
        Ok(())
    }

    /// The owner's unread incoming messages, in order of receipt (only text delivered as new).
    pub fn unread(&self) -> Result<Vec<InboxRow>> {
        self.unread_where("m.read = 0", [])
    }

    fn unread_where(&self, cond: &str, p: impl rusqlite::Params) -> Result<Vec<InboxRow>> {
        let mut st = self.conn.prepare(&format!(
            "SELECT m.seq, m.id, m.link_id, c.label, c.trust, m.kind, m.body, m.ts, m.received_ms, m.lamport, m.agent,
                    m.core
             FROM messages m JOIN links l ON l.link_id = m.link_id JOIN contacts c ON c.id = l.contact_id
             WHERE m.direction = 'in' AND m.kind = 'text' AND m.origin = 'live' AND l.state = 'active' AND {cond}
             ORDER BY m.seq"
        ))?;
        let rows = st.query_map(p, |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Vec<u8>>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, u8>(4)?,
                r.get::<_, String>(5)?,
                r.get::<_, String>(6)?,
                r.get::<_, i64>(7)?,
                r.get::<_, i64>(8)?,
                r.get::<_, i64>(9)?,
                r.get::<_, Option<String>>(10)?,
                r.get::<_, Vec<u8>>(11)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (seq, id, link, label, trust, kind, body, ts, rx, lamport, agent, core) = r?;
            // The address is read from the signed bytes: a column could be edited, `core` is checked by the ID
            let (to, topic) = antenna_proto::from_cbor::<antenna_proto::EnvelopeCore>(&core)
                .map(|c| (c.to, c.topic))
                .unwrap_or_default();
            let id = MessageId(arr32(id, "message id")?);
            let mut pst = self.conn.prepare_cached(
                "SELECT parent_id FROM message_parents WHERE msg_id = ?1 ORDER BY parent_id",
            )?;
            let parents = pst
                .query_map(params![&id.0[..]], |r| r.get::<_, Vec<u8>>(0))?
                .map(|p| Ok(MessageId(arr32(p?, "parent")?)))
                .collect::<Result<Vec<_>>>()?;
            out.push(InboxRow {
                seq,
                id,
                link_id: LinkId(arr32(link, "link id")?),
                label,
                trust,
                kind,
                body,
                ts: ts as u64,
                received_ms: rx as u64,
                lamport: lamport as u64,
                parents,
                agent,
                to,
                topic,
            });
        }
        Ok(out)
    }

    /// Marks messages as read.
    pub fn mark_read(&mut self, seqs: &[i64]) -> Result<()> {
        let tx = self.tx()?;
        for s in seqs {
            tx.execute("UPDATE messages SET read = 1 WHERE seq = ?1", params![s])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Message parents (for debugging and tests).
    pub fn parents_cbor(ids: &[MessageId]) -> Result<Vec<u8>> {
        ids_to_cbor(ids)
    }
}

// Agents, their read cursors, audit log (slice 2)

/// A link read by an agent session: for link isolation (any read) and for the permission ceiling (incoming only).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TaintEntry {
    /// Link (hex).
    pub link: String,
    /// Level at the time of reading.
    pub level: u8,
    /// When.
    pub at: u64,
    /// Incoming messages (the contact's text) were read: permission ceiling. `false` means only the owner's outgoing
    /// messages (link data, but not the contact's instructions): only link isolation.
    #[serde(default = "yes")]
    pub ceiling: bool,
}

fn yes() -> bool {
    true
}

/// A declared read of local data.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DeclEntry {
    /// Level.
    pub level: u8,
    /// What.
    pub what: String,
    /// When.
    pub at: u64,
}

/// An agent and its session.
#[derive(Debug, Clone)]
pub struct AgentRow {
    /// ID.
    pub id: i64,
    /// Name.
    pub name: String,
    /// The agent's links; `None` means all.
    pub links: Option<Vec<LinkId>>,
    /// Base local data label.
    pub local_level: u8,
    /// Created.
    pub created_ms: u64,
    /// Incoming messages with `seq` up to this are not shown to the agent (they arrived before it was created).
    pub start_seq: i64,
    /// Start of the current session.
    pub session_started_ms: u64,
    /// The process the token is bound to: (pid, starttime, comm).
    pub anchor: Option<(i32, u64, String)>,
    /// Taint.
    pub taint: Vec<TaintEntry>,
    /// Declared reads.
    pub declared: Vec<DeclEntry>,
    /// Also reads messages addressed to everyone and unaddressed ones (v6, CONTROL §20).
    pub everyone: bool,
    /// Whose messages the agent takes as tasks: `None` is the default (trust level 5), `Some([])` nobody.
    pub tasks_from: Option<Vec<LinkId>>,
}

/// An audit log entry.
#[derive(Debug, Clone)]
pub struct ReceiptRow {
    /// Number.
    pub seq: i64,
    /// Time.
    pub ts: u64,
    /// Who.
    pub actor: String,
    /// Action.
    pub action: String,
    /// Decision.
    pub decision: String,
    /// Details.
    pub reason: String,
    /// Message.
    pub msg_id: Option<MessageId>,
    /// Approval request.
    pub approval_id: Option<String>,
}

/// A new audit log entry.
pub struct NewReceipt<'a> {
    /// Link.
    pub link: &'a LinkId,
    /// Who.
    pub actor: &'a str,
    /// Action.
    pub action: &'a str,
    /// Decision.
    pub decision: &'a str,
    /// Details (without message text).
    pub reason: &'a str,
    /// Message.
    pub msg_id: Option<&'a MessageId>,
    /// Approval request.
    pub approval_id: Option<&'a str>,
}

const AGENT_SELECT: &str =
    "SELECT id, name, links, local_level, created_ms, start_seq, session_started_ms,
    anchor_pid, anchor_start, anchor_comm, taint, declared, anchor_boot, everyone, tasks_from FROM agents";

fn agent_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<(AgentRaw, i64)> {
    Ok((
        AgentRaw {
            name: r.get(1)?,
            links: r.get(2)?,
            local_level: r.get(3)?,
            created_ms: r.get(4)?,
            start_seq: r.get(5)?,
            session_started_ms: r.get(6)?,
            anchor_pid: r.get(7)?,
            anchor_start: r.get(8)?,
            anchor_comm: r.get(9)?,
            taint: r.get(10)?,
            declared: r.get(11)?,
            anchor_boot: r.get(12)?,
            everyone: r.get(13)?,
            tasks_from: r.get(14)?,
        },
        r.get(0)?,
    ))
}

struct AgentRaw {
    name: String,
    links: Option<String>,
    local_level: u8,
    created_ms: i64,
    start_seq: i64,
    session_started_ms: i64,
    anchor_pid: Option<i32>,
    anchor_start: Option<i64>,
    anchor_comm: Option<String>,
    taint: String,
    declared: String,
    anchor_boot: Option<String>,
    everyone: bool,
    tasks_from: Option<String>,
}

fn link_from_hex(s: &str) -> Result<LinkId> {
    let v = data_encoding::HEXLOWER
        .decode(s.as_bytes())
        .map_err(|_| Error::internal("db: bad link id"))?;
    Ok(LinkId(arr32(v, "link id")?))
}

/// A JSON list of link IDs (hex), as `agents.links` and `agents.tasks_from` keep them.
fn links_from_json(j: Option<String>, what: &str) -> Result<Option<Vec<LinkId>>> {
    let Some(j) = j else {
        return Ok(None);
    };
    let v: Vec<String> =
        serde_json::from_str(&j).map_err(|_| Error::internal(format!("db: bad agent {what}")))?;
    Ok(Some(
        v.iter()
            .map(|h| link_from_hex(h))
            .collect::<Result<Vec<_>>>()?,
    ))
}

fn links_to_json(links: Option<&[LinkId]>) -> Option<String> {
    links.map(|l| {
        serde_json::to_string(&l.iter().map(LinkId::to_hex).collect::<Vec<_>>())
            .expect("strings serialize")
    })
}

impl AgentRaw {
    fn into_row(self, id: i64) -> Result<AgentRow> {
        let links = links_from_json(self.links, "links")?;
        let tasks_from = links_from_json(self.tasks_from, "tasks")?;
        Ok(AgentRow {
            id,
            name: self.name,
            links,
            local_level: self.local_level,
            created_ms: self.created_ms as u64,
            start_seq: self.start_seq,
            session_started_ms: self.session_started_ms as u64,
            // A binding from another OS boot is not a binding (D-P-9): PIDs and start times repeat after a reboot
            anchor: match (self.anchor_pid, self.anchor_start) {
                (Some(p), Some(s)) if self.anchor_boot.as_deref() == crate::procinfo::boot_id() => {
                    Some((p, s as u64, self.anchor_comm.unwrap_or_default()))
                }
                _ => None,
            },
            taint: serde_json::from_str(&self.taint)
                .map_err(|_| Error::internal("db: bad agent taint"))?,
            declared: serde_json::from_str(&self.declared)
                .map_err(|_| Error::internal("db: bad agent declarations"))?,
            everyone: self.everyone,
            tasks_from,
        })
    }
}

impl Db {
    /// The last message `seq` (0 if empty).
    pub fn max_seq(&self) -> Result<i64> {
        Ok(self
            .conn
            .query_row("SELECT coalesce(max(seq), 0) FROM messages", [], |r| {
                r.get(0)
            })?)
    }

    /// New agent. It sees only incoming messages that arrive after its creation; `everyone`: also messages
    /// addressed to everyone and unaddressed ones (v6).
    pub fn agent_insert(
        &self,
        name: &str,
        token_hash: &[u8; 32],
        links: Option<&[LinkId]>,
        local_level: u8,
        everyone: bool,
        now_ms: u64,
    ) -> Result<i64> {
        let links_json = links_to_json(links);
        let start = self.max_seq()?;
        let r = self.conn.execute(
            "INSERT INTO agents(name, token_hash, links, local_level, created_ms, start_seq, session_started_ms,
               everyone)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?5, ?7)",
            params![name, &token_hash[..], links_json, local_level, now_ms as i64, start, everyone],
        );
        match r {
            Ok(_) => Ok(self.conn.last_insert_rowid()),
            Err(rusqlite::Error::SqliteFailure(e, _))
                if e.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(Error::bad_request(format!("agent {name:?} already exists")))
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Agent by token hash.
    pub fn agent_by_token(&self, token_hash: &[u8; 32]) -> Result<Option<AgentRow>> {
        let r = self
            .conn
            .query_row(
                &format!("{AGENT_SELECT} WHERE token_hash = ?1"),
                params![&token_hash[..]],
                agent_from_row,
            )
            .optional()?;
        r.map(|(raw, id)| raw.into_row(id)).transpose()
    }

    /// Agent by ID.
    pub fn agent(&self, id: i64) -> Result<AgentRow> {
        let (raw, id) = self
            .conn
            .query_row(
                &format!("{AGENT_SELECT} WHERE id = ?1"),
                params![id],
                agent_from_row,
            )
            .optional()?
            .ok_or_else(|| Error::new(code::TOKEN_INVALID, "agent was removed"))?;
        raw.into_row(id)
    }

    /// Agent by name.
    pub fn agent_by_name(&self, name: &str) -> Result<AgentRow> {
        let (raw, id) = self
            .conn
            .query_row(
                &format!("{AGENT_SELECT} WHERE name = ?1"),
                params![name],
                agent_from_row,
            )
            .optional()?
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no agent {name:?}")))?;
        raw.into_row(id)
    }

    /// All agents.
    pub fn agents(&self) -> Result<Vec<AgentRow>> {
        let mut st = self.conn.prepare(&format!("{AGENT_SELECT} ORDER BY id"))?;
        let rows = st.query_map([], agent_from_row)?;
        let mut out = Vec::new();
        for r in rows {
            let (raw, id) = r?;
            out.push(raw.into_row(id)?);
        }
        Ok(out)
    }

    /// Save the session's taint and declarations.
    pub fn agent_save_label(
        &self,
        id: i64,
        taint: &[TaintEntry],
        declared: &[DeclEntry],
    ) -> Result<()> {
        LABEL_GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.conn.execute(
            "UPDATE agents SET taint = ?2, declared = ?3 WHERE id = ?1",
            params![
                id,
                serde_json::to_string(taint).expect("serializable"),
                serde_json::to_string(declared).expect("serializable")
            ],
        )?;
        Ok(())
    }

    /// Bind the token to a process (or unbind it). Together with the binding, the current OS boot ID (D-P-9).
    pub fn agent_set_anchor(&self, id: i64, anchor: Option<(i32, u64, &str)>) -> Result<()> {
        let (p, s, c, b) = match anchor {
            Some((p, s, c)) => (Some(p), Some(s as i64), Some(c), crate::procinfo::boot_id()),
            None => (None, None, None, None),
        };
        self.conn.execute(
            "UPDATE agents SET anchor_pid = ?2, anchor_start = ?3, anchor_comm = ?4, anchor_boot = ?5 WHERE id = ?1",
            params![id, p, s, c, b],
        )?;
        Ok(())
    }

    /// Tests only: the boot ID of an agent binding (as if the binding was made in another OS boot).
    #[cfg(test)]
    pub fn agent_set_anchor_boot(&self, id: i64, boot: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE agents SET anchor_boot = ?2 WHERE id = ?1",
            params![id, boot],
        )?;
        Ok(())
    }

    /// New session: taint and declarations are reset. The process binding **stays** (otherwise the tree of a still
    /// living host would become the "owner" until the next MCP call); it is removed by itself when the host exits.
    /// What the agent has read stays read.
    pub fn agent_reset(&self, id: i64, now_ms: u64) -> Result<()> {
        LABEL_GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.conn.execute(
            "UPDATE agents SET taint = '[]', declared = '[]', session_started_ms = ?2 WHERE id = ?1",
            params![id, now_ms as i64],
        )?;
        Ok(())
    }

    /// Whose messages the agent takes as tasks (`agent_tasks`): `None` is the default (trust level 5).
    pub fn agent_set_tasks(&self, id: i64, tasks_from: Option<&[LinkId]>) -> Result<()> {
        self.conn.execute(
            "UPDATE agents SET tasks_from = ?2 WHERE id = ?1",
            params![id, links_to_json(tasks_from)],
        )?;
        Ok(())
    }

    /// New agent token hash (the dedicated wake agent: its own token for every launch, the old one stops working).
    pub fn agent_set_token(&self, id: i64, token_hash: &[u8; 32]) -> Result<()> {
        self.conn.execute(
            "UPDATE agents SET token_hash = ?2 WHERE id = ?1",
            params![id, &token_hash[..]],
        )?;
        Ok(())
    }

    /// The link's wake rule (v0.2): `(agent, rule JSON, created)`.
    pub fn wake_rule(&self, link: &LinkId) -> Result<Option<(i64, String, u64)>> {
        Ok(self
            .conn
            .query_row(
                "SELECT agent_id, rule, created_ms FROM wake_rules WHERE link_id = ?1",
                params![&link.0[..]],
                |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as u64)),
            )
            .optional()?)
    }

    /// All wake rules: `(link, agent, rule JSON, created)`.
    pub fn wake_rules(&self) -> Result<Vec<(LinkId, i64, String, u64)>> {
        let mut st = self.conn.prepare(
            "SELECT link_id, agent_id, rule, created_ms FROM wake_rules ORDER BY created_ms",
        )?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get::<_, i64>(3)? as u64,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (l, a, rule, c) = r?;
            out.push((LinkId(arr32(l, "wake link")?), a, rule, c));
        }
        Ok(out)
    }

    /// Write the link's wake rule.
    pub fn wake_rule_set(
        &self,
        link: &LinkId,
        agent_id: i64,
        rule: &str,
        now_ms: u64,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO wake_rules(link_id, agent_id, rule, created_ms) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(link_id) DO UPDATE SET agent_id = excluded.agent_id, rule = excluded.rule",
            params![&link.0[..], agent_id, rule, now_ms as i64],
        )?;
        Ok(())
    }

    /// Replace only the rule JSON of an existing wake rule (a resident agent's session record and counters).
    pub fn wake_rule_update(&self, link: &LinkId, rule: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE wake_rules SET rule = ?2 WHERE link_id = ?1",
            params![&link.0[..], rule],
        )?;
        Ok(())
    }

    /// Delete the link's wake rule.
    pub fn wake_rule_remove(&self, link: &LinkId) -> Result<()> {
        self.conn.execute(
            "DELETE FROM wake_rules WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        Ok(())
    }

    /// Revoke an agent (the token stops working).
    pub fn agent_remove(&self, id: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM agent_cursor WHERE agent_id = ?1", params![id])?;
        self.conn
            .execute("DELETE FROM agents WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Incoming messages unread **by this agent** on its links (every reader has its own cursor) that it may see
    /// (`sees`: the v6 visibility rule, CONTROL §20), at most `limit`. `passed` holds, per link, the highest `seq`
    /// examined before the limit cut, visible or not: the cursor moves past messages the agent will never see.
    pub fn agent_unread(
        &self,
        agent: &AgentRow,
        only: Option<&LinkId>,
        limit: usize,
        sees: &dyn Fn(&InboxRow) -> bool,
    ) -> Result<AgentUnread> {
        self.agent_unread_within(agent, only, limit, usize::MAX, sees)
    }

    /// [`Self::agent_unread`] within a budget of `max_chars` characters of text: the first visible message is taken
    /// whole whatever its length, and a later one that would go over the budget ends the page, unread, with
    /// [`AgentUnread::more`] set (a reply must never hold more than its reader is shown: what is cut off by the MCP
    /// host or the terminal would be marked read unseen).
    pub fn agent_unread_within(
        &self,
        agent: &AgentRow,
        only: Option<&LinkId>,
        limit: usize,
        max_chars: usize,
        sees: &dyn Fn(&InboxRow) -> bool,
    ) -> Result<AgentUnread> {
        let rows = self.unread_where(
            "m.seq > coalesce((SELECT last_seq FROM agent_cursor ac WHERE ac.agent_id = ?1 AND ac.link_id = m.link_id), ?2)",
            params![agent.id, agent.start_seq],
        )?;
        let mut out = AgentUnread::default();
        let mut chars = 0usize;
        for r in rows {
            if !agent
                .links
                .as_ref()
                .is_none_or(|ls| ls.contains(&r.link_id))
                || !only.is_none_or(|l| *l == r.link_id)
            {
                continue;
            }
            let visible = sees(&r);
            if out.rows.len() >= limit {
                out.more |= visible;
                break;
            }
            if visible {
                let n = r.body.chars().count();
                if !out.rows.is_empty() && chars.saturating_add(n) > max_chars {
                    out.more = true;
                    break;
                }
                chars = chars.saturating_add(n);
            }
            let e = out.passed.entry(r.link_id).or_insert(r.seq);
            *e = (*e).max(r.seq);
            if visible {
                out.rows.push(r);
            }
        }
        Ok(out)
    }

    /// Move the agent's cursor on a link.
    pub fn agent_advance(&self, agent_id: i64, link: &LinkId, seq: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO agent_cursor(agent_id, link_id, last_seq) VALUES (?1, ?2, ?3)
             ON CONFLICT(agent_id, link_id) DO UPDATE SET last_seq = max(last_seq, excluded.last_seq)",
            params![agent_id, &link.0[..], seq],
        )?;
        Ok(())
    }

    /// Entry in the link's audit log.
    pub fn receipt_add(&self, r: &NewReceipt<'_>, now_ms: u64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO receipts(link_id, ts, actor, action, decision, reason, msg_id, approval_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                &r.link.0[..],
                now_ms as i64,
                r.actor,
                r.action,
                r.decision,
                r.reason,
                r.msg_id.map(|m| m.0.to_vec()),
                r.approval_id
            ],
        )?;
        // The link's audit log is limited to the last 10,000 entries
        self.conn.execute(
            "DELETE FROM receipts WHERE link_id = ?1 AND seq <= (SELECT seq FROM receipts WHERE link_id = ?1
               ORDER BY seq DESC LIMIT 1 OFFSET 10000)",
            params![&r.link.0[..]],
        )?;
        Ok(())
    }

    /// The latest entries of the link's audit log (in order).
    pub fn receipts(&self, link: &LinkId, limit: u32) -> Result<Vec<ReceiptRow>> {
        let mut st = self.conn.prepare(
            "SELECT seq, ts, actor, action, decision, reason, msg_id, approval_id FROM receipts
             WHERE link_id = ?1 ORDER BY seq DESC LIMIT ?2",
        )?;
        let rows = st.query_map(params![&link.0[..], limit], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, String>(5)?,
                r.get::<_, Option<Vec<u8>>>(6)?,
                r.get::<_, Option<String>>(7)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (seq, ts, actor, action, decision, reason, msg, approval) = r?;
            out.push(ReceiptRow {
                seq,
                ts: ts as u64,
                actor,
                action,
                decision,
                reason,
                msg_id: msg
                    .map(|m| arr32(m, "receipt msg").map(MessageId))
                    .transpose()?,
                approval_id: approval,
            });
        }
        out.reverse();
        Ok(out)
    }

    /// New trust level for the contact (and the link network mode derived from it, SPEC §4).
    pub fn set_trust(&self, link: &LinkId, level: u8) -> Result<()> {
        if !(1..=5).contains(&level) {
            return Err(Error::bad_request("trust must be 1..5"));
        }
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "UPDATE contacts SET trust = ?2 WHERE id = (SELECT contact_id FROM links WHERE link_id = ?1)",
            params![&link.0[..], level],
        )?;
        tx.execute(
            "UPDATE links SET net_mode = ?2 WHERE link_id = ?1",
            params![&link.0[..], NetMode::for_trust(level).as_str()],
        )?;
        tx.commit()?;
        Ok(())
    }
}

/// A link history message.
#[derive(Debug, Clone)]
pub struct HistoryRow {
    /// Number.
    pub seq: i64,
    /// ID.
    pub id: MessageId,
    /// Incoming.
    pub incoming: bool,
    /// Type.
    pub kind: String,
    /// Text.
    pub body: String,
    /// Author time.
    pub ts: u64,
    /// Received / created locally.
    pub local_ms: u64,
    /// Lamport.
    pub lamport: u64,
    /// `received` / `queued` / `delivered` / `failed`.
    pub status: &'static str,
    /// Receipt (for `kind = receipt`).
    pub receipt: Option<antenna_proto::ReceiptBody>,
    /// Author agent (v5): our own agent for outgoing messages, the contact's agent for incoming ones.
    pub agent: Option<String>,
    /// Who it is for (v6): `(kind, agent)` as stored.
    pub to: ToCols,
    /// The topic (v6): `(id, title)`.
    pub topic: TopicCols,
    /// Incoming and not yet read by the owner.
    pub unread: bool,
    /// Ours, addressed to an agent the contact's node said it does not have (`no-agent/0`).
    pub no_agent: bool,
    /// The owner's urgent message (PG-58): ours sent with the flag, or the contact's with the flag honoured here.
    pub urgent: bool,
}

/// A stored address (v6): `(kind, agent)`.
pub type ToCols = Option<(String, Option<String>)>;
/// A stored topic (v6): `(id, title)`.
pub type TopicCols = Option<([u8; 16], String)>;

/// Address and topic columns of a message row (v6) → the values.
fn addr_cols(
    to_kind: Option<String>,
    to_agent: Option<String>,
    topic_id: Option<Vec<u8>>,
    topic_title: Option<String>,
) -> (ToCols, TopicCols) {
    let to = to_kind.map(|k| (k, to_agent));
    let topic = match (topic_id, topic_title) {
        (Some(id), Some(t)) => <[u8; 16]>::try_from(id).ok().map(|id| (id, t)),
        _ => None,
    };
    (to, topic)
}

/// The message an agent's reply answers (v6): who wrote it and its topic.
#[derive(Debug, Clone)]
pub struct Answered {
    /// It came from the contact.
    pub incoming: bool,
    /// The author's agent name (the contact's agent, from its announcement), `None` for the person.
    pub agent: Option<String>,
    /// Its topic, from the signed `core`.
    pub topic: Option<antenna_proto::Topic>,
}

/// A link's topic (v6, `topics`).
#[derive(Debug, Clone)]
pub struct TopicRow {
    /// ID.
    pub id: [u8; 16],
    /// Title of its latest message.
    pub title: String,
    /// Messages.
    pub count: u64,
    /// `seq` of the latest one.
    pub last_seq: i64,
    /// When the latest one was received or created, Unix ms.
    pub last_ms: u64,
}

/// Which part of a link's history [`Db::history_in`] reads.
#[derive(Debug, Clone, Default)]
pub struct HistoryFilter<'a> {
    /// Only this chat (CONTROL §26): the contact's agent, `""` the person chat.
    pub chat: Option<&'a str>,
    /// Only messages (text, files, file requests), no receipts.
    pub messages_only: bool,
}

impl Db {
    /// A page of the link history: messages with `seq < before` (or the latest), ascending; the second value tells
    /// whether there are older ones.
    pub fn history(
        &self,
        link: &LinkId,
        after: i64,
        before: Option<i64>,
        limit: u32,
    ) -> Result<(Vec<HistoryRow>, bool)> {
        self.history_in(link, after, before, limit, &HistoryFilter::default())
    }

    /// [`Db::history`] of one chat of the link, or of its messages only.
    pub fn history_in(
        &self,
        link: &LinkId,
        after: i64,
        before: Option<i64>,
        limit: u32,
        filter: &HistoryFilter<'_>,
    ) -> Result<(Vec<HistoryRow>, bool)> {
        let kinds = if filter.messages_only {
            crate::chats::MESSAGE_KINDS
        } else {
            "m.kind != 'control'"
        };
        let mut st = self.conn.prepare(&format!(
            "SELECT m.seq, m.id, m.direction, m.kind, m.body, m.ts, m.received_ms, m.lamport, m.failed,
                    EXISTS(SELECT 1 FROM outbox o WHERE o.msg_id = m.id),
                    CASE WHEN m.kind = 'receipt' OR m.direction = 'in' THEN m.core END, m.agent,
                    m.to_kind, m.to_agent, m.topic_id, m.topic_title, m.read, m.undelivered, m.urgent
             FROM messages m WHERE m.link_id = ?1 AND m.seq < ?2 AND m.seq > ?4 AND {kinds}
               AND (?5 IS NULL OR {chat} = ?5)
             ORDER BY m.seq DESC LIMIT ?3",
            chat = crate::chats::CHAT_OF,
        ))?;
        let rows = st.query_map(
            params![
                &link.0[..],
                before.unwrap_or(i64::MAX),
                limit as i64 + 1,
                after,
                filter.chat
            ],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, i64>(8)?,
                    r.get::<_, bool>(9)?,
                    r.get::<_, Option<Vec<u8>>>(10)?,
                    r.get::<_, Option<String>>(11)?,
                    (
                        r.get::<_, Option<String>>(12)?,
                        r.get::<_, Option<String>>(13)?,
                        r.get::<_, Option<Vec<u8>>>(14)?,
                        r.get::<_, Option<String>>(15)?,
                        r.get::<_, i64>(16)?,
                        r.get::<_, Option<String>>(17)?,
                        r.get::<_, i64>(18)?,
                    ),
                ))
            },
        )?;
        let mut out = Vec::new();
        for r in rows {
            let (seq, id, dir, kind, body, ts, local, lamport, failed, queued, rcore, agent, extra) =
                r?;
            let (to_kind, to_agent, topic_id, topic_title, read, undelivered, urgent) = extra;
            let incoming = dir == "in";
            let core = rcore
                .and_then(|c| antenna_proto::from_cbor::<antenna_proto::EnvelopeCore>(&c).ok());
            // An incoming message's address and topic come from the signed bytes (the agents' visibility rule reads
            // them); our own message's may be local only (a contact node without `addr/0`), so from the columns
            let (to, topic) = match &core {
                Some(c) if incoming => (
                    c.to.as_ref()
                        .map(|t| (t.kind().to_string(), t.agent().map(str::to_string))),
                    c.topic.as_ref().map(|t| (t.id, t.title.clone())),
                ),
                _ => addr_cols(to_kind, to_agent, topic_id, topic_title),
            };
            let receipt = core.and_then(|c| match c.body {
                antenna_proto::Body::Receipt(r) => Some(r),
                _ => None,
            });
            out.push(HistoryRow {
                seq,
                id: MessageId(arr32(id, "message id")?),
                incoming,
                kind,
                body,
                ts: ts as u64,
                local_ms: local as u64,
                lamport: lamport as u64,
                status: if incoming {
                    "received"
                } else if failed != 0 {
                    "failed"
                } else if queued {
                    "queued"
                } else {
                    "delivered"
                },
                receipt,
                agent,
                to,
                topic,
                unread: incoming && read == 0,
                no_agent: !incoming && undelivered.as_deref() == Some("no_agent"),
                urgent: urgent != 0,
            });
        }
        let more = out.len() > limit as usize;
        out.truncate(limit as usize);
        out.reverse();
        Ok((out, more))
    }
}

// History: signatures, author counters, verification, rollback, revoke (slice 3)

const MSG_SELECT: &str =
    "SELECT seq, id, author, n, lamport, ts, kind, body, core, coalesce(sig, x''), agent_key
     FROM messages";

fn msg_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<RawMsg> {
    Ok(RawMsg {
        seq: r.get(0)?,
        id: r.get(1)?,
        author: r.get(2)?,
        n: r.get(3)?,
        lamport: r.get(4)?,
        ts: r.get(5)?,
        kind: r.get(6)?,
        body: r.get(7)?,
        core: r.get(8)?,
        sig: r.get(9)?,
        agent_key: r.get(10)?,
    })
}

struct RawMsg {
    seq: i64,
    id: Vec<u8>,
    author: Vec<u8>,
    n: i64,
    lamport: i64,
    ts: i64,
    kind: String,
    body: String,
    core: Vec<u8>,
    sig: Vec<u8>,
    agent_key: Option<Vec<u8>>,
}

impl RawMsg {
    fn into_msg(self) -> Result<StoredMsg> {
        Ok(StoredMsg {
            seq: self.seq,
            id: MessageId(arr32(self.id, "message id")?),
            author: arr32(self.author, "author")?,
            n: self.n.max(0) as u64,
            lamport: self.lamport.max(0) as u64,
            ts: self.ts.max(0) as u64,
            kind: self.kind,
            body: self.body,
            core: self.core,
            sig: self.sig,
            agent_key: self.agent_key.map(|k| arr32(k, "agent key")).transpose()?,
        })
    }
}

fn collect_msgs(
    st: &mut rusqlite::Statement<'_>,
    p: impl rusqlite::Params,
) -> Result<Vec<StoredMsg>> {
    let rows = st.query_map(p, msg_from_row)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?.into_msg()?);
    }
    Ok(out)
}

impl Db {
    /// The link's Ed25519 link-root seed (a secret: for signing our own messages).
    pub fn root_seed(conn: &Connection, link: &LinkId) -> Result<Secret32> {
        let v: Zeroizing<Vec<u8>> = Zeroizing::new(conn.query_row(
            "SELECT root_ed25519_seed FROM links WHERE link_id = ?1",
            params![&link.0[..]],
            |r| r.get(0),
        )?);
        if v.len() != 32 {
            return Err(Error::internal("db: link-root seed is not 32 bytes"));
        }
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(&v);
        Ok(out)
    }

    /// Next author counter in the link (maximum + 1).
    pub fn next_n(conn: &Connection, link: &LinkId, author: &[u8; 32]) -> Result<u64> {
        let v: i64 = conn.query_row(
            "SELECT coalesce(max(n), 0) FROM messages WHERE link_id = ?1 AND author = ?2",
            params![&link.0[..], &author[..]],
            |r| r.get(0),
        )?;
        Ok(v as u64 + 1)
    }

    /// The author's message with this counter.
    pub fn message_at(
        conn: &Connection,
        link: &LinkId,
        author: &[u8; 32],
        n: u64,
    ) -> Result<Option<StoredMsg>> {
        let mut st = conn.prepare_cached(&format!(
            "{MSG_SELECT} WHERE link_id = ?1 AND author = ?2 AND n = ?3"
        ))?;
        Ok(collect_msgs(&mut st, params![&link.0[..], &author[..], n as i64])?.pop())
    }

    /// Message by ID (in this link).
    pub fn message_by_id(
        conn: &Connection,
        link: &LinkId,
        id: &MessageId,
    ) -> Result<Option<StoredMsg>> {
        let mut st =
            conn.prepare_cached(&format!("{MSG_SELECT} WHERE link_id = ?1 AND id = ?2"))?;
        Ok(collect_msgs(&mut st, params![&link.0[..], &id.0[..]])?.pop())
    }

    /// The author's messages with `from ≤ n ≤ to`, ascending by `n`.
    pub fn messages_by_n(
        conn: &Connection,
        link: &LinkId,
        author: &[u8; 32],
        from: u64,
        to: u64,
    ) -> Result<Vec<StoredMsg>> {
        let mut st = conn.prepare_cached(&format!(
            "{MSG_SELECT} WHERE link_id = ?1 AND author = ?2 AND n >= ?3 AND n <= ?4 ORDER BY n"
        ))?;
        collect_msgs(
            &mut st,
            params![
                &link.0[..],
                &author[..],
                from as i64,
                to.min(i64::MAX as u64) as i64
            ],
        )
    }

    /// IDs of the author's messages with `from ≤ n ≤ to` (pairs `(n, id)`), ascending by `n`.
    pub fn ids_by_n(
        conn: &Connection,
        link: &LinkId,
        author: &[u8; 32],
        from: u64,
        to: u64,
    ) -> Result<Vec<(u64, MessageId)>> {
        let mut st = conn.prepare_cached(
            "SELECT n, id FROM messages WHERE link_id = ?1 AND author = ?2 AND n >= ?3 AND n <= ?4 ORDER BY n",
        )?;
        let rows = st.query_map(
            params![
                &link.0[..],
                &author[..],
                from as i64,
                to.min(i64::MAX as u64) as i64
            ],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)),
        )?;
        let mut out = Vec::new();
        for r in rows {
            let (n, id) = r?;
            out.push((n as u64, MessageId(arr32(id, "message id")?)));
        }
        Ok(out)
    }

    /// All messages of the link by `(author, n, seq)` in a single pass (index `messages_audit`, no sorting), for the
    /// copy check.
    pub fn for_each_message(
        conn: &Connection,
        link: &LinkId,
        mut f: impl FnMut(StoredMsg) -> Result<()>,
    ) -> Result<()> {
        let mut st = conn.prepare(&format!(
            "{MSG_SELECT} WHERE link_id = ?1 ORDER BY author, n, seq"
        ))?;
        let rows = st.query_map(params![&link.0[..]], msg_from_row)?;
        for r in rows {
            f(r?.into_msg()?)?;
        }
        Ok(())
    }

    /// All heads and their recomputation: IDs of the link's messages not referenced by any `core.parents` (the caller
    /// checks this against the parsed `core`). Here the heads table is replaced with the recomputed heads.
    pub fn replace_heads(conn: &Connection, link: &LinkId, heads: &[MessageId]) -> Result<()> {
        conn.execute("DELETE FROM heads WHERE link_id = ?1", params![&link.0[..]])?;
        for h in heads {
            conn.execute(
                "INSERT OR IGNORE INTO heads(link_id, msg_id) VALUES (?1, ?2)",
                params![&link.0[..], &h.0[..]],
            )?;
        }
        Ok(())
    }

    /// All message IDs of the link.
    pub fn all_ids(conn: &Connection, link: &LinkId) -> Result<Vec<MessageId>> {
        let mut st = conn.prepare("SELECT id FROM messages WHERE link_id = ?1")?;
        let rows = st.query_map(params![&link.0[..]], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(MessageId(arr32(r?, "message id")?));
        }
        Ok(out)
    }

    /// Replace a damaged copy of a message with the contact's verified copy (the same ID, `antenna verify --repair`).
    pub fn repair_message(conn: &Connection, link: &LinkId, m: &StoredMsg) -> Result<bool> {
        let n = conn.execute(
            "UPDATE messages SET author = ?3, n = ?4, lamport = ?5, ts = ?6, kind = ?7, body = ?8, core = ?9, sig = ?10,
               agent_key = ?11
             WHERE link_id = ?1 AND id = ?2",
            params![
                &link.0[..],
                &m.id.0[..],
                &m.author[..],
                m.n as i64,
                m.lamport as i64,
                m.ts as i64,
                m.kind,
                m.body,
                m.core,
                m.sig,
                m.agent_key.map(|k| k.to_vec())
            ],
        )?;
        Ok(n > 0)
    }

    /// Link state counter +1 (inside a transaction that changes the ratchet session). Returns the new value: after
    /// the commit it must be written to the counter file (`statefile`).
    pub fn bump_state(conn: &Connection, link: &LinkId) -> Result<u64> {
        conn.execute(
            "UPDATE links SET state_counter = state_counter + 1 WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        Self::state_counter(conn, link)
    }

    /// Link state counter in the DB.
    pub fn state_counter(conn: &Connection, link: &LinkId) -> Result<u64> {
        let v: i64 = conn.query_row(
            "SELECT state_counter FROM links WHERE link_id = ?1",
            params![&link.0[..]],
            |r| r.get(0),
        )?;
        Ok(v.max(0) as u64)
    }

    /// Raise the link state counter to a value (after a rekey: above the file).
    pub fn set_state_counter(conn: &Connection, link: &LinkId, v: u64) -> Result<()> {
        conn.execute(
            "UPDATE links SET state_counter = max(state_counter, ?2) WHERE link_id = ?1",
            params![&link.0[..], v as i64],
        )?;
        Ok(())
    }

    /// State counters of all active links.
    pub fn state_counters(&self) -> Result<Vec<(LinkId, u64)>> {
        let mut st = self
            .conn
            .prepare("SELECT link_id, state_counter FROM links WHERE state = 'active'")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?)))?;
        let mut out = Vec::new();
        for r in rows {
            let (l, c) = r?;
            out.push((LinkId(arr32(l, "link id")?), c.max(0) as u64));
        }
        Ok(out)
    }

    /// Link block (`None` clears it).
    pub fn set_blocked(&self, link: &LinkId, blocked: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET blocked = ?2 WHERE link_id = ?1",
            params![&link.0[..], blocked],
        )?;
        Ok(())
    }

    /// Verification note (JSON: the divergence and the owner's decision).
    pub fn hist_note(&self, link: &LinkId) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT hist_note FROM links WHERE link_id = ?1",
                params![&link.0[..]],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// Save a verification note.
    pub fn set_hist_note(&self, link: &LinkId, note: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET hist_note = ?2 WHERE link_id = ?1",
            params![&link.0[..], note],
        )?;
        Ok(())
    }

    /// An accepted rekey offer awaiting confirmation (CBOR): it survives a restart so that a retry sends the same
    /// answer rather than a new one (otherwise the contact gets two different answers: a false alarm and a 10-minute
    /// wait).
    pub fn rekey_pending(conn: &Connection, link: &LinkId) -> Result<Option<Vec<u8>>> {
        Ok(conn
            .query_row(
                "SELECT rekey_pending FROM links WHERE link_id = ?1",
                params![&link.0[..]],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// Save / clear an accepted rekey offer (inside the caller's transaction).
    pub fn set_rekey_pending(conn: &Connection, link: &LinkId, v: Option<&[u8]>) -> Result<()> {
        conn.execute(
            "UPDATE links SET rekey_pending = ?2 WHERE link_id = ?1",
            params![&link.0[..], v],
        )?;
        Ok(())
    }

    /// When the history was last verified.
    pub fn set_verified(&self, link: &LinkId, at_ms: u64) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET verified_ms = ?2 WHERE link_id = ?1",
            params![&link.0[..], at_ms as i64],
        )?;
        Ok(())
    }

    /// What is known about the contact's side (v5, `ContactInfo::peer_kind`): whether it announced agents and whether
    /// its owner wrote (text, file, request, signed by link-root).
    pub fn peer_kind_flags(&self, link: &LinkId) -> Result<(bool, bool)> {
        Ok(self.conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM link_agents WHERE link_id = ?1 AND side = 'peer'),
                    EXISTS(SELECT 1 FROM messages WHERE link_id = ?1 AND direction = 'in'
                             AND kind IN ('text', 'file', 'request') AND agent IS NULL)",
            params![&link.0[..]],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// The link's incoming messages unread by the owner.
    pub fn unread_count(&self, link: &LinkId) -> Result<u64> {
        let n: i64 = self.conn.query_row(
            "SELECT count(*) FROM messages WHERE link_id = ?1 AND direction = 'in' AND read = 0
               AND kind = 'text' AND origin = 'live'",
            params![&link.0[..]],
            |r| r.get(0),
        )?;
        Ok(n as u64)
    }

    /// Our message `id_hex` on the link, addressed to an agent, is one the contact's node has no agent for (its
    /// `deliver` / `no_such_agent` receipt, PROTOCOL §23). `true` when such a message was marked now.
    pub fn mark_no_agent(&self, link: &LinkId, id_hex: &str) -> Result<bool> {
        let Some(id) = data_encoding::HEXLOWER_PERMISSIVE
            .decode(id_hex.as_bytes())
            .ok()
            .filter(|v| v.len() == 32)
        else {
            return Ok(false);
        };
        Ok(self.conn.execute(
            "UPDATE messages SET undelivered = 'no_agent' WHERE link_id = ?1 AND id = ?2 AND direction = 'out'
               AND to_kind = 'agent' AND undelivered IS NULL",
            params![&link.0[..], id],
        )? > 0)
    }

    /// Mark the link's incoming messages as read by the owner up to and including `seq` (`mark_read`).
    pub fn mark_read_upto(&self, link: &LinkId, seq: i64) -> Result<u64> {
        Ok(self.conn.execute(
            "UPDATE messages SET read = 1 WHERE link_id = ?1 AND direction = 'in' AND read = 0 AND seq <= ?2",
            params![&link.0[..], seq],
        )? as u64)
    }

    /// Mark exactly these incoming messages of the link as read by the owner (v6, `mark_read.ids`).
    pub fn mark_read_ids(&self, link: &LinkId, ids: &[MessageId]) -> Result<u64> {
        let mut n = 0;
        for id in ids {
            n += self.conn.execute(
                "UPDATE messages SET read = 1 WHERE link_id = ?1 AND id = ?2 AND direction = 'in' AND read = 0",
                params![&link.0[..], &id.0[..]],
            )? as u64;
        }
        Ok(n)
    }

    /// The link's topics (v6), most recent first: the title is the one of the topic's latest message.
    pub fn topics(&self, link: &LinkId) -> Result<Vec<TopicRow>> {
        let mut st = self.conn.prepare(
            "SELECT m.topic_id, count(*), max(m.seq),
                    (SELECT t.topic_title FROM messages t WHERE t.link_id = m.link_id AND t.topic_id = m.topic_id
                     ORDER BY t.seq DESC LIMIT 1),
                    (SELECT t.received_ms FROM messages t WHERE t.link_id = m.link_id AND t.topic_id = m.topic_id
                     ORDER BY t.seq DESC LIMIT 1)
             FROM messages m WHERE m.link_id = ?1 AND m.topic_id IS NOT NULL
             GROUP BY m.topic_id ORDER BY max(m.seq) DESC LIMIT 500",
        )?;
        let rows = st.query_map(params![&link.0[..]], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<i64>>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (id, count, last_seq, title, last_ms) = r?;
            let Ok(id) = <[u8; 16]>::try_from(id) else {
                continue;
            };
            out.push(TopicRow {
                id,
                title: title.unwrap_or_default(),
                count: count.max(0) as u64,
                last_seq,
                last_ms: last_ms.unwrap_or(0).max(0) as u64,
            });
        }
        Ok(out)
    }

    /// The link's topic with exactly this title, the most recently used one (v6).
    pub fn topic_by_title(&self, link: &LinkId, title: &str) -> Result<Option<[u8; 16]>> {
        let id: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT topic_id FROM messages WHERE link_id = ?1 AND topic_title = ?2 AND topic_id IS NOT NULL
                 ORDER BY seq DESC LIMIT 1",
                params![&link.0[..], title],
                |r| r.get(0),
            )
            .optional()?;
        Ok(id.and_then(|v| <[u8; 16]>::try_from(v).ok()))
    }

    /// The title of the link's topic with this ID (of its latest message), if the topic exists (v6).
    pub fn topic_title(&self, link: &LinkId, id: &[u8; 16]) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT topic_title FROM messages WHERE link_id = ?1 AND topic_id = ?2 ORDER BY seq DESC LIMIT 1",
                params![&link.0[..], &id[..]],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// Who wrote the message and its topic, from the signed `core` (v6: what an agent's reply answers).
    pub fn message_author_topic(&self, id: &MessageId) -> Result<Option<Answered>> {
        let row: Option<(String, Option<String>, Vec<u8>)> = self
            .conn
            .query_row(
                "SELECT direction, agent, core FROM messages WHERE id = ?1",
                params![&id.0[..]],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        Ok(row.map(|(dir, agent, core)| {
            let topic = antenna_proto::from_cbor::<antenna_proto::EnvelopeCore>(&core)
                .ok()
                .and_then(|c| c.topic);
            Answered {
                incoming: dir == "in",
                agent,
                topic,
            }
        }))
    }

    /// The message an agent's reply on the link answers by default (v6): the last one it read with `inbox`.
    pub fn agent_reply_to(&self, agent_id: i64, link: &LinkId) -> Result<Option<MessageId>> {
        let v: Option<Option<Vec<u8>>> = self
            .conn
            .query_row(
                "SELECT reply_to FROM agent_cursor WHERE agent_id = ?1 AND link_id = ?2",
                params![agent_id, &link.0[..]],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v.flatten()
            .and_then(|b| <[u8; 32]>::try_from(b).ok())
            .map(MessageId))
    }

    /// Remember what the agent last read on the link (v6). Only updates the cursor row `agent_advance` wrote: a row
    /// created here would carry cursor 0 and show the agent messages from before it was created (D-30).
    pub fn agent_set_reply_to(&self, agent_id: i64, link: &LinkId, id: &MessageId) -> Result<()> {
        self.conn.execute(
            "UPDATE agent_cursor SET reply_to = ?3 WHERE agent_id = ?1 AND link_id = ?2",
            params![agent_id, &link.0[..], &id.0[..]],
        )?;
        Ok(())
    }

    /// Change whether the agent reads messages addressed to everyone (v6).
    pub fn agent_set_everyone(&self, id: i64, everyone: bool) -> Result<()> {
        self.conn.execute(
            "UPDATE agents SET everyone = ?2 WHERE id = ?1",
            params![id, everyone],
        )?;
        Ok(())
    }

    /// The links whose wake agent this agent is (v6: it reads what the contact writes to the person there).
    pub fn wake_links_of(&self, agent_id: i64) -> Result<Vec<LinkId>> {
        let mut st = self
            .conn
            .prepare("SELECT link_id FROM wake_rules WHERE agent_id = ?1")?;
        let rows = st.query_map(params![agent_id], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(LinkId(arr32(r?, "wake link")?));
        }
        Ok(out)
    }

    /// The link's service messages (type `control`: agent announcements, PROTOCOL §21) by side and counter.
    pub fn control_messages(conn: &Connection, link: &LinkId) -> Result<Vec<StoredMsg>> {
        let mut st = conn.prepare(&format!(
            "{MSG_SELECT} WHERE link_id = ?1 AND kind = 'control' ORDER BY author, n"
        ))?;
        collect_msgs(&mut st, params![&link.0[..]])
    }

    /// The link's receipts from the shared history (type `receipt`), the last `limit`, ascending.
    pub fn dag_receipts(&self, link: &LinkId, limit: u32) -> Result<Vec<StoredMsg>> {
        let mut st = self.conn.prepare(&format!(
            "{MSG_SELECT} WHERE link_id = ?1 AND kind = 'receipt' ORDER BY seq DESC LIMIT ?2"
        ))?;
        let mut v = collect_msgs(&mut st, params![&link.0[..], limit])?;
        v.reverse();
        Ok(v)
    }

    /// Rename a contact (the label is unique).
    pub fn rename(&self, link: &LinkId, label: &str) -> Result<()> {
        let r = self.conn.execute(
            "UPDATE contacts SET label = ?2 WHERE id = (SELECT contact_id FROM links WHERE link_id = ?1)",
            params![&link.0[..], label],
        );
        match r {
            Ok(_) => Ok(()),
            Err(rusqlite::Error::SqliteFailure(e, _))
                if e.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(Error::bad_request(format!(
                    "label {label:?} is already used"
                )))
            }
            Err(e) => Err(e.into()),
        }
    }

    /// `antenna revoke` (SPEC §5, §13): the link keys are wiped (`secure_delete` + overwrite + WAL checkpoint), the
    /// queue is deleted, the link is marked `revoked`; the history is deleted at the owner's choice.
    pub fn revoke(&mut self, link: &LinkId, delete_history: bool) -> Result<()> {
        let tx = self.tx()?;
        let zero = vec![0u8; 32];
        tx.execute(
            "UPDATE links SET state = 'revoked', local_secret = ?2, root_ed25519_seed = ?2, root_mldsa_seed = ?2,
               blocked = NULL, hist_note = NULL, rekey_pending = NULL WHERE link_id = ?1",
            params![&link.0[..], zero],
        )?;
        tx.execute(
            "DELETE FROM sig_session WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        tx.execute(
            "DELETE FROM sig_identity WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        tx.execute(
            "DELETE FROM outbox WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        tx.execute(
            "DELETE FROM agent_cursor WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        // A contact's photo is personal data: it goes with the link (its message stays in a kept history)
        crate::pictures::forget_link(&tx, link)?;
        // Keys of our own agents in this link are link keys too (v5)
        tx.execute(
            "UPDATE link_agents SET seed = NULL WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        if delete_history {
            tx.execute(
                "DELETE FROM link_agents WHERE link_id = ?1",
                params![&link.0[..]],
            )?;
            tx.execute(
                "DELETE FROM message_parents WHERE link_id = ?1",
                params![&link.0[..]],
            )?;
            tx.execute("DELETE FROM heads WHERE link_id = ?1", params![&link.0[..]])?;
            tx.execute(
                "DELETE FROM messages WHERE link_id = ?1",
                params![&link.0[..]],
            )?;
            tx.execute(
                "DELETE FROM receipts WHERE link_id = ?1",
                params![&link.0[..]],
            )?;
            // The owner's names for the link's chats say what they were about (D-113)
            tx.execute("DELETE FROM chats WHERE link_id = ?1", params![&link.0[..]])?;
        }
        // The label is freed: a new link with the same person can take the old name
        tx.execute(
            "UPDATE contacts SET label = label || '~revoked-' || hex(randomblob(4))
             WHERE id = (SELECT contact_id FROM links WHERE link_id = ?1)",
            params![&link.0[..]],
        )?;
        tx.commit()?;
        // Old pages with keys must not live on in the WAL (secure_delete wipes the pages of the main file)
        let _ = self
            .conn
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
        Ok(())
    }

    /// Outgoing messages in the queue: (queue seq, message ID).
    pub fn outbox_ids(&self, link: &LinkId) -> Result<Vec<(i64, MessageId)>> {
        Ok(self
            .outbox(link)?
            .into_iter()
            .map(|i| (i.seq, i.msg_id))
            .collect())
    }

    /// Delete our own undelivered message (it is in the queue): when the history is restored after a rollback, its
    /// counter is taken by a message the contact already had; the text will be sent again with the next counter.
    pub fn delete_unsent(conn: &Connection, link: &LinkId, id: &MessageId) -> Result<()> {
        conn.execute(
            "DELETE FROM outbox WHERE link_id = ?1 AND msg_id = ?2",
            params![&link.0[..], &id.0[..]],
        )?;
        conn.execute(
            "DELETE FROM message_parents WHERE link_id = ?1 AND msg_id = ?2",
            params![&link.0[..], &id.0[..]],
        )?;
        conn.execute(
            "DELETE FROM heads WHERE link_id = ?1 AND msg_id = ?2",
            params![&link.0[..], &id.0[..]],
        )?;
        conn.execute(
            "DELETE FROM messages WHERE link_id = ?1 AND id = ?2",
            params![&link.0[..], &id.0[..]],
        )?;
        Ok(())
    }

    /// Recompute the heads from the parents index (after deleting a message).
    pub fn rebuild_heads(conn: &Connection, link: &LinkId) -> Result<()> {
        conn.execute("DELETE FROM heads WHERE link_id = ?1", params![&link.0[..]])?;
        conn.execute(
            "INSERT OR IGNORE INTO heads(link_id, msg_id)
             SELECT m.link_id, m.id FROM messages m WHERE m.link_id = ?1
               AND NOT EXISTS(SELECT 1 FROM message_parents p WHERE p.link_id = m.link_id AND p.parent_id = m.id)",
            params![&link.0[..]],
        )?;
        Ok(())
    }

    /// Whether the message is in the queue.
    pub fn in_outbox(conn: &Connection, link: &LinkId, id: &MessageId) -> Result<bool> {
        Ok(conn
            .query_row(
                "SELECT 1 FROM outbox WHERE link_id = ?1 AND msg_id = ?2",
                params![&link.0[..], &id.0[..]],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// The contact's pinned libsignal identity (from the pairing transcript).
    pub fn pinned_identity(conn: &Connection, link: &LinkId) -> Result<Vec<u8>> {
        Ok(conn.query_row(
            "SELECT identity FROM sig_remote_identity WHERE link_id = ?1",
            params![&link.0[..]],
            |r| r.get(0),
        )?)
    }

    /// Replace a blob in the queue (re-encryption after a rekey).
    pub fn outbox_set_blob(conn: &Connection, seq: i64, blob: &[u8]) -> Result<()> {
        conn.execute(
            "UPDATE outbox SET blob = ?2, attempts = 0 WHERE seq = ?1",
            params![seq, blob],
        )?;
        Ok(())
    }
}

struct RawLink {
    link_id: Vec<u8>,
    label: String,
    trust: u8,
    role: String,
    net_mode: String,
    created_ms: i64,
    pairing_kx: String,
    local_secret: Vec<u8>,
    local_port: Option<u16>,
    peer_endpoint: Vec<u8>,
    peer_addrs: Vec<u8>,
    root_ed25519_pk: Vec<u8>,
    sig_local_addr: String,
    sig_remote_addr: String,
    lamport: i64,
    last_kx: Option<String>,
    last_rx_version: Option<u32>,
    last_rx_pq_len: Option<u32>,
    last_paths: Option<String>,
    peer_root_ed25519: Vec<u8>,
    blocked: Option<String>,
}

impl RawLink {
    fn into_row(self) -> Result<LinkRow> {
        let secret = Zeroizing::new(self.local_secret);
        let mut local_secret = Zeroizing::new([0u8; 32]);
        if secret.len() != 32 {
            return Err(Error::internal("db: local secret is not 32 bytes"));
        }
        local_secret.copy_from_slice(&secret);
        Ok(LinkRow {
            link_id: LinkId(arr32(self.link_id, "link id")?),
            label: self.label,
            trust: self.trust,
            role: PairRole::parse(&self.role)?,
            net_mode: NetMode::parse(&self.net_mode)?,
            created_ms: self.created_ms as u64,
            pairing_kx: self.pairing_kx,
            local_secret,
            local_port: self.local_port,
            peer_endpoint: arr32(self.peer_endpoint, "peer endpoint")?,
            peer_addrs: antenna_proto::from_cbor(&self.peer_addrs)?,
            root_ed25519_pk: arr32(self.root_ed25519_pk, "root key")?,
            peer_root_ed25519: arr32(self.peer_root_ed25519, "peer root key")?,
            sig_local_addr: self.sig_local_addr,
            sig_remote_addr: self.sig_remote_addr,
            lamport: self.lamport as u64,
            last_kx: self.last_kx,
            last_rx_version: self.last_rx_version,
            last_rx_pq_len: self.last_rx_pq_len,
            last_paths: self
                .last_paths
                .map(|s| s.split_whitespace().map(str::to_string).collect())
                .unwrap_or_default(),
            blocked: self.blocked,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto;

    fn new_link(id: u8, label: Option<&str>) -> NewLink {
        NewLink {
            link_id: LinkId([id; 32]),
            role: PairRole::Inviter,
            label: label.map(str::to_string),
            trust: 3,
            transcript_hash: [1; 32],
            pairing_kx: "X25519MLKEM768".into(),
            local_secret: crypto::random_secret(),
            peer_endpoint: [2; 32],
            peer_addrs: AddrHints::default(),
            root_ed25519_seed: crypto::random_secret(),
            root_ed25519_pk: [3; 32],
            root_mldsa_seed: crypto::random_secret(),
            root_mldsa_vk: vec![4; 1952],
            peer_root_ed25519: [5; 32],
            peer_root_mldsa: vec![6; 1952],
            sig_local_addr: "a".into(),
            sig_remote_addr: "b".into(),
            sig_identity_keypair: Zeroizing::new(vec![7; 64]),
            sig_registration_id: 9,
            sig_remote_identity: vec![8; 33],
            sig_session_record: Zeroizing::new(vec![9; 100]),
        }
    }

    /// D-P-9: an agent's process binding is stored with the OS boot ID; from another boot (or an old record without
    /// a boot ID) it is not a binding: after a reboot, PIDs and start times repeat for other processes.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn agent_anchor_does_not_survive_a_reboot() {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join(FILE_NAME), &crypto::random_secret()).unwrap();
        let id = db
            .agent_insert("claude", &[1; 32], None, 5, false, 1)
            .unwrap();
        db.agent_set_anchor(id, Some((4242, 777, "claude")))
            .unwrap();
        let a = db.agent(id).unwrap().anchor;
        assert_eq!(a, Some((4242, 777, "claude".to_string())));
        assert!(
            crate::procinfo::boot_id().is_some(),
            "boot id is readable on this OS"
        );
        db.agent_set_anchor_boot(id, Some("00000000-0000-0000-0000-000000000000"))
            .unwrap();
        assert_eq!(db.agent(id).unwrap().anchor, None, "another boot");
        db.agent_set_anchor_boot(id, None).unwrap();
        assert_eq!(
            db.agent(id).unwrap().anchor,
            None,
            "record without a boot id"
        );
        db.agent_set_anchor(id, Some((4242, 777, "claude")))
            .unwrap();
        assert!(db.agent(id).unwrap().anchor.is_some());
        db.agent_set_anchor(id, None).unwrap();
        assert_eq!(db.agent(id).unwrap().anchor, None);
    }

    #[test]
    fn encrypted_file_and_wrong_key() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join(FILE_NAME);
        let key = crypto::random_secret();
        {
            let mut db = Db::open(&p, &key).unwrap();
            db.insert_link(&new_link(1, Some("Confidential Label")), 1)
                .unwrap();
        }
        let raw = std::fs::read(&p).unwrap();
        assert!(!raw.starts_with(b"SQLite format 3\0"));
        assert!(
            !raw.windows("Confidential".len())
                .any(|w| w == "Confidential".as_bytes())
        );
        let wrong = crypto::random_secret();
        assert!(Db::open(&p, &wrong).is_err());
        let db = Db::open(&p, &key).unwrap();
        assert_eq!(db.links().unwrap()[0].label, "Confidential Label");
    }

    #[test]
    fn labels_are_unique_and_lookup_works() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Db::open(&dir.path().join(FILE_NAME), &crypto::random_secret()).unwrap();
        assert_eq!(db.insert_link(&new_link(1, Some("bob")), 1).unwrap(), "bob");
        assert_eq!(
            db.insert_link(&new_link(2, Some("bob")), 1).unwrap(),
            "bob-2"
        );
        let auto = db.insert_link(&new_link(3, None), 1).unwrap();
        assert!(auto.starts_with("contact-03030303"), "{auto}");
        assert_eq!(db.find_link("bob-2").unwrap().link_id, LinkId([2; 32]));
        assert_eq!(db.find_link("0303030303").unwrap().link_id, LinkId([3; 32]));
        assert_eq!(db.find_link("nobody").unwrap_err().code, code::NOT_FOUND);
    }

    #[test]
    fn dag_heads_and_lamport() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Db::open(&dir.path().join(FILE_NAME), &crypto::random_secret()).unwrap();
        db.insert_link(&new_link(1, Some("bob")), 1).unwrap();
        let link = LinkId([1; 32]);
        let m = |id: u8, parents: &'static [MessageId], lamport: u64| MessageRecord {
            id: MessageId([id; 32]),
            link_id: link,
            incoming: true,
            author: [0; 32],
            lamport,
            ts: 0,
            kind: "text",
            body: "x",
            core: b"",
            parents,
            n: 0,
            sig: b"",
            origin: "live",
            agent: None,
            to: None,
            topic: None,
        };
        static P1: [MessageId; 1] = [MessageId([1; 32])];
        static P23: [MessageId; 2] = [MessageId([2; 32]), MessageId([3; 32])];
        let tx = db.tx().unwrap();
        Db::insert_message(&tx, &m(1, &[], 1), 1).unwrap();
        // Two branches from 1
        Db::insert_message(&tx, &m(2, &P1, 2), 1).unwrap();
        Db::insert_message(&tx, &m(3, &P1, 2), 1).unwrap();
        tx.commit().unwrap();
        assert_eq!(
            Db::heads(db.conn(), &link).unwrap(),
            vec![MessageId([2; 32]), MessageId([3; 32])]
        );
        // merge
        let tx = db.tx().unwrap();
        Db::insert_message(&tx, &m(4, &P23, 3), 1).unwrap();
        tx.commit().unwrap();
        assert_eq!(
            Db::heads(db.conn(), &link).unwrap(),
            vec![MessageId([4; 32])]
        );
        assert_eq!(Db::lamport(db.conn(), &link).unwrap(), 3);
        assert_eq!(db.unread().unwrap().len(), 4);
        assert_eq!(db.unread().unwrap()[3].parents.len(), 2);
    }

    #[test]
    fn out_of_order_child_first_keeps_heads_correct() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Db::open(&dir.path().join(FILE_NAME), &crypto::random_secret()).unwrap();
        db.insert_link(&new_link(1, Some("bob")), 1).unwrap();
        let link = LinkId([1; 32]);
        static P1: [MessageId; 1] = [MessageId([1; 32])];
        let tx = db.tx().unwrap();
        let child = MessageRecord {
            id: MessageId([2; 32]),
            link_id: link,
            incoming: true,
            author: [0; 32],
            lamport: 2,
            ts: 0,
            kind: "text",
            body: "child",
            core: b"",
            parents: &P1,
            n: 0,
            sig: b"",
            origin: "live",
            agent: None,
            to: None,
            topic: None,
        };
        Db::insert_message(&tx, &child, 1).unwrap();
        let parent = MessageRecord {
            id: MessageId([1; 32]),
            parents: &[],
            lamport: 1,
            body: "parent",
            ..child
        };
        Db::insert_message(&tx, &parent, 1).unwrap();
        tx.commit().unwrap();
        assert_eq!(
            Db::heads(db.conn(), &link).unwrap(),
            vec![MessageId([2; 32])]
        );
    }

    #[test]
    fn outbox_order_and_removal() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Db::open(&dir.path().join(FILE_NAME), &crypto::random_secret()).unwrap();
        db.insert_link(&new_link(1, Some("bob")), 1).unwrap();
        let link = LinkId([1; 32]);
        for i in 0..3u8 {
            Db::outbox_push(db.conn(), &link, &MessageId([i; 32]), &[i], 1).unwrap();
        }
        let items = db.outbox(&link).unwrap();
        assert_eq!(
            items.iter().map(|i| i.blob[0]).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        db.outbox_bump(items[0].seq).unwrap();
        db.outbox_remove(items[1].seq).unwrap();
        let items = db.outbox(&link).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].attempts, 1);
        assert_eq!(db.outbox_len(&link).unwrap(), 2);
    }
}
