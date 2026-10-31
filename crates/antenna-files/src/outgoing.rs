// SPDX-License-Identifier: AGPL-3.0-only
//! Sending a file (`antenna share`, SPEC §10 step 1): sender-side check in the same sandbox, encryption into the link's
//! store, signed manifest. The "may this be sent" decision (levels, secrets → approval) is made by the daemon policy
//! from the report.

use std::path::Path;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, ReadBuf};

use crate::blobs::LinkBlobs;
use crate::crypt::{FileSecret, random_bytes};
use crate::error::{Error, Result, code};
use crate::manifest::{
    FileOffer, MANIFEST_VERSION, Manifest, ManifestSigner, SenderCheck, SignedManifest,
    SignedManifestExt,
};
use crate::names::normalize;
use crate::report::CheckReport;
use crate::sandbox::Checker;

/// An `AsyncRead` that computes the BLAKE3 and the SHA-256 of what was read.
pub struct HashingReader<R> {
    inner: R,
    hasher: blake3::Hasher,
    sha256: sha2::Sha256,
    len: u64,
}

impl<R> HashingReader<R> {
    /// Wraps a reader.
    pub fn new(inner: R) -> Self {
        Self {
            inner,
            hasher: blake3::Hasher::new(),
            sha256: sha2::Sha256::default(),
            len: 0,
        }
    }

    /// Length and BLAKE3 of what was read.
    pub fn finish(&self) -> (u64, [u8; 32]) {
        (self.len, *self.hasher.finalize().as_bytes())
    }

    /// SHA-256 of what was read: shown next to BLAKE3, because `shasum` and `sha256sum` are on every system.
    pub fn sha256(&self) -> [u8; 32] {
        use sha2::Digest as _;
        self.sha256.clone().finalize().into()
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for HashingReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let r = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &r {
            let new = buf.filled()[before..].to_vec();
            self.hasher.update(&new);
            sha2::Digest::update(&mut self.sha256, &new);
            self.len += new.len() as u64;
        }
        r
    }
}

/// Result of preparing a send.
#[derive(Debug)]
pub struct Prepared {
    /// Offer for the link message (manifest + secret).
    pub offer: FileOffer,
    /// Manifest.
    pub manifest: Manifest,
    /// The sender's check report (secrets → approval is decided by the daemon policy).
    pub report: CheckReport,
    /// Draft blob in the link's store.
    pub blob: iroh_blobs::Hash,
    /// SHA-256 of the content (the first pass; the second pass's BLAKE3 matched it, so it is of what is sent).
    pub sha256: [u8; 32],
}

/// Prepares sending file `path` under name `name` over link `link_id` to recipient `recipient`.
///
/// The file is read twice (sandboxed check and encryption); if it changed between the passes (different length or
/// BLAKE3), the send is cancelled: the sender's report must apply to what is actually sent.
///
/// The blob stays a draft: the daemon decides from the report (secrets → owner approval, SPEC §9) and only then calls
/// `blobs.offer_existing(blob)` and sends the offer; on refusal, `blobs.forget_outgoing(blob)`.
#[allow(
    clippy::too_many_arguments,
    reason = "the file, the link's blob store, the checker and the manifest signing context"
)]
pub async fn prepare(
    path: &Path,
    name: &str,
    blobs: &LinkBlobs,
    checker: &Checker,
    signer: &impl ManifestSigner,
    link_id: &[u8; 32],
    recipient: &[u8; 32],
) -> Result<Prepared> {
    let file = std::fs::File::open(path)?;
    prepare_file(file, name, blobs, checker, signer, link_id, recipient).await
}

/// The same for an already open file (the daemon itself opens files from `shared/` requested by the contact, without
/// following symlinks). The file must be a regular file.
#[allow(
    clippy::too_many_arguments,
    reason = "the file, the link's blob store, the checker and the manifest signing context"
)]
pub async fn prepare_file(
    file: std::fs::File,
    name: &str,
    blobs: &LinkBlobs,
    checker: &Checker,
    signer: &impl ManifestSigner,
    link_id: &[u8; 32],
    recipient: &[u8; 32],
) -> Result<Prepared> {
    use std::io::{Seek, SeekFrom};
    let name = normalize(name)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(Error::new(code::BAD_NAME, "not a regular file"));
    }
    let size = meta.len();
    let mut first = file.try_clone()?;
    first.seek(SeekFrom::Start(0))?;
    let mut hr = HashingReader::new(tokio::fs::File::from_std(first));
    // At the sender: text from PDFs and documents and archive contents, to search for secrets (SPEC §9).
    let outcome = checker.check_outgoing(&mut hr, size, &name).await;
    // The check may not have read the whole file (the worker is not isolated, killed by a limit): hash the whole file,
    // otherwise "file changed" would be reported instead of the real reason ("check did not run").
    tokio::io::copy(&mut hr, &mut tokio::io::sink()).await?;
    let (checked_len, checked_hash) = hr.finish();
    let sha256 = hr.sha256();
    let secret = FileSecret::random();
    let mut second = file;
    second.seek(SeekFrom::Start(0))?;
    let out = blobs.add_outgoing(second, &secret).await?;
    if out.plain.len != size || out.plain.len != checked_len || out.plain.blake3 != checked_hash {
        blobs.forget_outgoing(out.blob).await.ok();
        return Err(Error::new(
            code::BAD_STATE,
            "the file changed while it was being prepared",
        ));
    }
    let manifest = Manifest {
        v: MANIFEST_VERSION,
        file_id: random_bytes(),
        name,
        mime: outcome.report.mime.clone(),
        size,
        blake3: out.plain.blake3,
        blob: *out.blob.as_bytes(),
        blob_size: out.blob_size,
        sender_check: SenderCheck {
            verdict: outcome.report.verdict,
            findings: outcome
                .report
                .findings
                .iter()
                .map(|f| f.code.chars().take(64).collect())
                .take(64)
                .collect(),
        },
        created_ms: crate::now_ms(),
    };
    let signed = SignedManifest::seal(&manifest, signer, link_id, recipient)?;
    Ok(Prepared {
        offer: FileOffer {
            manifest: signed,
            secret: *secret.expose(),
        },
        manifest,
        report: outcome.report,
        blob: out.blob,
        sha256,
    })
}
