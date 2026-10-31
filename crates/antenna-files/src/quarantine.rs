// SPDX-License-Identifier: AGPL-3.0-only
//! Quarantine (SPEC §10 step 2, §13): an incoming file lives here from the manifest until explicit acceptance or
//! rejection.
//!
//! "Encrypted quarantine storage to which neither the agent nor the OS has a path":
//! - the content is only the `xfile/0` ciphertext in the link's iroh-blobs store (`<root>/<link>/blobs`); there is no
//!   plaintext on disk at any point before acceptance; plaintext exists only in memory, on the path
//!   "store → decryption → sandbox worker" or, at acceptance, "store → decryption → unnamed file in the destination
//!   directory";
//! - the file record (manifest, file key, check report) and the preview are encrypted with the same STREAM, under a key
//!   derived from the quarantine key (in stage B, from the keystore root key): `<root>/<link>/items/<id>.x` and
//!   `<id>.p.x`;
//! - the quarantine root is a daemon directory (0700), not `~/Antenna/links/…`; the `.metadata_never_index` file turns
//!   Spotlight off;
//! - rejection wipes the record with the file key (crypto-shredding), leaves a `<id>.rejected` mark (a repeat of the
//!   same offer is not accepted) and deletes the blob through store garbage collection.
//!
//! The destination is decided by the quarantine, not by the caller: by the lower of the level at offer time and the
//! current level (SPEC §9: a downgrade applies immediately, an upgrade does not widen what was already sent) and by the
//! link folder recorded at offer time. Operations on one file do not run in parallel.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zeroize::Zeroizing;

use crate::accept::{Incoming, open_dir_nofollow};
use crate::blobs::LinkBlobs;
use crate::codec::{from_cbor, to_cbor};
use crate::crypt::{FileSecret, Plain, StreamDecryptor, decrypt_to_vec, encrypt_to_vec};
use crate::error::{Error, Result, code};
use crate::manifest::{FileOffer, Manifest, SignedManifest, SignedManifestExt};
use crate::names::{is_special, normalize};
use crate::policy::{Acceptor, Destination, admit, level_files, may_accept};
use crate::report::{CheckReport, Preview, Verdict};
use crate::sandbox::{CheckOutcome, Checker};
use crate::text::escape_visible;

/// State of a file in quarantine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum State {
    /// The manifest was accepted (signature and level limits checked); the file is not here yet.
    Offered,
    /// The ciphertext was downloaded and matched the manifest by BLAKE3 (bao).
    Downloaded,
    /// Checked in the sandbox.
    Checked,
    /// Accepted: the name in the destination directory.
    Accepted {
        /// File name.
        name: String,
        /// Where.
        dest: Destination,
    },
}

/// A quarantine record as the daemon sees it. It has no file secret: the secret is stored only in the encrypted record
/// on disk ([`Record`]) and read inside the quarantine, so an `Item` can be serialized and shown without risk.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Item {
    /// ID (hex `file_id`).
    pub id: String,
    /// Link.
    #[serde(with = "serde_bytes")]
    pub link: [u8; 32],
    /// The link folder in `~/Antenna/links/` (set by the daemon at offer time).
    pub folder: String,
    /// Signed manifest (evidence for the history).
    pub signed: SignedManifest,
    /// Parsed manifest.
    pub manifest: Manifest,
    /// The contact's level at offer time.
    pub level_at_offer: u8,
    /// State.
    pub state: State,
    /// Check report.
    pub report: Option<CheckReport>,
    /// Created, ms.
    pub created_ms: u64,
    /// ID of the offer message in the link history (for acceptance and rejection receipts).
    #[serde(default, with = "serde_bytes")]
    pub message_id: Option<[u8; 32]>,
    /// SHA-256 of the plaintext, computed here when it was decrypted for the check (records from before have none
    /// until the file is accepted).
    #[serde(default, with = "serde_bytes")]
    pub sha256: Option<[u8; 32]>,
    /// Why the daemon's own accept at level 5 (D-99) left this file for the owner (D-128); cleared by an accept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held: Option<Held>,
    /// The folder an accepted file went to when it is not the link folder (a save folder or the project folder at
    /// level 5, D-130): where it is, whatever the settings say later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_dir: Option<PathBuf>,
}

