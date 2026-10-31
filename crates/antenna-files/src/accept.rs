// SPDX-License-Identifier: AGPL-3.0-only
//! Writing an accepted file into `inbox/`, `shared/` or the project folder (SPEC §10 steps 5–6).
//!
//! - the destination directory is opened component by component with `O_NOFOLLOW | O_DIRECTORY` from the daemon's base
//!   directory: a symlink in place of `inbox` cannot redirect the write into `~/.ssh`;
//! - the file is created under a hidden temporary name with `O_CREAT | O_EXCL | O_NOFOLLOW`, mode `0600` (no exec
//!   bits), then `renameat2(RENAME_NOREPLACE)`: an existing file (or a hard link to someone else's file) is never
//!   overwritten;
//! - case duplicates (`Report.pdf` next to `report.pdf`) are rejected: on macOS/Windows they are the same file;
//! - plaintext is written only after decryption and STREAM verification; if the final length and BLAKE3 do not match
//!   the manifest, the temporary file is deleted and nothing appears in the directory.
//!
//! Limit (CONTROL §11): an agent with the same uid can swap the base directory `~/Antenna/links` itself; the file
//! system does not protect against a process with the owner's rights. The protection here is against names and paths
//! sent by the contact.
//!
//! Windows: not ported yet (D-134, WP-21, phase W3). No destination folder is opened there, so every function that
//! would write or read a folder refuses with `not_implemented` and a received file stays held in quarantine.

use std::collections::{HashMap, HashSet};
#[cfg(unix)]
use std::os::fd::OwnedFd;
use std::path::Path;

#[cfg(unix)]
use rustix::fs::{AtFlags, Mode, OFlags};

use crate::error::{Error, Result, code};
use crate::names::{MAX_NAME_BYTES, fold_key};

#[cfg(unix)]
fn io(e: impl std::fmt::Display) -> Error {
    Error::internal(format!("accept: {e}"))
}

/// An open destination folder: a directory descriptor opened without following symlinks ([`open_dir_nofollow`]).
#[cfg(unix)]
pub type DestDir = OwnedFd;

/// Opens `base/rel...` component by component without following symlinks; missing directories are created (0700).
#[cfg(unix)]
pub fn open_dir_nofollow(base: &Path, rel: &[&str]) -> Result<DestDir> {
    let dir_flags = OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::RDONLY | OFlags::CLOEXEC;
    let mut fd = rustix::fs::open(base, dir_flags, Mode::empty()).map_err(|e| {
        Error::new(
            code::FORBIDDEN,
            format!("destination base is not a plain directory: {e}"),
        )
    })?;
    for comp in rel {
        if comp.is_empty() || *comp == "." || *comp == ".." || comp.contains('/') {
            return Err(Error::new(code::BAD_NAME, "bad destination component"));
        }
        match rustix::fs::mkdirat(&fd, *comp, Mode::from_raw_mode(0o700)) {
            Ok(()) | Err(rustix::io::Errno::EXIST) => {}
            Err(e) => return Err(io(e)),
        }
        fd = rustix::fs::openat(&fd, *comp, dir_flags, Mode::empty()).map_err(|e| {
            Error::new(
                code::FORBIDDEN,
                format!("destination is not a plain directory (symlink?): {e}"),
            )
        })?;
    }
    Ok(fd)
}

/// Opens an existing regular file `base/rel…` for reading without following symlinks at any step (a file from
/// `shared/` requested by the contact). Every component must be a safe name ([`crate::names::archive_path_problem`]).
#[cfg(unix)]
pub fn open_file_nofollow(base: &Path, rel: &[&str]) -> Result<std::fs::File> {
    let (last, dirs) = rel
        .split_last()
        .ok_or_else(|| Error::new(code::BAD_NAME, "empty path"))?;
    let dir_flags = OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::RDONLY | OFlags::CLOEXEC;
    let mut fd = rustix::fs::open(base, dir_flags, Mode::empty())
        .map_err(|_| Error::new(code::NOT_FOUND, "no such file"))?;
    for comp in dirs.iter().chain(std::iter::once(last)) {
        if crate::names::archive_path_problem(comp).is_some() || comp.is_empty() || *comp == "." {
            return Err(Error::new(code::BAD_NAME, "bad path component"));
        }
    }
    for comp in dirs {
        fd = rustix::fs::openat(&fd, *comp, dir_flags, Mode::empty())
            .map_err(|_| Error::new(code::NOT_FOUND, "no such file (or a symlink on the way)"))?;
    }
    let f = rustix::fs::openat(
        &fd,
        *last,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
        Mode::empty(),
    )
    .map_err(|_| Error::new(code::NOT_FOUND, "no such file (or a symlink)"))?;
    let st = rustix::fs::fstat(&f).map_err(io)?;
    if rustix::fs::FileType::from_raw_mode(st.st_mode) != rustix::fs::FileType::RegularFile {
        return Err(Error::new(code::BAD_NAME, "not a regular file"));
    }
    Ok(std::fs::File::from(f))
}

