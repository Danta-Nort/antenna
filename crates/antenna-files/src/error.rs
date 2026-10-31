// SPDX-License-Identifier: AGPL-3.0-only
//! Crate error: a machine-readable code plus text for a human (like `antenna_core::error`).
//!
//! The error text contains no secrets, no contact's file names and no content (SPEC §13 "Logs"): a file name is contact
//! data, it goes only into the manifest and is shown to the owner escaped.

use std::fmt;

/// Error codes. In stage B they become control protocol codes (`antenna_proto::control::code`).
pub mod code {
    /// The file ciphertext is damaged, reordered, truncated or extended (STREAM rejected a chunk).
    pub const CORRUPT: &str = "file_corrupt";
    /// The plaintext hash or size does not match the manifest.
    pub const HASH_MISMATCH: &str = "file_hash_mismatch";
    /// The manifest signature is invalid or the manifest failed to parse.
    pub const BAD_MANIFEST: &str = "bad_manifest";
    /// The trust level does not allow files (level 1).
    pub const LEVEL_FORBIDS_FILES: &str = "level_forbids_files";
    /// The level's daily volume is exceeded.
    pub const QUOTA: &str = "file_quota_exceeded";
    /// The file name is forbidden (`..`, a path, special characters, a reserved Windows name…).
    pub const BAD_NAME: &str = "bad_file_name";
    /// The folder already has a file with this name (including one that differs only in case).
    pub const NAME_TAKEN: &str = "file_name_taken";
    /// Acceptance needs the owner, an approval or `--force` with the password.
    pub const FORBIDDEN: &str = "forbidden";
    /// A separate approval is needed (dot files and auto-executable names).
    pub const APPROVAL_REQUIRED: &str = "approval_required";
    /// No such file in quarantine.
    pub const NOT_FOUND: &str = "not_found";
    /// Wrong state (for example, acceptance before the check).
    pub const BAD_STATE: &str = "bad_state";
    /// The sandboxed check did not run (no sandbox, the worker crashed, timeout).
    pub const CHECK_FAILED: &str = "check_failed";
    /// The transfer failed (network, store).
    pub const TRANSFER: &str = "transfer_failed";
    /// Internal error (I/O, store).
    pub const INTERNAL: &str = "internal";
    /// Not available on this platform yet (the Windows port, D-134); the message says what.
    pub const NOT_IMPLEMENTED: &str = antenna_proto::control::code::NOT_IMPLEMENTED;
}

/// Crate error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    /// Code from [`code`].
    pub code: &'static str,
    /// Description.
    pub message: String,
}

/// Crate result.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// New error.
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// Internal error.
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(code::INTERNAL, message)
    }

    /// Corrupted ciphertext.
    pub fn corrupt(message: impl Into<String>) -> Self {
        Self::new(code::CORRUPT, message)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::internal(format!("io: {e}"))
    }
}
