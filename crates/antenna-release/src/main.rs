// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna-release`: the release key, the release manifest and its signature (D-82, `docs/UPDATES.md` §5).
//!
//! ```text
//! antenna-release keygen [--key PATH]                      new release key (0600), prints the line to pin
//! antenna-release public [--key PATH]                      the public key and the line to pin, again
//! antenna-release manifest --version V --commit C [--channel preview|stable] [--created T] [--models CATALOG] --out FILE FILES|DIR…
//! antenna-release sign [--key PATH] MANIFEST               writes (or adds to) MANIFEST.sig
//! antenna-release verify [--pinned|--test-key|--public B64…] [--models CATALOG] MANIFEST [--dir DIR]
//! ```
//! The key path comes from `--key` or the environment variable `ANTENNA_RELEASE_KEY`.

use std::{
    path::{Path, PathBuf},
    process::ExitCode,
};

use antenna_update::{
    keys::{self, KeySet},
    manifest::{self, Manifest},
    sig::{self, SignatureFile},
    signing,
};
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "antenna-release",
    version,
    about = "Antenna release key, manifest and signature"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Debug, Subcommand)]
enum Cmd {
    /// Generate the release key: the secret key file (mode 0600, never overwritten) and the public key to pin.
    Keygen {
        /// Secret key file.
        #[arg(long, env = "ANTENNA_RELEASE_KEY")]
        key: PathBuf,
    },
    /// Print the public key of a secret key file and the line to pin.
    Public {
        /// Secret key file.
        #[arg(long, env = "ANTENNA_RELEASE_KEY")]
        key: PathBuf,
    },
    /// Build the release manifest from the release files.
    Manifest {
        /// Release version (`0.1.0-preview.3`).
        #[arg(long)]
        version: String,
        /// Build commit, as `antenna --version` prints it.
        #[arg(long)]
        commit: String,
        /// `preview` or `stable` (default: `preview` for a pre-release version, `stable` otherwise).
        #[arg(long)]
        channel: Option<String>,
        /// Time, `YYYY-MM-DDTHH:MM:SSZ` (default: now).
        #[arg(long)]
        created: Option<String>,
        /// Where to write the manifest (`antenna-<version>-manifest.json`).
        #[arg(long)]
        out: PathBuf,
        /// The catalog of local models this release's daemon was built with (`packaging/models.json` of the tag):
        /// copied into the manifest's `models` (D-104).
        #[arg(long)]
        models: Option<PathBuf>,
        /// Release files, or folders with them.
        #[arg(required = true)]
        files: Vec<PathBuf>,
    },
    /// Sign a manifest: writes `<manifest>.sig`, or adds this key's signature to an existing one.
    Sign {
        /// Secret key file.
        #[arg(
            long,
            env = "ANTENNA_RELEASE_KEY",
            required_unless_present = "test_key"
        )]
        key: Option<PathBuf>,
        /// Sign with the public test key instead (test fixtures, `packaging/macos/check-update.sh`): only debug builds
        /// asked to (`ANTENNA_UPDATE_TEST_KEY=1`) accept it.
        #[arg(long, conflicts_with = "key")]
        test_key: bool,
        /// The manifest.
        manifest: PathBuf,
    },
    /// Verify a manifest's signature and the release files next to it.
    Verify {
        /// Trust the keys pinned in this build (default).
        #[arg(long, conflicts_with_all = ["test_key", "public"])]
        pinned: bool,
        /// Trust only the public test key (fixtures).
        #[arg(long, conflicts_with = "public")]
        test_key: bool,
        /// Trust these public keys (base64).
        #[arg(long)]
        public: Vec<String>,
        /// The signature file (default `<manifest>.sig`).
        #[arg(long)]
        sig: Option<PathBuf>,
        /// The catalog of local models the release's daemon was built with: the manifest's `models` must equal it.
        #[arg(long)]
        models: Option<PathBuf>,
        /// Folder with the release files (default: the manifest's folder).
        #[arg(long)]
        dir: Option<PathBuf>,
        /// Every asset must be present.
        #[arg(long)]
        all: bool,
        /// The manifest.
        manifest: PathBuf,
    },
}

