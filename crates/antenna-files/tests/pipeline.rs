// SPDX-License-Identifier: AGPL-3.0-only
//! The whole receive pipeline (SPEC §10): manifest → quarantine → sandboxed check → preview → explicit acceptance, per
//! level. The sender and the recipient are real iroh endpoints on 127.0.0.1, a link store, the worker in the sandbox.

// The file check needs the worker sandbox: Linux, Landlock + seccomp; macOS, Seatbelt (D-P-12). On other OSes the check
// fails closed (verdict failed), and there is nothing for these tests to run.
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use antenna_files::blobs::LinkBlobs;
use antenna_files::crypt::{FileSecret, random_bytes};
use antenna_files::error::code;
use antenna_files::manifest::{
    FileOffer, Manifest, ManifestSigner, SenderCheck, SignedManifest, SignedManifestExt,
};
use antenna_files::outgoing;
use antenna_files::policy::{Acceptor, OwnerForce};
use antenna_files::quarantine::{Quarantine, State};
use antenna_files::report::{PreviewKind, Verdict};
use ed25519_dalek::SigningKey;
use iroh::protocol::Router;

use common::{addr, ep};

struct World {
    _t: tempfile::TempDir,
    root: std::path::PathBuf,
    // Sender.
    s_ep: iroh::Endpoint,
    s_blobs: LinkBlobs,
    s_router: Router,
    s_key: SigningKey,
    // Recipient.
    r_ep: iroh::Endpoint,
    r_blobs: LinkBlobs,
    q: Quarantine,
    link: [u8; 32],
    r_pub: [u8; 32],
    links_base: std::path::PathBuf,
}

async fn world() -> World {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().to_path_buf();
    let s_ep = ep().await;
    let r_ep = ep().await;
    let s_blobs = LinkBlobs::open(root.join("sender/blobs"), r_ep.id())
        .await
        .unwrap();
    let s_router = Router::builder(s_ep.clone())
        .accept(iroh_blobs::ALPN, s_blobs.protocol())
        .spawn();
    let link = random_bytes::<32>();
    let links_base = root.join("home/Antenna/links");
    std::fs::create_dir_all(&links_base).unwrap();
    let q = Quarantine::open(root.join("recv/quarantine"), random_bytes(), &links_base).unwrap();
    let r_blobs = LinkBlobs::open(q.blobs_dir(&link), s_ep.id())
        .await
        .unwrap();
    World {
        _t: t,
        root,
        s_ep,
        s_blobs,
        s_router,
        s_key: SigningKey::from_bytes(&random_bytes()),
        r_ep,
        r_blobs,
        q,
        link,
        r_pub: random_bytes(),
        links_base,
    }
}

impl World {
    async fn share(&self, name: &str, data: &[u8]) -> FileOffer {
        let p = self.root.join(format!(
            "src-{}",
            data_encoding::HEXLOWER.encode(&random_bytes::<4>())
        ));
        std::fs::write(&p, data).unwrap();
        let prep = outgoing::prepare(
            &p,
            name,
            &self.s_blobs,
            &common::checker(),
            &self.s_key,
            &self.link,
            &self.r_pub,
        )
        .await
        .unwrap();
        std::fs::remove_file(&p).unwrap();
        // The daemon sends after the policy decision on the sender's report.
        self.s_blobs.offer_existing(prep.blob).await.unwrap();
        prep.offer
    }

    fn author(&self) -> [u8; 32] {
        ManifestSigner::verifying_key(&self.s_key)
    }

    /// Offer → download → check; returns the id.
    async fn receive(&self, offer: &FileOffer, level: u8) -> String {
        let item = self
            .q
            .offer(
                &self.link,
                "bob",
                &self.author(),
                &self.r_pub,
                level,
                offer,
                0,
                None,
                None,
            )
            .unwrap();
        let conn = self
            .r_ep
            .connect(addr(&self.s_ep), iroh_blobs::ALPN)
            .await
            .unwrap();
        self.q
            .download(&self.link, &item.id, &self.r_blobs, conn)
            .await
            .unwrap();
        self.q
            .check(&self.link, &item.id, &self.r_blobs, &common::checker())
            .await
            .unwrap();
        item.id
    }