/// The entry of the directory whose name equals `name` ignoring case and Unicode normalization form, if any.
#[cfg(unix)]
pub fn existing_name(dir: &DestDir, name: &str) -> Result<Option<String>> {
    let key = fold_key(name);
    let dup = rustix::fs::openat(
        dir,
        ".",
        OFlags::DIRECTORY | OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io)?;
    let mut d = rustix::fs::Dir::read_from(&dup).map_err(io)?;
    while let Some(ent) = d.read() {
        let ent = ent.map_err(io)?;
        let n = ent.file_name().to_string_lossy().into_owned();
        if n != "." && n != ".." && fold_key(&n) == key {
            return Ok(Some(n));
        }
    }
    Ok(None)
}

/// Whether the entry `name` of the directory is a regular file (not followed if a symlink) with exactly this size and
/// BLAKE3: a received file that is already there (preview.8: accepted without a second copy).
#[cfg(unix)]
pub fn same_content(dir: &DestDir, name: &str, size: u64, blake3: &[u8; 32]) -> Result<bool> {
    let Ok(f) = rustix::fs::openat(
        dir,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
        Mode::empty(),
    ) else {
        return Ok(false);
    };
    let st = rustix::fs::fstat(&f).map_err(io)?;
    if rustix::fs::FileType::from_raw_mode(st.st_mode) != rustix::fs::FileType::RegularFile
        || st.st_size as u64 != size
    {
        return Ok(false);
    }
    let mut h = blake3::Hasher::new();
    h.update_reader(std::fs::File::from(f)).map_err(io)?;
    Ok(h.finalize().as_bytes() == blake3)
}

/// How many names an accept tries for one file: the contact's name, then `<stem> (2).<ext>` … `(1000)`. After that the
/// accept fails with `file_name_taken` and the owner chooses a name. The same bound as the number a receipt may name.
pub const NAME_ATTEMPTS: u32 = antenna_proto::ReceiptBody::MAX_NAME_NUMBER;

/// Extensions kept whole when a number goes in front of them (`report (2).tar.gz`, not `report.tar (2).gz`).
const DOUBLE_EXTENSIONS: [&str; 4] = [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst"];

/// The `n`-th name for `name` (`n` ≥ 2): `<stem> (n).<ext>`, the way browsers and file managers number a copy. A double
/// extension such as `.tar.gz` stays whole; a dot file (`.env`) and a name without an extension get the number at the
/// end. The stem is shortened at a character boundary so the result stays within [`MAX_NAME_BYTES`].
pub fn numbered_name(name: &str, n: u32) -> String {
    let lower = name.to_ascii_lowercase();
    let ext_len = DOUBLE_EXTENSIONS
        .iter()
        .find(|e| lower.ends_with(*e) && lower.len() > e.len())
        .map(|e| e.len())
        .or_else(|| name.rfind('.').filter(|i| *i > 0).map(|i| name.len() - i))
        .unwrap_or(0);
    let (stem, ext) = name.split_at(name.len() - ext_len);
    let tag = format!(" ({n})");
    let room = MAX_NAME_BYTES.saturating_sub(tag.len() + ext.len());
    let mut cut = stem.len().min(room);
    while !stem.is_char_boundary(cut) {
        cut -= 1;
    }
    // A shortened stem must not end in a space or a dot before the tag.
    let stem = stem[..cut].trim_end_matches([' ', '.']);
    format!("{stem}{tag}{ext}")
}

/// Which number `saved` is among the numbered names of `name` (ignoring case and Unicode form): `n` for
/// `<stem> (n).<ext>`, 0 for `name` itself or any other name.
pub fn name_number(name: &str, saved: &str) -> u32 {
    let key = fold_key(saved);
    (2..=NAME_ATTEMPTS)
        .find(|n| fold_key(&numbered_name(name, *n)) == key)
        .unwrap_or(0)
}

/// The names an accept may give a file called `name`, in order: `name`, then its numbered names ([`NAME_ATTEMPTS`] in
/// all).
fn candidates(name: &str) -> impl Iterator<Item = String> + '_ {
    std::iter::once(name.to_string())
        .chain((2..=NAME_ATTEMPTS).map(move |n| numbered_name(name, n)))
}

