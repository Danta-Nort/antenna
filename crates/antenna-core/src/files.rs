// SPDX-License-Identifier: AGPL-3.0-only
//! Files in the daemon (SPEC §10; slice 4, stage B): connects the `antenna-files` crate (encryption, manifest, blob
//! store and ACL, quarantine, sandboxed check, preview, accepting) with links, the level policy and the control socket.
//!
//! Receiving pipeline: a `file` message (signed manifest + file secret inside the Triple Ratchet) → quarantine accepts
//! or refuses **by the manifest** (the link author's signature, level 1 has no files, the level's daily volume) → the
//! ciphertext is downloaded as an iroh-blobs blob from the link endpoint (resumption, BLAKE3/bao verification) → check
//! in a worker process (`antennad --antenna-files-worker check`: Landlock + seccomp + rlimits) and preview → explicit
//! acceptance by the owner or an agent (`file_accept`) into `inbox/` / `shared/` of the link folder → an `accept_file`
//! receipt in the link's shared history. Threat: the contact immediately gets a rejection receipt, the record is kept
//! encrypted for 7 days for the owner's decision (`--force` + password), then deleted (Q-F-3).
//!
//! The blob store is per link (`<data>/quarantine/<link>/blobs`) and is opened lazily: on the first download, send, or
//! when the contact connects via the iroh-blobs ALPN to this link's endpoint (the endpoint accept-list admits only the
//! contact).

use std::{
    collections::HashMap,
    ffi::OsString,
    path::{Path, PathBuf},
    sync::{Arc, Mutex as StdMutex, PoisonError},
    time::Duration,
};

use antenna_files::{
    blobs::LinkBlobs,
    quarantine::{Item, Quarantine, State},
    report::{Preview, PreviewKind, Severity, Verdict},
    sandbox::{AvHook, Checker, CheckerConfig},
};
use antenna_proto::{
    Body, LinkId, MessageId, MessageType,
    control::{FileFinding, FileInfo, FilePreviewView, code},
    files::{FileOffer, FileRequest},
};
use iroh::{
    EndpointId,
    endpoint::Connection,
    protocol::{AcceptError, ProtocolHandler},
};
use tokio::sync::{OnceCell, Semaphore, mpsc};

use crate::{
    addressing::Addr,
    crypto::Secret32,
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms,
    store::{Db, LinkRow},
};

/// How long a threat is kept for the owner's decision (Q-F-3).
pub const THREAT_KEEP_MS: u64 = 7 * 24 * 3600 * 1000;
/// Window of the level's daily volume.
const DAY_MS: u64 = 24 * 3600 * 1000;
/// Simultaneous downloads.
const MAX_DOWNLOADS: usize = 4;
/// Download attempts (network) before pausing until the next start.
const DOWNLOAD_TRIES: u32 = 8;
/// How long to serve a sent file to the contact if it has answered with neither acceptance nor rejection.
pub const OUT_KEEP_MS: u64 = 14 * DAY_MS;
/// Requests from `shared/` per contact per hour (each one checks and encrypts the whole file).
const REQUESTS_PER_HOUR: usize = 20;
/// Unaccepted quarantine records per link (empty files are not limited by volume, so they are limited by count).
const MAX_PENDING: usize = 256;
/// A download without progress for this many seconds is a stall (the contact holds the connection and sends no data).
const STALL_SECS: u64 = 60;
/// Default largest `share_file_content` an agent may send, decoded bytes (`antennad --share-content-max-mib`).
pub const SHARE_CONTENT_MAX_DEFAULT: u64 = 25 * 1024 * 1024;
/// Staged `share_file_content` uploads older than this were left by a crash and are removed.
const STAGED_STALE: Duration = Duration::from_secs(3600);
/// Staging area of outgoing content in the data directory: `<data-dir>/outgoing/<link hex>/<random>.part`.
const OUTGOING_DIR: &str = "outgoing";

/// Node file settings.
#[derive(Debug, Clone)]
pub struct FilesConfig {
    /// Links folders (SPEC §10: `~/Antenna/links/<contact>/{inbox,shared}`).
    pub links_dir: PathBuf,
    /// Check worker executable (`None` means the daemon itself: `current_exe`).
    pub worker: Option<PathBuf>,
    /// Worker arguments.
    pub worker_args: Vec<OsString>,
    /// External antivirus (none by default; Q-F-2: used if installed and specified by the owner).
    pub av: Option<AvHook>,
    /// Project folder for level 5 (set by the owner).
    pub project_dir: Option<PathBuf>,
}

impl FilesConfig {
    /// Default settings: `$HOME/Antenna/links`, the worker is the daemon itself.
    pub fn new(links_dir: PathBuf) -> Self {
        Self {
            links_dir,
            worker: None,
            worker_args: vec![WORKER_ARG.into(), "check".into()],
            av: None,
            project_dir: None,
        }
    }
}

/// Hidden `antennad` argument that starts a worker process.
pub const WORKER_ARG: &str = "--antenna-files-worker";

/// File pipeline work.
pub(crate) enum Job {
    /// Arrived live over a link: a file offer or request.
    Incoming {
        link: LinkId,
        msg: MessageId,
        body: Box<Body>,
    },
    /// Continue downloading and checking after a restart.
    Resume { link: LinkId, id: String },
}

/// A link's blob store and the iroh-blobs protocol handler with ACL.
pub(crate) struct LinkStore {
    pub(crate) blobs: LinkBlobs,
    proto: iroh_blobs::BlobsProtocol,
}

/// Session files.
pub(crate) struct Files {
    pub(crate) cfg: FilesConfig,
    pub(crate) q: Quarantine,
    pub(crate) checker: Checker,
    data_dir: PathBuf,
    stores: StdMutex<HashMap<LinkId, Arc<OnceCell<Arc<LinkStore>>>>>,
    pub(crate) jobs: mpsc::UnboundedSender<Job>,
    downloads: Semaphore,
    /// Requests from `shared/` per link: times of the latest ones (within the hour) and "in progress".
    requests: StdMutex<HashMap<LinkId, (Vec<u64>, bool)>>,
    /// Checking the daily volume and recording an offer happen in one step (otherwise parallel offers see the same
    /// `used`).
    offer_lock: StdMutex<()>,
    /// Download and check: one at a time per link, so one link does not take all the slots.
    link_slots: StdMutex<HashMap<LinkId, Arc<Semaphore>>>,
}

impl std::fmt::Debug for Files {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Files(..)")
    }
}

fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

/// A sent file the contact can still download: the blob in the link store, the offer message, the time.
/// It is stored in the open in `<data>/quarantine/<link>/out/<file_id>` (the data directory is `0700`): the ciphertext
/// hash and the message ID are not secrets.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct OutRecord {
    #[serde(with = "serde_bytes")]
    blob: [u8; 32],
    #[serde(with = "serde_bytes")]
    message_id: [u8; 32],
    created_ms: u64,
    /// Ciphertext size (limit for unanswered serving of the contact's requests).
    size: u64,
    /// BLAKE3 of (path, size, mtime) of a file from `shared/`: a repeated request for the same file does not encrypt it
    /// again.
    #[serde(default, with = "serde_bytes")]
    src_key: [u8; 32],
    /// SHA-256 of the content (v7), for the answer the sending agent gets.
    #[serde(default, with = "serde_bytes")]
    sha256: Option<[u8; 32]>,
    /// The agent that sent it (v7): it is told of the contact's answer. An agent's offer is signed by link-root, so
    /// the history does not name it.
    #[serde(default)]
    agent: Option<String>,
}

impl Files {
    fn out_dir(&self, link: &LinkId) -> PathBuf {
        self.q.link_dir(&link.0).join("out")
    }

    fn out_save(&self, link: &LinkId, file_id: &str, r: &OutRecord) -> Result<()> {
        let dir = self.out_dir(link);
        std::fs::create_dir_all(&dir)?;
        let bytes = antenna_proto::to_cbor(r).map_err(|e| Error::internal(e.to_string()))?;
        std::fs::write(dir.join(file_id), bytes)?;
        Ok(())
    }

    fn out_list(&self, link: &LinkId) -> Vec<(PathBuf, OutRecord)> {
        let Ok(rd) = std::fs::read_dir(self.out_dir(link)) else {
            return vec![];
        };
        rd.flatten()
            .filter_map(|e| {
                let p = e.path();
                let r = std::fs::read(&p).ok()?;
                Some((p, antenna_proto::from_cbor::<OutRecord>(&r).ok()?))
            })
            .collect()
    }

    /// Where an accepted file is on disk (the link folder recorded at offer time, or the owner's project folder).
    pub(crate) fn saved_path(&self, item: &Item) -> Option<String> {
        let State::Accepted { name, dest } = &item.state else {
            return None;
        };
        let dir = match dest {
            antenna_files::policy::Destination::Inbox => {
                self.cfg.links_dir.join(&item.folder).join("inbox")
            }
            antenna_files::policy::Destination::Shared => {
                self.cfg.links_dir.join(&item.folder).join("shared")
            }
            // The folder recorded at accept (a save folder, D-130); records from before, the project folder
            antenna_files::policy::Destination::Project => item
                .saved_dir
                .clone()
                .or_else(|| self.cfg.project_dir.clone())?,
        };
        Some(dir.join(name).to_string_lossy().into_owned())
    }

    /// Stop serving a sent file: the blob goes to the link store's garbage collection, the record is deleted.
    async fn out_forget(&self, store: &LinkStore, path: &Path, r: &OutRecord) {
        let _ = store
            .blobs
            .forget_outgoing(iroh_blobs::Hash::from_bytes(r.blob))
            .await;
        let _ = std::fs::remove_file(path);
    }
}

impl Files {
    /// Open the quarantine (`<data>/quarantine`, the key comes from the keystore root key).
    pub(crate) fn new(
        data_dir: &Path,
        cfg: FilesConfig,
        key: Secret32,
    ) -> Result<(Arc<Self>, mpsc::UnboundedReceiver<Job>)> {
        let mut cfg = cfg;
        // Links folders (SPEC §10) are created on the first receipt (`ensure_links_dir`), not on `unlock`: a daemon
        // that does not need files (tests, the window) does not touch the home directory. A symlink for the directory
        // itself (another disk) is allowed; further along the path the daemon does not follow symlinks (O_NOFOLLOW at
        // every step)
        if !cfg.links_dir.is_absolute() {
            return Err(Error::bad_request("--links-dir must be an absolute path"));
        }
        // The real path even when the folder does not exist yet (it is created on the first receipt): every path the
        // daemon compares with it (`folder_in_links`) is resolved the same way. Otherwise a parent behind a symlink
        // (`/var` → `/private/var` for temporary directories on macOS) would put every path outside the links folder,
        // and a write into a link's `shared/` would not count as handing data to that link.
        if let Some(c) = real_path(&cfg.links_dir) {
            cfg.links_dir = c;
        }
        let q = Quarantine::open(data_dir.join("quarantine"), *key, &cfg.links_dir)?;
        let worker = match &cfg.worker {
            Some(w) => w.clone(),
            None => std::env::current_exe()?,
        };
        let mut cc = CheckerConfig::new(worker);
        cc.worker_args = cfg.worker_args.clone();
        if cfg.worker.is_none() {
            cc.worker_prefix = vec![WORKER_ARG.into()];
        }
        cc.av = cfg.av.clone();
        let (tx, rx) = mpsc::unbounded_channel();
        Ok((
            Arc::new(Self {
                cfg,
                q,
                checker: Checker::new(cc),
                data_dir: data_dir.to_path_buf(),
                stores: StdMutex::new(HashMap::new()),
                jobs: tx,
                downloads: Semaphore::new(MAX_DOWNLOADS),
                requests: StdMutex::new(HashMap::new()),
                offer_lock: StdMutex::new(()),
                link_slots: StdMutex::new(HashMap::new()),
            }),
            rx,
        ))
    }