    async fn accept(
        &self,
        id: &str,
        level: u8,
        who: &Acceptor<'_>,
        special_ok: bool,
        rename: Option<&str>,
    ) -> antenna_files::Result<antenna_files::quarantine::Accepted> {
        self.q
            .accept(
                &self.link,
                id,
                &self.r_blobs,
                level,
                who,
                special_ok,
                None,
                rename,
                &antenna_files::kinds::Allow::default(),
            )
            .await
    }
}

#[tokio::test]
async fn level_one_gets_no_file_whoever_asks() {
    let w = world().await;
    let offer = w.share("notes.txt", b"hello").await;
    // From the manifest, before the download: a level 1 contact gets no files, neither at the agent's request nor
    // otherwise.
    let e =
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            1,
            &offer,
            0,
            None,
            None,
        )
        .unwrap_err();
    assert_eq!(e.code, code::LEVEL_FORBIDS_FILES);
    assert!(w.q.pending(&w.link).unwrap().is_empty());
    // And even if a record somehow exists, nobody may accept at level 1, not even with --force.
    let id = w.receive(&offer, 2).await;
    let force = OwnerForce::after_owner_password_check();
    let e = w
        .accept(&id, 1, &Acceptor::OwnerForce(&force), true, None)
        .await
        .unwrap_err();
    assert_eq!(e.code, code::LEVEL_FORBIDS_FILES);
    w.s_router.shutdown().await.unwrap();
}

#[tokio::test]
async fn level_two_inbox_only_after_the_owner() {
    let w = world().await;
    let body = "Quarterly report for Zoë.\nPLAINTEXT-MARKER-7f3a\n".repeat(200);
    let offer = w.share("résumé.txt", body.as_bytes()).await;
    let id = w.receive(&offer, 2).await;
    // Preview: the whole text, the original stays in quarantine.
    let (report, preview) = w.q.preview(&w.link, &id).unwrap();
    assert_eq!(report.verdict, Verdict::Clean, "{:?}", report.findings);
    let p = preview.unwrap();
    assert_eq!(p.kind, PreviewKind::Text);
    assert_eq!(p.text.unwrap(), body);
    // No plaintext in quarantine: neither in the store nor in the records.
    for f in walk(&w.root.join("recv")) {
        let b = std::fs::read(&f).unwrap();
        assert!(
            !b.windows(20).any(|x| x == b"PLAINTEXT-MARKER-7f3a"),
            "plaintext in {}",
            f.display()
        );
    }
    // The agent cannot accept (level 2: owner only).
    let e = w
        .accept(&id, 2, &Acceptor::Agent, false, None)
        .await
        .unwrap_err();
    assert_eq!(e.code, code::FORBIDDEN);
    assert!(!w.links_base.join("bob/inbox/résumé.txt").exists());
    // The owner: into inbox/, no exec bits, the hash matches.
    let a = w
        .accept(&id, 2, &Acceptor::Owner, false, None)
        .await
        .unwrap();
    let path = w.links_base.join("bob/inbox/résumé.txt");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(a.blake3, *blake3::hash(body.as_bytes()).as_bytes());
    assert!(!w.links_base.join("bob/shared").exists());
    // Not a second time.
    assert_eq!(
        w.accept(&id, 2, &Acceptor::Owner, false, None)
            .await
            .unwrap_err()
            .code,
        code::BAD_STATE
    );
    assert!(w.q.pending(&w.link).unwrap().is_empty());
    w.s_router.shutdown().await.unwrap();
}

fn walk(p: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(p);
            }
        }
    }
    out
}

#[tokio::test]
async fn level_three_agent_accepts_clean_files_into_shared() {
    let w = world().await;
    let png = common::samples::png(20, 10, &[]);
    let offer = w.share("chart.png", &png).await;
    let id = w.receive(&offer, 3).await;
    let (r, p) = w.q.preview(&w.link, &id).unwrap();
    assert_eq!(r.verdict, Verdict::Clean);
    assert_eq!(p.unwrap().images.len(), 1);
    let a = w
        .accept(&id, 3, &Acceptor::Agent, false, None)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(w.links_base.join("bob/shared/chart.png")).unwrap(),
        png
    );
    assert_eq!(a.size, png.len() as u64);
    // The level was lowered after the offer: the current one applies, the agent can no longer accept.
    let offer = w.share("chart2.png", &png).await;
    let id = w.receive(&offer, 3).await;
    assert_eq!(
        w.accept(&id, 2, &Acceptor::Agent, false, None)
            .await
            .unwrap_err()
            .code,
        code::FORBIDDEN
    );
    w.s_router.shutdown().await.unwrap();
}