/// On-disk record (encrypted): `Item` + file secret. Never leaves this module.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    item: Item,
    #[serde(with = "serde_bytes")]
    secret: [u8; 32],
}

impl std::fmt::Debug for Item {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Item")
            .field("id", &self.id)
            .field("size", &self.manifest.size)
            .field("state", &self.state)
            .field("verdict", &self.report.as_ref().map(|r| r.verdict))
            .finish_non_exhaustive()
    }
}

/// Summary for `antenna files pending`: the name is escaped (control and invisible characters as `\u{..}`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Summary {
    /// ID.
    pub id: String,
    /// Link (hex).
    pub link: String,
    /// Name from the manifest, escaped for display.
    pub name: String,
    /// MIME by content at the sender.
    pub sender_mime: String,
    /// Size.
    pub size: u64,
    /// State.
    pub state: State,
    /// Verdict.
    pub verdict: Option<Verdict>,
    /// Type by signature on our side.
    pub mime: Option<String>,
}

/// Accepted file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Accepted {
    /// Name in the destination directory.
    pub name: String,
    /// Where.
    pub dest: Destination,
    /// BLAKE3 of the plaintext (for the link history).
    pub blake3: [u8; 32],
    /// SHA-256 of the plaintext (shown next to BLAKE3), when known.
    pub sha256: Option<[u8; 32]>,
    /// Size.
    pub size: u64,
    /// The same file (name, size, BLAKE3) was already in the folder: nothing new was written (preview.8).
    pub duplicate: bool,
    /// The contact's name was taken by another file, so the daemon gave this one the numbered name `<stem> (n).<ext>`
    /// with this `n` (D-128), or found the same file under one; 0 otherwise.
    pub name_number: u32,
}

/// Why the daemon's own accept left a file waiting for the owner (D-128): the error code and its message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Held {
    /// Error code (`file_name_taken`, `forbidden`, `internal`, …), or a reason of the own-computer rules (D-130:
    /// `threat`, `executable`, `installer`, `uninspected`, `check_failed`).
    pub code: String,
    /// What happened, without the file's name or content.
    pub message: String,
    /// The check's rules that matched, for a reason of the own-computer rules (D-130).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rules: Vec<String>,
}

/// Whether a received file can be accepted under a name (`file_name_check`, preview.8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NameState {
    /// No file has this name.
    Free,
    /// Another file has it; a free name in the same folder.
    Taken(String),
    /// A file with this name and the same content is there already: accepting saves nothing new.
    Same,
    /// The name breaks the naming rules (why).
    Invalid(String),
}

/// The first [`Capture::HEAD`] and the last [`Capture::TAIL`] bytes written through it (D-130): the daemon's own look
/// at the magic numbers of what it hands to the check worker.
struct Capture<W> {
    inner: W,
    head: Vec<u8>,
    tail: Vec<u8>,
}

impl<W> Capture<W> {
    const HEAD: usize = 8192;
    const TAIL: usize = crate::detect::UDIF_TRAILER;

    fn new(inner: W) -> Self {
        Self {
            inner,
            head: Vec::with_capacity(Self::HEAD),
            tail: Vec::with_capacity(2 * Self::TAIL),
        }
    }

    fn record(&mut self, b: &[u8]) {
        let take = (Self::HEAD - self.head.len()).min(b.len());
        self.head.extend_from_slice(&b[..take]);
        self.tail
            .extend_from_slice(&b[b.len().saturating_sub(Self::TAIL)..]);
        if self.tail.len() > Self::TAIL {
            self.tail.drain(..self.tail.len() - Self::TAIL);
        }
    }
}

impl<W: tokio::io::AsyncWrite + Unpin> tokio::io::AsyncWrite for Capture<W> {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        let r = std::pin::Pin::new(&mut self.inner).poll_write(cx, buf);
        if let std::task::Poll::Ready(Ok(n)) = &r {
            let n = *n;
            self.record(&buf[..n]);
        }
        r
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// Daemon quarantine.
pub struct Quarantine {
    root: PathBuf,
    links_base: PathBuf,
    master: Zeroizing<[u8; 32]>,
    busy: Mutex<HashSet<String>>,
}

/// Marks a file busy for the duration of an operation.
struct Busy<'a> {
    q: &'a Quarantine,
    key: String,
}