type R = Result<(), String>;

fn e(x: impl std::fmt::Display) -> String {
    x.to_string()
}

fn today() -> String {
    antenna_update::utc_now()[..10].to_string()
}

fn print_public(raw: &[u8; 32]) {
    let id = keys::key_id(raw);
    println!("key id:     {id}");
    println!("public key: {}", data_encoding::BASE64.encode(raw));
    println!();
    println!("Pin it: add this line to RELEASE_KEYS in crates/antenna-update/src/keys.rs");
    println!("{}", keys::pin_line(raw, &today()));
}

fn keygen(path: &Path) -> R {
    let k = signing::generate();
    signing::write_secret(path, &k).map_err(e)?;
    eprintln!(
        "wrote the secret release key to {} (mode 0600). Keep it there; back it up offline.",
        path.display()
    );
    let raw = k.verifying_key().to_bytes();
    print_public(&raw);
    Ok(())
}

/// The `models` of a catalog file, after the strict check the daemon applies to its compiled-in copy.
fn catalog_models(path: &Path) -> Result<Vec<serde_json::Value>, String> {
    let text = std::fs::read_to_string(path).map_err(|x| format!("{}: {x}", path.display()))?;
    antenna_proto::models::Catalog::parse(&text).map_err(e)?;
    let v: serde_json::Value = serde_json::from_str(&text).map_err(e)?;
    v["models"]
        .as_array()
        .cloned()
        .ok_or_else(|| format!("{}: no models", path.display()))
}

fn manifest_cmd(
    version: &str,
    commit: &str,
    channel: Option<&str>,
    created: Option<&str>,
    out: &Path,
    models: Option<&Path>,
    files: &[PathBuf],
) -> R {
    let channel = channel.unwrap_or(if version.contains('-') {
        "preview"
    } else {
        "stable"
    });
    let created = created
        .map(str::to_string)
        .unwrap_or_else(antenna_update::utc_now);
    let mut m = signing::build_manifest(version, channel, commit, &created, files).map_err(e)?;
    if let Some(p) = models {
        m.models = catalog_models(p)?;
        // Still within the manifest's size limit with the catalog in it.
        Manifest::parse(&m.to_bytes()).map_err(e)?;
    }
    let want = manifest::manifest_name(version);
    if out.file_name().is_none_or(|n| n != want.as_str()) {
        return Err(format!("the manifest must be called {want}"));
    }
    std::fs::write(out, m.to_bytes()).map_err(|x| format!("{}: {x}", out.display()))?;
    eprintln!(
        "wrote {} ({} assets, {} local models)",
        out.display(),
        m.assets.len(),
        m.models.len()
    );
    for a in &m.assets {
        println!(
            "{}  {} {} {}  {} bytes  sha256 {}",
            a.name, a.os, a.arch, a.kind, a.size, a.sha256
        );
    }
    Ok(())
}

fn sign_cmd(key: Option<&Path>, test_key: bool, manifest_path: &Path) -> R {
    let k = match key {
        Some(key) if !test_key => signing::read_secret(key).map_err(e)?,
        _ => {
            eprintln!(
                "signing with the PUBLIC TEST KEY: only debug builds with ANTENNA_UPDATE_TEST_KEY=1 accept this"
            );
            keys::test_signing_key()
        }
    };
    let bytes =
        std::fs::read(manifest_path).map_err(|x| format!("{}: {x}", manifest_path.display()))?;
    Manifest::parse(&bytes).map_err(e)?;
    let sig_path = PathBuf::from(format!("{}.sig", manifest_path.display()));
    let entry = sig::sign(&bytes, &k);
    let file = match std::fs::read(&sig_path) {
        Ok(old) => {
            let mut f = SignatureFile::parse(&old).map_err(e)?;
            f.add(entry);
            f
        }
        Err(_) => SignatureFile::new(entry),
    };
    // The signature must verify with the key that made it before it is written.
    sig::verify(&bytes, &file.to_bytes(), &KeySet::of(&[k.verifying_key()])).map_err(e)?;
    std::fs::write(&sig_path, file.to_bytes())
        .map_err(|x| format!("{}: {x}", sig_path.display()))?;
    eprintln!(
        "wrote {} (key {}, {} signature(s))",
        sig_path.display(),
        keys::key_id(k.verifying_key().as_bytes()),
        file.signatures.len()
    );
    Ok(())
}