/// An accepted picture keeps its safe preview (preview.9): the window shows received pictures in the conversation
/// from it after the accept, as before it. Up to preview.8 the accept deleted the preview and `preview` refused an
/// accepted file, so every accepted picture showed "Couldn't show the preview image".
#[tokio::test]
async fn an_accepted_picture_keeps_its_safe_preview() {
    let w = world().await;
    let png = common::samples::png(24, 16, &[]);
    let offer = w.share("logo.png", &png).await;
    let id = w.receive(&offer, 5).await;
    let (_, before) = w.q.preview(&w.link, &id).unwrap();
    let before = before.expect("a checked picture has a preview");
    w.accept(&id, 5, &Acceptor::Owner, false, None)
        .await
        .unwrap();
    assert!(matches!(
        w.q.get(&w.link, &id).unwrap().state,
        State::Accepted { .. }
    ));
    let (r, after) = w.q.preview(&w.link, &id).unwrap();
    assert_eq!(r.verdict, Verdict::Clean);
    let after = after.expect("the accept keeps the preview");
    assert_eq!(after.kind, PreviewKind::Image);
    assert_eq!(after.images, before.images);
    // The same file again under the same name: accepted as that file (preview.8), and its preview stays too.
    let offer = w.share("logo.png", &png).await;
    let id2 = w.receive(&offer, 5).await;
    assert!(
        w.accept(&id2, 5, &Acceptor::Owner, false, None)
            .await
            .unwrap()
            .duplicate
    );
    assert!(w.q.preview(&w.link, &id2).unwrap().1.is_some());
    // A rejected file has none: the reject still wipes the record and the preview.
    let offer = w.share("other.png", &png).await;
    let id3 = w.receive(&offer, 5).await;
    w.q.reject(&w.link, &id3, &w.r_blobs).await.unwrap();
    assert!(w.q.preview(&w.link, &id3).is_err());
    w.s_router.shutdown().await.unwrap();
}

/// D-99: level 5 saves into the owner's project folder; without one (the desktop app sets none) into the link's
/// `shared/`, instead of a file nobody can accept.
#[tokio::test]
async fn level_five_without_a_project_folder_saves_into_shared() {
    let w = world().await;
    let png = common::samples::png(12, 8, &[]);
    let offer = w.share("photo.png", &png).await;
    let id = w.receive(&offer, 5).await;
    let a = w
        .accept(&id, 5, &Acceptor::Owner, false, None)
        .await
        .unwrap();
    assert_eq!(a.dest, antenna_files::policy::Destination::Shared);
    assert_eq!(
        std::fs::read(w.links_base.join("bob/shared/photo.png")).unwrap(),
        png
    );
    // With a project folder, level 5 goes there as before.
    let project = w.root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let offer = w.share("photo2.png", &png).await;
    let id = w.receive(&offer, 5).await;
    let a =
        w.q.accept(
            &w.link,
            &id,
            &w.r_blobs,
            5,
            &Acceptor::Owner,
            false,
            Some(&project),
            None,
            &antenna_files::kinds::Allow::default(),
        )
        .await
        .unwrap();
    assert_eq!(a.dest, antenna_files::policy::Destination::Project);
    assert_eq!(std::fs::read(project.join("photo2.png")).unwrap(), png);
    w.s_router.shutdown().await.unwrap();
}

#[tokio::test]
async fn threats_stay_in_quarantine_unless_the_owner_forces() {
    let w = world().await;
    let offer = w.share("readme.txt", &common::samples::eicar()).await;
    let id = w.receive(&offer, 4).await;
    let (r, p) = w.q.preview(&w.link, &id).unwrap();
    assert_eq!(r.verdict, Verdict::Threat);
    assert!(p.is_none(), "no preview for a threat");
    for who in [Acceptor::Agent, Acceptor::Owner] {
        assert_eq!(
            w.accept(&id, 4, &who, false, None).await.unwrap_err().code,
            code::FORBIDDEN
        );
    }
    assert!(!w.links_base.join("bob/shared/readme.txt").exists());
    // SPEC §10 step 5: the owner with --force and the password may.
    let force = OwnerForce::after_owner_password_check();
    w.accept(&id, 4, &Acceptor::OwnerForce(&force), false, None)
        .await
        .unwrap();
    assert!(w.links_base.join("bob/shared/readme.txt").exists());

    // Rejection: the record with the key is wiped, the blob no longer belongs to the link.
    let offer = w.share("readme2.txt", &common::samples::eicar()).await;
    let id = w.receive(&offer, 4).await;
    w.q.reject(&w.link, &id, &w.r_blobs).await.unwrap();
    assert_eq!(w.q.get(&w.link, &id).unwrap_err().code, code::NOT_FOUND);
    w.s_router.shutdown().await.unwrap();
}

