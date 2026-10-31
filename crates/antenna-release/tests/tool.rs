// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna-release` end to end: keygen → manifest → sign → verify, and the refusals that matter.

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{fs, path::Path, process::Command};

fn tool(args: &[&str], key: Option<&Path>) -> (bool, String, String) {
    let mut c = Command::new(env!("CARGO_BIN_EXE_antenna-release"));
    c.args(args).env_remove("ANTENNA_RELEASE_KEY");
    if let Some(k) = key {
        c.env("ANTENNA_RELEASE_KEY", k);
    }
    let o = c.output().unwrap();
    (
        o.status.success(),
        String::from_utf8_lossy(&o.stdout).into_owned(),
        String::from_utf8_lossy(&o.stderr).into_owned(),
    )
}

// Unix modes; Windows refuses release key files (`keygen_is_refused_on_windows`).
#[cfg(unix)]
#[test]
fn keygen_manifest_sign_verify() {
    let d = tempfile::tempdir().unwrap();
    let key = d.path().join("secret/release-key");
    let (ok, out, err) = tool(&["keygen"], Some(&key));
    assert!(ok, "{err}");
    assert_eq!(
        fs::metadata(&key).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let public = out
        .lines()
        .find_map(|l| l.strip_prefix("public key: "))
        .unwrap()
        .to_string();
    assert!(out.contains("PinnedKey { id: \""), "{out}");
    // A second keygen never overwrites the key.
    assert!(!tool(&["keygen"], Some(&key)).0);
    // `public` prints the same key again.
    assert!(tool(&["public"], Some(&key)).1.contains(&public));

    let rel = d.path().join("dist");
    fs::create_dir(&rel).unwrap();
    let v = "0.1.0-preview.3";
    fs::write(rel.join(format!("Antenna-{v}-macos-arm64.dmg")), b"dmg").unwrap();
    fs::write(rel.join(format!("antenna-{v}-linux-x86_64.tar.gz")), b"tgz").unwrap();
    fs::write(rel.join("SHA256SUMS.txt"), b"sums").unwrap();
    let m = rel.join(format!("antenna-{v}-manifest.json"));
    let ms = m.to_str().unwrap();
    let (ok, _, err) = tool(
        &[
            "manifest",
            "--version",
            v,
            "--commit",
            "0123456789ab",
            "--out",
            ms,
            rel.to_str().unwrap(),
        ],
        None,
    );
    assert!(ok, "{err}");
    let (ok, _, err) = tool(&["sign", ms], Some(&key));
    assert!(ok, "{err}");
    assert!(rel.join(format!("antenna-{v}-manifest.json.sig")).is_file());

    let (ok, out, err) = tool(&["verify", "--public", &public, "--all", ms], None);
    assert!(ok, "{out}{err}");
    assert!(out.contains("signature ok"), "{out}");
    // The test key does not verify a release signed by the release key; the pinned list (empty for now in this build,
    // or holding the real key later) does not trust this freshly generated key either.
    assert!(!tool(&["verify", "--test-key", ms], None).0);
    assert!(!tool(&["verify", ms], None).0);
    // A tampered asset is caught by verify.
    fs::write(rel.join(format!("antenna-{v}-linux-x86_64.tar.gz")), b"tgZ").unwrap();
    let (ok, out, _) = tool(&["verify", "--public", &public, ms], None);
    assert!(!ok && out.contains("DOES NOT MATCH"), "{out}");
    // A fixture signed with the public test key verifies with --test-key only.
    let fixture = d.path().join("fixture");
    std::fs::create_dir(&fixture).unwrap();
    for e in fs::read_dir(&rel).unwrap().flatten() {
        if e.file_name().to_string_lossy().ends_with(".tar.gz")
            || e.file_name().to_string_lossy().ends_with(".dmg")
        {
            fs::copy(e.path(), fixture.join(e.file_name())).unwrap();
        }
    }
    let fm = fixture.join(format!("antenna-{v}-manifest.json"));
    let fms = fm.to_str().unwrap();
    assert!(
        tool(
            &[
                "manifest",
                "--version",
                v,
                "--commit",
                "0123456789ab",
                "--out",
                fms,
                fixture.to_str().unwrap()
            ],
            None
        )
        .0
    );
    let (ok, _, err) = tool(&["sign", "--test-key", fms], None);
    assert!(ok && err.contains("PUBLIC TEST KEY"), "{err}");
    assert!(tool(&["verify", "--test-key", fms], None).0);
    assert!(!tool(&["verify", "--public", &public, fms], None).0);
    // A key file others can read is refused.
    fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(!tool(&["sign", ms], Some(&key)).0);
}

/// Windows refuses release key files until their DACL can be set and checked (D-134, WP-4): keygen writes nothing.
#[cfg(windows)]
#[test]
fn keygen_is_refused_on_windows() {
    let d = tempfile::tempdir().unwrap();
    let key = d.path().join("secret/release-key");
    let (ok, out, err) = tool(&["keygen"], Some(&key));
    assert!(!ok && err.contains("not supported on Windows"), "{err}");
    assert!(!out.contains("public key"), "{out}");
    assert!(!key.parent().unwrap().exists());
}

#[test]
fn the_manifest_name_and_unknown_files() {
    let d = tempfile::tempdir().unwrap();
    let v = "0.1.0-preview.3";
    fs::write(
        d.path().join(format!("antenna-{v}-linux-x86_64.tar.gz")),
        b"tgz",
    )
    .unwrap();
    let wrong = d.path().join("manifest.json");
    assert!(
        !tool(
            &[
                "manifest",
                "--version",
                v,
                "--commit",
                "0123456789ab",
                "--out",
                wrong.to_str().unwrap(),
                d.path().to_str().unwrap()
            ],
            None
        )
        .0
    );
    fs::write(d.path().join("stray.bin"), b"?").unwrap();
    let m = d.path().join(format!("antenna-{v}-manifest.json"));
    let (ok, _, err) = tool(
        &[
            "manifest",
            "--version",
            v,
            "--commit",
            "0123456789ab",
            "--out",
            m.to_str().unwrap(),
            d.path().to_str().unwrap(),
        ],
        None,
    );
    assert!(!ok && err.contains("stray.bin"), "{err}");
}

/// The local model catalog travels in the signed manifest (D-104): `--models` copies the tag's catalog in, `verify
/// --models` refuses a manifest whose catalog differs from the one the daemon was built with, and a catalog the
/// daemon would refuse is refused here too.
#[test]
#[cfg_attr(windows, ignore = "WP-4 (W1): release key files")]
fn the_model_catalog_goes_into_the_manifest_and_is_checked() {
    let d = tempfile::tempdir().unwrap();
    let key = d.path().join("k/release-key");
    let (ok, out, err) = tool(&["keygen"], Some(&key));
    assert!(ok, "{err}");
    let public = out
        .lines()
        .find_map(|l| l.strip_prefix("public key: "))
        .unwrap()
        .to_string();
    let v = "0.1.0-preview.8";
    let rel = d.path().join("dist");
    fs::create_dir(&rel).unwrap();
    fs::write(rel.join(format!("antenna-{v}-linux-x86_64.tar.gz")), b"tgz").unwrap();
    let catalog = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packaging/models.json");
    let m = rel.join(format!("antenna-{v}-manifest.json"));
    let (ms, cs) = (m.to_str().unwrap(), catalog.to_str().unwrap());
    let (ok, _, err) = tool(
        &[
            "manifest",
            "--version",
            v,
            "--commit",
            "0123456789ab",
            "--models",
            cs,
            "--out",
            ms,
            rel.to_str().unwrap(),
        ],
        None,
    );
    assert!(ok, "{err}");
    assert!(err.contains("3 local models"), "{err}");
    let manifest: serde_json::Value = serde_json::from_slice(&fs::read(&m).unwrap()).unwrap();
    assert_eq!(manifest["models"][0]["id"], "qwen3.5-2b");
    assert!(tool(&["sign", ms], Some(&key)).0);
    let (ok, out, err) = tool(&["verify", "--public", &public, "--models", cs, ms], None);
    assert!(ok, "{out}{err}");
    assert!(out.contains("local models: 3, equal to"), "{out}");
    // Another catalog (one hash changed): refused.
    let other = d.path().join("models.json");
    let text = fs::read_to_string(&catalog).unwrap();
    fs::write(
        &other,
        text.replace(
            "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
            "0000000000000000000000000000000000000000000000000000000000000000",
        ),
    )
    .unwrap();
    let (ok, _, err) = tool(
        &[
            "verify",
            "--public",
            &public,
            "--models",
            other.to_str().unwrap(),
            ms,
        ],
        None,
    );
    assert!(!ok && err.contains("differ"), "{err}");
    // A catalog the daemon would refuse (a branch instead of a commit) does not go into a manifest.
    fs::write(
        &other,
        text.replace("f6d5376be1edb4d416d56da11e5397a961aca8ae", "main"),
    )
    .unwrap();
    let (ok, _, err) = tool(
        &[
            "manifest",
            "--version",
            v,
            "--commit",
            "0123456789ab",
            "--models",
            other.to_str().unwrap(),
            "--out",
            ms,
            rel.to_str().unwrap(),
        ],
        None,
    );
    assert!(!ok && err.contains("commit"), "{err}");
}
