// SPDX-License-Identifier: AGPL-3.0-only
//! Build commit for `--version` and the daemon version: `ANTENNA_COMMIT` from the environment (CI), otherwise
//! `git rev-parse --short=12 HEAD`, otherwise `unknown` (a build from an archive without `.git`). `antennad` has the
//! same file.

use std::{path::Path, process::Command};

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .ok()?;
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    (out.status.success() && !s.is_empty()).then_some(s)
}

fn main() {
    println!("cargo:rerun-if-env-changed=ANTENNA_COMMIT");
    let dir = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let commit = match std::env::var("ANTENNA_COMMIT") {
        Ok(c) if !c.trim().is_empty() => c.trim().to_string(),
        _ => {
            // Rebuild on a new commit: HEAD and the current branch's ref (worktrees have their own paths,
            // `--git-path`).
            for f in ["HEAD", "packed-refs"] {
                if let Some(p) = git(&dir, &["rev-parse", "--git-path", f]) {
                    println!("cargo:rerun-if-changed={}", dir.join(p).display());
                }
            }
            if let Some(r) = git(&dir, &["symbolic-ref", "-q", "HEAD"])
                && let Some(p) = git(&dir, &["rev-parse", "--git-path", &r])
            {
                println!("cargo:rerun-if-changed={}", dir.join(p).display());
            }
            git(&dir, &["rev-parse", "--short=12", "HEAD"]).unwrap_or_else(|| "unknown".into())
        }
    };
    println!("cargo:rustc-env=ANTENNA_COMMIT={commit}");
}