/// Every entry name of the directory (one read of it).
#[cfg(unix)]
fn entries(dir: &DestDir) -> Result<Vec<String>> {
    let dup = rustix::fs::openat(
        dir,
        ".",
        OFlags::DIRECTORY | OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io)?;
    let mut d = rustix::fs::Dir::read_from(&dup).map_err(io)?;
    let mut out = Vec::new();
    while let Some(ent) = d.read() {
        let ent = ent.map_err(io)?;
        let n = ent.file_name().to_string_lossy().into_owned();
        if n != "." && n != ".." {
            out.push(n);
        }
    }
    Ok(out)
}

/// A file already in the directory, under `name` or one of its numbered names (ignoring case and Unicode form), with
/// exactly this size and BLAKE3: a re-sent copy of a file saved before, accepted without another copy. The contact's
/// name is looked at first, then the numbered names in order.
pub fn existing_copy(
    dir: &DestDir,
    name: &str,
    size: u64,
    blake3: &[u8; 32],
) -> Result<Option<String>> {
    let order: HashMap<String, u32> = candidates(name)
        .zip(1u32..)
        .map(|(c, i)| (fold_key(&c), i))
        .collect();
    let mut found: Vec<(u32, String)> = entries(dir)?
        .into_iter()
        .filter_map(|e| order.get(&fold_key(&e)).map(|i| (*i, e)))
        .collect();
    found.sort();
    for (_, e) in found {
        if same_content(dir, &e, size, blake3)? {
            return Ok(Some(e));
        }
    }
    Ok(None)
}

/// A free name for `name` in the directory: `name` itself, else the first free numbered name (`report (2).pdf`, …).
/// This is what an accept would choose now; the accept claims its name itself ([`Incoming::commit_numbered`]).
pub fn free_name(dir: &DestDir, name: &str) -> Result<String> {
    let taken: HashSet<String> = entries(dir)?.iter().map(|e| fold_key(e)).collect();
    candidates(name)
        .find(|c| !taken.contains(&fold_key(c)))
        .ok_or_else(no_free_name)
}

fn no_free_name() -> Error {
    Error::new(
        code::NAME_TAKEN,
        format!(
            "the name and its numbered names up to ({NAME_ATTEMPTS}) are all taken in the folder: choose another name"
        ),
    )
}

/// Whether the directory has a name equal to `name` ignoring case and Unicode normalization form.
#[cfg(unix)]
pub fn name_taken(dir: &DestDir, name: &str) -> Result<bool> {
    let key = fold_key(name);
    let dup = rustix::fs::openat(
        dir,
        ".",
        OFlags::DIRECTORY | OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io)?;
    let mut d = rustix::fs::Dir::read_from(&dup).map_err(io)?;
    while let Some(ent) = d.read() {
        let ent = ent.map_err(io)?;
        let n = ent.file_name().to_string_lossy();
        if n == "." || n == ".." {
            continue;
        }
        if fold_key(&n) == key {
            return Ok(true);
        }
    }
    Ok(false)
}

/// File for writing the content being accepted.
///
/// On Linux, an unnamed `O_TMPFILE` file in the destination directory: while decryption and verification run it is
/// not visible in the directory (neither to the agent nor to indexers), and if the daemon crashes it disappears by
/// itself; the name appears only in [`Incoming::commit`] via `linkat`, which never replaces an existing file. Where
/// `O_TMPFILE` is unavailable: a hidden temporary name `.antenna-incoming-…` (`O_EXCL`, `O_NOFOLLOW`) and
/// `renameat2(RENAME_NOREPLACE)`; leftovers after a crash are removed by [`remove_stale_incoming`].
#[cfg(unix)]
pub struct Incoming {
    dir: DestDir,
    /// Temporary name (empty for `O_TMPFILE` and after commit).
    tmp: String,
    file: Option<std::fs::File>,
}

/// Prefix of hidden temporary files during acceptance.
pub const INCOMING_PREFIX: &str = ".antenna-incoming-";
/// The same prefix in the earlier `x` builds: their leftovers after a crash are removed too.
pub const LEGACY_INCOMING_PREFIX: &str = ".x-incoming-";

