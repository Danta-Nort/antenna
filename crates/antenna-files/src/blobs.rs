// SPDX-License-Identifier: AGPL-3.0-only
//! File transfer (SPEC §10 "content-addressed (iroh-blobs, BLAKE3 verified streaming)", "The blob store is isolated
//! per link"): the `xfile/0` ciphertext is an iroh-blobs 0.103 blob in a **separate per-link store** with an ACL.
//!
//! - the store holds only ciphertext (STACK "Files"): neither the sender nor the recipient has the plaintext there;
//! - each link has its own store (a separate directory): deduplication only within a link; moreover the `xfile/0` salt
//!   is random, so the same file in two links is two unrelated blobs;
//! - ACL ([`LinkBlobs::protocol`]): connections only from the EndpointId of this link's contact; a `get` request only
//!   for a whole blob (not hash-seq) from the set of blobs **sent in this link**; `get_many`, `push`, `observe` are
//!   refused. The refusal happens before the store is touched, so the response time does not reveal whether a blob
//!   exists;
//! - resumption: `fetch` requests only the missing ranges, the recipient verifies BLAKE3/bao on every chunk; nothing
//!   beyond the manifest size (the level quota was computed from it) is downloaded, any excess is deleted;
//! - an outgoing blob is a draft (`draft/`) until the policy decides on sending; it is served only after
//!   `offer_existing`.
//!
//! An iroh-blobs 0.103 pitfall (TROUBLESHOOTING, slice 4 stage A, "iroh-blobs 0.103"; found by reading the code):
//! `EventMask.push`/`get_many`/`observe` are not read; all request kinds are decided by `mask.get`, so the default
//! policy **does not forbid** push (the stock client currently aborts push by itself on `recv.stop`, but relying on
//! that accident is not acceptable). So here every request is intercepted and everything except an allowed `get` is
//! rejected explicitly (tests cover push, observe, hash-seq).

use std::collections::HashSet;
use std::io::Read;
use std::path::Path;
use std::sync::{Arc, RwLock};

use bytes::Bytes;
use futures::StreamExt;
use iroh::EndpointId;
use iroh::endpoint::Connection;
use iroh_blobs::api::remote::GetProgressItem;
use iroh_blobs::provider::events::{
    AbortReason, ConnectMode, EventMask, EventSender, ObserveMode, ProviderMessage, RequestMode,
    ThrottleMode,
};
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::{BlobsProtocol, Hash};

use crate::crypt::{FileSecret, Plain, encrypt_reader};
use crate::error::{Error, Result, code};

/// Tag prefix for blobs sent in this link (they may be served to the contact).
pub const TAG_OUT: &str = "out/";
/// Tag prefix for blobs received from the contact: `in/<hash>/<record>`, one tag per quarantine record (two offers of
/// the same ciphertext do not interfere with each other); it protects partial downloads from garbage collection; such
/// blobs are never served.
pub const TAG_IN: &str = "in/";
/// Default store garbage collection interval.
pub const GC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);
/// Tag prefix for outgoing blobs not yet allowed to be served (waiting for the policy decision: secrets → approval).
pub const TAG_DRAFT: &str = "draft/";

/// Result of adding an outgoing file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outgoing {
    /// Blob hash (BLAKE3 of the ciphertext).
    pub blob: Hash,
    /// Ciphertext size.
    pub blob_size: u64,
    /// Plaintext length and BLAKE3.
    pub plain: Plain,
}

/// Download result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fetched {
    /// Bytes downloaded in this attempt (excluding what was already local).
    pub downloaded: u64,
    /// Was local before the start.
    pub had: u64,
}

/// ACL counters (for tests and `antenna doctor`).
#[derive(Debug, Default)]
pub struct AclStats {
    /// Connections refused.
    pub denied_connections: std::sync::atomic::AtomicU64,
    /// Requests refused.
    pub denied_requests: std::sync::atomic::AtomicU64,
}

