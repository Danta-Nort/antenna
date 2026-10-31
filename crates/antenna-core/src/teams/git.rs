// SPDX-License-Identifier: AGPL-3.0-only
//! The daemon's git plumbing for teams (D-111 item 4). Only the daemon runs git, never inside a sandbox and never in
//! a folder a worker can write as the place git looks for its repository:
//!
//! - **Explicit repository.** Every call names the project's git directory (`--git-dir`), found once when the owner
//!   created the team, and a private index file of the daemon (`GIT_INDEX_FILE`) outside every sandbox. A worker's
//!   folder is only ever the work tree. A `.git` file or folder a worker plants there is not a repository git
//!   discovers (git never discovers one with `--git-dir`), and the snapshot refuses nested repositories outright.
//! - **No code from the repository's side.** Hooks are off (`core.hooksPath=/dev/null`), fsmonitor and automatic gc
//!   are off, diffs use no external diff or textconv driver; the environment is cleared except `PATH`, `HOME` and the
//!   locale, so a `GIT_DIR` of the daemon's own environment changes nothing.
//! - **Why not `git worktree`.** A worktree shares the project's object store and refs with the worker: worker A could
//!   read worker B's submitted commits (and the taint they carry) through `.git`, and could write any ref, including
//!   the project's branch. A daemon-managed checkout per worker, with commits made by the daemon, keeps each worker to
//!   its own folder (§3.7 item 3).

use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use antenna_proto::control::code;
use tokio::io::AsyncWriteExt;

use crate::error::{Error, Result};

/// How long one git call may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(300);
/// A result commit adds at most this many bytes of new files.
pub(crate) const MAX_RESULT_BYTES: u64 = 256 << 20;
/// A result commit changes at most this many files.
pub(crate) const MAX_RESULT_FILES: usize = 20_000;
/// The longest diff a reviewer gets.
pub(crate) const MAX_DIFF: usize = 256 * 1024;

/// What `git` call failed and how.
fn git_err(what: &str, out: &std::process::Output) -> Error {
    let err = String::from_utf8_lossy(&out.stderr);
    let first = err.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    Error::internal(format!(
        "git {what}: {}{}",
        first.chars().take(300).collect::<String>(),
        if first.is_empty() {
            format!("exit {:?}", out.status.code())
        } else {
            String::new()
        }
    ))
}

/// The `git` program: from the daemon's `PATH`, as the owner's terminal would find it.
fn git_program() -> PathBuf {
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|d| d.join("git"))
                .find(|c| c.is_file())
        })
        .unwrap_or_else(|| PathBuf::from("/usr/bin/git"))
}

/// A git command with the daemon's hardening and nothing of the daemon's environment but `PATH`, `HOME` and the
/// locale.
fn command() -> tokio::process::Command {
    let mut c = tokio::process::Command::new(git_program());
    c.env_clear();
    for k in ["PATH", "HOME", "XDG_CONFIG_HOME"] {
        if let Some(v) = std::env::var_os(k) {
            c.env(k, v);
        }
    }
    c.env("LANG", "C")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "core.quotePath=false",
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "core.autocrlf=false",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    c
}

async fn output(
    mut c: tokio::process::Command,
    input: Option<&[u8]>,
) -> Result<std::process::Output> {
    if input.is_some() {
        c.stdin(Stdio::piped());
    }
    let mut child = c
        .spawn()
        .map_err(|e| Error::internal(format!("git: cannot start git: {e}")))?;
    if let (Some(data), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(data)
            .await
            .map_err(|e| Error::internal(format!("git: input: {e}")))?;
    }
    tokio::time::timeout(GIT_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| Error::new(code::TIMEOUT, "git did not finish in 5 minutes"))?
        .map_err(|e| Error::internal(format!("git: {e}")))
}