#[cfg(unix)]
impl Incoming {
    /// Creates a file for writing in directory `dir` (0600).
    pub fn create(dir: DestDir) -> Result<Self> {
        #[cfg(target_os = "linux")]
        match rustix::fs::openat(
            &dir,
            ".",
            OFlags::TMPFILE | OFlags::WRONLY | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        ) {
            Ok(fd) => {
                return Ok(Self {
                    dir,
                    tmp: String::new(),
                    file: Some(std::fs::File::from(fd)),
                });
            }
            Err(
                rustix::io::Errno::OPNOTSUPP | rustix::io::Errno::ISDIR | rustix::io::Errno::INVAL,
            ) => {}
            Err(e) => return Err(io(e)),
        }
        let tmp = format!(
            "{INCOMING_PREFIX}{}",
            data_encoding::HEXLOWER.encode(&crate::crypt::random_bytes::<8>())
        );
        let fd = rustix::fs::openat(
            &dir,
            tmp.as_str(),
            OFlags::CREATE | OFlags::EXCL | OFlags::WRONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )
        .map_err(io)?;
        Ok(Self {
            dir,
            tmp,
            file: Some(std::fs::File::from(fd)),
        })
    }

    /// The file to write to.
    pub fn file(&mut self) -> &mut std::fs::File {
        self.file.as_mut().expect("open until commit")
    }

    /// Finishes: fsync, mode 0600 (no exec), atomically gives it the name `name` without replacing an existing file.
    pub fn commit(mut self, name: &str) -> Result<()> {
        let f = self.finish()?;
        if name_taken(&self.dir, name)? {
            return Err(Error::new(
                code::NAME_TAKEN,
                "a file with this name (ignoring case) already exists",
            ));
        }
        match self.claim(&f, name) {
            Ok(()) => Ok(()),
            Err(rustix::io::Errno::EXIST) => Err(Error::new(
                code::NAME_TAKEN,
                "a file with this name already exists",
            )),
            Err(e) => Err(io(e)),
        }
    }

    /// Finishes like [`Incoming::commit`] under `name` or, when a file has that name (ignoring case), under the first
    /// free numbered name (`report (2).pdf`, …); returns the name it got. Each name is claimed with the same exclusive
    /// step as `commit` (it fails rather than replace), so when another accept takes a name between the look at the
    /// folder and the claim, this one moves on to the next number: two accepts never get the same name and neither
    /// replaces the other's file. After [`NAME_ATTEMPTS`] names: `file_name_taken`.
    pub fn commit_numbered(self, name: &str) -> Result<String> {
        self.commit_numbered_with(name, |_| {})
    }

    /// [`Incoming::commit_numbered`] with `before_claim` called right before each claim (tests take a name there, as
    /// a concurrent accept would).
    fn commit_numbered_with(
        mut self,
        name: &str,
        mut before_claim: impl FnMut(&str),
    ) -> Result<String> {
        let f = self.finish()?;
        let mut taken: HashSet<String> = entries(&self.dir)?.iter().map(|e| fold_key(e)).collect();
        for c in candidates(name) {
            let key = fold_key(&c);
            if taken.contains(&key) {
                continue;
            }
            before_claim(&c);
            match self.claim(&f, &c) {
                Ok(()) => return Ok(c),
                Err(rustix::io::Errno::EXIST) => {
                    taken.insert(key);
                }
                Err(e) => return Err(io(e)),
            }
        }
        Err(no_free_name())
    }

    /// fsync and mode 0600 (no exec) before the file gets a name; the file stays open for [`Incoming::claim`].
    fn finish(&mut self) -> Result<std::fs::File> {
        let f = self.file.take().expect("open until commit");
        // macOS: a received file carries the quarantine attribute a browser gives a download, so Gatekeeper checks a
        // program or a disk image when it is opened (D-130). Set before the file has a name; a volume without extended
        // attributes saves it without one.
        #[cfg(target_os = "macos")]
        {
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let value = format!("0081;{secs:08x};Antenna;");
            if let Err(e) = rustix::fs::fsetxattr(
                &f,
                "com.apple.quarantine",
                value.as_bytes(),
                rustix::fs::XattrFlags::empty(),
            ) {
                tracing::debug!("accept: quarantine attribute not set: {e}");
            }
        }
        f.sync_all().map_err(io)?;
        rustix::fs::fchmod(&f, Mode::from_raw_mode(0o600)).map_err(io)?;
        Ok(f)
    }