/// Blob store of one link.
///
/// Every iroh-blobs 0.103 `FsStore` starts its own multi-threaded tokio runtime (a thread per core), so the daemon
/// opens a link's store only for the duration of transfers and closes it when idle (TROUBLESHOOTING, slice 4 stage A,
/// "iroh-blobs 0.103").
pub struct LinkBlobs {
    store: FsStore,
    gc: std::time::Duration,
    offered: Arc<RwLock<HashSet<Hash>>>,
    peer: EndpointId,
    acl: Arc<AclStats>,
}

fn tag(prefix: &str, h: &Hash) -> String {
    format!("{prefix}{}", h.to_hex())
}

fn in_tag(h: &Hash, owner: &str) -> String {
    let owner: String = owner
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        .take(64)
        .collect();
    format!("{TAG_IN}{}/{owner}", h.to_hex())
}

fn err(e: impl std::fmt::Display) -> Error {
    Error::internal(format!("blob store: {e}"))
}

impl LinkBlobs {
    /// Opens (creates) the link's store in directory `dir` (0700); `peer` is the EndpointId of this link's contact.
    pub async fn open(dir: impl AsRef<Path>, peer: EndpointId) -> Result<Self> {
        Self::open_with_gc(dir, peer, GC_INTERVAL).await
    }