    /// A link's store (opened on first access).
    pub(crate) async fn store(&self, link: &LinkId, peer: EndpointId) -> Result<Arc<LinkStore>> {
        let cell = self
            .stores
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(*link)
            .or_default()
            .clone();
        let dir = self.q.blobs_dir(&link.0);
        cell.get_or_try_init(|| async move {
            let blobs = LinkBlobs::open(dir, peer).await?;
            // Outgoing drafts belong to no one after a restart: policy decisions live in daemon memory
            let _ = blobs.clear_drafts().await;
            let proto = blobs.protocol();
            Ok::<_, Error>(Arc::new(LinkStore { blobs, proto }))
        })
        .await
        .cloned()
    }

    /// Close all stores (`antenna lock`).
    pub(crate) async fn shutdown(&self) {
        let cells: Vec<_> = self
            .stores
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .drain()
            .collect();
        for (_, c) in cells {
            if let Some(s) = c.get() {
                let _ = s.blobs.shutdown().await;
            }
        }
    }

    /// Close one link's store (`revoke`).
    pub(crate) async fn close_link(&self, link: &LinkId) {
        let c = self
            .stores
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(link);
        if let Some(c) = c
            && let Some(s) = c.get()
        {
            let _ = s.blobs.shutdown().await;
        }
    }

    /// The daemon's data directory (its files can never be sent to anyone).
    pub(crate) fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    /// Create the links folder (`0700`) before the first receipt.
    fn ensure_links_dir(&self) -> Result<()> {
        use crate::owner_only::OwnerOnly;
        std::fs::DirBuilder::new()
            .recursive(true)
            .owner_only()
            .create(&self.cfg.links_dir)?;
        Ok(())
    }

    /// A link's download-and-check slot.
    fn link_slot(&self, link: &LinkId) -> Arc<Semaphore> {
        self.link_slots
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(*link)
            .or_insert_with(|| Arc::new(Semaphore::new(1)))
            .clone()
    }

    /// Erase everything about a link (after `revoke`): store, quarantine records and keys, serving: crypto-shred.
    pub(crate) async fn purge_link(&self, link: &LinkId) {
        self.close_link(link).await;
        let dir = self.q.link_dir(&link.0);
        if let Err(e) = std::fs::remove_dir_all(&dir)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!("files: purge {}: {e}", &link.to_hex()[..8]);
        }
    }
}

/// iroh-blobs ALPN handler on a link endpoint: the store is opened on the contact's first connection.
pub(crate) struct BlobsHandler {
    pub(crate) files: Arc<Files>,
    pub(crate) link: LinkId,
    pub(crate) peer: EndpointId,
}

impl std::fmt::Debug for BlobsHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BlobsHandler(..)")
    }
}

impl ProtocolHandler for BlobsHandler {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        // The link endpoint's accept-list already admits only the contact; check once more explicitly
        if conn.remote_id() != self.peer {
            conn.close(antenna_proto::link::CLOSE_NOT_PAIRED.into(), b"");
            return Ok(());
        }
        let st = self
            .files
            .store(&self.link, self.peer)
            .await
            .map_err(AcceptError::from_err)?;
        st.proto.accept(conn).await
    }

    async fn shutdown(&self) {
        // The store is closed by the session (`Files::shutdown`), not by the link's Router
    }
}

/// A name a shell takes as one word without quotes (D-125): letters and digits of any script, `.`, `_` and `-` stay;
/// every other character (a space, a quote, `$`, `&`, …) becomes `-`, runs of `-` become one, and `-` and `.` are
/// taken off both ends ("atlas server" → `atlas-server`, "Bob's Mac" → `Bob-s-Mac`). Empty when nothing is left.
pub(crate) fn shell_word(label: &str) -> String {
    let mut out = String::new();
    for c in label.chars() {
        let c = if c.is_alphanumeric() || matches!(c, '.' | '_' | '-') {
            c
        } else {
            '-'
        };
        if !(c == '-' && out.ends_with('-')) {
            out.push(c);
        }
    }
    out.trim_matches(['-', '.']).to_string()
}

/// A link folder name without regard to other links (D-125): the contact label as one shell word ([`shell_word`]) if
/// that is a safe name, otherwise the start of the link ID. A link whose folder was made under the label as it is
/// (before D-125, "atlas server") keeps that folder while it exists: nothing is moved silently. The label stays the
/// contact's display name everywhere.
fn folder_base(row: &LinkRow, links_dir: Option<&Path>) -> String {
    folder_name(&row.label, &row.link_id.to_hex(), links_dir)
}

/// [`folder_base`] from the label and the link ID (hex).
fn folder_name(label: &str, link_hex: &str, links_dir: Option<&Path>) -> String {
    let safe = |n: &str| {
        antenna_files::names::normalize(n)
            .ok()
            .filter(|n| !antenna_files::names::is_special(n))
    };
    if let (Some(dir), Some(legacy)) = (links_dir, safe(label))
        && legacy != shell_word(&legacy)
        && std::fs::symlink_metadata(dir.join(&legacy)).is_ok()
    {
        return legacy;
    }
    safe(&shell_word(label)).unwrap_or_else(|| link_hex[..16.min(link_hex.len())].to_string())
}

/// Folders of all links (in the order of `rows`, which is by creation time) in `links_dir`: names that coincide after
/// normalization and case folding (`fold_key`: "José" in NFC and NFD, "Bob" and "bob" on macOS) get a suffix from the
/// link ID for every link except the oldest, so two links never share a folder.
pub(crate) fn folders(rows: &[LinkRow], links_dir: Option<&Path>) -> Vec<String> {
    let items: Vec<(String, String)> = rows
        .iter()
        .map(|r| (r.label.clone(), r.link_id.to_hex()))
        .collect();
    folder_names(&items, links_dir)
}

/// [`folders`] from (label, link ID hex) pairs.
fn folder_names(items: &[(String, String)], links_dir: Option<&Path>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    items
        .iter()
        .map(|(label, hex)| {
            let base = folder_name(label, hex, links_dir);
            if seen.insert(antenna_files::names::fold_key(&base)) {
                base
            } else {
                format!("{base}-{}", &hex[..8.min(hex.len())])
            }
        })
        .collect()
}

/// The real path of `p` whose tail may not exist yet: the deepest existing ancestor is resolved (symlinks), the
/// non-existent tail is appended as is.
fn real_path(p: &Path) -> Option<PathBuf> {
    let mut existing = p;
    let mut tail = Vec::new();
    while std::fs::symlink_metadata(existing).is_err() {
        tail.push(existing.file_name()?.to_os_string());
        existing = existing.parent()?;
    }
    let mut full = std::fs::canonicalize(existing).ok()?;
    for t in tail.into_iter().rev() {
        full.push(t);
    }
    Some(full)
}

/// Name of the links folder containing `path` (`~/` is expanded; the tail may not exist yet).
pub(crate) fn folder_in_links(links_dir: &Path, path: &str) -> Option<String> {
    let path = path.trim();
    let p = match path.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var_os("HOME")?).join(rest),
        None => PathBuf::from(path),
    };
    if !p.is_absolute()
        || p.components().any(|c| {
            matches!(
                c,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
    {
        return None;
    }
    let full = real_path(&p)?;
    let rel = full.strip_prefix(links_dir).ok()?;
    match rel.components().next()? {
        std::path::Component::Normal(n) => Some(n.to_string_lossy().into_owned()),
        _ => None,
    }
}

fn severity(s: Severity) -> &'static str {
    match s {
        Severity::Info => "info",
        Severity::Warn => "warn",
        Severity::Threat => "threat",
    }
}

/// File details from a quarantine record (the name is escaped).
pub(crate) fn info_of(item: &Item, label: &str) -> FileInfo {
    let (state, dest, saved_as) = match &item.state {
        State::Offered => ("offered", None, None),
        State::Downloaded => ("downloaded", None, None),
        State::Checked => ("checked", None, None),
        State::Accepted { name, dest } => (
            "accepted",
            Some(
                match dest {
                    antenna_files::policy::Destination::Inbox => "inbox",
                    antenna_files::policy::Destination::Shared => "shared",
                    antenna_files::policy::Destination::Project => "project",
                }
                .to_string(),
            ),
            Some(antenna_files::text::escape_visible(name, 300)),
        ),
    };
    let r = item.report.as_ref();
    FileInfo {
        id: item.id.clone(),
        contact: label.to_string(),
        link_id: hex(&item.link),
        direction: "in".into(),
        name: antenna_files::text::escape_visible(&item.manifest.name, 300),
        size: item.manifest.size,
        sender_mime: antenna_files::text::escape_visible(&item.manifest.mime, 128),
        sender_verdict: item.manifest.sender_check.verdict.as_str().into(),
        state: state.into(),
        verdict: r.map(|r| r.verdict.as_str().to_string()),
        mime: r.map(|r| r.mime.clone()),
        findings: r
            .map(|r| {
                r.findings
                    .iter()
                    .map(|f| FileFinding {
                        code: f.code.clone(),
                        severity: severity(f.severity).into(),
                        detail: f.detail.clone(),
                    })
                    .collect()
            })
            .unwrap_or_default(),
        sandbox: r.map(|r| r.sandbox.clone()).filter(|s| !s.is_empty()),
        dest,
        saved_as,
        saved_path: None,
        blake3: hex(&item.manifest.blake3),
        sha256: item.sha256.map(|h| hex(&h)),
        message_id: item.message_id.map(|m| hex(&m)),
        created_ms: item.created_ms,
        expires_ms: r
            .filter(|r| r.verdict == Verdict::Threat)
            .map(|_| item.created_ms + THREAT_KEEP_MS),
        reason: None,
        withdrawal: None,
        duplicate: false,
        held: item
            .held
            .as_ref()
            .filter(|_| !matches!(item.state, State::Accepted { .. }))
            .map(|h| antenna_proto::control::FileHeld {
                code: h.code.clone(),
                message: h.message.clone(),
                rules: h.rules.clone(),
            }),
        class: r.and_then(|r| r.class).map(|c| c.as_str().to_string()),
        labels: vec![],
    }
}

/// Preview for the reply (PNG as base64).
pub(crate) fn preview_view(p: &Preview) -> FilePreviewView {
    FilePreviewView {
        kind: match p.kind {
            PreviewKind::Image => "image",
            PreviewKind::Pdf => "pdf",
            PreviewKind::Document => "document",
            PreviewKind::Text => "text",
            PreviewKind::Archive => "archive",
            PreviewKind::None => "none",
        }
        .into(),
        text: p.text.clone(),
        images_png_base64: p
            .images
            .iter()
            .map(|b| data_encoding::BASE64.encode(b))
            .collect(),
        truncated: p.truncated,
        notice: None,
    }
}

/// Manifest signature with the link's link-root key.
struct RootSigner(ed25519_dalek::SigningKey);

impl antenna_files::manifest::ManifestSigner for RootSigner {
    fn verifying_key(&self) -> [u8; 32] {
        self.0.verifying_key().to_bytes()
    }
    fn sign_bytes(&self, msg: &[u8]) -> [u8; 64] {
        use ed25519_dalek::Signer;
        self.0.sign(msg).to_bytes()
    }
}

/// A file prepared for sending (the blob is a draft until the policy decision).
pub(crate) struct Outgoing {
    pub(crate) prepared: antenna_files::outgoing::Prepared,
    pub(crate) store: Arc<LinkStore>,
    /// Source key for requests from `shared/` (zeros otherwise).
    pub(crate) src_key: [u8; 32],
    /// The agent that sends it (its name on this node), told of the contact's answer (CONTROL §14); `None`: the owner.
    pub(crate) agent: Option<String>,
}

/// Open a file for sending: an absolute path, a regular file, not from the daemon's data directory. Returns the file,
/// the canonical path and the default name.
pub(crate) fn open_for_share(
    files: &Files,
    path: &str,
) -> Result<(std::fs::File, PathBuf, String)> {
    // Windows: opening without following a reparse point swapped in after `canonicalize` (into the data directory, say)
    // and the sender's sandboxed check are WP-21 and WP-19 (D-134, phase W3): refused until then.
    if cfg!(windows) {
        return Err(Error::new(
            code::NOT_IMPLEMENTED,
            "sending files is not available on Windows yet",
        ));
    }
    let p = Path::new(path);
    if !p.is_absolute() {
        return Err(Error::bad_request("the file path must be absolute"));
    }
    let canon =
        std::fs::canonicalize(p).map_err(|e| Error::new(code::NOT_FOUND, format!("file: {e}")))?;
    let data =
        std::fs::canonicalize(files.data_dir()).unwrap_or_else(|_| files.data_dir().to_path_buf());
    if canon.starts_with(&data) && !canon.starts_with(&files.cfg.links_dir) {
        return Err(Error::new(
            code::FORBIDDEN,
            "files of the Antenna daemon (keys, database, quarantine) are never shared",
        ));
    }
    let file = {
        let mut o = std::fs::OpenOptions::new();
        o.read(true);
        // NONBLOCK: a FIFO does not hang the daemon on open (only a regular file is accepted below)
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.custom_flags(
                (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32,
            );
        }
        o.open(&canon)
            .map_err(|e| Error::new(code::NOT_FOUND, format!("file: {e}")))?
    };
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(Error::bad_request("not a regular file"));
    }
    let name = canon
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".into());
    Ok((file, canon, name))
}