    /// Gives the written file the name `name` in one exclusive step, the `O_EXCL` of naming a finished file: `linkat`
    /// of the unnamed `O_TMPFILE` file, `renameat2(RENAME_NOREPLACE)` of the hidden temporary name, or `linkat` where
    /// there is no `renameat2`. Each fails with `EEXIST` when the name exists and never replaces a file.
    fn claim(&mut self, f: &std::fs::File, name: &str) -> rustix::io::Result<()> {
        let r = if self.tmp.is_empty() {
            // O_TMPFILE: give the unnamed file a name; linkat does not replace an existing one.
            use std::os::fd::AsRawFd;
            let proc_path = format!("/proc/self/fd/{}", f.as_raw_fd());
            rustix::fs::linkat(
                rustix::fs::CWD,
                proc_path.as_str(),
                &self.dir,
                name,
                AtFlags::SYMLINK_FOLLOW,
            )
        } else {
            #[cfg(target_os = "linux")]
            let r = rustix::fs::renameat_with(
                &self.dir,
                self.tmp.as_str(),
                &self.dir,
                name,
                rustix::fs::RenameFlags::NOREPLACE,
            );
            #[cfg(not(target_os = "linux"))]
            let r = rustix::fs::linkat(
                &self.dir,
                self.tmp.as_str(),
                &self.dir,
                name,
                AtFlags::empty(),
            )
            .and_then(|_| rustix::fs::unlinkat(&self.dir, self.tmp.as_str(), AtFlags::empty()));
            r
        };
        if r.is_ok() {
            self.tmp.clear();
        }
        r
    }
}

#[cfg(unix)]
impl Drop for Incoming {
    fn drop(&mut self) {
        self.file.take();
        if !self.tmp.is_empty() {
            let _ = rustix::fs::unlinkat(&self.dir, self.tmp.as_str(), AtFlags::empty());
        }
    }
}

/// Removes acceptance leftovers after a daemon crash (`.antenna-incoming-*` and the legacy `.x-incoming-*` in
/// directory `base/rel…`). Call at startup.
#[cfg(unix)]
pub fn remove_stale_incoming(base: &Path, rel: &[&str]) -> Result<usize> {
    let dir = open_dir_nofollow(base, rel)?;
    let dup = rustix::fs::openat(
        &dir,
        ".",
        OFlags::DIRECTORY | OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io)?;
    let mut d = rustix::fs::Dir::read_from(&dup).map_err(io)?;
    let mut stale = Vec::new();
    while let Some(ent) = d.read() {
        let ent = ent.map_err(io)?;
        let n = ent.file_name().to_string_lossy().into_owned();
        if n.starts_with(INCOMING_PREFIX) || n.starts_with(LEGACY_INCOMING_PREFIX) {
            stale.push(n);
        }
    }
    for n in &stale {
        let _ = rustix::fs::unlinkat(&dir, n.as_str(), AtFlags::empty());
    }
    Ok(stale.len())
}

/// Windows: an open destination folder. None is ever made yet: saving there (each folder opened without following
/// reparse points, `CREATE_NEW`, the final path compared with the expected long name, Mark of the Web) is WP-21, phase
/// W3 (D-134), so [`open_dir_nofollow`] refuses and nothing that takes a folder is reached.
#[cfg(windows)]
pub struct DestDir(());

#[cfg(windows)]
fn not_ported(what: &str) -> Error {
    Error::new(
        code::NOT_IMPLEMENTED,
        format!("{what} is not available on Windows yet"),
    )
}

/// Windows: refused (WP-21), nothing is created.
#[cfg(windows)]
pub fn open_dir_nofollow(_base: &Path, _rel: &[&str]) -> Result<DestDir> {
    Err(not_ported("saving received files"))
}

/// Windows: refused (WP-21): a contact's request for a file from `shared/` is not served.
#[cfg(windows)]
pub fn open_file_nofollow(_base: &Path, _rel: &[&str]) -> Result<std::fs::File> {
    Err(not_ported("sending files from shared/"))
}

/// Windows: refused (WP-21).
#[cfg(windows)]
pub fn existing_name(_dir: &DestDir, _name: &str) -> Result<Option<String>> {
    Err(not_ported("saving received files"))
}

/// Windows: refused (WP-21).
#[cfg(windows)]
pub fn same_content(_dir: &DestDir, _name: &str, _size: u64, _blake3: &[u8; 32]) -> Result<bool> {
    Err(not_ported("saving received files"))
}

#[cfg(windows)]
fn entries(_dir: &DestDir) -> Result<Vec<String>> {
    Err(not_ported("saving received files"))
}

/// Windows: refused (WP-21).
#[cfg(windows)]
pub fn name_taken(_dir: &DestDir, _name: &str) -> Result<bool> {
    Err(not_ported("saving received files"))
}

/// Windows: never made ([`Incoming::create`] refuses, WP-21).
#[cfg(windows)]
pub struct Incoming {
    file: std::fs::File,
}

#[cfg(windows)]
impl Incoming {
    /// Windows: refused (WP-21).
    pub fn create(_dir: DestDir) -> Result<Self> {
        Err(not_ported("saving received files"))
    }