#[tokio::test]
async fn dangerous_and_special_names() {
    let w = world().await;
    // A name that is a path: it cannot be accepted under that name, under a new name it can.
    let offer = w.share("authorized_keys", b"ssh-ed25519 AAAA").await;
    // (The sender normalizes the name; a malicious sender signs a manifest with any name.)
    let mut m: Manifest = offer.manifest.open(&w.author(), &w.link, &w.r_pub).unwrap();
    m.name = "../../.ssh/authorized_keys".into();
    m.file_id = random_bytes();
    let evil = FileOffer {
        manifest: SignedManifest::seal(&m, &w.s_key, &w.link, &w.r_pub).unwrap(),
        secret: offer.secret,
    };
    let id = w.receive(&evil, 4).await;
    assert_eq!(
        w.accept(&id, 4, &Acceptor::Agent, false, None)
            .await
            .unwrap_err()
            .code,
        code::BAD_NAME
    );
    w.accept(&id, 4, &Acceptor::Agent, false, Some("keys.txt"))
        .await
        .unwrap();
    assert!(w.links_base.join("bob/shared/keys.txt").exists());
    assert!(!w.root.join("home/.ssh").exists());
    // Auto-executed names and dot files: only with a separate approval.
    for name in [".envrc", "Makefile", "package.json"] {
        let offer = w.share(name, b"echo pwned").await;
        let id = w.receive(&offer, 4).await;
        assert_eq!(
            w.accept(&id, 4, &Acceptor::Agent, false, None)
                .await
                .unwrap_err()
                .code,
            code::APPROVAL_REQUIRED,
            "{name}"
        );
        w.accept(&id, 4, &Acceptor::Agent, true, None)
            .await
            .unwrap();
    }
    // Case duplicate: under that name (the owner's choice) refused; under the contact's name saved as the next
    // number (D-128). The file already there is never replaced.
    let offer = w.share("KEYS.TXT", b"other").await;
    let id = w.receive(&offer, 4).await;
    assert_eq!(
        w.accept(&id, 4, &Acceptor::Agent, false, Some("KEYS.TXT"))
            .await
            .unwrap_err()
            .code,
        code::NAME_TAKEN
    );
    let acc = w
        .accept(&id, 4, &Acceptor::Agent, false, None)
        .await
        .unwrap();
    assert_eq!((acc.name.as_str(), acc.name_number), ("KEYS (2).TXT", 2));
    assert_eq!(
        std::fs::read(w.links_base.join("bob/shared/keys.txt")).unwrap(),
        b"ssh-ed25519 AAAA"
    );
    assert_eq!(
        std::fs::read(w.links_base.join("bob/shared/KEYS (2).TXT")).unwrap(),
        b"other"
    );
    w.s_router.shutdown().await.unwrap();
}