/// What identifies a file served from `shared/` (the request path, inode, size and modification time), `None` for a
/// hard-linked one.
#[cfg(unix)]
fn shared_key(path: &str, meta: &std::fs::Metadata) -> Option<[u8; 32]> {
    use std::os::unix::fs::MetadataExt;
    if meta.nlink() > 1 {
        return None;
    }
    Some(
        *blake3::hash(
            format!(
                "{}\0{}\0{}\0{}.{}",
                path,
                meta.ino(),
                meta.len(),
                meta.mtime(),
                meta.mtime_nsec()
            )
            .as_bytes(),
        )
        .as_bytes(),
    )
}

/// Windows: the link count and file index need `GetFileInformationByHandle` (D-134, WP-21); `None`, never served.
/// (`open_file_nofollow` refuses there first.)
#[cfg(windows)]
fn shared_key(_path: &str, _meta: &std::fs::Metadata) -> Option<[u8; 32]> {
    None
}

/// Create the staging file of a `share_file_content` upload in `<data-dir>/outgoing/<link hex>/` (directories `0700`):
/// a random name ending in `.part`, mode `0600`, `O_CREAT | O_EXCL | O_NOFOLLOW`, read and write. The name is removed
/// at once: the bytes live only behind the returned descriptor, so a refusal, an error, a wait for approval or a
/// dropped connection leaves nothing on disk once the descriptor is closed. The file is opened here directly, not
/// through [`open_for_share`], which refuses files of the data directory on purpose: this one the daemon made itself.
pub(crate) fn stage_outgoing(data_dir: &Path, link: &LinkId) -> Result<std::fs::File> {
    use crate::owner_only::OwnerOnly;
    // Windows: the sender's sandboxed check is WP-19 (D-134, phase W3), so nothing is staged for sending there yet.
    if cfg!(windows) {
        return Err(Error::new(
            code::NOT_IMPLEMENTED,
            "sending files is not available on Windows yet",
        ));
    }
    sweep_staged(data_dir);
    let top = data_dir.join(OUTGOING_DIR);
    let dir = top.join(link.to_hex());
    std::fs::DirBuilder::new()
        .recursive(true)
        .owner_only()
        .create(&dir)?;
    for d in [&top, &dir] {
        let m = std::fs::symlink_metadata(d)?;
        if !m.is_dir() {
            return Err(Error::internal(format!(
                "{} is not a directory",
                d.display()
            )));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if m.permissions().mode() & 0o077 != 0 {
                std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))?;
            }
        }
    }
    let path = dir.join(format!("{}.part", hex(&crate::crypto::random::<16>())));
    let mut o = std::fs::OpenOptions::new();
    o.read(true).write(true).create_new(true).owner_only();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    let file = o.open(&path)?;
    std::fs::remove_file(&path)?;
    Ok(file)
}