impl Drop for Busy<'_> {
    fn drop(&mut self) {
        if let Ok(mut b) = self.q.busy.lock() {
            b.remove(&self.key);
        }
    }
}

fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

fn mkdir700(p: &Path) -> Result<()> {
    std::fs::create_dir_all(p)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Quarantine record limit (the preview is in a separate file).
const MAX_RECORD: usize = 1 << 20;
/// Preview file limit.
const MAX_PREVIEW: usize = 128 << 20;

impl Quarantine {
    /// Opens the quarantine in `root` with key `master` (32 bytes; stage B: HKDF from the keystore root key);
    /// `links_base` is `~/Antenna/links` (link folders with `inbox/` and `shared/`).
    pub fn open(
        root: impl Into<PathBuf>,
        master: [u8; 32],
        links_base: impl Into<PathBuf>,
    ) -> Result<Self> {
        let root = root.into();
        mkdir700(&root)?;
        let never = root.join(".metadata_never_index");
        if !never.exists() {
            std::fs::write(&never, b"")?;
        }
        Ok(Self {
            root,
            links_base: links_base.into(),
            master: Zeroizing::new(master),
            busy: Mutex::new(HashSet::new()),
        })
    }

    fn lock(&self, link: &[u8; 32], id: &str) -> Result<Busy<'_>> {
        let key = format!("{}/{id}", hex(link));
        let mut b = self.busy.lock().map_err(|_| Error::internal("lock"))?;
        if !b.insert(key.clone()) {
            return Err(Error::new(
                code::BAD_STATE,
                "another operation on this file is in progress",
            ));
        }
        Ok(Busy { q: self, key })
    }

    /// Link directory.
    pub fn link_dir(&self, link: &[u8; 32]) -> PathBuf {
        self.root.join(hex(link))
    }

    /// Directory of the link's blob store (for [`LinkBlobs::open`]).
    pub fn blobs_dir(&self, link: &[u8; 32]) -> PathBuf {
        self.link_dir(link).join("blobs")
    }

    fn check_id(id: &str) -> Result<()> {
        if id.len() != 32
            || !id
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(Error::new(code::NOT_FOUND, "bad file id"));
        }
        Ok(())
    }

    fn item_path(&self, link: &[u8; 32], id: &str, suffix: &str) -> Result<PathBuf> {
        Self::check_id(id)?;
        Ok(self
            .link_dir(link)
            .join("items")
            .join(format!("{id}{suffix}")))
    }

    fn record_secret(&self, link: &[u8; 32], id: &str, what: &[u8]) -> FileSecret {
        let hk = Hkdf::<Sha256>::new(Some(b"x/quarantine/v0/record"), self.master.as_ref());
        let mut k = Zeroizing::new([0u8; 32]);
        hk.expand_multi_info(&[link, id.as_bytes(), what], k.as_mut())
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        FileSecret::from_bytes(*k)
    }

    fn write_encrypted(&self, path: &Path, secret: &FileSecret, plain: &[u8]) -> Result<()> {
        mkdir700(path.parent().expect("items dir"))?;
        let (ct, _) = encrypt_to_vec(secret, plain)?;
        let tmp = path.with_extension(format!("tmp{}", hex(&crate::crypt::random_bytes::<4>())));
        {
            use std::io::Write;
            let mut o = std::fs::OpenOptions::new();
            o.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                o.mode(0o600);
            }
            let mut f = o.open(&tmp)?;
            f.write_all(&ct)?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    fn read_encrypted(
        &self,
        path: &Path,
        secret: &FileSecret,
    ) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let ct = match std::fs::read(path) {
            Ok(c) => c,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let (plain, _) = decrypt_to_vec(secret, &ct)?;
        Ok(Some(Zeroizing::new(plain)))
    }

    /// Saves a record (encrypted, atomically).
    fn save(&self, item: &Item, secret: &[u8; 32]) -> Result<()> {
        let path = self.item_path(&item.link, &item.id, ".x")?;
        let rec = Record {
            item: item.clone(),
            secret: *secret,
        };
        let plain = Zeroizing::new(to_cbor(&rec)?);
        self.write_encrypted(
            &path,
            &self.record_secret(&item.link, &item.id, b"record"),
            &plain,
        )
    }

    fn save_preview(&self, link: &[u8; 32], id: &str, p: Option<&Preview>) -> Result<()> {
        let path = self.item_path(link, id, ".p.x")?;
        match p {
            Some(p) => self.write_encrypted(
                &path,
                &self.record_secret(link, id, b"preview"),
                &to_cbor(p)?,
            ),
            None => match std::fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.into()),
            },
        }
    }

    fn load(&self, link: &[u8; 32], id: &str) -> Result<(Item, FileSecret)> {
        let path = self.item_path(link, id, ".x")?;
        let Some(plain) = self.read_encrypted(&path, &self.record_secret(link, id, b"record"))?
        else {
            return Err(Error::new(code::NOT_FOUND, "no such file in quarantine"));
        };
        let rec: Record = from_cbor(&plain, MAX_RECORD, "quarantine record")
            .map_err(|e| Error::corrupt(format!("record: {}", e.message)))?;
        let Record { item, mut secret } = rec;
        let file_secret = FileSecret::from_bytes(secret);
        zeroize::Zeroize::zeroize(&mut secret);
        if item.id != id || &item.link != link {
            return Err(Error::corrupt("record moved"));
        }
        let secret = file_secret;
        Ok((item, secret))
    }

    /// Reads a record (without the file secret).
    pub fn get(&self, link: &[u8; 32], id: &str) -> Result<Item> {
        Ok(self.load(link, id)?.0)
    }

    /// Files in the link's quarantine (`antenna files pending`): everything not yet accepted.
    pub fn pending(&self, link: &[u8; 32]) -> Result<Vec<Summary>> {
        let dir = self.link_dir(link).join("items");
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Ok(out);
        };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let Some(id) = n.strip_suffix(".x") else {
                continue;
            };
            if id.ends_with(".p") {
                continue;
            }
            let Ok(item) = self.get(link, id) else {
                continue;
            };
            if matches!(item.state, State::Accepted { .. }) {
                continue;
            }
            out.push(Summary {
                id: item.id.clone(),
                link: hex(link),
                name: escape_visible(&item.manifest.name, 300),
                sender_mime: item.manifest.mime.clone(),
                size: item.manifest.size,
                state: item.state.clone(),
                verdict: item.report.as_ref().map(|r| r.verdict),
                mime: item.report.as_ref().map(|r| r.mime.clone()),
            });
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(out)
    }

    /// Step 1 (SPEC §10 step 1): accepts an offer from the manifest: the author's signature with the link context,
    /// level limits. The file is not here yet. `used_today` is how many bytes were already accepted from the contact
    /// today (tracked by the daemon); `folder` is the link folder in `~/Antenna/links/`.
    #[allow(
        clippy::too_many_arguments,
        reason = "SPEC §10 step 1 checks each of these values against the manifest and the level"
    )]
    pub fn offer(
        &self,
        link: &[u8; 32],
        folder: &str,
        author: &[u8; 32],
        recipient: &[u8; 32],
        level: u8,
        offer: &FileOffer,
        used_today: u64,
        level5_daily: Option<u64>,
        message_id: Option<[u8; 32]>,
    ) -> Result<Item> {
        let folder = normalize(folder)?;
        let manifest = offer.manifest.open(author, link, recipient)?;
        admit(level, manifest.size, used_today, level5_daily)?;
        let id = hex(&manifest.file_id);
        let _busy = self.lock(link, &id)?;
        if self.item_path(link, &id, ".x")?.exists()
            || self.item_path(link, &id, ".rejected")?.exists()
        {
            return Err(Error::new(code::BAD_STATE, "this file was already offered"));
        }
        let item = Item {
            id,
            link: *link,
            folder,
            signed: offer.manifest.clone(),
            manifest,
            level_at_offer: level,
            state: State::Offered,
            report: None,
            created_ms: crate::now_ms(),
            message_id,
            sha256: None,
            held: None,
            saved_dir: None,
        };
        self.save(&item, &offer.secret)?;
        Ok(item)
    }

    /// Step 2 (SPEC §10 step 2): downloads the ciphertext into the link's store (with resumption); iroh-blobs verifies
    /// BLAKE3/bao, the size is at most what the manifest declares.
    pub async fn download(
        &self,
        link: &[u8; 32],
        id: &str,
        blobs: &LinkBlobs,
        conn: iroh::endpoint::Connection,
    ) -> Result<crate::blobs::Fetched> {
        let _busy = self.lock(link, id)?;
        let (mut item, secret) = self.load(link, id)?;
        if item.state != State::Offered && item.state != State::Downloaded {
            return Err(Error::new(code::BAD_STATE, "already downloaded"));
        }
        let hash = iroh_blobs::Hash::from_bytes(item.manifest.blob);
        let f = blobs
            .fetch(conn, hash, item.manifest.blob_size, &item.id, |_| {})
            .await?;
        item.state = State::Downloaded;
        self.save(&item, secret.expose())?;
        Ok(f)
    }

    /// Decrypts the blob as a stream into `w`, verifying STREAM, the length and the plaintext BLAKE3 against the
    /// manifest; also returns the plaintext's SHA-256.
    pub async fn decrypt_into(
        blobs: &LinkBlobs,
        manifest: &Manifest,
        secret: &FileSecret,
        w: &mut (impl tokio::io::AsyncWrite + Unpin),
    ) -> Result<(Plain, [u8; 32])> {
        use sha2::Digest as _;
        let hash = iroh_blobs::Hash::from_bytes(manifest.blob);
        let mut r = blobs.reader(hash);
        let mut d = StreamDecryptor::new(secret);
        let mut sha = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        let mut out = Vec::with_capacity(2 << 20);
        loop {
            let n = r
                .read(&mut buf)
                .await
                .map_err(|e| Error::internal(format!("blob read: {e}")))?;
            if n == 0 {
                break;
            }
            out.clear();
            d.update(&buf[..n], &mut out)?;
            sha.update(&out);
            w.write_all(&out)
                .await
                .map_err(|e| Error::internal(format!("write: {e}")))?;
        }
        out.clear();
        let p = d.finish(&mut out)?;
        sha.update(&out);
        w.write_all(&out)
            .await
            .map_err(|e| Error::internal(format!("write: {e}")))?;
        if p.len != manifest.size || p.blake3 != manifest.blake3 {
            return Err(Error::new(
                code::HASH_MISMATCH,
                "plaintext length or BLAKE3 differs from the manifest",
            ));
        }
        Ok((p, sha.finalize().into()))
    }

    /// Steps 3–4 (SPEC §10 steps 3–4): sandboxed check and preview. The plaintext goes from the store to the worker
    /// through memory.
    pub async fn check(
        &self,
        link: &[u8; 32],
        id: &str,
        blobs: &LinkBlobs,
        checker: &Checker,
    ) -> Result<CheckOutcome> {
        let _busy = self.lock(link, id)?;
        let (mut item, secret) = self.load(link, id)?;
        if item.state != State::Downloaded && item.state != State::Checked {
            return Err(Error::new(
                code::BAD_STATE,
                "the file is not downloaded yet",
            ));
        }
        let (tx, rx) = tokio::io::duplex(4 << 20);
        let manifest = item.manifest.clone();
        // The first and last bytes the worker gets, for the daemon's own look at the magic numbers (D-130)
        let mut tx = Capture::new(tx);
        let feed = async {
            let r = Self::decrypt_into(blobs, &manifest, &secret, &mut tx).await;
            let Capture { head, tail, .. } = tx;
            (r, head, tail)
        };
        let ((fed, head, tail), mut outcome) = tokio::join!(
            feed,
            checker.check(rx, item.manifest.size, &item.manifest.name, true)
        );
        if fed.is_ok() {
            crate::kinds::guard_class(&mut outcome.report, &head, &tail, &item.manifest.name);
        }
        match fed {
            Ok((_, sha256)) => item.sha256 = Some(sha256),
            // Ciphertext or hash mismatch: the worker's result does not count, the file is damaged.
            Err(e) if e.code == code::CORRUPT || e.code == code::HASH_MISMATCH => {
                outcome = CheckOutcome {
                    report: CheckReport::failed("corrupt", format!("{}: {}", e.code, e.message)),
                    preview: None,
                };
            }
            // The check stopped reading (isolation failure, timeout): its own report is the reason.
            Err(e) if outcome.report.verdict != Verdict::Failed => {
                outcome = CheckOutcome {
                    report: CheckReport::failed(
                        "check_input",
                        format!("{}: {}", e.code, e.message),
                    ),
                    preview: None,
                };
            }
            _ => {}
        }
        item.report = Some(outcome.report.clone());
        item.state = State::Checked;
        self.save_preview(link, id, outcome.preview.as_ref())?;
        self.save(&item, secret.expose())?;
        Ok(outcome)
    }

    /// `antenna files preview <id>`: the report and the safe preview (after the check, and kept once the file is
    /// accepted). The original never leaves the quarantine. A file accepted by preview.8 or earlier has no preview left
    /// (`None`).
    pub fn preview(&self, link: &[u8; 32], id: &str) -> Result<(CheckReport, Option<Preview>)> {
        let item = self.get(link, id)?;
        let (State::Checked | State::Accepted { .. }, Some(r)) = (&item.state, item.report) else {
            return Err(Error::new(code::BAD_STATE, "the file is not checked yet"));
        };
        let path = self.item_path(link, id, ".p.x")?;
        let p = match self.read_encrypted(&path, &self.record_secret(link, id, b"preview"))? {
            Some(b) => {
                Some(from_cbor(&b, MAX_PREVIEW, "preview").map_err(|e| Error::corrupt(e.message))?)
            }
            None => None,
        };
        Ok((r, p))
    }

    /// Steps 5–6 (SPEC §10 steps 5–6): explicit acceptance. The lower of the level at offer time and the current
    /// level `level_now` applies; it decides who may accept and where to: `inbox/` or `shared/` of the link folder
    /// (recorded at offer time), at level 5 `project` (the project folder from the owner's configuration; without one,
    /// the link's `shared/`). The name is
    /// normalized (or `rename` is used), special names only with `special_approved`. Returns the name and BLAKE3 for
    /// the link history; the daemon sets the taint.
    #[allow(
        clippy::too_many_arguments,
        reason = "the acceptance policy inputs: level, acceptor, special name, project folder, rename"
    )]
    pub async fn accept(
        &self,
        link: &[u8; 32],
        id: &str,
        blobs: &LinkBlobs,
        level_now: u8,
        acceptor: &Acceptor<'_>,
        special_approved: bool,
        project: Option<&Path>,
        rename: Option<&str>,
        allow: &crate::kinds::Allow,
    ) -> Result<Accepted> {
        let _busy = self.lock(link, id)?;
        let (mut item, secret) = self.load(link, id)?;
        let level = level_now.min(item.level_at_offer);
        let verdict = match (&item.state, &item.report) {
            // What the rules for this contact cover does not need the owner (D-130): code and markup at level 5, the
            // owner's allowlist below it
            (State::Checked, Some(r)) => {
                crate::kinds::effective_verdict(r, &item.manifest.name, level, allow)
            }
            (State::Downloaded, _) => Verdict::Failed, // unchecked counts as "failed the check"
            (State::Accepted { .. }, _) => {
                return Err(Error::new(code::BAD_STATE, "already accepted"));
            }
            _ => {
                return Err(Error::new(
                    code::BAD_STATE,
                    "the file is not downloaded yet",
                ));
            }
        };
        let name = normalize(rename.unwrap_or(&item.manifest.name))?;
        may_accept(
            level,
            verdict,
            acceptor,
            is_special(&name),
            special_approved,
        )?;
        let (dest, dir) = self.dest_dir(&item, level, project)?;
        let saved_dir = project
            .filter(|_| dest == Destination::Project)
            .map(Path::to_path_buf);
        // Without a name of the owner's, a taken name gets the next free number (`DECISIONS (2).md`, D-128), the way
        // browsers save a download: a re-sent file with new content is never dropped and never replaces the old one.
        let numbered = rename.is_none();
        // A re-sent copy of a file that is already there (same size and BLAKE3 under this name, or under one of its
        // numbers when the daemon numbers): accepted without a second copy, so that neither the owner nor the daemon's
        // own accept at level 5 is stuck on "the name is taken" (preview.8)
        let existing = if numbered {
            crate::accept::existing_copy(&dir, &name, item.manifest.size, &item.manifest.blake3)?
        } else {
            match crate::accept::existing_name(&dir, &name)? {
                Some(e)
                    if crate::accept::same_content(
                        &dir,
                        &e,
                        item.manifest.size,
                        &item.manifest.blake3,
                    )? =>
                {
                    Some(e)
                }
                _ => None,
            }
        };
        if let Some(existing) = existing {
            item.state = State::Accepted {
                name: existing.clone(),
                dest,
            };
            item.held = None;
            item.saved_dir = saved_dir;
            self.save(&item, secret.expose())?;
            return Ok(Accepted {
                name_number: if numbered {
                    crate::accept::name_number(&name, &existing)
                } else {
                    0
                },
                name: existing,
                dest,
                blake3: item.manifest.blake3,
                sha256: item.sha256,
                size: item.manifest.size,
                duplicate: true,
            });
        }
        let mut inc = Incoming::create(dir)?;
        let file = inc
            .file()
            .try_clone()
            .map_err(|e| Error::internal(format!("{e}")))?;
        let mut w = tokio::fs::File::from_std(file);
        let (p, sha256) = Self::decrypt_into(blobs, &item.manifest, &secret, &mut w).await?;
        item.sha256 = Some(sha256);
        w.flush()
            .await
            .map_err(|e| Error::internal(format!("{e}")))?;
        drop(w);
        let saved = if numbered {
            inc.commit_numbered(&name)?
        } else {
            inc.commit(&name)?;
            name.clone()
        };
        item.state = State::Accepted {
            name: saved.clone(),
            dest,
        };
        item.held = None;
        item.saved_dir = saved_dir;
        // The safe preview stays: it is what the window shows for this file in the conversation and the viewer from
        // now on (the window never decodes a received original). Up to preview.8 the accept deleted it, and every
        // accepted picture showed "Couldn't show the preview image" (TROUBLESHOOTING).
        self.save(&item, secret.expose())?;
        Ok(Accepted {
            name_number: if numbered {
                crate::accept::name_number(&name, &saved)
            } else {
                0
            },
            name: saved,
            dest,
            blake3: p.blake3,
            sha256: Some(sha256),
            size: p.len,
            duplicate: false,
        })
    }

    /// Records why the daemon's own accept (level 5, D-99) left a checked file for the owner, so every list of the
    /// file says why it waits; `None` clears it.
    pub fn set_held(&self, link: &[u8; 32], id: &str, held: Option<Held>) -> Result<()> {
        let _busy = self.lock(link, id)?;
        let (mut item, secret) = self.load(link, id)?;
        if matches!(item.state, State::Accepted { .. }) || item.held == held {
            return Ok(());
        }
        item.held = held;
        self.save(&item, secret.expose())
    }

    /// Where a file of this link is accepted at this level, and that folder opened without following symlinks.
    fn dest_dir(
        &self,
        item: &Item,
        level: u8,
        project: Option<&Path>,
    ) -> Result<(Destination, crate::accept::DestDir)> {
        let dest = match level_files(level, None)
            .ok_or_else(|| Error::new(code::LEVEL_FORBIDS_FILES, "no files at this level"))?
            .dest
        {
            // Level 5 without a project folder (the desktop app sets none): the link's `shared/`, as at levels 3–4,
            // rather than a file that can never be accepted (D-99)
            Destination::Project if project.is_none() => Destination::Shared,
            d => d,
        };
        let dir = match (dest, project) {
            (Destination::Inbox, _) => {
                open_dir_nofollow(&self.links_base, &[item.folder.as_str(), "inbox"])?
            }
            (Destination::Shared, _) | (Destination::Project, None) => {
                open_dir_nofollow(&self.links_base, &[item.folder.as_str(), "shared"])?
            }
            (Destination::Project, Some(p)) => open_dir_nofollow(p, &[])?,
        };
        Ok((dest, dir))
    }

    /// `file_name_check` (preview.8): can the file be accepted under `name` (the contact's name when `None`) now? The
    /// accept checks again: another process may take the name in between. Returns the name as it would be saved.
    pub fn name_check(
        &self,
        link: &[u8; 32],
        id: &str,
        level_now: u8,
        project: Option<&Path>,
        name: Option<&str>,
    ) -> Result<(String, NameState)> {
        let item = self.get(link, id)?;
        let contacts = name.is_none();
        let raw = name.unwrap_or(&item.manifest.name);
        let name = match normalize(raw) {
            Ok(n) => n,
            Err(e) => return Ok((raw.to_string(), NameState::Invalid(e.message))),
        };
        let level = level_now.min(item.level_at_offer);
        let (_, dir) = self.dest_dir(&item, level, project)?;
        // The contact's name: the accept numbers it when it is taken (D-128), and finds the same file under a number
        if contacts
            && crate::accept::existing_copy(&dir, &name, item.manifest.size, &item.manifest.blake3)?
                .is_some()
        {
            return Ok((name, NameState::Same));
        }
        let state = match crate::accept::existing_name(&dir, &name)? {
            None => NameState::Free,
            Some(e)
                if crate::accept::same_content(
                    &dir,
                    &e,
                    item.manifest.size,
                    &item.manifest.blake3,
                )? =>
            {
                NameState::Same
            }
            Some(_) => NameState::Taken(crate::accept::free_name(&dir, &name)?),
        };
        Ok((name, state))
    }

    /// `antenna files reject <id>`: wipes the record with the file key and the preview, deletes the blob, remembers the
    /// rejection (a repeat of the same offer is not accepted).
    pub async fn reject(&self, link: &[u8; 32], id: &str, blobs: &LinkBlobs) -> Result<()> {
        let _busy = self.lock(link, id)?;
        let item = self.get(link, id)?;
        let mark = self.item_path(link, id, ".rejected")?;
        // Mark: a repeat of the same offer is not accepted; the size counts toward the link's daily volume.
        std::fs::write(&mark, item.manifest.size.to_string())?;
        self.save_preview(link, id, None)?;
        std::fs::remove_file(self.item_path(link, id, ".x")?)?;
        blobs
            .forget_incoming(iroh_blobs::Hash::from_bytes(item.manifest.blob), id)
            .await?;
        Ok(())
    }

    /// All records of the link (including accepted ones), for daemon listings.
    pub fn items(&self, link: &[u8; 32]) -> Result<Vec<Item>> {
        let dir = self.link_dir(link).join("items");
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Ok(out);
        };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let Some(id) = n.strip_suffix(".x") else {
                continue;
            };
            if id.ends_with(".p") {
                continue;
            }
            if let Ok(item) = self.get(link, id) {
                out.push(item);
            }
        }
        out.sort_by_key(|i| (i.created_ms, i.id.clone()));
        Ok(out)
    }

    /// Links that have a quarantine directory (hex `link_id` → bytes).
    pub fn links(&self) -> Vec<[u8; 32]> {
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return out;
        };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if let Ok(b) = data_encoding::HEXLOWER.decode(n.as_bytes())
                && let Ok(a) = <[u8; 32]>::try_from(b.as_slice())
            {
                out.push(a);
            }
        }
        out
    }

    /// Volume of the link's files offered since `since_ms` (accepted, pending and rejected), for the level's daily
    /// limit.
    pub fn volume_since(&self, link: &[u8; 32], since_ms: u64) -> u64 {
        let mut total = 0u64;
        if let Ok(items) = self.items(link) {
            for i in items.iter().filter(|i| i.created_ms >= since_ms) {
                total = total.saturating_add(i.manifest.size);
            }
        }
        let dir = self.link_dir(link).join("items");
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                if !e.file_name().to_string_lossy().ends_with(".rejected") {
                    continue;
                }
                let recent = e
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .is_some_and(|d| d.as_millis() as u64 >= since_ms);
                if recent
                    && let Ok(v) = std::fs::read_to_string(e.path())
                    && let Ok(n) = v.trim().parse::<u64>()
                {
                    total = total.saturating_add(n);
                }
            }
        }
        total
    }
}