fn verify_cmd(
    test_key: bool,
    public: &[String],
    sig_path: Option<&Path>,
    dir: Option<&Path>,
    all: bool,
    models: Option<&Path>,
    manifest_path: &Path,
) -> R {
    let keys = if test_key {
        KeySet::test_only()
    } else if !public.is_empty() {
        KeySet::from_base64(public).map_err(e)?
    } else {
        KeySet::pinned()
    };
    let bytes =
        std::fs::read(manifest_path).map_err(|x| format!("{}: {x}", manifest_path.display()))?;
    let sp = sig_path
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(format!("{}.sig", manifest_path.display())));
    let sb = std::fs::read(&sp).map_err(|x| format!("{}: {x}", sp.display()))?;
    let v = sig::verify(&bytes, &sb, &keys).map_err(e)?;
    let (m, version) = Manifest::parse(&bytes).map_err(e)?;
    println!(
        "manifest {version} ({}, {}, commit {}): signature ok, key(s) {}",
        m.channel,
        m.created,
        m.commit,
        v.key_ids.join(", ")
    );
    let dir = dir
        .map(Path::to_path_buf)
        .or_else(|| manifest_path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));
    if let Some(p) = models {
        if m.models != catalog_models(p)? {
            return Err(format!(
                "the manifest's local models differ from {} (the catalog its daemon was built with)",
                p.display()
            ));
        }
        println!(
            "  local models: {}, equal to {}",
            m.models.len(),
            p.display()
        );
    }
    let mut bad = 0;
    for a in &m.assets {
        let p = dir.join(&a.name);
        if !p.is_file() {
            println!("  {}: not present", a.name);
            if all {
                bad += 1;
            }
            continue;
        }
        let (size, sha, b3) = manifest::hash_file(&p).map_err(e)?;
        if size == a.size && sha == a.sha256 && b3 == a.blake3 {
            println!("  {}: ok", a.name);
        } else {
            println!("  {}: DOES NOT MATCH", a.name);
            bad += 1;
        }
    }
    if bad > 0 {
        return Err(format!("{bad} release file(s) missing or not matching"));
    }
    Ok(())
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let r = match &cli.cmd {
        Cmd::Keygen { key } => keygen(key),
        Cmd::Public { key } => signing::read_secret(key)
            .map_err(e)
            .map(|k| print_public(&k.verifying_key().to_bytes())),
        Cmd::Manifest {
            version,
            commit,
            channel,
            created,
            out,
            models,
            files,
        } => manifest_cmd(
            version,
            commit,
            channel.as_deref(),
            created.as_deref(),
            out,
            models.as_deref(),
            files,
        ),
        Cmd::Sign {
            key,
            test_key,
            manifest,
        } => sign_cmd(key.as_deref(), *test_key, manifest),
        Cmd::Verify {
            pinned: _,
            test_key,
            public,
            sig,
            dir,
            all,
            models,
            manifest,
        } => verify_cmd(
            *test_key,
            public,
            sig.as_deref(),
            dir.as_deref(),
            *all,
            models.as_deref(),
            manifest,
        ),
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(m) => {
            eprintln!("antenna-release: {m}");
            ExitCode::FAILURE
        }
    }
}
