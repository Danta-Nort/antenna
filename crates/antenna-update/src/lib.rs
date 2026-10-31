// SPDX-License-Identifier: AGPL-3.0-only
//! Signed Antenna releases and `antenna update` (SPEC §12, §13; DECISIONS D-82; the format is `docs/UPDATES.md`).
//!
//! - [`manifest`]: the release manifest `antenna-<version>-manifest.json` (version, channel, commit, and for every
//!   asset its name, platform, size, SHA-256 and BLAKE3);
//! - [`sig`]: the detached signature `…-manifest.json.sig` (Ed25519 over the exact manifest bytes with a context);
//! - [`keys`]: the release keys pinned in this binary (a list, so that keys can be rotated) and the test key that only
//!   debug builds accept, and only when asked to;
//! - [`package`]: finding the manifest, signature and asset among the files the owner points at, and verifying them;
//! - [`install`]: replacing the installed version (macOS: `Antenna.app`; Linux: the binaries in the `install.sh`
//!   layout) atomically, with the old one kept as `.previous` for rollback, and recovery after an interruption.
//!
//! No custom cryptography (SPEC §7, §15): signatures are `ed25519-dalek` (`verify_strict`), hashes are `sha2` and
//! `blake3`, keys come from the OS CSPRNG through `rand`.

#![deny(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the window closes the CLI's stdio during an update; the update log file is the record"
)]

pub mod fetch;
pub mod install;
pub mod keys;
pub mod manifest;
pub mod package;
pub mod sig;
pub mod signing;
pub mod version;

pub use version::Version;

/// Error codes (stable: the CLI prints them, the window maps them to its own text).
pub mod code {
    /// This build has no release key pinned: nothing can be verified, so nothing is installed.
    pub const NO_RELEASE_KEY: &str = "no_release_key";
    /// The signature file is malformed, or no pinned key signed the manifest.
    pub const BAD_SIGNATURE: &str = "bad_signature";
    /// The manifest is malformed or not an Antenna release manifest.
    pub const BAD_MANIFEST: &str = "bad_manifest";
    /// The update is not newer than the installed version (no downgrades).
    pub const NOT_NEWER: &str = "not_newer";
    /// The release has no asset for this platform and install, or the given asset is for another one.
    pub const WRONG_PLATFORM: &str = "wrong_platform";
    /// The asset for this platform is not among the given files.
    pub const ASSET_MISSING: &str = "asset_missing";
    /// The asset's size or hash differs from the manifest.
    pub const HASH_MISMATCH: &str = "hash_mismatch";
    /// This installation cannot update itself (a development build, the Linux window bundle).
    pub const UNSUPPORTED_INSTALL: &str = "unsupported_install";
    /// The files given to `--from` are not a release (no manifest, several manifests, no signature).
    pub const BAD_REQUEST: &str = "bad_request";
    /// Installing failed; the old version was restored.
    pub const INSTALL_FAILED: &str = "install_failed";
    /// There is no `.previous` version to roll back to.
    pub const ROLLBACK_UNAVAILABLE: &str = "rollback_unavailable";
    /// Another update is running.
    pub const UPDATE_IN_PROGRESS: &str = "update_in_progress";
    /// Fetching the manifest over HTTPS failed.
    pub const FETCH_FAILED: &str = "fetch_failed";
    /// File system or process error.
    pub const IO: &str = "io";
}

/// An update error with a stable code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    /// Machine-readable code ([`code`]).
    pub code: &'static str,
    /// Message for the owner.
    pub message: String,
}

impl Error {
    /// New error.
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// An I/O error with what was being done.
    pub fn io(what: impl std::fmt::Display, e: impl std::fmt::Display) -> Self {
        Self::new(code::IO, format!("{what}: {e}"))
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

/// Result with [`Error`].
pub type Result<T> = std::result::Result<T, Error>;

/// Current UTC time as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn utc_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    utc_from_unix(secs)
}

/// Seconds since the Unix epoch as `YYYY-MM-DDTHH:MM:SSZ` (the proleptic Gregorian calendar; days to civil date as in
/// H. Hinnant's `civil_from_days`).
pub fn utc_from_unix(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Lowercase hex.
pub fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

/// Whether the string is lowercase hex of `len` characters.
pub(crate) fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    #[test]
    fn utc_dates() {
        assert_eq!(super::utc_from_unix(0), "1970-01-01T00:00:00Z");
        assert_eq!(super::utc_from_unix(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(super::utc_from_unix(1_791_030_896), "2026-10-03T12:34:56Z");
        assert_eq!(super::utc_now().len(), 20);
    }
}
