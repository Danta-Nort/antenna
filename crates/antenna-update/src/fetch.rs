// SPDX-License-Identifier: AGPL-3.0-only
//! Fetching a release over HTTPS (`antenna update --check`, and the daemon's daily check for updates that install by
//! themselves, D-103): `curl`, HTTPS only, also for redirects, with a size limit, so that neither the CLI nor the
//! daemon carries an HTTP client of its own for this. What is fetched is trusted only after the signature check.

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use crate::{Error, Result, code};

/// The preview channel's manifest on the project's update host: the newest release of any kind, previews and stable
/// releases alike (the release script writes a stable release under both names).
pub const PREVIEW_URL: &str = "https://updates.stillbyte.dev/antenna/antenna-preview-manifest.json";

/// The stable channel's manifest: the newest release without a pre-release suffix.
pub const STABLE_URL: &str = "https://updates.stillbyte.dev/antenna/antenna-stable-manifest.json";

/// The channel a version follows by itself: a pre-release (`0.1.0-preview.11`) the preview channel, any other version
/// the stable one, so a stable install is never offered a preview it did not ask for.
pub const fn channel_url(version: &str) -> &'static str {
    let b = version.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'-' {
            return PREVIEW_URL;
        }
        i += 1;
    }
    STABLE_URL
}

/// The update URL built into release builds (D-137): the manifest of this version's channel ([`channel_url`]) on the
/// project's update host, with its signature and the release files next to it. Debug builds have none, so tests and
/// development builds never reach the network by themselves.
pub const BUILT_IN_URL: Option<&str> = if cfg!(debug_assertions) {
    None
} else {
    Some(channel_url(env!("CARGO_PKG_VERSION")))
};

/// The value that turns the update URL off where it is configured (`ANTENNA_UPDATE_URL=off`, or `off` as the first
/// line of the file): no daily check, and the built-in URL is not used either.
pub const OFF: &str = "off";

/// Where the update URL comes from: `explicit` (`--url`), then `ANTENNA_UPDATE_URL`, then the first line of
/// `<config>/antenna/update-url` (`config` is `$XDG_CONFIG_HOME` or `~/.config`), then [`BUILT_IN_URL`]. A configured
/// value that is empty or [`OFF`] means no URL. Never set over a link.
pub fn update_url(explicit: Option<&str>, config_dir: &Path) -> Option<String> {
    resolve_url(
        explicit,
        std::env::var("ANTENNA_UPDATE_URL").ok(),
        config_dir,
        BUILT_IN_URL,
    )
}

fn resolve_url(
    explicit: Option<&str>,
    env: Option<String>,
    config_dir: &Path,
    built_in: Option<&str>,
) -> Option<String> {
    let configured = explicit.map(str::to_string).or(env).or_else(|| {
        std::fs::read_to_string(config_dir.join("antenna/update-url"))
            .ok()
            .map(|s| s.lines().next().unwrap_or_default().trim().to_string())
    });
    match configured {
        Some(s) if s.is_empty() || s == OFF => None,
        Some(s) => Some(s),
        None => built_in.map(str::to_string),
    }
}

/// `$XDG_CONFIG_HOME` (when absolute) or `~/.config`.
pub fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/"))
                .join(".config")
        })
}

/// The URL of a release file next to the manifest (`<URL without its last segment>/<name>`).
pub fn sibling(manifest_url: &str, name: &str) -> String {
    let base = manifest_url
        .rsplit_once('/')
        .map(|(b, _)| b)
        .unwrap_or_default();
    format!("{base}/{name}")
}