#[tokio::test]
async fn substituted_chunk_or_lying_manifest_never_reaches_the_folder() {
    let w = world().await;
    // A malicious sender: ciphertext with a substituted byte in a chunk, an honest bao hash (over the damaged bytes).
    let secret = FileSecret::random();
    let plain = vec![b'z'; 200_000];
    let (mut ct, p) = antenna_files::crypt::encrypt_to_vec(&secret, &plain).unwrap();
    ct[antenna_files::crypt::HEADER_LEN + 70_000] ^= 1;
    let tag = w
        .s_blobs
        .store()
        .blobs()
        .add_bytes(ct.clone())
        .await
        .unwrap();
    w.s_blobs.offer_existing(tag.hash).await.unwrap();
    let evil_out = tag.hash;
    let s_blobs = &w.s_blobs;
    let mk = |blob: [u8; 32], blake: [u8; 32], size: u64| Manifest {
        v: 0,
        file_id: random_bytes(),
        name: "data.bin".into(),
        mime: "application/octet-stream".into(),
        size,
        blake3: blake,
        blob,
        blob_size: antenna_files::crypt::ciphertext_len(size),
        sender_check: SenderCheck {
            verdict: Verdict::Clean,
            findings: vec![],
        },
        created_ms: 0,
    };
    let m = mk(*evil_out.as_bytes(), p.blake3, p.len);
    let offer = FileOffer {
        manifest: SignedManifest::seal(&m, &w.s_key, &w.link, &w.r_pub).unwrap(),
        secret: *secret.expose(),
    };
    let item =
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            4,
            &offer,
            0,
            None,
            None,
        )
        .unwrap();
    let conn = w
        .r_ep
        .connect(addr(&w.s_ep), iroh_blobs::ALPN)
        .await
        .unwrap();
    w.q.download(&w.link, &item.id, &w.r_blobs, conn)
        .await
        .unwrap(); // bao matches: the blob is as declared
    let o =
        w.q.check(&w.link, &item.id, &w.r_blobs, &common::checker())
            .await
            .unwrap();
    assert_eq!(o.report.verdict, Verdict::Failed, "{:?}", o.report.findings);
    assert!(
        o.report.findings[0].detail.contains("file_corrupt"),
        "{:?}",
        o.report.findings
    );
    assert!(o.preview.is_none());
    let force = OwnerForce::after_owner_password_check();
    let e = w
        .accept(&item.id, 4, &Acceptor::OwnerForce(&force), false, None)
        .await
        .unwrap_err();
    assert_eq!(e.code, code::CORRUPT);
    let shared = w.links_base.join("bob/shared");
    assert!(
        std::fs::read_dir(&shared).map(|d| d.count()).unwrap_or(0) == 0,
        "nothing may appear in shared/"
    );

    // The manifest lies about the plaintext BLAKE3.
    let good = common::offered(
        s_blobs,
        std::io::Cursor::new(b"honest bytes".to_vec()),
        &secret,
    )
    .await;
    let m = mk(*good.blob.as_bytes(), random_bytes(), good.plain.len);
    let offer = FileOffer {
        manifest: SignedManifest::seal(&m, &w.s_key, &w.link, &w.r_pub).unwrap(),
        secret: *secret.expose(),
    };
    let item =
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            4,
            &offer,
            0,
            None,
            None,
        )
        .unwrap();
    let conn = w
        .r_ep
        .connect(addr(&w.s_ep), iroh_blobs::ALPN)
        .await
        .unwrap();
    w.q.download(&w.link, &item.id, &w.r_blobs, conn)
        .await
        .unwrap();
    let o =
        w.q.check(&w.link, &item.id, &w.r_blobs, &common::checker())
            .await
            .unwrap();
    assert_eq!(o.report.verdict, Verdict::Failed);
    assert!(
        o.report.findings[0].detail.contains("file_hash_mismatch"),
        "{:?}",
        o.report.findings
    );
    let e = w
        .accept(&item.id, 4, &Acceptor::OwnerForce(&force), false, None)
        .await
        .unwrap_err();
    assert_eq!(e.code, code::HASH_MISMATCH);
    assert!(std::fs::read_dir(&shared).map(|d| d.count()).unwrap_or(0) == 0);
    w.s_router.shutdown().await.unwrap();
}

#[tokio::test]
async fn manifest_from_someone_else_or_for_another_link_is_refused() {
    let w = world().await;
    let offer = w.share("a.txt", b"x").await;
    let stranger = SigningKey::from_bytes(&random_bytes());
    let e =
        w.q.offer(
            &w.link,
            "bob",
            &ManifestSigner::verifying_key(&stranger),
            &w.r_pub,
            3,
            &offer,
            0,
            None,
            None,
        )
        .unwrap_err();
    assert_eq!(e.code, code::BAD_MANIFEST);
    let e =
        w.q.offer(
            &random_bytes(),
            "bob",
            &w.author(),
            &w.r_pub,
            3,
            &offer,
            0,
            None,
            None,
        )
        .unwrap_err();
    assert_eq!(e.code, code::BAD_MANIFEST);
    // A repeat of the same offer.
    w.q.offer(
        &w.link,
        "bob",
        &w.author(),
        &w.r_pub,
        3,
        &offer,
        0,
        None,
        None,
    )
    .unwrap();
    assert_eq!(
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            3,
            &offer,
            0,
            None,
            None
        )
        .unwrap_err()
        .code,
        code::BAD_STATE
    );
    // Level 2 daily volume (100 MiB): from the manifest, before the download.
    let e =
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            2,
            &w.share("b.txt", b"y").await,
            100 << 20,
            None,
            None,
        )
        .unwrap_err();
    assert_eq!(e.code, code::QUOTA);
    let item =
        w.q.get(&w.link, &w.q.pending(&w.link).unwrap()[0].id)
            .unwrap();
    assert_eq!(item.state, State::Offered);
    w.s_router.shutdown().await.unwrap();
}