fn trimmed(out: &std::process::Output) -> String {
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A full commit ID (40 or 64 hex digits).
pub(crate) fn is_oid(s: &str) -> bool {
    matches!(s.len(), 40 | 64) && s.chars().all(|c| c.is_ascii_hexdigit())
}

/// A branch name the daemon creates or accepts: `git check-ref-format`-safe ASCII without `..`, `@{` or a leading
/// `-`.
pub(crate) fn valid_branch(b: &str) -> bool {
    !b.is_empty()
        && b.len() <= 200
        && !b.starts_with('-')
        && !b.starts_with('/')
        && !b.ends_with('/')
        && !b.ends_with(".lock")
        && !b.contains("..")
        && !b.contains("@{")
        && !b.contains("//")
        && b.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.'))
}

/// The project as git sees it: its top folder, its git directory and the branch checked out there.
pub(crate) struct Project {
    /// `git rev-parse --show-toplevel`.
    pub top: PathBuf,
    /// `git rev-parse --git-common-dir`, absolute.
    pub git_dir: PathBuf,
    /// The branch checked out in it (`None`: a detached HEAD).
    pub branch: Option<String>,
}

/// Find the project: the owner's own repository, read with the owner's configuration (no worker has touched it).
pub(crate) async fn project(dir: &Path) -> Result<Project> {
    let mut c = command();
    c.arg("-C").arg(dir).args([
        "rev-parse",
        "--show-toplevel",
        "--git-common-dir",
        "--abbrev-ref",
        "HEAD",
    ]);
    let out = output(c, None).await?;
    if !out.status.success() {
        return Err(Error::bad_request(format!(
            "{} is not a git repository: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let text = trimmed(&out);
    let mut lines = text.lines();
    let top = PathBuf::from(lines.next().unwrap_or_default());
    let common = PathBuf::from(lines.next().unwrap_or_default());
    let branch = lines
        .next()
        .filter(|b| *b != "HEAD" && !b.is_empty())
        .map(str::to_string);
    let git_dir = if common.is_absolute() {
        common
    } else {
        top.join(common)
    };
    let git_dir = git_dir
        .canonicalize()
        .map_err(|e| Error::bad_request(format!("{}: {e}", git_dir.display())))?;
    Ok(Project {
        top,
        git_dir,
        branch,
    })
}

/// A merge into a branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Merged {
    /// The branch's new commit.
    pub commit: String,
    /// `fast_forward`, `merge`, or `nothing` (already contained).
    pub how: &'static str,
}

/// A recorded snapshot of a worker's folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Snapshot {
    /// The commit.
    pub commit: String,
    /// Files changed against the base.
    pub files: u32,
    /// Lines added.
    pub insertions: u64,
    /// Lines removed.
    pub deletions: u64,
}

/// Who a daemon-made commit is by.
pub(crate) struct Author<'a> {
    /// Name.
    pub name: &'a str,
    /// Email (`<worker>@antenna.invalid` for a worker).
    pub email: &'a str,
}

/// The project's repository, by its git directory.
#[derive(Debug, Clone)]
pub(crate) struct Repo {
    git_dir: PathBuf,
}

impl Repo {
    pub(crate) fn new(git_dir: &Path) -> Self {
        Self {
            git_dir: git_dir.to_path_buf(),
        }
    }

    fn cmd(&self) -> tokio::process::Command {
        let mut c = command();
        c.arg(format!("--git-dir={}", self.git_dir.display()));
        c
    }

    async fn run(&self, what: &str, args: &[&str]) -> Result<String> {
        let mut c = self.cmd();
        c.args(args);
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(git_err(what, &out));
        }
        Ok(trimmed(&out))
    }

    /// The commit a revision names, or `None`.
    pub(crate) async fn commit_of(&self, rev: &str) -> Result<Option<String>> {
        let mut c = self.cmd();
        c.args(["rev-parse", "--verify", "--quiet"])
            .arg(format!("{rev}^{{commit}}"));
        let out = output(c, None).await?;
        Ok(out
            .status
            .success()
            .then(|| trimmed(&out))
            .filter(|s| is_oid(s)))
    }

    /// The tip of a branch.
    pub(crate) async fn branch_tip(&self, branch: &str) -> Result<Option<String>> {
        self.commit_of(&format!("refs/heads/{branch}")).await
    }

    /// Point a branch at `new` if it is still at `old` (`None`: the branch must not exist yet).
    pub(crate) async fn set_branch(
        &self,
        branch: &str,
        new: &str,
        old: Option<&str>,
    ) -> Result<()> {
        if !valid_branch(branch) || !is_oid(new) {
            return Err(Error::internal("git: bad branch or commit"));
        }
        let r = format!("refs/heads/{branch}");
        self.run("update-ref", &["update-ref", &r, new, old.unwrap_or("")])
            .await
            .map(|_| ())
    }

    /// Delete a branch the daemon made (`team/<task>`).
    pub(crate) async fn delete_branch(&self, branch: &str) -> Result<()> {
        if !valid_branch(branch) {
            return Err(Error::internal("git: bad branch"));
        }
        let r = format!("refs/heads/{branch}");
        let _ = self.run("update-ref -d", &["update-ref", "-d", &r]).await;
        Ok(())
    }

    /// Whether `a` is an ancestor of `b`.
    async fn is_ancestor(&self, a: &str, b: &str) -> Result<bool> {
        let mut c = self.cmd();
        c.args(["merge-base", "--is-ancestor", a, b]);
        let out = output(c, None).await?;
        match out.status.code() {
            Some(0) => Ok(true),
            Some(1) => Ok(false),
            _ => Err(git_err("merge-base", &out)),
        }
    }

    /// Make `dir` a checkout of `commit` (everything in it before is removed), with the daemon's index for it.
    pub(crate) async fn checkout(&self, commit: &str, dir: &Path, index: &Path) -> Result<()> {
        if !is_oid(commit) {
            return Err(Error::internal("git: bad commit"));
        }
        if dir.exists() {
            std::fs::remove_dir_all(dir)?;
        }
        let _ = std::fs::remove_file(index);
        mkdir_private(dir)?;
        let mut c = self.cmd();
        c.arg(format!("--work-tree={}", dir.display()))
            .env("GIT_INDEX_FILE", index)
            .current_dir(dir)
            .args(["read-tree", "--reset", "-u", commit]);
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(git_err("read-tree", &out));
        }
        Ok(())
    }

    /// Record what is in `dir` now as a commit on top of `base`: the files git would add with `add -A` (the project's
    /// `.gitignore` rules hold), refused if they hold another repository or are too large.
    pub(crate) async fn snapshot(
        &self,
        dir: &Path,
        index: &Path,
        base: &str,
        message: &str,
        author: &Author<'_>,
    ) -> Result<Snapshot> {
        let tree = self.write_tree_of(dir, index).await?;
        self.check_size(base, &tree).await?;
        let mut c = self.cmd();
        c.args(["commit-tree", &tree, "-p", base, "-F", "-"])
            .env("GIT_AUTHOR_NAME", author.name)
            .env("GIT_AUTHOR_EMAIL", author.email)
            .env("GIT_COMMITTER_NAME", author.name)
            .env("GIT_COMMITTER_EMAIL", author.email);
        let out = output(c, Some(message.as_bytes())).await?;
        if !out.status.success() {
            return Err(git_err("commit-tree", &out));
        }
        let commit = trimmed(&out);
        let (files, insertions, deletions) = self.numstat(base, &commit).await?;
        Ok(Snapshot {
            commit,
            files,
            insertions,
            deletions,
        })
    }

    /// The tree object of what `add -A` takes from `dir` (written into the project's object store).
    async fn write_tree_of(&self, dir: &Path, index: &Path) -> Result<String> {
        if let Some(p) = nested_repository(dir)? {
            return Err(Error::bad_request(format!(
                "the folder holds another git repository at {}: remove it (results are recorded by the daemon; a \
                 worker does not need git)",
                p.display()
            )));
        }
        let mut c = self.cmd();
        c.arg(format!("--work-tree={}", dir.display()))
            .env("GIT_INDEX_FILE", index)
            .current_dir(dir)
            .args(["add", "-A", "--", "."]);
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(git_err("add", &out));
        }
        let mut c = self.cmd();
        c.env("GIT_INDEX_FILE", index).arg("write-tree");
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(git_err("write-tree", &out));
        }
        Ok(trimmed(&out))
    }

    /// Refuse a result with too many files, too many new bytes or a submodule entry.
    async fn check_size(&self, base: &str, tree: &str) -> Result<()> {
        let raw = self
            .run(
                "diff-tree",
                &["diff-tree", "-r", "--no-renames", "--raw", base, tree],
            )
            .await?;
        let mut blobs = Vec::new();
        for line in raw.lines() {
            // `:<old mode> <new mode> <old oid> <new oid> <status>\t<path>`
            let meta = line.split('\t').next().unwrap_or("");
            let f: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
            if f.len() < 5 {
                continue;
            }
            if f[1] == "160000" {
                return Err(Error::bad_request(
                    "the result holds a git submodule entry: workers change files, not submodules",
                ));
            }
            if f[4] != "D" && is_oid(f[3]) {
                blobs.push(f[3].to_string());
            }
        }
        if blobs.len() > MAX_RESULT_FILES {
            return Err(Error::new(
                code::TOO_LARGE,
                format!(
                    "the result changes {} files; at most {MAX_RESULT_FILES}",
                    blobs.len()
                ),
            ));
        }
        if blobs.is_empty() {
            return Ok(());
        }
        let mut c = self.cmd();
        c.args(["cat-file", "--batch-check=%(objectsize)"]);
        let mut input = blobs.join("\n");
        input.push('\n');
        let out = output(c, Some(input.as_bytes())).await?;
        if !out.status.success() {
            return Err(git_err("cat-file", &out));
        }
        let total: u64 = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().parse::<u64>().ok())
            .sum();
        if total > MAX_RESULT_BYTES {
            return Err(Error::new(
                code::TOO_LARGE,
                format!(
                    "the result adds {} MiB of files; at most {} MiB (build outputs belong in .gitignore)",
                    total >> 20,
                    MAX_RESULT_BYTES >> 20
                ),
            ));
        }
        Ok(())
    }

    /// Files, insertions and deletions between two commits.
    async fn numstat(&self, a: &str, b: &str) -> Result<(u32, u64, u64)> {
        let s = self
            .run(
                "diff --numstat",
                &["diff", "--no-ext-diff", "--no-textconv", "--numstat", a, b],
            )
            .await?;
        let (mut files, mut ins, mut del) = (0u32, 0u64, 0u64);
        for l in s.lines() {
            let mut f = l.split('\t');
            files = files.saturating_add(1);
            ins = ins.saturating_add(f.next().and_then(|x| x.parse().ok()).unwrap_or(0));
            del = del.saturating_add(f.next().and_then(|x| x.parse().ok()).unwrap_or(0));
        }
        Ok((files, ins, del))
    }

    /// The diff between two commits: `--stat` and the patch, cut at [`MAX_DIFF`].
    pub(crate) async fn diff(&self, a: &str, b: &str) -> Result<(String, String, bool)> {
        let stat = self
            .run(
                "diff --stat",
                &["diff", "--no-ext-diff", "--no-textconv", "--stat", a, b],
            )
            .await?;
        let mut c = self.cmd();
        c.args(["diff", "--no-ext-diff", "--no-textconv", "--no-color", a, b]);
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(git_err("diff", &out));
        }
        let mut diff = String::from_utf8_lossy(&out.stdout).into_owned();
        let truncated = diff.len() > MAX_DIFF;
        if truncated {
            let mut cut = MAX_DIFF;
            while !diff.is_char_boundary(cut) {
                cut -= 1;
            }
            diff.truncate(cut);
        }
        Ok((stat, diff, truncated))
    }

    /// The diff of a worker's folder as it is now against `base` (nothing is committed).
    pub(crate) async fn diff_folder(
        &self,
        base: &str,
        dir: &Path,
        index: &Path,
    ) -> Result<(String, String, bool)> {
        let tree = self.write_tree_of(dir, index).await?;
        self.diff(base, &tree).await
    }

    /// Merge `from` into `branch` without touching any work tree: a fast-forward when possible, otherwise a merge
    /// commit made with `merge-tree --write-tree` (git 2.38 or later). Conflicts change nothing and list the files.
    pub(crate) async fn merge_into(
        &self,
        branch: &str,
        from: &str,
        message: &str,
    ) -> Result<Merged> {
        let tip = self
            .branch_tip(branch)
            .await?
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no branch {branch}")))?;
        let new = self.merge_commit(&tip, from, message).await?;
        if new.commit != tip {
            self.set_branch(branch, &new.commit, Some(&tip)).await?;
        }
        Ok(new)
    }

    /// The commit a merge of `from` into `tip` gives (made, not pointed to by any branch yet).
    pub(crate) async fn merge_commit(
        &self,
        tip: &str,
        from: &str,
        message: &str,
    ) -> Result<Merged> {
        if self.is_ancestor(from, tip).await? {
            return Ok(Merged {
                commit: tip.to_string(),
                how: "nothing",
            });
        }
        if self.is_ancestor(tip, from).await? {
            return Ok(Merged {
                commit: from.to_string(),
                how: "fast_forward",
            });
        }
        let mut c = self.cmd();
        c.args(["merge-tree", "--write-tree", "--name-only", tip, from]);
        let out = output(c, None).await?;
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        match out.status.code() {
            Some(0) => {}
            Some(1) => {
                // The tree OID, then the conflicted files, then a blank line and the messages.
                let files: Vec<&str> = text
                    .lines()
                    .skip(1)
                    .take_while(|l| !l.is_empty())
                    .take(20)
                    .collect();
                return Err(Error::new(
                    code::MERGE_CONFLICT,
                    format!("merging conflicts in: {}", files.join(", ")),
                ));
            }
            _ => {
                let e = git_err("merge-tree", &out);
                return Err(
                    if String::from_utf8_lossy(&out.stderr).contains("write-tree") {
                        Error::internal(format!(
                            "{}: teams need git 2.38 or later (merge-tree --write-tree)",
                            e.message
                        ))
                    } else {
                        e
                    },
                );
            }
        }
        let tree = text.lines().next().unwrap_or("").trim().to_string();
        if !is_oid(&tree) {
            return Err(Error::internal("git merge-tree: no tree"));
        }
        let mut c = self.cmd();
        c.args(["commit-tree", &tree, "-p", tip, "-p", from, "-F", "-"]);
        if !self.has_identity().await {
            c.env("GIT_AUTHOR_NAME", "Antenna")
                .env("GIT_AUTHOR_EMAIL", "antenna@antenna.invalid")
                .env("GIT_COMMITTER_NAME", "Antenna")
                .env("GIT_COMMITTER_EMAIL", "antenna@antenna.invalid");
        }
        let out = output(c, Some(message.as_bytes())).await?;
        if !out.status.success() {
            return Err(git_err("commit-tree", &out));
        }
        Ok(Merged {
            commit: trimmed(&out),
            how: "merge",
        })
    }

    /// The repository has a committer identity of the owner's (merge commits are the owner's then).
    async fn has_identity(&self) -> bool {
        let name = self.run("config", &["config", "user.name"]).await;
        let email = self.run("config", &["config", "user.email"]).await;
        matches!((name, email), (Ok(n), Ok(e)) if !n.is_empty() && !e.is_empty())
    }

    /// The work tree where `branch` is checked out, if any (the project itself, or another worktree of the owner's).
    pub(crate) async fn checked_out_at(&self, branch: &str) -> Result<Option<PathBuf>> {
        let s = self
            .run("worktree list", &["worktree", "list", "--porcelain"])
            .await?;
        let want = format!("branch refs/heads/{branch}");
        let mut current: Option<PathBuf> = None;
        for l in s.lines() {
            if let Some(p) = l.strip_prefix("worktree ") {
                current = Some(PathBuf::from(p));
            } else if l == want {
                return Ok(current);
            }
        }
        Ok(None)
    }

    /// Move a checked-out branch to `commit` in its own work tree, as `git merge --ff-only` does there: the owner's
    /// local changes stay, and a change that would overwrite them refuses and changes nothing.
    pub(crate) async fn fast_forward_in(&self, tree: &Path, commit: &str) -> Result<()> {
        if !is_oid(commit) {
            return Err(Error::internal("git: bad commit"));
        }
        let mut c = command();
        c.arg("-C")
            .arg(tree)
            .args(["merge", "--ff-only", "--no-edit", commit]);
        let out = output(c, None).await?;
        if !out.status.success() {
            return Err(Error::new(
                code::MERGE_CONFLICT,
                format!(
                    "the project's working folder {} could not move to the result: {}",
                    tree.display(),
                    String::from_utf8_lossy(&out.stderr)
                        .lines()
                        .find(|l| !l.trim().is_empty())
                        .unwrap_or("")
                ),
            ));
        }
        Ok(())
    }
}

