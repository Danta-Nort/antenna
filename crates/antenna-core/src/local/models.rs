// SPDX-License-Identifier: AGPL-3.0-only
//! Getting a model file onto this computer and keeping it honest (`docs/LOCAL-ASSISTANT.md` §2.3, CONTROL §24).
//!
//! - **Download:** `curl` in the agent sandbox (D-71, D-P-13), HTTPS only (also for redirects), through the daemon's
//!   CONNECT proxy whose only destinations are the hub's hosts (`huggingface.co`, `*.hf.co`); its only writable folder
//!   is the model's own download folder, so a compromised `curl` cannot touch the models already checked. It resumes
//!   with a `Range` request after a network drop or a daemon restart, and resolves the pinned address again each time
//!   (the CDN's redirect carries a short-lived token).
//! - **Check:** after the last byte the daemon computes the SHA-256 of the file and compares it and the size with the
//!   release's catalog; only then is the file made read-only and moved to `models/<id>.gguf`. A mismatch deletes it.
//!   The file's device, inode, size and modification time are kept; any change means checking again before the next
//!   load ([`Session::model_checked`]).
//! - **Disk space** is checked first: free ≥ what is left to download + 10 % of the size + 1 GB.

use std::{
    io::Read,
    path::{Path, PathBuf},
    sync::{
        Arc, PoisonError,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};

use antenna_proto::{
    control::{LocalModelInfo, code},
    models::CatalogModel,
};
use sha2::Digest;

use super::{Progress, db, hardware};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
};

const GB: u64 = 1_000_000_000;

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// Disk space a download needs: what is left of the file, 10 % of its size, and 1 GB of room for everything else.
pub(crate) fn space_needed(size: u64, have: u64) -> u64 {
    size.saturating_sub(have)
        .saturating_add(size / 10)
        .saturating_add(GB)
}

/// Why a file is not the model it should be, or `None` when it is (size first: no need to hash a short file).
fn check_file(
    path: &Path,
    cm: &CatalogModel,
    done: &AtomicU64,
    cancel: &AtomicBool,
) -> std::io::Result<Option<String>> {
    let mut f = std::fs::File::open(path)?;
    let len = f.metadata()?.len();
    if len != cm.size {
        return Ok(Some(format!(
            "the file is {len} bytes; this model is {} bytes",
            cm.size
        )));
    }
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut n_total = 0u64;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("cancelled"));
        }
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        n_total += n as u64;
        done.store(n_total, Ordering::Relaxed);
    }
    let got = data_encoding::HEXLOWER.encode(&h.finalize());
    Ok((got != cm.sha256).then(|| {
        format!(
            "its SHA-256 is {}…, the release expects {}…",
            &got[..12],
            &cm.sha256[..12]
        )
    }))
}

impl Session {
    pub(super) fn set_progress(&self, id: &str, f: impl FnOnce(&mut Progress)) {
        let mut g = self
            .local
            .progress
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        f(g.entry(id.to_string()).or_default());
    }

    fn clear_progress(&self, id: &str) {
        self.local
            .progress
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
    }

    fn fail_model(&self, id: &str, code: &'static str, why: String) {
        tracing::warn!("local model {id}: {code}: {why}");
        self.set_progress(id, |p| {
            p.state = "failed";
            p.speed = None;
            p.error_code = Some(code);
            p.error = Some(why);
        });
        self.publish_model(id, true);
    }

    /// The model's download folder: `<data>/local/dl/<id>/` with the `.part` file in `work/`.
    pub(super) fn dl_dir(&self, id: &str) -> PathBuf {
        self.local_dir().join("dl").join(id)
    }