/// Where and by whom a file is accepted is decided by the quarantine: by the lower level (at offer time and now) and by
/// the link folder from the offer.
#[tokio::test]
async fn destination_follows_the_lower_level_and_the_link_folder() {
    let w = world().await;
    let offer = w.share("plan.txt", b"plan").await;
    let id = w.receive(&offer, 2).await; // offered at level 2
    // The level was raised to 4: for this file it is still level 2, the agent may not accept.
    assert_eq!(
        w.accept(&id, 4, &Acceptor::Agent, false, None)
            .await
            .unwrap_err()
            .code,
        code::FORBIDDEN
    );
    // The owner: and the file goes into inbox/ (not shared/), into this link's folder.
    let a = w
        .accept(&id, 4, &Acceptor::Owner, false, None)
        .await
        .unwrap();
    assert_eq!(a.dest, antenna_files::policy::Destination::Inbox);
    assert!(w.links_base.join("bob/inbox/plan.txt").exists());
    assert!(!w.links_base.join("bob/shared").exists());
    w.s_router.shutdown().await.unwrap();
}

/// Concurrent acceptance of one file succeeds once; a rejected file cannot come back with the same offer.
#[tokio::test]
async fn one_operation_at_a_time_and_rejection_sticks() {
    let w = world().await;
    let offer = w.share("one.txt", b"one").await;
    let id = w.receive(&offer, 4).await;
    let (r1, r2) = tokio::join!(
        w.accept(&id, 4, &Acceptor::Agent, false, Some("copy1.txt")),
        w.accept(&id, 4, &Acceptor::Agent, false, Some("copy2.txt")),
    );
    assert!(
        r1.is_ok() ^ r2.is_ok(),
        "exactly one accept must win: {r1:?} {r2:?}"
    );
    let n = std::fs::read_dir(w.links_base.join("bob/shared"))
        .unwrap()
        .count();
    assert_eq!(n, 1);
    let offer = w.share("two.txt", b"two").await;
    let id = w.receive(&offer, 4).await;
    w.q.reject(&w.link, &id, &w.r_blobs).await.unwrap();
    let e =
        w.q.offer(
            &w.link,
            "bob",
            &w.author(),
            &w.r_pub,
            4,
            &offer,
            0,
            None,
            None,
        )
        .unwrap_err();
    assert_eq!(e.code, code::BAD_STATE);
    w.s_router.shutdown().await.unwrap();
}

/// Two offers of the same ciphertext are independent (rejecting one does not break the other); a quarantine record
/// seen from outside does not carry the file secret.
#[tokio::test]
async fn two_offers_of_one_blob_and_no_secret_in_items() {
    let mut w = world().await;
    w.r_blobs.shutdown().await.ok();
    w.r_blobs = LinkBlobs::open_with_gc(
        w.q.blobs_dir(&w.link),
        w.s_ep.id(),
        std::time::Duration::from_secs(1),
    )
    .await
    .unwrap();
    let offer_a = w.share("same.txt", b"same bytes").await;
    let mut m: Manifest = offer_a
        .manifest
        .open(&w.author(), &w.link, &w.r_pub)
        .unwrap();
    m.file_id = random_bytes();
    let offer_b = FileOffer {
        manifest: SignedManifest::seal(&m, &w.s_key, &w.link, &w.r_pub).unwrap(),
        secret: offer_a.secret,
    };
    let id_a = w.receive(&offer_a, 4).await;
    let id_b = w.receive(&offer_b, 4).await;
    w.q.reject(&w.link, &id_a, &w.r_blobs).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(3)).await; // garbage collection has run
    w.accept(&id_b, 4, &Acceptor::Agent, false, Some("b.txt"))
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(w.links_base.join("bob/shared/b.txt")).unwrap(),
        b"same bytes"
    );
    // An Item serializes without the file secret.
    let item = w.q.get(&w.link, &id_b).unwrap();
    let bytes = antenna_files::codec::to_cbor(&item).unwrap();
    assert!(
        !bytes.windows(32).any(|x| x == offer_a.secret),
        "the file secret leaked into Item"
    );
    w.s_router.shutdown().await.unwrap();
}