/// A folder only this user can enter.
pub(crate) fn mkdir_private(dir: &Path) -> Result<()> {
    use crate::owner_only::{OwnerOnly, owner_only_dir};
    std::fs::DirBuilder::new()
        .recursive(true)
        .owner_only()
        .create(dir)?;
    owner_only_dir(dir)?;
    Ok(())
}

/// The first `.git` (a folder or a file) inside `dir`, symlinks not followed: a nested repository, which `add -A`
/// would record as a submodule and read its own files for.
fn nested_repository(dir: &Path) -> Result<Option<PathBuf>> {
    let mut stack = vec![dir.to_path_buf()];
    let mut seen = 0usize;
    while let Some(d) = stack.pop() {
        let rd = match std::fs::read_dir(&d) {
            Ok(r) => r,
            Err(_) => continue,
        };
        for e in rd.flatten() {
            seen += 1;
            if seen > 2_000_000 {
                return Err(Error::new(
                    code::TOO_LARGE,
                    "the folder holds more than 2,000,000 entries",
                ));
            }
            let name = e.file_name();
            let path = e.path();
            if name == ".git" {
                return Ok(Some(path.strip_prefix(dir).unwrap_or(&path).to_path_buf()));
            }
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                stack.push(path);
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_names_and_commit_ids() {
        for b in ["main", "antenna/web", "team/0123abcd", "feature/x-1.2"] {
            assert!(valid_branch(b), "{b}");
        }
        for b in [
            "", "-x", "a..b", "a@{1}", "a b", "a;rm", "/a", "a/", "a//b", "x.lock", "a\nb",
        ] {
            assert!(!valid_branch(b), "{b:?}");
        }
        assert!(is_oid(&"a".repeat(40)));
        assert!(!is_oid("HEAD"));
        assert!(!is_oid(&"g".repeat(40)));
    }

    #[test]
    fn a_nested_repository_is_found() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("src/vendor/lib")).unwrap();
        assert_eq!(nested_repository(d.path()).unwrap(), None);
        std::fs::write(d.path().join("src/vendor/lib/.git"), "gitdir: /tmp/evil\n").unwrap();
        assert_eq!(
            nested_repository(d.path()).unwrap(),
            Some(PathBuf::from("src/vendor/lib/.git"))
        );
    }
}