    /// `model_install`: start (or resume) a download, or copy and check a file the owner has. Returns the state at
    /// once; the job reports through `local_model` events.
    pub fn model_install(
        self: &Arc<Self>,
        id: &str,
        from_file: Option<&str>,
    ) -> Result<LocalModelInfo> {
        let cm = self.catalog_model(id)?;
        if self
            .local
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id)
        {
            return self.model_info(id);
        }
        let from = match from_file {
            None => None,
            Some(f) => {
                let p = PathBuf::from(f);
                if !p.is_absolute() {
                    return Err(Error::bad_request("from_file must be an absolute path"));
                }
                let m = std::fs::metadata(&p)
                    .map_err(|e| Error::new(code::NOT_FOUND, format!("{f}: {e}")))?;
                if !m.is_file() {
                    return Err(Error::bad_request(format!("{f} is not a file")));
                }
                if m.len() != cm.size {
                    return Err(Error::new(
                        code::HASH_MISMATCH,
                        format!("{f} is {} bytes; {} is {} bytes", m.len(), cm.name, cm.size),
                    ));
                }
                Some(p)
            }
        };
        let models = self.models_dir();
        let dl = self.dl_dir(id);
        let part = dl.join("work").join(format!("{id}.gguf.part"));
        if from.is_none() && self.model_path(id).is_file() {
            // Installed already: check it again only if the file changed.
            let this = self.clone();
            let id2 = id.to_string();
            tokio::spawn(async move {
                if let Err(e) = this.model_checked(&id2).await {
                    tracing::warn!("local model {id2}: {}", e.message);
                }
            });
            return self.model_info(id);
        }
        let have = if from.is_some() { 0 } else { file_len(&part) };
        let need = space_needed(cm.size, have);
        let free = hardware::disk_free(&self.local_dir());
        if free < need {
            return Err(Error::new(
                code::NO_SPACE,
                format!(
                    "not enough disk space: {} is needed, {} is free",
                    hardware::gb(need),
                    hardware::gb(free)
                ),
            ));
        }
        for d in [&models, &dl.join("work")] {
            use crate::owner_only::OwnerOnly;
            std::fs::DirBuilder::new()
                .recursive(true)
                .owner_only()
                .create(d)?;
        }
        if from.is_none() {
            // A restart resumes a download, never a copy.
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::model_set(
                &db,
                &db::ModelRow {
                    id: id.into(),
                    state: "downloading".into(),
                    size: cm.size,
                    sha256: cm.sha256.clone(),
                    verified: None,
                },
                now_ms(),
            )?;
        }
        let (tx, rx) = tokio::sync::watch::channel(false);
        self.local
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.to_string(), tx);
        self.set_progress(id, |p| {
            *p = Progress {
                state: "downloading",
                done: have,
                ..Default::default()
            }
        });
        let this = self.clone();
        tokio::spawn(async move {
            let id = cm.id.clone();
            this.install_job(cm, from, part, rx).await;
            this.local
                .jobs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&id);
        });
        self.publish_model(id, true);
        self.model_info(id)
    }

    async fn install_job(
        self: &Arc<Self>,
        cm: CatalogModel,
        from: Option<PathBuf>,
        part: PathBuf,
        mut cancel: tokio::sync::watch::Receiver<bool>,
    ) {
        let id = cm.id.clone();
        let got = match &from {
            Some(f) => self.copy_in(&cm, f, &part, &mut cancel).await,
            None => self.fetch(&cm, &part, &mut cancel).await,
        };
        if *cancel.borrow() {
            return;
        }
        if let Err(e) = got {
            if from.is_some() {
                let _ = std::fs::remove_dir_all(self.dl_dir(&id));
            }
            self.fail_model(&id, e.code, e.message);
            return;
        }
        match self.verify_and_place(&cm, &part, &mut cancel).await {
            Ok(()) => {
                self.clear_progress(&id);
                let _ = std::fs::remove_dir_all(self.dl_dir(&id));
                tracing::info!("local model {id}: checked and installed");
                self.publish_model(&id, true);
                self.publish_local_agents_of(&id);
            }
            Err(e) if *cancel.borrow() => {
                tracing::info!("local model {id}: cancelled ({})", e.message);
            }
            Err(e) => {
                let _ = std::fs::remove_dir_all(self.dl_dir(&id));
                {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    let _ = db::model_delete(&db, &id);
                }
                self.fail_model(&id, e.code, e.message);
            }
        }
    }

    /// The owner's file → the `.part` file (a copy: the owner's original stays as it was).
    async fn copy_in(
        &self,
        cm: &CatalogModel,
        from: &Path,
        part: &Path,
        cancel: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let done = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (f, p, d, st) = (
            from.to_path_buf(),
            part.to_path_buf(),
            done.clone(),
            stop.clone(),
        );
        let mut job = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            let mut r = std::fs::File::open(&f)?;
            let mut w = std::fs::File::create(&p)?;
            let mut buf = vec![0u8; 1 << 20];
            loop {
                if st.load(Ordering::Relaxed) {
                    return Err(std::io::Error::other("cancelled"));
                }
                let n = r.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                std::io::Write::write_all(&mut w, &buf[..n])?;
                d.fetch_add(n as u64, Ordering::Relaxed);
            }
            w.sync_all()
        });
        let id = cm.id.clone();
        loop {
            tokio::select! {
                r = &mut job => {
                    return r
                        .map_err(|e| Error::internal(format!("copy: {e}")))?
                        .map_err(|e| Error::internal(format!("copy {}: {e}", from.display())));
                }
                _ = cancel.changed() => {
                    stop.store(true, Ordering::Relaxed);
                }
                _ = tokio::time::sleep(Duration::from_millis(250)) => {
                    let n = done.load(Ordering::Relaxed);
                    self.set_progress(&id, |p| p.done = n);
                    self.publish_model(&id, false);
                }
            }
        }
    }

    /// Hash the `.part` file; if it is the model, make it read-only, move it into `models/` and record it as checked.
    async fn verify_and_place(
        &self,
        cm: &CatalogModel,
        part: &Path,
        cancel: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        self.set_progress(&cm.id, |p| {
            p.state = "verifying";
            p.done = 0;
            p.speed = None;
        });
        self.publish_model(&cm.id, true);
        self.verify_file(cm, part, cancel).await?;
        let dest = self.model_path(&cm.id);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(part, std::fs::Permissions::from_mode(0o444))?;
        }
        #[cfg(windows)]
        {
            let mut p = std::fs::metadata(part)?.permissions();
            p.set_readonly(true);
            std::fs::set_permissions(part, p)?;
        }
        std::fs::rename(part, &dest)?;
        let stamp = db::FileStamp::of(&dest)?;
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db::model_set(
            &db,
            &db::ModelRow {
                id: cm.id.clone(),
                state: "ready".into(),
                size: cm.size,
                sha256: cm.sha256.clone(),
                verified: Some(stamp),
            },
            now_ms(),
        )?;
        Ok(())
    }

    /// SHA-256 and size against the catalog; a mismatch deletes the file (`hash_mismatch`).
    async fn verify_file(
        &self,
        cm: &CatalogModel,
        path: &Path,
        cancel: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let done = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (p, c, d, st) = (path.to_path_buf(), cm.clone(), done.clone(), stop.clone());
        let mut job = tokio::task::spawn_blocking(move || check_file(&p, &c, &d, &st));
        let result = loop {
            tokio::select! {
                r = &mut job => break r,
                _ = cancel.changed() => stop.store(true, Ordering::Relaxed),
                _ = tokio::time::sleep(Duration::from_millis(250)) => {
                    let n = done.load(Ordering::Relaxed);
                    self.set_progress(&cm.id, |p| p.done = n);
                    self.publish_model(&cm.id, false);
                }
            }
        };
        match result.map_err(|e| Error::internal(format!("check: {e}")))? {
            Ok(None) => Ok(()),
            Ok(Some(why)) => {
                let _ = std::fs::remove_file(path);
                Err(Error::new(
                    code::HASH_MISMATCH,
                    format!(
                        "the file does not match what this version of Antenna expects ({why}); it was deleted"
                    ),
                ))
            }
            Err(e) => Err(Error::internal(format!("check {}: {e}", path.display()))),
        }
    }

    /// Before a load: the model file is there and unchanged since its check, or it is checked again now (and deleted
    /// if it no longer matches).
    pub(crate) async fn model_checked(&self, id: &str) -> Result<PathBuf> {
        let cm = self.catalog_model(id)?;
        let path = self.model_path(id);
        let row = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::models(&db)?.into_iter().find(|r| r.id == id)
        };
        let now = db::FileStamp::of(&path).map_err(|_| {
            Error::new(
                code::NOT_FOUND,
                format!(
                    "{} is not on this computer: install it in Local models",
                    cm.name
                ),
            )
        })?;
        let same = row.as_ref().is_some_and(|r| {
            r.state == "ready"
                && r.sha256 == cm.sha256
                && r.size == cm.size
                && r.verified == Some(now)
        });
        if same {
            return Ok(path);
        }
        tracing::info!("local model {id}: the file changed since its check; checking it again");
        let (_tx, mut rx) = tokio::sync::watch::channel(false);
        let r = self.verify_file(&cm, &path, &mut rx).await;
        self.clear_progress(id);
        match r {
            Ok(()) => {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                db::model_set(
                    &db,
                    &db::ModelRow {
                        id: id.into(),
                        state: "ready".into(),
                        size: cm.size,
                        sha256: cm.sha256.clone(),
                        verified: Some(db::FileStamp::of(&path)?),
                    },
                    now_ms(),
                )?;
                drop(db);
                self.publish_model(id, true);
                Ok(path)
            }
            Err(e) => {
                {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    let _ = db::model_delete(&db, id);
                }
                self.fail_model(id, e.code, e.message.clone());
                Err(e)
            }
        }
    }

    /// `model_remove`: cancel a download, unload the model, delete its file. Its local agents stay (`no_model`).
    pub async fn model_remove(self: &Arc<Self>, id: &str) -> Result<LocalModelInfo> {
        self.catalog_model(id)?;
        let job = self
            .local
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        if let Some(tx) = job {
            let _ = tx.send(true);
            // Let the job see the flag and stop its `curl`.
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.local_stop_agents_of(id).await;
        self.local.pool.unload(id).await;
        let _ = std::fs::remove_dir_all(self.dl_dir(id));
        let path = self.model_path(id);
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::model_delete(&db, id)?;
        }
        self.clear_progress(id);
        tracing::info!("local model {id}: removed");
        self.publish_model(id, true);
        self.publish_local_agents_of(id);
        self.model_info(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use antenna_proto::models::Catalog;

    fn model_for(bytes: &[u8]) -> CatalogModel {
        let mut m = Catalog::builtin().unwrap().models[0].clone();
        m.size = bytes.len() as u64;
        m.sha256 = data_encoding::HEXLOWER.encode(&sha2::Sha256::digest(bytes));
        m
    }

    #[test]
    fn a_file_is_the_model_only_with_its_exact_size_and_hash() {
        let t = tempfile::tempdir().unwrap();
        let good = b"GGUF a tiny test model".repeat(1000);
        let cm = model_for(&good);
        let p = t.path().join("m.gguf.part");
        let (done, cancel) = (AtomicU64::new(0), AtomicBool::new(false));
        std::fs::write(&p, &good).unwrap();
        assert_eq!(check_file(&p, &cm, &done, &cancel).unwrap(), None);
        assert_eq!(done.load(Ordering::Relaxed), good.len() as u64);
        // One byte changed: same size, another hash.
        let mut bad = good.clone();
        bad[100] ^= 1;
        std::fs::write(&p, &bad).unwrap();
        let why = check_file(&p, &cm, &done, &cancel).unwrap().unwrap();
        assert!(why.contains("SHA-256"), "{why}");
        // Short: refused by its size, before any hashing.
        std::fs::write(&p, &good[..10]).unwrap();
        let why = check_file(&p, &cm, &done, &cancel).unwrap().unwrap();
        assert!(why.contains("10 bytes"), "{why}");
        // Cancelled: no verdict.
        std::fs::write(&p, &good).unwrap();
        cancel.store(true, Ordering::Relaxed);
        assert!(check_file(&p, &cm, &done, &cancel).is_err());
    }

    #[test]
    fn a_download_needs_room_for_the_rest_of_the_file_and_more() {
        // 2.74 GB from scratch: the file, 10 %, 1 GB.
        assert_eq!(
            space_needed(2_740_000_000, 0),
            2_740_000_000 + 274_000_000 + GB
        );
        // Resumed at 2 GB: only the rest of the file is new.
        assert_eq!(
            space_needed(2_740_000_000, 2_000_000_000),
            740_000_000 + 274_000_000 + GB
        );
        // A .part file longer than the model (it is deleted before the download) asks for no negative room.
        assert_eq!(space_needed(100, 1_000), 10 + GB);
    }
}