/// Remove staged uploads older than [`STAGED_STALE`]: only a crash between creating and unlinking one leaves a name
/// behind. Runs when a session opens and before every new upload.
pub(crate) fn sweep_staged(data_dir: &Path) {
    let Ok(links) = std::fs::read_dir(data_dir.join(OUTGOING_DIR)) else {
        return;
    };
    for l in links.flatten() {
        let Ok(rd) = std::fs::read_dir(l.path()) else {
            continue;
        };
        for e in rd.flatten() {
            let p = e.path();
            let stale = e
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > STAGED_STALE);
            if stale && p.extension().is_some_and(|x| x == "part") {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
}

/// Where the bytes of an outgoing file come from (the approval screen says it).
pub(crate) enum ShareSource<'a> {
    /// A local file (canonical path).
    Path(&'a str),
    /// Bytes the agent sent by value (`share_file_content`): no local file is read.
    Content,
}

impl Session {
    /// Session files.
    pub(crate) fn files(&self) -> Result<&Arc<Files>> {
        self.files
            .as_ref()
            .ok_or_else(|| Error::new(code::NOT_IMPLEMENTED, "files are disabled on this node"))
    }

    /// Link folder (taking label collisions with other links into account).
    pub(crate) fn folder_for(&self, row: &LinkRow) -> String {
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()
            .unwrap_or_default();
        let dir = self.files().ok().map(|f| f.cfg.links_dir.as_path());
        rows.iter()
            .zip(folders(&rows, dir))
            .find(|(r, _)| r.link_id == row.link_id)
            .map(|(_, f)| f)
            .unwrap_or_else(|| folder_base(row, dir))
    }

    /// The link whose folder contains the path: writing there passes data to that link, reading there is its data.
    pub(crate) fn link_of_path(&self, path: &str) -> Option<LinkRow> {
        let f = self.files().ok()?;
        let folder = folder_in_links(&f.cfg.links_dir, path)?;
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()
            .ok()?;
        let names = folders(&rows, Some(&f.cfg.links_dir));
        rows.into_iter()
            .zip(names)
            .find(|(_, n)| *n == folder)
            .map(|(r, _)| r)
    }

    /// File info with the absolute path of an accepted file (the window opens it, e.g. a signed update, D-82).
    pub(crate) fn file_info(&self, item: &Item, label: &str) -> FileInfo {
        let mut i = info_of(item, label);
        if let Ok(f) = self.files() {
            i.saved_path = f.saved_path(item);
        }
        // From level 3 the check's heuristics are labels (D-130)
        if let (Some(r), Ok(row)) = (item.report.as_ref(), self.row_of(&LinkId(item.link))) {
            let level = row.trust.min(item.level_at_offer);
            let allow = self.file_allow(&row.link_id);
            i.labels = antenna_files::kinds::labels(r, &item.manifest.name, level, &allow);
            // Only a threat the rules read as one is deleted after 7 days
            if antenna_files::kinds::effective_verdict(r, &item.manifest.name, level, &allow)
                != Verdict::Threat
            {
                i.expires_ms = None;
            }
        }
        i
    }

    pub(crate) fn emit_file(&self, link: &LinkId, info: FileInfo) {
        let _ = self.events.send(NodeEvent::File {
            link: *link,
            info: Box::new(info),
        });
    }

    fn row_of(&self, link: &LinkId) -> Result<LinkRow> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(link)
    }

    /// A file by ID (or its prefix of at least 8 hex characters) among the links in `scope` (`None` means all): the
    /// record and the link row.
    pub(crate) fn find_file(&self, id: &str, scope: Option<&[LinkId]>) -> Result<(Item, LinkRow)> {
        let f = self.files()?;
        let id = id.trim().to_ascii_lowercase();
        if id.len() < 8 || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::bad_request(
                "file id: 8 to 32 hex characters (antenna files pending)",
            ));
        }
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?;
        let mut found = Vec::new();
        for row in rows {
            if scope.is_some_and(|s| !s.contains(&row.link_id)) {
                continue;
            }
            for item in f.q.items(&row.link_id.0)? {
                if item.id.starts_with(&id) {
                    found.push((item, row.clone()));
                }
            }
        }
        match found.len() {
            0 => Err(Error::new(code::NOT_FOUND, "no such file in quarantine")),
            1 => Ok(found.remove(0)),
            _ => Err(Error::bad_request(
                "several files start with this id: give more characters",
            )),
        }
    }

    /// Files of the links in `scope` (`None` means all), of a single link only (`contact`), including accepted ones
    /// (`all`).
    pub(crate) fn files_list(
        &self,
        scope: Option<&[LinkId]>,
        only: Option<&LinkId>,
        all: bool,
    ) -> Result<Vec<(FileInfo, LinkId, u8)>> {
        let f = self.files()?;
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?;
        let mut out = Vec::new();
        for row in rows {
            if scope.is_some_and(|s| !s.contains(&row.link_id))
                || only.is_some_and(|o| *o != row.link_id)
            {
                continue;
            }
            for item in f.q.items(&row.link_id.0)? {
                if !all && matches!(item.state, State::Accepted { .. }) {
                    continue;
                }
                out.push((self.file_info(&item, &row.label), row.link_id, row.trust));
            }
        }
        out.sort_by_key(|(i, _, _)| i.created_ms);
        Ok(out)
    }

    /// Prepare a file for sending over a link: sender-side check, encryption into the link store, signed manifest.
    pub(crate) async fn prepare_outgoing(
        &self,
        row: &LinkRow,
        file: std::fs::File,
        name: &str,
    ) -> Result<Outgoing> {
        let f = self.files()?.clone();
        self.ensure_running(&row.link_id)?;
        let peer = iroh::PublicKey::from_bytes(&row.peer_endpoint)
            .map_err(|_| Error::internal("bad peer endpoint in db"))?;
        let store = f.store(&row.link_id, peer).await?;
        let seed = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            Db::root_seed(db.conn(), &row.link_id)?
        };
        let signer = RootSigner(ed25519_dalek::SigningKey::from_bytes(&seed));
        let prepared = antenna_files::outgoing::prepare_file(
            file,
            name,
            &store.blobs,
            &f.checker,
            &signer,
            &row.link_id.0,
            &row.peer_root_ed25519,
        )
        .await?;
        Ok(Outgoing {
            prepared,
            store,
            src_key: [0; 32],
            agent: None,
        })
    }

    /// Send a prepared file: the blob is served to the contact, the offer goes into the link's history and queue.
    /// `addr`: who the offer is for (PG-19), on the wire only to a node with `file-addr/0`.
    pub(crate) async fn send_outgoing(
        &self,
        row: &LinkRow,
        out: Outgoing,
        addr: &Addr,
    ) -> Result<FileInfo> {
        out.store.blobs.offer_existing(out.prepared.blob).await?;
        let m = &out.prepared.manifest;
        let body = Body::File(out.prepared.offer.clone());
        // An agent's file goes out signed by the agent's key in the link, like its messages (PROTOCOL §21), so the
        // contact's owner can save its files apart (D-130); the manifest stays signed by link-root. Only to a node
        // with `file-fate/0`: an older node has only ever seen file offers signed by link-root.
        let author = out
            .agent
            .as_deref()
            .filter(|_| {
                self.rt(&row.link_id)
                    .is_ok_and(|rt| rt.shared.peer_supports_file_fate())
            })
            .map(|a| self.agent_public_name(a, &row.link_id));
        let (id, _) = match self
            .send_body_as(
                row,
                MessageType::File,
                body,
                Duration::ZERO,
                None,
                author,
                addr,
            )
            .await
        {
            Ok(r) => r,
            Err(e) => {
                let _ = out.store.blobs.forget_outgoing(out.prepared.blob).await;
                return Err(e);
            }
        };
        // Serve until the contact answers (acceptance or rejection) or OUT_KEEP_MS, after which the blob goes to
        // garbage collection
        let rec = OutRecord {
            blob: *out.prepared.blob.as_bytes(),
            message_id: id.0,
            created_ms: now_ms(),
            size: m.blob_size,
            src_key: out.src_key,
            sha256: Some(out.prepared.sha256),
            agent: out.agent.clone(),
        };
        if let Err(e) = self.files()?.out_save(&row.link_id, &hex(&m.file_id), &rec) {
            tracing::warn!("files: outgoing record: {e}");
        }
        let info = FileInfo {
            id: hex(&m.file_id),
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            direction: "out".into(),
            name: antenna_files::text::escape_visible(&m.name, 300),
            size: m.size,
            sender_mime: m.mime.clone(),
            sender_verdict: m.sender_check.verdict.as_str().into(),
            state: "sent".into(),
            verdict: Some(out.prepared.report.verdict.as_str().into()),
            mime: Some(out.prepared.report.mime.clone()),
            findings: out
                .prepared
                .report
                .findings
                .iter()
                .map(|f| FileFinding {
                    code: f.code.clone(),
                    severity: severity(f.severity).into(),
                    detail: f.detail.clone(),
                })
                .collect(),
            sandbox: Some(out.prepared.report.sandbox.clone()).filter(|s| !s.is_empty()),
            dest: None,
            saved_as: None,
            saved_path: None,
            blake3: hex(&m.blake3),
            sha256: Some(hex(&out.prepared.sha256)),
            message_id: Some(id.to_hex()),
            created_ms: now_ms(),
            expires_ms: None,
            reason: None,
            withdrawal: None,
            duplicate: false,
            held: None,
            class: out.prepared.report.class.map(|c| c.as_str().to_string()),
            // This computer's check labels what it sent; the contact's check decides there (D-130)
            labels: out
                .prepared
                .report
                .findings
                .iter()
                .filter(|f| f.severity != Severity::Info)
                .map(|f| f.code.clone())
                .collect(),
        };
        self.emit_file(&row.link_id, info.clone());
        Ok(info)
    }

    /// Secrets and threats in the sender's report: reasons for approval (SPEC §9 "at any level").
    pub(crate) fn outgoing_reasons(out: &Outgoing, level: u8) -> Vec<String> {
        let r = &out.prepared.report;
        let mut v: Vec<String> = r
            .findings
            .iter()
            .filter(|f| f.code.starts_with("secret"))
            .map(|f| f.code.clone())
            .collect();
        // From level 3 this computer's check only labels what it sends: the contact's check decides there (D-130)
        if level < antenna_files::kinds::LABELS_FROM
            && matches!(r.verdict, Verdict::Threat | Verdict::Failed)
        {
            v.push(format!("sender_check:{}", r.verdict.as_str()));
        }
        v
    }

    /// The owner's `antenna share`: secrets in the file need approval for the owner too (SPEC §9); level 1 has no
    /// files at all.
    pub async fn owner_share_file(
        &self,
        contact: &str,
        path: &str,
        name: Option<&str>,
        approval_id: Option<&str>,
        addr: &Addr,
    ) -> Result<FileInfo> {
        let row = self.find_link(contact)?;
        if row.trust <= 1 {
            return Err(Error::new(code::DENIED, "trust level 1 exchanges no files"));
        }
        let f = self.files()?.clone();
        let (file, canon, default_name) = open_for_share(&f, path)?;
        let name = name.map(str::to_string).unwrap_or(default_name);
        let out = self.prepare_outgoing(&row, file, &name).await?;
        // A secret in the content or in the name (the name goes to the contact in plain text in the manifest):
        // approval (SPEC §9)
        let mut reasons: Vec<String> = Self::outgoing_reasons(&out, row.trust)
            .into_iter()
            .filter(|r| r.starts_with("secret"))
            .collect();
        reasons.extend(
            crate::policy::scan_secrets(&out.prepared.manifest.name)
                .into_iter()
                .map(|k| format!("secret_in_name:{k}")),
        );
        // To the owner's own computer (level 5, D-99) a secret goes without approval; the audit log keeps it
        let reasons = self.waive_level_5(&row, row.trust, "owner", "share_file", reasons);
        if !reasons.is_empty() {
            let m = &out.prepared.manifest;
            let req = share_approval(
                "owner",
                "owner",
                &row,
                &row,
                reasons,
                ShareSource::Path(&canon.to_string_lossy()),
                &m.name,
                m.size,
                &m.blake3,
            );
            match self.gate(req, approval_id, &row.link_id, "owner") {
                Ok(_) => {}
                Err(e) => {
                    let _ = out.store.blobs.forget_outgoing(out.prepared.blob).await;
                    return Err(e);
                }
            }
        }
        self.send_outgoing(&row, out, addr).await
    }

    /// The address of an offer from its signed `core` (PROTOCOL §19, §23): what the sender addressed, never a derived
    /// column. An error when the message is missing or unreadable: the caller refuses.
    pub(crate) fn offer_to(
        &self,
        link: &LinkId,
        message_id: &[u8; 32],
    ) -> Result<Option<antenna_proto::To>> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let m = Db::message_by_id(db.conn(), link, &antenna_proto::MessageId(*message_id))?
            .ok_or_else(|| {
                Error::new(code::NOT_FOUND, "the offer's message is not in the history")
            })?;
        let core: antenna_proto::EnvelopeCore = antenna_proto::from_cbor(&m.core)?;
        Ok(core.to)
    }

    /// The answer to a file request goes to the contact's agent that asked (PG-19), read from the request's signed
    /// author, an announced agent key (PROTOCOL §21). A request signed by link-root (the person, or an agent of a node
    /// from before 0.2.0) gets an answer without an address, as before: every agent of the contact with the link sees
    /// it.
    fn request_addr(&self, link: &LinkId, msg: &MessageId) -> Addr {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let agent = Db::message_by_id(db.conn(), link, msg)
            .ok()
            .flatten()
            .and_then(|m| m.agent_key)
            .and_then(|k| crate::agentid::lookup(db.conn(), link, &k).ok().flatten())
            .filter(|k| !k.mine)
            .map(|k| k.name);
        Addr {
            urgent: false,
            to: agent.map(antenna_proto::To::Agent),
            topic: None,
        }
    }

    /// Send a request for a file from the contact's `shared/`.
    /// `agent`: the name the contact knows the asking agent by; its key signs the request (PROTOCOL §21), so the
    /// contact's node addresses the answer to it (PG-19). `None`: the owner, signed by link-root.
    pub(crate) async fn send_file_request(
        &self,
        row: &LinkRow,
        path: &str,
        agent: Option<String>,
    ) -> Result<(String, String)> {
        let path = path.trim_start_matches('/');
        if path.is_empty() || path.len() > antenna_proto::files::MAX_REQUEST_PATH {
            return Err(Error::bad_request(
                "path inside the contact's shared/ folder",
            ));
        }
        if let Some(p) = antenna_files::names::archive_path_problem(path) {
            return Err(Error::bad_request(format!("bad path: {p}")));
        }
        let body = Body::FileRequest(FileRequest { path: path.into() });
        let (id, sent) = self
            .send_body_as(
                row,
                MessageType::Request,
                body,
                Duration::from_secs(2),
                None,
                agent,
                &Addr::default(),
            )
            .await?;
        Ok((id.to_hex(), sent.status))
    }

    /// The owner's `antenna request` (level 2+; the contact decides, by its own trust level for this node).
    pub async fn owner_request_file(
        &self,
        contact: &str,
        path: &str,
    ) -> Result<(String, String, String)> {
        let row = self.find_link(contact)?;
        if row.trust <= 1 {
            return Err(Error::new(code::DENIED, "trust level 1 exchanges no files"));
        }
        // The path goes to the contact in plain message text: the same secret scanner as for `send`
        let reasons: Vec<String> = crate::policy::scan_secrets(path)
            .into_iter()
            .map(|k| format!("secret:{k}"))
            .collect();
        let reasons = self.waive_level_5(&row, row.trust, "owner", "request_file", reasons);
        if !reasons.is_empty() {
            self.gate(
                request_approval("owner", "owner", &row, &row, reasons, path),
                None,
                &row.link_id,
                "owner",
            )?;
        }
        let (id, status) = self.send_file_request(&row, path, None).await?;
        Ok((row.label, id, status))
    }

    /// File preview (the original never leaves the quarantine).
    pub(crate) fn preview_of(&self, item: &Item) -> Result<Option<FilePreviewView>> {
        let f = self.files()?;
        let (_, p) = f.q.preview(&item.link, &item.id)?;
        Ok(p.as_ref().map(preview_view))
    }

    /// Accept a file (the caller has already decided the policy: who accepts and whether a special name is approved).
    #[allow(
        clippy::too_many_arguments,
        reason = "the owner and agent paths pass different policy inputs (acceptor, approved special name, rename) and audit fields"
    )]
    pub(crate) async fn accept_file(
        &self,
        item: &Item,
        row: &LinkRow,
        acceptor: &antenna_files::policy::Acceptor<'_>,
        special_approved: bool,
        rename: Option<&str>,
        actor: &str,
        decision: &str,
    ) -> Result<FileInfo> {
        let f = self.files()?.clone();
        let peer = iroh::PublicKey::from_bytes(&row.peer_endpoint)
            .map_err(|_| Error::internal("bad peer endpoint in db"))?;
        let store = f.store(&row.link_id, peer).await?;
        f.ensure_links_dir()?;
        // At level 5, the save folder of the agent that signed the offer, the contact's, or `--project-dir` (D-130)
        let project = self.save_dir_of(item, row);
        let allow = self.file_allow(&row.link_id);
        let acc =
            f.q.accept(
                &row.link_id.0,
                &item.id,
                &store.blobs,
                row.trust,
                acceptor,
                special_approved,
                project.as_deref(),
                rename,
                &allow,
            )
            .await?;
        let item = f.q.get(&row.link_id.0, &item.id)?;
        let mut info = self.file_info(&item, &row.label);
        info.duplicate = acc.duplicate;
        let refs: Vec<MessageId> = item.message_id.map(MessageId).into_iter().collect();
        let dest = info.dest.as_deref().unwrap_or("?");
        let copy = if acc.name_number != 0 {
            format!(" as copy ({})", acc.name_number)
        } else {
            String::new()
        };
        self.receipt(
            &row.link_id,
            actor,
            "accept_file",
            decision,
            &if acc.duplicate {
                format!(
                    "the same file ({} bytes) was already in {dest}/{copy}",
                    acc.size
                )
            } else {
                format!("{} bytes into {dest}/{copy}", acc.size)
            },
            refs.first(),
            None,
        );
        // The contact learns the number its file got when the offered name was taken (D-128, `file-saved-as/0`)
        self.dag_receipt_numbered(
            &row.link_id,
            actor,
            "accept_file",
            "accepted",
            &refs,
            acc.name_number,
        );
        self.emit_file(&row.link_id, info.clone());
        // The other agents that may see this file learn where it is (CONTROL §14)
        self.notice_saved(&row.link_id, row.trust, &info, actor);
        Ok(info)
    }

    /// Reject a file: the record and the key are erased, the blob goes to garbage collection; the contact gets a
    /// `reject_file` receipt.
    pub(crate) async fn reject_file(
        &self,
        item: &Item,
        row: &LinkRow,
        actor: &str,
        decision: &str,
    ) -> Result<FileInfo> {
        self.reject_file_why(item, row, actor, decision, None).await
    }

    /// [`Session::reject_file`] that tells the sender why (D-130, `file-fate/0`): a refusal of the daemon's own.
    pub(crate) async fn reject_file_why(
        &self,
        item: &Item,
        row: &LinkRow,
        actor: &str,
        decision: &str,
        why: Option<&str>,
    ) -> Result<FileInfo> {
        let f = self.files()?.clone();
        let peer = iroh::PublicKey::from_bytes(&row.peer_endpoint)
            .map_err(|_| Error::internal("bad peer endpoint in db"))?;
        let store = f.store(&row.link_id, peer).await?;
        let mut info = info_of(item, &row.label);
        f.q.reject(&row.link_id.0, &item.id, &store.blobs).await?;
        info.state = "rejected".into();
        let refs: Vec<MessageId> = item.message_id.map(MessageId).into_iter().collect();
        self.receipt(
            &row.link_id,
            actor,
            "reject_file",
            decision,
            why.unwrap_or(""),
            refs.first(),
            None,
        );
        match why {
            Some(w) => self.dag_receipt_fate(&row.link_id, "reject_file", decision, &refs, w, &[]),
            None => self.dag_receipt(&row.link_id, actor, "reject_file", decision, &refs),
        }
        self.emit_file(&row.link_id, info.clone());
        Ok(info)
    }

    /// The owner's `antenna files accept`: a threat or an unchecked file only with `force` (the caller has checked the
    /// password).
    pub async fn owner_file_accept(
        &self,
        id: &str,
        name: Option<&str>,
        force: bool,
        allow_special: bool,
    ) -> Result<FileInfo> {
        let (item, row) = self.find_file(id, None)?;
        let forced = antenna_files::policy::OwnerForce::after_owner_password_check();
        let acceptor = if force {
            antenna_files::policy::Acceptor::OwnerForce(&forced)
        } else {
            antenna_files::policy::Acceptor::Owner
        };
        self.accept_file(
            &item,
            &row,
            &acceptor,
            allow_special,
            name,
            "owner",
            if force { "forced" } else { "accepted" },
        )
        .await
    }

    /// `file_name_check` (preview.8): whether a received file can be accepted under `name` now.
    pub async fn owner_file_name_check(
        &self,
        id: &str,
        name: Option<&str>,
    ) -> Result<antenna_proto::control::FileNameCheck> {
        use antenna_files::quarantine::NameState;
        let (item, row) = self.find_file(id, None)?;
        let f = self.files()?.clone();
        f.ensure_links_dir()?;
        let project = self.save_dir_of(&item, &row);
        let (name, state) = f.q.name_check(
            &row.link_id.0,
            &item.id,
            row.trust,
            project.as_deref(),
            name,
        )?;
        let (state, suggestion, message) = match state {
            NameState::Free => ("free", None, None),
            NameState::Same => ("same_file", None, None),
            NameState::Taken(s) => (
                "taken",
                Some(s),
                Some("a file with this name (ignoring case) already exists".to_string()),
            ),
            NameState::Invalid(m) => ("invalid", None, Some(m)),
        };
        Ok(antenna_proto::control::FileNameCheck {
            name: antenna_files::text::escape_visible(&name, 300),
            state: state.into(),
            suggestion,
            message,
        })
    }

    /// The owner's `antenna files reject`.
    pub async fn owner_file_reject(&self, id: &str) -> Result<FileInfo> {
        let (item, row) = self.find_file(id, None)?;
        self.reject_file(&item, &row, "owner", "rejected").await
    }

    /// The owner's `antenna files withdraw` (PROTOCOL §19): a file this node sent that the contact has not answered yet
    /// is no longer served, and a contact whose node has `file-withdraw/0` gets a `withdraw_file` / `withdrawn` receipt
    /// referring to the offer, on which it deletes its pending copy. `id` is the file ID or the offer message ID (8+ hex).
    /// A file the contact already accepted or rejected has no outgoing record any more: `not_found`.
    pub async fn owner_file_withdraw(&self, id: &str) -> Result<FileInfo> {
        let f = self.files()?.clone();
        let id = id.trim().to_ascii_lowercase();
        if id.len() < 8 || id.len() > 64 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::bad_request(
                "file id: 8 to 64 hex characters, the file ID or the offer message ID",
            ));
        }
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()?;
        let mut found = Vec::new();
        for row in rows {
            for (path, rec) in f.out_list(&row.link_id) {
                let file_id = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if file_id.starts_with(&id) || hex(&rec.message_id).starts_with(&id) {
                    found.push((row.clone(), path, rec, file_id));
                }
            }
        }
        let (row, path, rec, file_id) = match found.len() {
            0 => {
                return Err(Error::new(
                    code::NOT_FOUND,
                    "no sent file waits for the contact's answer with this id: the contact already accepted or \
                     rejected it, or it was sent more than 14 days ago",
                ));
            }
            1 => found.remove(0),
            _ => {
                return Err(Error::bad_request(
                    "several sent files start with this id: give more characters",
                ));
            }
        };
        let peer = iroh::PublicKey::from_bytes(&row.peer_endpoint)
            .map_err(|_| Error::internal("bad peer endpoint in db"))?;
        let store = f.store(&row.link_id, peer).await?;
        f.out_forget(&store, &path, &rec).await;
        let msg = MessageId(rec.message_id);
        let notify = self
            .rt(&row.link_id)
            .is_ok_and(|rt| rt.shared.peer_supports_file_withdraw());
        self.receipt(
            &row.link_id,
            "owner",
            "withdraw_file",
            "withdrawn",
            if notify {
                ""
            } else {
                "the contact's node cannot withdraw: no longer served"
            },
            Some(&msg),
            None,
        );
        if notify {
            self.dag_receipt(&row.link_id, "owner", "withdraw_file", "withdrawn", &[msg]);
        }
        let mut info = self.sent_file_info(&row, &msg, &file_id);
        info.state = "withdrawn".into();
        info.withdrawal = Some(
            if notify {
                "contact_notified"
            } else {
                "contact_cannot_withdraw"
            }
            .into(),
        );
        tracing::info!(
            "link {}: sent file {} withdrawn ({})",
            &row.link_id.to_hex()[..8],
            &file_id[..8.min(file_id.len())],
            info.withdrawal.as_deref().unwrap_or("")
        );
        self.emit_file(&row.link_id, info.clone());
        Ok(info)
    }

    /// What the history knows about a file this node sent (the manifest of its offer message), for replies about it.
    fn sent_file_info(&self, row: &LinkRow, msg: &MessageId, file_id: &str) -> FileInfo {
        let manifest = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            Db::message_by_id(db.conn(), &row.link_id, msg)
                .ok()
                .flatten()
        }
        .and_then(|m| antenna_proto::from_cbor::<antenna_proto::EnvelopeCore>(&m.core).ok())
        .and_then(|core| match core.body {
            Body::File(offer) => {
                antenna_proto::from_cbor::<antenna_proto::files::Manifest>(&offer.manifest.body)
                    .ok()
            }
            _ => None,
        });
        FileInfo {
            id: file_id.to_string(),
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            direction: "out".into(),
            name: manifest
                .as_ref()
                .map(|m| antenna_files::text::escape_visible(&m.name, 300))
                .unwrap_or_default(),
            size: manifest.as_ref().map_or(0, |m| m.size),
            sender_mime: manifest
                .as_ref()
                .map(|m| m.mime.clone())
                .unwrap_or_default(),
            sender_verdict: manifest
                .as_ref()
                .map(|m| m.sender_check.verdict.as_str().into())
                .unwrap_or_default(),
            state: "sent".into(),
            verdict: None,
            mime: None,
            findings: Vec::new(),
            sandbox: None,
            dest: None,
            saved_as: None,
            saved_path: None,
            blake3: manifest
                .as_ref()
                .map(|m| hex(&m.blake3))
                .unwrap_or_default(),
            sha256: None,
            message_id: Some(msg.to_hex()),
            created_ms: manifest.as_ref().map_or(0, |m| m.created_ms),
            expires_ms: None,
            reason: None,
            withdrawal: None,
            duplicate: false,
            held: None,
            class: None,
            labels: vec![],
        }
    }

    /// The contact withdrew its offer (`withdraw_file`, PROTOCOL §19): a copy that is not accepted yet is deleted like a
    /// rejection (a repeat of the same offer is not taken), and the owner's subscriptions get `state: "withdrawn"`. An
    /// accepted file stays. Only this link's quarantine is looked at, so a contact can withdraw only its own offers.
    async fn on_withdrawn(self: Arc<Self>, link: LinkId, refs: Vec<MessageId>) {
        let Ok(f) = self.files().cloned() else { return };
        let Ok(row) = self.row_of(&link) else { return };
        let Ok(peer) = iroh::PublicKey::from_bytes(&row.peer_endpoint) else {
            return;
        };
        let Ok(items) = f.q.items(&link.0) else {
            return;
        };
        let items: Vec<Item> = items
            .into_iter()
            .filter(|it| it.message_id.is_some_and(|m| refs.iter().any(|r| r.0 == m)))
            .filter(|it| !matches!(it.state, State::Accepted { .. }))
            .collect();
        if items.is_empty() {
            return;
        }
        let Ok(store) = f.store(&link, peer).await else {
            return;
        };
        for item in items {
            let mut info = self.file_info(&item, &row.label);
            // A download or check of this file may hold it for a moment: retry for up to a minute.
            let mut tries = 0;
            loop {
                match f.q.reject(&link.0, &item.id, &store.blobs).await {
                    Ok(()) => break,
                    Err(e) if e.code == code::NOT_FOUND => break,
                    Err(e) if tries < 30 => {
                        tracing::debug!("link {}: withdrawn file busy: {e}", &link.to_hex()[..8]);
                        tries += 1;
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                    Err(e) => {
                        tracing::warn!("link {}: withdrawn file: {e}", &link.to_hex()[..8]);
                        break;
                    }
                }
            }
            info.state = "withdrawn".into();
            self.emit_file(&link, info);
        }
    }

    /// A checked file from a level-5 contact that the rules do not hold (D-130), the owner's own computer, is accepted by the daemon
    /// on the owner's standing word (D-99), dot-file names included: the same accept as the owner's, with the same
    /// receipts. A taken name gets the next free number (D-128). If it still cannot be saved (an invalid name, every
    /// number taken, the folder or the disk), it stays in quarantine for the owner with the reason (`held`), which
    /// every list of the file and its `file` event show: never silently.
    ///
    /// `release`: the file is an asset of a release signed by a key pinned in this daemon
    /// (D-103), which the daemon verified, so the hold of a program or an installer does not apply (D-130).
    pub(crate) async fn accept_own_as(
        &self,
        item: &Item,
        row: &LinkRow,
        release: bool,
    ) -> Option<FileInfo> {
        let signed = antenna_files::policy::OwnerForce::signed_release();
        let acceptor = if release {
            antenna_files::policy::Acceptor::OwnerForce(&signed)
        } else {
            antenna_files::policy::Acceptor::Owner
        };
        let r = self
            .accept_file(
                item,
                row,
                &acceptor,
                true,
                None,
                "owner",
                crate::approvals::ALLOWED_AT_5,
            )
            .await;
        match r {
            Ok(info) => Some(info),
            Err(e) => {
                tracing::info!(
                    "link {}: a file from the owner's own computer stays in quarantine: {}",
                    &row.link_id.to_hex()[..8],
                    e.code
                );
                let held = antenna_files::quarantine::Held {
                    code: e.code.to_string(),
                    message: e.message.clone(),
                    rules: vec![],
                };
                if let Ok(f) = self.files()
                    && f.q.set_held(&row.link_id.0, &item.id, Some(held)).is_ok()
                    && let Ok(it) = f.q.get(&row.link_id.0, &item.id)
                {
                    self.emit_file(&row.link_id, self.file_info(&it, &row.label));
                }
                // The sender learns that it waits, and the accept's error code (D-130)
                self.not_saved(row, item, e.code);
                None
            }
        }
    }

    // Pipeline: incoming offers and requests, download, check, maintenance

    /// The session's file pipeline work (until `antenna lock`).
    pub(crate) async fn files_loop(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<Job>) {
        // Leftovers of receiving after a crash (`.antenna-incoming-*`, from pre-release builds `.x-incoming-*`): only
        // in links folders that already exist
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links();
        if let (Ok(f), Ok(rows)) = (self.files(), rows) {
            let names = folders(&rows, Some(&f.cfg.links_dir));
            for (row, folder) in rows.iter().zip(names) {
                let _ = row;
                for sub in ["inbox", "shared"] {
                    let p = f.cfg.links_dir.join(&folder).join(sub);
                    if std::fs::symlink_metadata(&p).is_ok_and(|m| m.is_dir()) {
                        let _ = antenna_files::accept::remove_stale_incoming(
                            &f.cfg.links_dir,
                            &[&folder, sub],
                        );
                    }
                }
            }
        }
        // Finish downloading and checking what did not complete before the restart
        if let Ok(f) = self.files() {
            for link in f.q.links() {
                if let Ok(items) = f.q.items(&link) {
                    for it in items {
                        if matches!(it.state, State::Offered | State::Downloaded) {
                            let _ = f.jobs.send(Job::Resume {
                                link: LinkId(link),
                                id: it.id,
                            });
                        }
                    }
                }
            }
        }
        loop {
            let job = tokio::select! {
                j = rx.recv() => match j { Some(j) => j, None => break },
                _ = self.closed_wait() => break,
            };
            let me = self.clone();
            tokio::spawn(async move {
                match job {
                    Job::Incoming { link, msg, body } => match *body {
                        Body::File(offer) => me.on_offer(link, msg, offer).await,
                        Body::FileRequest(req) => me.on_request(link, msg, req).await,
                        Body::Receipt(r) => me.on_contact_receipt(link, r).await,
                        _ => {}
                    },
                    Job::Resume { link, id } => me.download_and_check(link, id).await,
                }
            });
        }
    }

    async fn on_offer(self: Arc<Self>, link: LinkId, msg: MessageId, offer: FileOffer) {
        let Ok(f) = self.files().cloned() else { return };
        let Ok(row) = self.row_of(&link) else { return };
        let folder = self.folder_for(&row);
        // Daily volume, the number of pending records and recording the offer: under one lock and outside tokio
        // threads (every quarantine record gets decrypted)
        let r = {
            let (f, row, offer) = (f.clone(), row.clone(), offer.clone());
            tokio::task::spawn_blocking(move || {
                let _g = f.offer_lock.lock().unwrap_or_else(PoisonError::into_inner);
                let pending =
                    f.q.items(&row.link_id.0)?
                        .iter()
                        .filter(|i| !matches!(i.state, State::Accepted { .. }))
                        .count();
                if pending >= MAX_PENDING {
                    return Err(antenna_files::error::Error::new(
                        antenna_files::error::code::QUOTA,
                        "too many files of this contact are waiting in quarantine",
                    ));
                }
                let used =
                    f.q.volume_since(&row.link_id.0, now_ms().saturating_sub(DAY_MS));
                f.q.offer(
                    &row.link_id.0,
                    &folder,
                    &row.peer_root_ed25519,
                    &row.root_ed25519_pk,
                    row.trust,
                    &offer,
                    used,
                    None,
                    Some(msg.0),
                )
            })
            .await
            .unwrap_or_else(|_| Err(antenna_files::error::Error::internal("offer task")))
        };
        match r {
            Ok(item) => {
                self.emit_file(&link, self.file_info(&item, &row.label));
                self.download_and_check(link, item.id).await;
            }
            Err(e) => {
                // Refused by the manifest (level 1, volume, signature): nothing is downloaded; the contact gets a
                // rejection receipt
                tracing::info!(
                    "link {}: file offer refused: {}",
                    &link.to_hex()[..8],
                    e.code
                );
                self.receipt(
                    &link,
                    "owner",
                    "reject_file",
                    "denied",
                    e.code,
                    Some(&msg),
                    None,
                );
                if e.code != antenna_files::error::code::BAD_STATE {
                    // Why, to a node that takes it (D-130): the limits in one word, so that it does not tell which;
                    // anything else about the offer is a manifest that does not hold
                    let why = if matches!(
                        e.code,
                        antenna_files::error::code::QUOTA
                            | antenna_files::error::code::LEVEL_FORBIDS_FILES
                    ) {
                        antenna_proto::files::fate::LIMIT
                    } else {
                        antenna_proto::files::fate::DAMAGED
                    };
                    self.dag_receipt_fate(&link, "reject_file", "denied", &[msg], why, &[]);
                }
                let name = antenna_proto::from_cbor::<antenna_proto::files::Manifest>(
                    &offer.manifest.body,
                )
                .ok();
                self.emit_file(
                    &link,
                    FileInfo {
                        id: name.as_ref().map(|m| hex(&m.file_id)).unwrap_or_default(),
                        contact: row.label.clone(),
                        link_id: link.to_hex(),
                        direction: "in".into(),
                        name: name
                            .as_ref()
                            .map(|m| antenna_files::text::escape_visible(&m.name, 300))
                            .unwrap_or_default(),
                        size: name.as_ref().map_or(0, |m| m.size),
                        sender_mime: String::new(),
                        sender_verdict: String::new(),
                        state: "refused".into(),
                        verdict: None,
                        mime: None,
                        findings: vec![],
                        sandbox: None,
                        dest: None,
                        saved_as: None,
                        saved_path: None,
                        blake3: String::new(),
                        sha256: None,
                        message_id: Some(msg.to_hex()),
                        created_ms: now_ms(),
                        expires_ms: None,
                        reason: Some(e.code.into()),
                        withdrawal: None,
                        duplicate: false,
                        held: None,
                        class: None,
                        labels: vec![],
                    },
                );
            }
        }
    }

    /// Download (with retries) and check in the sandbox. One download and check at a time per link; the shared
    /// download slot is held only for the duration of an attempt (not during pauses); a download without progress for
    /// [`STALL_SECS`] is a stall.
    async fn download_and_check(self: &Arc<Self>, link: LinkId, id: String) {
        let Ok(f) = self.files().cloned() else { return };
        let slot = f.link_slot(&link);
        let Ok(_link_permit) = slot.acquire().await else {
            return;
        };
        let Ok(row) = self.row_of(&link) else { return };
        let Ok(peer) = iroh::PublicKey::from_bytes(&row.peer_endpoint) else {
            return;
        };
        let store = match f.store(&link, peer).await {
            Ok(s) => s,
            Err(e) => return tracing::warn!("files: store: {e}"),
        };
        let Ok(item) = f.q.get(&link.0, &id) else {
            return;
        };
        if item.state == State::Offered {
            let hash = iroh_blobs::Hash::from_bytes(item.manifest.blob);
            let mut delay = Duration::from_secs(1);
            let mut done = false;
            for _ in 0..DOWNLOAD_TRIES {
                if self.is_closed() {
                    return;
                }
                let r = {
                    let Ok(_permit) = f.downloads.acquire().await else {
                        return;
                    };
                    let conn = match self.rt(&link) {
                        Ok(rt) => rt.shared.blob_conn().await,
                        Err(e) => Err(e),
                    };
                    match conn {
                        Ok(conn) => {
                            let dl = f.q.download(&link.0, &id, &store.blobs, conn.clone());
                            // Watchdog: no new bytes for STALL_SECS means a stall (the download resumes on the next
                            // attempt)
                            let watchdog = async {
                                let mut last = store.blobs.local(hash).await.map_or(0, |l| l.0);
                                let mut idle = 0;
                                loop {
                                    tokio::time::sleep(Duration::from_secs(5)).await;
                                    let now = store.blobs.local(hash).await.map_or(0, |l| l.0);
                                    if now != last {
                                        last = now;
                                        idle = 0;
                                    } else {
                                        idle += 5;
                                        if idle >= STALL_SECS {
                                            break;
                                        }
                                    }
                                }
                            };
                            let r = tokio::select! {
                                r = dl => r.map_err(Error::from),
                                _ = watchdog => Err(Error::network("file download stalled: no data from the contact")),
                            };
                            conn.close(0u32.into(), b"");
                            r
                        }
                        Err(e) => Err(e),
                    }
                };
                match r {
                    Ok(_) => {
                        done = true;
                        break;
                    }
                    Err(e) if e.code == antenna_files::error::code::CORRUPT => {
                        // The sender served the wrong thing: rejected
                        tracing::warn!(
                            "link {}: file blob rejected: {}",
                            &link.to_hex()[..8],
                            e.message
                        );
                        let _ = self
                            .reject_file_why(
                                &item,
                                &row,
                                "owner",
                                "denied",
                                Some(antenna_proto::files::fate::DAMAGED),
                            )
                            .await;
                        return;
                    }
                    // The record was deleted (the owner refused) or is already downloaded: nothing to retry
                    Err(e)
                        if e.code == code::NOT_FOUND
                            || e.code == antenna_files::error::code::BAD_STATE =>
                    {
                        return;
                    }
                    Err(e) => {
                        tracing::debug!("link {}: file download: {e}", &link.to_hex()[..8]);
                        tokio::time::sleep(delay).await;
                        delay = (delay * 2).min(Duration::from_secs(60));
                    }
                }
            }
            if !done {
                // It will finish downloading on the next session start (the record is in the `offered` state)
                return;
            }
            if let Ok(it) = f.q.get(&link.0, &id) {
                self.emit_file(&link, self.file_info(&it, &row.label));
            }
        }
        match f.q.check(&link.0, &id, &store.blobs, &f.checker).await {
            Ok(outcome) => {
                // A picture without a safe preview shows only its type icon in the window: say why here, so that a
                // missing picture is never silent (the codes only, never the file's name or content).
                let r = &outcome.report;
                if r.mime.starts_with("image/") && outcome.preview.is_none() {
                    let codes: Vec<&str> = r.findings.iter().map(|f| f.code.as_str()).collect();
                    tracing::warn!(
                        "link {}: file {}: a picture got no safe preview: verdict {}, findings [{}], sandbox {}",
                        &link.to_hex()[..8],
                        &id[..id.len().min(8)],
                        r.verdict.as_str(),
                        codes.join(","),
                        r.sandbox
                    );
                }
                let Ok(item) = f.q.get(&link.0, &id) else {
                    return;
                };
                self.emit_file(&link, self.file_info(&item, &row.label));
                // From the owner's own computer (level 5) saved at once unless the own-computer rules hold it; the
                // sender is told what became of it (D-99, D-130, `file_fate`)
                self.after_check(&row, &item, &outcome.report).await;
            }
            Err(e) => tracing::warn!("link {}: file check: {e}", &link.to_hex()[..8]),
        }
    }

    /// A contact's receipt about our file (`accept_file` / `reject_file` referring to the offer): stop serving it.
    /// This way a contact can only give up its own download: other links and other files are not affected.
    async fn on_contact_receipt(self: Arc<Self>, link: LinkId, r: antenna_proto::ReceiptBody) {
        if r.action == "withdraw_file" && r.decision == "withdrawn" && !r.refs.is_empty() {
            return self.on_withdrawn(link, r.refs).await;
        }
        let Some((state, keep)) = Self::fate_of_receipt(&r) else {
            return;
        };
        if r.refs.is_empty() {
            return;
        }
        let Ok(f) = self.files().cloned() else { return };
        let Ok(row) = self.row_of(&link) else { return };
        let Ok(peer) = iroh::PublicKey::from_bytes(&row.peer_endpoint) else {
            return;
        };
        let recs: Vec<_> = f
            .out_list(&link)
            .into_iter()
            .filter(|(_, rec)| r.refs.iter().any(|m| m.0 == rec.message_id))
            .collect();
        if recs.is_empty() {
            return;
        }
        let Ok(store) = f.store(&link, peer).await else {
            return;
        };
        for (p, rec) in recs {
            // The agent that sent the file learns its fate: accepted and saved there, held for the contact's owner,
            // rejected, or blocked (CONTROL §14, D-130)
            if let Some(file_id) = p.file_name().and_then(|n| n.to_str()) {
                let msg = MessageId(rec.message_id);
                if let Some(agent) = &rec.agent {
                    let mut info = self.sent_file_info(&row, &msg, file_id);
                    info.sha256 = rec.sha256.map(|h| hex(&h));
                    // The offered name was taken there: the name the contact's node gave it (D-128)
                    if r.action == "accept_file" && r.name_number != 0 {
                        info.saved_as = Some(antenna_files::accept::numbered_name(
                            &info.name,
                            r.name_number,
                        ));
                    }
                    if !r.why.is_empty() {
                        info.held = Some(antenna_proto::control::FileHeld {
                            code: r.why.clone(),
                            message: crate::file_fate::fate_message(&r.why).to_string(),
                            rules: r.rules.clone(),
                        });
                    }
                    self.notice_answered(&link, agent, info, state);
                }
            }
            // Held: the contact may still accept it, so it stays served until the final answer or 14 days
            if !keep {
                f.out_forget(&store, &p, &rec).await;
            }
        }
    }

    /// A contact's request for a file from our `shared/`: from level 3 (SPEC §9 "read-only to shared/"), without
    /// secrets or threats, send it; otherwise a rejection receipt (the owner can send it themselves).
    async fn on_request(self: Arc<Self>, link: LinkId, msg: MessageId, req: FileRequest) {
        let Ok(f) = self.files().cloned() else { return };
        let Ok(row) = self.row_of(&link) else { return };
        let deny = |why: &str| {
            self.receipt(
                &link,
                "owner",
                "request_file",
                "denied",
                why,
                Some(&msg),
                None,
            );
            self.dag_receipt(&link, "owner", "request_file", "denied", &[msg]);
        };
        if row.trust < 3 {
            return deny("trust level below 3: shared/ is not readable");
        }
        // Each request checks and encrypts the whole file: one at a time and at most REQUESTS_PER_HOUR per hour
        {
            let now = now_ms();
            let mut g = f.requests.lock().unwrap_or_else(PoisonError::into_inner);
            let e = g.entry(link).or_default();
            e.0.retain(|t| now.saturating_sub(*t) < 3_600_000);
            if e.1 || e.0.len() >= REQUESTS_PER_HOUR {
                drop(g);
                return deny("too many file requests: one at a time, 20 per hour");
            }
            e.0.push(now);
            e.1 = true;
        }
        struct Busy<'a>(&'a Files, LinkId);
        impl Drop for Busy<'_> {
            fn drop(&mut self) {
                if let Some(e) = self
                    .0
                    .requests
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .get_mut(&self.1)
                {
                    e.1 = false;
                }
            }
        }
        let _busy = Busy(&f, link);
        let parts: Vec<&str> = req.path.split('/').filter(|p| !p.is_empty()).collect();
        if parts.is_empty() || antenna_files::names::archive_path_problem(&req.path).is_some() {
            return deny("bad path");
        }
        let mut rel = vec![self.folder_for(&row), "shared".to_string()];
        rel.extend(parts.iter().map(|p| p.to_string()));
        let rel_refs: Vec<&str> = rel.iter().map(String::as_str).collect();
        let file = match antenna_files::accept::open_file_nofollow(&f.cfg.links_dir, &rel_refs) {
            Ok(file) => file,
            Err(_) => return deny("no such file in shared/"),
        };
        // A hard link in shared/ can lead anywhere (including the daemon's data directory)
        let Ok(meta) = file.metadata() else {
            return deny("no such file in shared/");
        };
        let Some(src_key) = shared_key(&req.path, &meta) else {
            return deny("hard-linked files are not served from shared/");
        };
        // The same file, not yet answered by the contact, is not encrypted again; unanswered serving of requests is
        // capped at the daily volume of the contact's level
        let outs = f.out_list(&link);
        if outs.iter().any(|(_, r)| r.src_key == src_key) {
            return deny("this file was already sent and is not answered yet");
        }
        let open: u64 = outs.iter().map(|(_, r)| r.size).sum();
        let quota =
            antenna_files::policy::level_files(row.trust, None).map_or(0, |r| r.daily_bytes);
        if open.saturating_add(meta.len()) > quota {
            return deny("too much was sent and is not answered yet");
        }
        let name = parts.last().copied().unwrap_or("file").to_string();
        let mut out = match self.prepare_outgoing(&row, file, &name).await {
            Ok(o) => o,
            Err(e) => return deny(e.code),
        };
        out.src_key = src_key;
        let reasons = Self::outgoing_reasons(&out, row.trust);
        if !reasons.is_empty() {
            let _ = out.store.blobs.forget_outgoing(out.prepared.blob).await;
            return deny("the file needs the owner (secrets or a failed check): share it manually");
        }
        let addr = self.request_addr(&link, &msg);
        match self.send_outgoing(&row, out, &addr).await {
            Ok(_) => {
                self.receipt(
                    &link,
                    "owner",
                    "request_file",
                    "allowed",
                    "",
                    Some(&msg),
                    None,
                );
                self.dag_receipt(&link, "owner", "request_file", "allowed", &[msg]);
            }
            Err(e) => deny(e.code),
        }
    }

    /// Maintenance: deleting threats older than 7 days (Q-F-3), batches of check receipts (Q-22).
    pub(crate) async fn files_maintenance(self: Arc<Self>) {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tokio::select! {
                _ = tick.tick() => {}
                _ = self.closed_wait() => break,
            }
            self.flush_check_batches(false);
            let Ok(f) = self.files().cloned() else {
                continue;
            };
            let now = now_ms();
            for link in f.q.links() {
                // A sent file the contact did not answer within OUT_KEEP_MS is no longer served
                let old: Vec<_> = f
                    .out_list(&LinkId(link))
                    .into_iter()
                    .filter(|(_, r)| r.created_ms + OUT_KEEP_MS < now)
                    .collect();
                if !old.is_empty()
                    && let Ok(row) = self.row_of(&LinkId(link))
                    && let Ok(peer) = iroh::PublicKey::from_bytes(&row.peer_endpoint)
                    && let Ok(store) = f.store(&row.link_id, peer).await
                {
                    for (p, r) in old {
                        f.out_forget(&store, &p, &r).await;
                    }
                }
                let Ok(items) = f.q.items(&link) else {
                    continue;
                };
                let allow = self.file_allow(&LinkId(link));
                let trust = self.row_of(&LinkId(link)).map_or(1, |r| r.trust);
                for it in items {
                    // A threat as the rules for its level read it: from level 3 a heuristic is a label, and such a
                    // file waits like any other (D-130)
                    let threat = it.report.as_ref().is_some_and(|r| {
                        antenna_files::kinds::effective_verdict(
                            r,
                            &it.manifest.name,
                            trust.min(it.level_at_offer),
                            &allow,
                        ) == Verdict::Threat
                            && r.verdict == Verdict::Threat
                    });
                    if threat
                        && it.state == State::Checked
                        && it.created_ms + THREAT_KEEP_MS < now
                        && let Ok(row) = self.row_of(&LinkId(link))
                        && let Ok(peer) = iroh::PublicKey::from_bytes(&row.peer_endpoint)
                        && let Ok(store) = f.store(&row.link_id, peer).await
                    {
                        let _ = f.q.reject(&link, &it.id, &store.blobs).await;
                        self.receipt(
                            &row.link_id,
                            "owner",
                            "reject_file",
                            "expired",
                            "threat kept 7 days",
                            None,
                            None,
                        );
                    }
                }
            }
        }
    }
}