/// Fetches a URL over HTTPS (`curl --proto =https --proto-redir =https`), at most `max` bytes, into memory or into the
/// file `to`. A non-HTTPS URL is refused before anything runs.
pub fn https(url: &str, max: u64, to: Option<&Path>) -> Result<Vec<u8>> {
    if !url.starts_with("https://") {
        return Err(Error::new(
            code::BAD_REQUEST,
            "the update URL must be https://",
        ));
    }
    let curl = ["/usr/bin/curl", "/bin/curl"]
        .into_iter()
        .find(|p| Path::new(p).is_file())
        .unwrap_or("curl");
    let mut c = Command::new(curl);
    c.args([
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--max-time",
        "600",
        "--max-filesize",
    ])
    .arg(max.to_string())
    .stdin(Stdio::null());
    if let Some(p) = to {
        c.arg("--output").arg(p);
    }
    c.arg("--").arg(url);
    let o = c
        .output()
        .map_err(|e| Error::new(code::FETCH_FAILED, format!("cannot run curl: {e}")))?;
    if !o.status.success() {
        return Err(Error::new(
            code::FETCH_FAILED,
            format!("{url}: {}", String::from_utf8_lossy(&o.stderr).trim()),
        ));
    }
    if o.stdout.len() as u64 > max {
        return Err(Error::new(
            code::FETCH_FAILED,
            format!("{url}: larger than {max} bytes"),
        ));
    }
    Ok(o.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_and_the_url_sources() {
        assert_eq!(
            https("http://example.com/m.json", 10, None)
                .unwrap_err()
                .code,
            code::BAD_REQUEST
        );
        assert_eq!(
            sibling(
                "https://example.com/r/antenna-1.0.0-manifest.json",
                "a.tar.gz"
            ),
            "https://example.com/r/a.tar.gz"
        );
        let d = tempfile::tempdir().unwrap();
        assert_eq!(
            update_url(Some("https://x/m.json"), d.path()).as_deref(),
            Some("https://x/m.json")
        );
        std::fs::create_dir_all(d.path().join("antenna")).unwrap();
        std::fs::write(
            d.path().join("antenna/update-url"),
            "https://example.com/m.json\nsecond line\n",
        )
        .unwrap();
        if std::env::var_os("ANTENNA_UPDATE_URL").is_none() {
            assert_eq!(
                update_url(None, d.path()).as_deref(),
                Some("https://example.com/m.json")
            );
        }
    }

    #[test]
    fn the_built_in_url_comes_last_and_off_turns_it_off() {
        const B: Option<&str> = Some("https://example.com/built-in.json");
        let d = tempfile::tempdir().unwrap();
        let url = |explicit, env: Option<&str>| {
            resolve_url(explicit, env.map(str::to_string), d.path(), B)
        };
        // Nothing configured: the built-in one.
        assert_eq!(url(None, None).as_deref(), B);
        assert_eq!(resolve_url(None, None, d.path(), None), None);
        // The environment and --url come before it; empty or `off` means none at all.
        assert_eq!(
            url(None, Some("https://example.com/env.json")).as_deref(),
            Some("https://example.com/env.json")
        );
        assert_eq!(url(None, Some("off")), None);
        assert_eq!(url(None, Some("")), None);
        assert_eq!(
            url(Some("https://example.com/cli.json"), Some("off")).as_deref(),
            Some("https://example.com/cli.json")
        );
        // The file, the same way: its first line decides; `off` there turns the built-in one off too.
        std::fs::create_dir_all(d.path().join("antenna")).unwrap();
        let file = d.path().join("antenna/update-url");
        std::fs::write(&file, "https://example.com/file.json\n").unwrap();
        assert_eq!(
            url(None, None).as_deref(),
            Some("https://example.com/file.json")
        );
        std::fs::write(&file, "off\nhttps://example.com/file.json\n").unwrap();
        assert_eq!(url(None, None), None);
        std::fs::write(&file, "").unwrap();
        assert_eq!(url(None, None), None);
    }

    #[test]
    fn a_version_follows_its_own_channel() {
        assert_eq!(channel_url("0.1.0-preview.11"), PREVIEW_URL);
        assert_eq!(channel_url("0.2.0-rc.1"), PREVIEW_URL);
        assert_eq!(channel_url("0.1.0"), STABLE_URL);
        assert_eq!(channel_url("1.0.0"), STABLE_URL);
    }

    #[test]
    fn only_release_builds_carry_the_built_in_url() {
        // Tests run debug builds: they must never check the real host by themselves (CONTRIBUTING.md, Tests: loopback only).
        assert_eq!(BUILT_IN_URL.is_none(), cfg!(debug_assertions));
        if let Some(u) = BUILT_IN_URL {
            assert!(u.starts_with("https://") && u.ends_with("-manifest.json"));
        }
    }
}