    /// The file to write to.
    pub fn file(&mut self) -> &mut std::fs::File {
        &mut self.file
    }

    /// Windows: refused (WP-21).
    pub fn commit(self, _name: &str) -> Result<()> {
        Err(not_ported("saving received files"))
    }

    /// Windows: refused (WP-21).
    pub fn commit_numbered(self, _name: &str) -> Result<String> {
        Err(not_ported("saving received files"))
    }
}

/// Windows: refused (WP-21); nothing can be left over there, since nothing is saved.
#[cfg(windows)]
pub fn remove_stale_incoming(_base: &Path, _rel: &[&str]) -> Result<usize> {
    Err(not_ported("saving received files"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // A unix symlink; Windows reparse points come with WP-21.
    #[cfg(unix)]
    #[test]
    fn symlinked_destination_is_refused() {
        let t = tempfile::tempdir().unwrap();
        let target = t.path().join("secret");
        std::fs::create_dir(&target).unwrap();
        std::fs::create_dir(t.path().join("links")).unwrap();
        std::os::unix::fs::symlink(&target, t.path().join("links/inbox")).unwrap();
        let e = open_dir_nofollow(&t.path().join("links"), &["inbox"])
            .err()
            .unwrap();
        assert_eq!(e.code, code::FORBIDDEN);
    }

    /// Acceptance leftovers after a crash are removed, both ours and those of the earlier `x` builds; owner files
    /// are not.
    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn stale_incoming_of_both_builds_is_removed() {
        let t = tempfile::tempdir().unwrap();
        let inbox = t.path().join("alice/inbox");
        std::fs::create_dir_all(&inbox).unwrap();
        for n in [
            ".antenna-incoming-0011",
            ".x-incoming-0022",
            "keep.txt",
            ".hidden",
        ] {
            std::fs::write(inbox.join(n), b"x").unwrap();
        }
        assert_eq!(
            remove_stale_incoming(t.path(), &["alice", "inbox"]).unwrap(),
            2
        );
        let mut left: Vec<_> = std::fs::read_dir(&inbox)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, [".hidden", "keep.txt"]);
    }

    // Unix modes; Windows saving is WP-21.
    #[cfg(unix)]
    #[test]
    fn commit_does_not_replace_and_has_no_exec() {
        let t = tempfile::tempdir().unwrap();
        let dir = open_dir_nofollow(t.path(), &["inbox"]).unwrap();
        let mut inc = Incoming::create(dir).unwrap();
        inc.file().write_all(b"one").unwrap();
        inc.commit("a.txt").unwrap();
        let p = t.path().join("inbox/a.txt");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // The same name and a case duplicate: rejected, the old content stays in place.
        for n in ["a.txt", "A.TXT"] {
            let dir = open_dir_nofollow(t.path(), &["inbox"]).unwrap();
            let mut inc = Incoming::create(dir).unwrap();
            inc.file().write_all(b"two").unwrap();
            assert_eq!(inc.commit(n).unwrap_err().code, code::NAME_TAKEN);
        }
        assert_eq!(std::fs::read(&p).unwrap(), b"one");
        // While writing: on Linux the directory has neither the name nor a temporary file (O_TMPFILE); where
        // O_TMPFILE is unavailable (macOS), only a hidden temporary name with the acceptance prefix, never the
        // contact's file name.
        let dir = open_dir_nofollow(t.path(), &["inbox"]).unwrap();
        let mut inc = Incoming::create(dir).unwrap();
        inc.file().write_all(b"in progress").unwrap();
        let during: Vec<String> = std::fs::read_dir(t.path().join("inbox"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n != "a.txt")
            .collect();
        #[cfg(target_os = "linux")]
        assert!(during.is_empty(), "{during:?}");
        #[cfg(not(target_os = "linux"))]
        assert!(
            during.len() == 1 && during[0].starts_with(INCOMING_PREFIX),
            "{during:?}"
        );
        drop(inc);
        // No temporary files are left.
        let names: Vec<_> = std::fs::read_dir(t.path().join("inbox"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(names.len(), 1, "{names:?}");
    }

    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn hardlink_target_is_not_overwritten() {
        let t = tempfile::tempdir().unwrap();
        let victim = t.path().join("victim");
        std::fs::write(&victim, b"precious").unwrap();
        std::fs::create_dir(t.path().join("inbox")).unwrap();
        std::fs::hard_link(&victim, t.path().join("inbox/x.txt")).unwrap();
        let dir = open_dir_nofollow(t.path(), &["inbox"]).unwrap();
        let mut inc = Incoming::create(dir).unwrap();
        inc.file().write_all(b"evil").unwrap();
        assert_eq!(inc.commit("x.txt").unwrap_err().code, code::NAME_TAKEN);
        assert_eq!(std::fs::read(&victim).unwrap(), b"precious");
    }

    fn incoming(base: &Path, content: &[u8]) -> Incoming {
        let dir = open_dir_nofollow(base, &["shared"]).unwrap();
        let mut inc = Incoming::create(dir).unwrap();
        inc.file().write_all(content).unwrap();
        inc
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn numbered_names_keep_the_extension_and_the_length_limit() {
        for (name, n, want) in [
            ("report.pdf", 2, "report (2).pdf"),
            ("report.tar.gz", 3, "report (3).tar.gz"),
            (".env", 2, ".env (2)"),
            ("Makefile", 2, "Makefile (2)"),
            ("DECISIONS.md", 10, "DECISIONS (10).md"),
        ] {
            assert_eq!(numbered_name(name, n), want);
        }
        // At the length limit the stem gives way, at a character boundary, and the result is a valid name.
        let long = format!("{}.txt", "é".repeat(125));
        assert_eq!(long.len(), 254);
        for n in [2, 1000] {
            let c = numbered_name(&long, n);
            assert!(c.len() <= MAX_NAME_BYTES, "{}", c.len());
            assert!(c.ends_with(&format!(" ({n}).txt")), "{c}");
            assert_eq!(crate::names::normalize(&c).unwrap(), c);
        }
    }

    /// A taken name (ignoring case): the next free number, the files already there untouched.
    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn a_numbered_commit_takes_the_next_free_name_and_replaces_nothing() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir(t.path().join("shared")).unwrap();
        std::fs::write(t.path().join("shared/Notes.txt"), b"one").unwrap();
        let got = incoming(t.path(), b"two")
            .commit_numbered("notes.txt")
            .unwrap();
        assert_eq!(got, "notes (2).txt");
        let got = incoming(t.path(), b"three")
            .commit_numbered("notes.txt")
            .unwrap();
        assert_eq!(got, "notes (3).txt");
        let shared = t.path().join("shared");
        assert_eq!(
            names(&shared),
            ["Notes.txt", "notes (2).txt", "notes (3).txt"]
        );
        assert_eq!(std::fs::read(shared.join("Notes.txt")).unwrap(), b"one");
        assert_eq!(
            std::fs::read(shared.join("notes (3).txt")).unwrap(),
            b"three"
        );
        // A free name is kept as it is.
        let got = incoming(t.path(), b"four")
            .commit_numbered("other.txt")
            .unwrap();
        assert_eq!(got, "other.txt");
    }

    /// Another accept takes the chosen name between the look at the folder and the claim: the claim fails instead of
    /// replacing that file, and this accept moves on to the next number. Negative control: a claim that replaces (an
    /// `unlinkat` of the name before the `linkat`) loses the other accept's file and fails this test.
    // `commit_numbered_with` is the unix claim; Windows saving is WP-21.
    #[cfg(unix)]
    #[test]
    fn a_name_taken_between_the_look_and_the_claim_moves_on_and_replaces_nothing() {
        let t = tempfile::tempdir().unwrap();
        let shared = t.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::write(shared.join("a.txt"), b"first").unwrap();
        let mut raced = 0;
        let got = incoming(t.path(), b"mine")
            .commit_numbered_with("a.txt", |c| {
                if raced == 0 {
                    raced += 1;
                    use std::io::Write as _;
                    let mut other = std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(shared.join(c))
                        .unwrap();
                    other.write_all(b"the other accept").unwrap();
                }
            })
            .unwrap();
        assert_eq!(got, "a (3).txt");
        assert_eq!(
            std::fs::read(shared.join("a (2).txt")).unwrap(),
            b"the other accept"
        );
        assert_eq!(std::fs::read(shared.join("a (3).txt")).unwrap(), b"mine");
        assert_eq!(names(&shared), ["a (2).txt", "a (3).txt", "a.txt"]);
    }

    /// Many accepts of the same name at once: each file gets its own name and every content is there once.
    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn concurrent_numbered_commits_get_distinct_names() {
        const N: usize = 12;
        let t = tempfile::tempdir().unwrap();
        let shared = t.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::write(shared.join("r.txt"), b"old").unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(N));
        let got: Vec<String> = std::thread::scope(|s| {
            let hs: Vec<_> = (0..N)
                .map(|i| {
                    let inc = incoming(t.path(), format!("content {i}").as_bytes());
                    let barrier = barrier.clone();
                    s.spawn(move || {
                        barrier.wait();
                        inc.commit_numbered("r.txt").unwrap()
                    })
                })
                .collect();
            hs.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let distinct: HashSet<&String> = got.iter().collect();
        assert_eq!(distinct.len(), N, "{got:?}");
        assert_eq!(names(&shared).len(), N + 1);
        let mut contents: Vec<Vec<u8>> = got
            .iter()
            .map(|n| std::fs::read(shared.join(n)).unwrap())
            .collect();
        contents.sort();
        let mut want: Vec<Vec<u8>> = (0..N)
            .map(|i| format!("content {i}").into_bytes())
            .collect();
        want.sort();
        assert_eq!(contents, want);
        assert_eq!(std::fs::read(shared.join("r.txt")).unwrap(), b"old");
    }

    /// The attempts are capped: with the name and every numbered name taken, `file_name_taken`, and nothing is left
    /// in the folder.
    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn numbered_commit_gives_up_after_the_cap() {
        let t = tempfile::tempdir().unwrap();
        let shared = t.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::write(shared.join("c.txt"), b"x").unwrap();
        for n in 2..=NAME_ATTEMPTS {
            std::fs::write(shared.join(numbered_name("c.txt", n)), b"x").unwrap();
        }
        let e = incoming(t.path(), b"new")
            .commit_numbered("c.txt")
            .unwrap_err();
        assert_eq!(e.code, code::NAME_TAKEN);
        assert_eq!(names(&shared).len(), NAME_ATTEMPTS as usize);
        let dir = open_dir_nofollow(t.path(), &["shared"]).unwrap();
        assert_eq!(free_name(&dir, "c.txt").unwrap_err().code, code::NAME_TAKEN);
        // One more free number would have been taken.
        std::fs::remove_file(shared.join(numbered_name("c.txt", 700))).unwrap();
        let got = incoming(t.path(), b"new").commit_numbered("c.txt").unwrap();
        assert_eq!(got, "c (700).txt");
    }

    /// A re-sent file is found under the contact's name or a numbered one, by size and BLAKE3.
    #[test]
    #[cfg_attr(windows, ignore = "WP-21 (W3): saving received files")]
    fn an_existing_copy_is_found_under_a_numbered_name() {
        let t = tempfile::tempdir().unwrap();
        let shared = t.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::write(shared.join("d.md"), b"v1").unwrap();
        std::fs::write(shared.join("D (2).md"), b"v2").unwrap();
        std::fs::write(shared.join("other.md"), b"v3").unwrap();
        let dir = open_dir_nofollow(t.path(), &["shared"]).unwrap();
        let h = |b: &[u8]| *blake3::hash(b).as_bytes();
        assert_eq!(
            existing_copy(&dir, "d.md", 2, &h(b"v1"))
                .unwrap()
                .as_deref(),
            Some("d.md")
        );
        assert_eq!(
            existing_copy(&dir, "d.md", 2, &h(b"v2"))
                .unwrap()
                .as_deref(),
            Some("D (2).md")
        );
        assert_eq!(existing_copy(&dir, "d.md", 2, &h(b"v3")).unwrap(), None);
        assert_eq!(free_name(&dir, "d.md").unwrap(), "d (3).md");
        assert_eq!(name_number("d.md", "D (2).md"), 2);
        assert_eq!(name_number("d.md", "d.md"), 0);
        assert_eq!(name_number("d.md", "other.md"), 0);
    }

    /// Windows refuses to save or serve files and creates nothing (WP-21); leftovers are not touched either.
    #[cfg(windows)]
    #[test]
    fn saving_and_serving_files_are_refused_on_windows() {
        let t = tempfile::tempdir().unwrap();
        let e = open_dir_nofollow(t.path(), &["alice", "inbox"])
            .err()
            .unwrap();
        assert_eq!(e.code, code::NOT_IMPLEMENTED);
        assert!(!t.path().join("alice").exists());
        std::fs::create_dir(t.path().join("shared")).unwrap();
        std::fs::write(t.path().join("shared/a.txt"), b"x").unwrap();
        assert_eq!(
            open_file_nofollow(t.path(), &["shared", "a.txt"])
                .unwrap_err()
                .code,
            code::NOT_IMPLEMENTED
        );
        std::fs::write(t.path().join("shared/.antenna-incoming-0011"), b"x").unwrap();
        assert_eq!(
            remove_stale_incoming(t.path(), &["shared"])
                .unwrap_err()
                .code,
            code::NOT_IMPLEMENTED
        );
        assert!(t.path().join("shared/.antenna-incoming-0011").exists());
    }
}