/// Approval for a request for a file from the contact's `shared/`: the path goes to the contact as message text.
pub(crate) fn request_approval(
    requester_id: &str,
    requester: &str,
    target: &LinkRow,
    attributed: &LinkRow,
    reasons: Vec<String>,
    path: &str,
) -> crate::policy::NewApproval {
    crate::policy::NewApproval {
        requester_id: requester_id.into(),
        requester: requester.into(),
        contact: attributed.link_id,
        contact_label: attributed.label.clone(),
        contact_trust: attributed.trust,
        action: "request_file".into(),
        target: Some(target.label.clone()),
        target_link: Some(target.link_id),
        reasons,
        grants: antenna_proto::control::Grants {
            read: "none".into(),
            write: format!("a file from {}'s shared/ into quarantine", target.label),
            commands: "none".into(),
            send: format!(
                "a file request to {} (trust {}) with this path as text",
                target.label, target.trust
            ),
        },
        quote: path.chars().take(2000).collect(),
        request_hash: crate::policy::request_hash(
            requester_id,
            "request_file",
            Some(&target.link_id),
            path.as_bytes(),
        ),
        // An agent's request goes out by the daemon after approval (D-100)
        completes: requester_id != "owner",
    }
}

/// Approval request for sending a file (secrets, a file outside the link folder, flow between links, no-write-down).
/// It is bound to (source, name, BLAKE3 of the content): for content sent by value the source is the fixed text
/// "content from the agent (N bytes)", so a retry with the same bytes matches and other bytes do not.
#[allow(
    clippy::too_many_arguments,
    reason = "the approval binds exactly these values: requester, links, reasons, source, name, size and BLAKE3"
)]
pub(crate) fn share_approval(
    requester_id: &str,
    requester: &str,
    target: &LinkRow,
    attributed: &LinkRow,
    reasons: Vec<String>,
    source: ShareSource<'_>,
    name: &str,
    size: u64,
    blake3: &[u8; 32],
) -> crate::policy::NewApproval {
    let (path, read) = match source {
        ShareSource::Path(p) => (p.to_string(), format!("local file {p}")),
        ShareSource::Content => (
            format!("content from the agent ({size} bytes)"),
            "none: content the agent produced itself, no local file".to_string(),
        ),
    };
    let detail = format!("{}\u{0}{}\u{0}{}", path, name, hex(blake3));
    crate::policy::NewApproval {
        requester_id: requester_id.into(),
        requester: requester.into(),
        contact: attributed.link_id,
        contact_label: attributed.label.clone(),
        contact_trust: attributed.trust,
        action: "share_file".into(),
        target: Some(target.label.clone()),
        target_link: Some(target.link_id),
        reasons,
        grants: antenna_proto::control::Grants {
            read,
            write: "none".into(),
            commands: "none".into(),
            send: format!(
                "file {name} ({size} bytes) to {} (trust {})",
                target.label, target.trust
            ),
        },
        quote: format!("{path} → {name}"),
        request_hash: crate::policy::request_hash(
            requester_id,
            "share_file",
            Some(&target.link_id),
            detail.as_bytes(),
        ),
        // An agent's file goes out by the daemon after approval (D-100)
        completes: requester_id != "owner",
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use antenna_files::{blobs::LinkBlobs, crypt::FileSecret};
    use iroh::{Endpoint, EndpointAddr, RelayMode, endpoint::presets, protocol::Router};

    use super::*;

    async fn ep() -> Endpoint {
        Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind_addr("127.0.0.1:0")
            .unwrap()
            .bind()
            .await
            .unwrap()
    }

    fn addr(ep: &Endpoint) -> EndpointAddr {
        EndpointAddr::new(ep.id()).with_ip_addr(ep.bound_sockets()[0])
    }

    /// A links folder that does not exist yet, under a parent reached through a symlink (macOS: temporary directories
    /// are `/var/folders/…`, really `/private/var/folders/…`): paths inside it, given either way, are in the links
    /// folder. Before the fix only the given form of the folder was kept, so every path resolved to the real one fell
    /// outside it.
    /// Link folders are one shell word (D-125): a label with spaces or quotes gets `-` instead; a folder made before
    /// under the label as it is keeps working; labels that become the same word get the link ID's start.
    #[test]
    fn link_folders_are_shell_words_and_old_folders_stay() {
        assert_eq!(shell_word("atlas server"), "atlas-server");
        assert_eq!(shell_word("Bob's Mac (work)"), "Bob-s-Mac-work");
        assert_eq!(shell_word("  José  "), "José");
        assert_eq!(shell_word("a & b; $(rm)"), "a-b-rm");
        assert_eq!(shell_word("-.x.-"), "x");
        assert_eq!(shell_word("'\"'"), "");
        let t = tempfile::tempdir().unwrap();
        let hex = |n: u8| format!("{n:02x}").repeat(32);
        let items = vec![
            ("atlas server".to_string(), hex(1)),
            ("atlas-server".to_string(), hex(2)),
            ("!!!".to_string(), hex(3)),
            ("alice".to_string(), hex(4)),
        ];
        assert_eq!(
            folder_names(&items, Some(t.path())),
            [
                "atlas-server",
                &format!("atlas-server-{}", &hex(2)[..8]),
                &hex(3)[..16],
                "alice"
            ]
        );
        // The folder of an older link made under the label as it is: kept, nothing moved
        std::fs::create_dir(t.path().join("atlas server")).unwrap();
        assert_eq!(
            folder_names(&items, Some(t.path())),
            ["atlas server", "atlas-server", &hex(3)[..16], "alice"]
        );
        assert_eq!(folder_names(&items[..1], None), ["atlas-server"]);
    }

    // A unix symlink (a junction on Windows comes with WP-21).
    #[cfg(unix)]
    #[test]
    fn links_folder_behind_a_symlink_is_recognized_before_it_exists() {
        let t = tempfile::tempdir().unwrap();
        let real = t.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let via = t.path().join("via");
        std::os::unix::fs::symlink(&real, &via).unwrap();
        let cfg = FilesConfig::new(via.join("node/links"));
        let (files, _rx) = Files::new(t.path(), cfg, zeroize::Zeroizing::new([7u8; 32])).unwrap();
        let links = &files.cfg.links_dir;
        for given in [&via, &real] {
            let p = given.join("node/links/bob/shared/notes.txt");
            assert_eq!(
                folder_in_links(links, p.to_str().unwrap()).as_deref(),
                Some("bob"),
                "{p:?} in {links:?}"
            );
        }
        assert_eq!(
            folder_in_links(links, real.join("node/other/x").to_str().unwrap()),
            None
        );
    }

    /// D-F-17, SPEC §10 "another link's blob by hash": the iroh-blobs handler on a link endpoint serves only that
    /// link's store and only to its contact, the way the daemon wires it (`Files::store` + `BlobsHandler` in the link's
    /// Router).
    #[tokio::test]
    async fn link_blobs_handler_serves_only_its_link_store_and_only_its_contact() {
        let t = tempfile::tempdir().unwrap();
        let cfg = FilesConfig::new(t.path().join("links"));
        let (files, _rx) = Files::new(t.path(), cfg, zeroize::Zeroizing::new([7u8; 32])).unwrap();
        let (b, c) = (ep().await, ep().await); // Contacts B and C
        let (s1, s2) = (ep().await, ep().await); // The node's link endpoints with B and with C
        let (l1, l2) = (LinkId([1; 32]), LinkId([2; 32]));
        let handler = |link, peer| BlobsHandler {
            files: files.clone(),
            link,
            peer,
        };
        let r1 = Router::builder(s1.clone())
            .accept(iroh_blobs::ALPN, handler(l1, b.id()))
            .spawn();
        let r2 = Router::builder(s2.clone())
            .accept(iroh_blobs::ALPN, handler(l2, c.id()))
            .spawn();
        // X is sent to B (link 1), Y to C (link 2)
        let st1 = files.store(&l1, b.id()).await.unwrap();
        let st2 = files.store(&l2, c.id()).await.unwrap();
        let x = st1
            .blobs
            .add_outgoing(
                std::io::Cursor::new(vec![1u8; 300_000]),
                &FileSecret::random(),
            )
            .await
            .unwrap();
        st1.blobs.offer_existing(x.blob).await.unwrap();
        let y = st2
            .blobs
            .add_outgoing(std::io::Cursor::new(vec![2u8; 1000]), &FileSecret::random())
            .await
            .unwrap();
        st2.blobs.offer_existing(y.blob).await.unwrap();

        let c_store = LinkBlobs::open(t.path().join("c"), s2.id()).await.unwrap();
        // 1) C knows the hash of X and asks for it over its own link: not a single byte
        assert!(fetch(&c_store, &s2, &c, x.blob, x.blob_size).await.is_err());
        assert_eq!(c_store.local(x.blob).await.unwrap().0, 0);
        // 2) C goes to the endpoint of the link with B: the connection is closed (wrong contact)
        assert!(fetch(&c_store, &s1, &c, x.blob, x.blob_size).await.is_err());
        assert_eq!(c_store.local(x.blob).await.unwrap().0, 0);
        // 3) C gets its own; 4) B gets X over its own link
        fetch(&c_store, &s2, &c, y.blob, y.blob_size).await.unwrap();
        let b_store = LinkBlobs::open(t.path().join("b"), s1.id()).await.unwrap();
        fetch(&b_store, &s1, &b, x.blob, x.blob_size).await.unwrap();
        assert!(b_store.local(x.blob).await.unwrap().1);
        r1.shutdown().await.unwrap();
        r2.shutdown().await.unwrap();
        files.shutdown().await;
    }

    async fn fetch(
        store: &LinkBlobs,
        from: &Endpoint,
        me: &Endpoint,
        h: iroh_blobs::Hash,
        n: u64,
    ) -> std::io::Result<antenna_files::blobs::Fetched> {
        let conn = me
            .connect(addr(from), iroh_blobs::ALPN)
            .await
            .map_err(|e| anyhow_like(&e.to_string()))?;
        tokio::time::timeout(
            Duration::from_secs(10),
            store.fetch(conn, h, n, "t", |_| {}),
        )
        .await
        .map_err(|_| anyhow_like("timeout"))?
        .map_err(|e| anyhow_like(&e.to_string()))
    }

    fn anyhow_like(s: &str) -> std::io::Error {
        std::io::Error::other(s.to_string())
    }
}