    /// The same with a garbage collection interval.
    pub async fn open_with_gc(
        dir: impl AsRef<Path>,
        peer: EndpointId,
        gc: std::time::Duration,
    ) -> Result<Self> {
        let dir = dir.as_ref();
        std::fs::create_dir_all(dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
        let mut opts = iroh_blobs::store::fs::options::Options::new(dir);
        opts.gc = Some(iroh_blobs::store::GcConfig {
            interval: gc,
            add_protected: None,
        });
        let store = FsStore::load_with_opts(dir.join("blobs.db"), opts)
            .await
            .map_err(err)?;
        let mut offered = HashSet::new();
        let mut tags = store.tags().list_prefix(TAG_OUT).await.map_err(err)?;
        while let Some(t) = tags.next().await {
            offered.insert(t.map_err(err)?.hash);
        }
        Ok(Self {
            store,
            gc,
            offered: Arc::new(RwLock::new(offered)),
            peer,
            acl: Arc::new(AclStats::default()),
        })
    }

    /// Store (only for reading ciphertext and for tests).
    pub fn store(&self) -> &FsStore {
        &self.store
    }

    /// ACL counters.
    pub fn acl_stats(&self) -> Arc<AclStats> {
        self.acl.clone()
    }

    /// iroh-blobs protocol handler with the ACL, registered on the endpoint of **this** link:
    /// `Router::builder(ep).accept(iroh_blobs::ALPN, link.protocol())`.
    pub fn protocol(&self) -> BlobsProtocol {
        let mask = EventMask {
            connected: ConnectMode::Intercept,
            get: RequestMode::Intercept,
            get_many: RequestMode::Disabled,
            push: RequestMode::Disabled,
            observe: ObserveMode::Intercept,
            throttle: ThrottleMode::None,
        };
        let (tx, mut rx) = EventSender::channel(64, mask);
        let offered = self.offered.clone();
        let peer = self.peer;
        let acl = self.acl.clone();
        tokio::spawn(async move {
            use std::sync::atomic::Ordering::Relaxed;
            let deny = || Err(AbortReason::Permission);
            while let Some(msg) = rx.recv().await {
                match msg {
                    ProviderMessage::ClientConnected(m) => {
                        let ok = m.endpoint_id == Some(peer);
                        if !ok {
                            acl.denied_connections.fetch_add(1, Relaxed);
                        }
                        m.tx.send(if ok { Ok(()) } else { deny() }).await.ok();
                    }
                    ProviderMessage::GetRequestReceived(m) => {
                        let ok = m.request.ranges.is_blob()
                            && offered
                                .read()
                                .map(|o| o.contains(&m.request.hash))
                                .unwrap_or(false);
                        if !ok {
                            acl.denied_requests.fetch_add(1, Relaxed);
                        }
                        m.tx.send(if ok { Ok(()) } else { deny() }).await.ok();
                    }
                    ProviderMessage::GetManyRequestReceived(m) => {
                        acl.denied_requests.fetch_add(1, Relaxed);
                        m.tx.send(deny()).await.ok();
                    }
                    ProviderMessage::PushRequestReceived(m) => {
                        acl.denied_requests.fetch_add(1, Relaxed);
                        m.tx.send(deny()).await.ok();
                    }
                    ProviderMessage::ObserveRequestReceived(m) => {
                        acl.denied_requests.fetch_add(1, Relaxed);
                        m.tx.send(deny()).await.ok();
                    }
                    ProviderMessage::Throttle(m) => {
                        m.tx.send(Ok(())).await.ok();
                    }
                    _ => {}
                }
            }
        });
        BlobsProtocol::new(&self.store, Some(tx))
    }

    /// Encrypts plaintext from `reader` (STREAM) directly into the link's store. The blob is a draft (tag `draft/`): it
    /// is not served to the contact until the daemon calls [`Self::offer_existing`] after the policy decision
    /// (secrets → approval). The plaintext is never written to disk.
    pub async fn add_outgoing(
        &self,
        reader: impl Read + Send + 'static,
        secret: &FileSecret,
    ) -> Result<Outgoing> {
        let (tx, rx) = tokio::sync::mpsc::channel::<std::io::Result<Bytes>>(8);
        let secret = secret.clone();
        let enc = tokio::task::spawn_blocking(move || {
            encrypt_reader(&secret, reader, |chunk| {
                tx.blocking_send(Ok(Bytes::from(chunk)))
                    .map_err(|_| Error::internal("blob store stopped reading"))
            })
        });
        let stream =
            futures::stream::unfold(rx, |mut rx| async move { rx.recv().await.map(|x| (x, rx)) });
        let tag_info = self
            .store
            .blobs()
            .add_stream(stream)
            .await
            .temp_tag()
            .await
            .map_err(err)?;
        let plain = enc.await.map_err(err)??;
        let blob = tag_info.hash();
        self.store
            .tags()
            .set(tag(TAG_DRAFT, &blob), blob)
            .await
            .map_err(err)?;
        drop(tag_info);
        let blob_size = self.local(blob).await?.0;
        if blob_size != crate::crypt::ciphertext_len(plain.len) {
            return Err(Error::internal("ciphertext length mismatch"));
        }
        Ok(Outgoing {
            blob,
            blob_size,
            plain,
        })
    }

    /// Allows serving the full blob from this link's store to the contact (after the policy decision on sending).
    pub async fn offer_existing(&self, blob: Hash) -> Result<()> {
        if !self.local(blob).await?.1 {
            return Err(Error::new(
                code::NOT_FOUND,
                "blob is not complete in this link store",
            ));
        }
        self.store
            .tags()
            .set(tag(TAG_OUT, &blob), blob)
            .await
            .map_err(err)?;
        self.store
            .tags()
            .delete(tag(TAG_DRAFT, &blob))
            .await
            .map_err(err)?;
        self.offered
            .write()
            .map_err(|_| Error::internal("lock"))?
            .insert(blob);
        Ok(())
    }

    /// How many bytes of the blob are local and whether it is complete.
    pub async fn local(&self, hash: Hash) -> Result<(u64, bool)> {
        let l = self.store.remote().local(hash).await.map_err(err)?;
        Ok((l.local_bytes(), l.is_complete()))
    }

    /// Downloads a blob from the contact over the link's connection (resumption: only what is missing; bao verification
    /// on every chunk). `progress` receives the number of bytes downloaded in this attempt.
    pub async fn fetch(
        &self,
        conn: Connection,
        hash: Hash,
        expected_size: u64,
        owner: &str,
        mut progress: impl FnMut(u64),
    ) -> Result<Fetched> {
        // Tag before the download: a partial download is not garbage collected and resumes after a restart.
        let my_tag = in_tag(&hash, owner);
        self.store
            .tags()
            .set(my_tag.as_str(), hash)
            .await
            .map_err(err)?;
        let had = self.local(hash).await?.0;
        match self
            .fetch_bounded(conn, hash, expected_size, had, &mut progress)
            .await
        {
            Err(e) if e.code == code::CORRUPT => {
                // The sender sent the wrong thing (more than declared, another size): remove only our own tag; a blob
                // needed by other records, or our outgoing blob with the same hash, stays under their tags.
                self.store.tags().delete(my_tag.as_str()).await.ok();
                Err(e)
            }
            r => r,
        }
    }

    async fn fetch_bounded(
        &self,
        conn: Connection,
        hash: Hash,
        expected_size: u64,
        had: u64,
        progress: &mut impl FnMut(u64),
    ) -> Result<Fetched> {
        if had > expected_size {
            return Err(Error::new(
                code::CORRUPT,
                "blob is larger than the manifest says",
            ));
        }
        let mut downloaded = 0;
        {
            let mut s = std::pin::pin!(self.store.remote().fetch(conn, hash).stream());
            while let Some(item) = s.next().await {
                match item {
                    GetProgressItem::Progress(n) => {
                        downloaded = n;
                        // The level quota was computed from the manifest size: do not download more than declared.
                        if had.saturating_add(n) > expected_size {
                            return Err(Error::new(
                                code::CORRUPT,
                                "blob is larger than the manifest says",
                            ));
                        }
                        progress(n);
                    }
                    GetProgressItem::Done(st) => {
                        downloaded = st.payload_bytes_read;
                        break;
                    }
                    GetProgressItem::Error(e) => {
                        return Err(Error::new(code::TRANSFER, format!("fetch: {e}")));
                    }
                }
            }
        }
        let (size, complete) = self.local(hash).await?;
        if size != expected_size {
            return Err(Error::new(
                code::CORRUPT,
                "blob size differs from the manifest",
            ));
        }
        if !complete {
            return Err(Error::new(code::TRANSFER, "blob incomplete"));
        }
        Ok(Fetched { downloaded, had })
    }

    /// Reads the blob ciphertext (`AsyncRead`).
    pub fn reader(&self, hash: Hash) -> iroh_blobs::api::blobs::BlobReader {
        self.store.blobs().reader(hash)
    }

    /// Forgets an outgoing blob: removes the `out/` and `draft/` tags and the serve permission; the store's garbage
    /// collection deletes the data unless other tags hold the blob.
    pub async fn forget_outgoing(&self, hash: Hash) -> Result<()> {
        self.offered
            .write()
            .map_err(|_| Error::internal("lock"))?
            .remove(&hash);
        for p in [TAG_OUT, TAG_DRAFT] {
            self.store.tags().delete(tag(p, &hash)).await.map_err(err)?;
        }
        Ok(())
    }

    /// Forgets the incoming blob of one quarantine record (`owner`): removes only its tag. The daemon wipes the file
    /// key separately (crypto-shredding), so the ciphertext is useless even before garbage collection.
    pub async fn forget_incoming(&self, hash: Hash, owner: &str) -> Result<()> {
        self.store
            .tags()
            .delete(in_tag(&hash, owner).as_str())
            .await
            .map_err(err)?;
        Ok(())
    }

    /// Removes all outgoing drafts (policy decisions live in the daemon's memory, so after a restart drafts belong to
    /// nobody). Call at startup.
    pub async fn clear_drafts(&self) -> Result<u64> {
        self.store
            .tags()
            .delete_prefix(TAG_DRAFT)
            .await
            .map_err(err)
    }

    /// The store's garbage collection runs by itself every [`GC_INTERVAL`] (or every interval set with
    /// [`Self::open_with_gc`]). It deletes blobs without tags (the `out/`, `in/`, `draft/` tags and the temporary tags
    /// of running operations protect blobs). iroh-blobs 0.103 has no direct deletion (`delete`, `gc_run_once` are not
    /// public).
    pub fn gc_interval(&self) -> std::time::Duration {
        self.gc
    }

    /// Whether the blob may be served to the contact.
    pub fn is_offered(&self, hash: &Hash) -> bool {
        self.offered
            .read()
            .map(|o| o.contains(hash))
            .unwrap_or(false)
    }

    /// Closes the store.
    pub async fn shutdown(&self) -> Result<()> {
        self.store.shutdown().await.map_err(err)
    }
}
