// SPDX-License-Identifier: AGPL-3.0-only
//! Core error: a machine-readable code (also passed on to the control protocol) plus human-readable text.
//!
//! Error text must not contain secrets or message contents (SPEC §13).

use antenna_proto::control::{ApprovalInfo, ErrorBody, code};

/// Core error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    /// Code from [`antenna_proto::control::code`].
    pub code: &'static str,
    /// Description.
    pub message: String,
    /// For `approval_required`: the request to the owner.
    pub approval: Option<Box<ApprovalInfo>>,
}

/// Core result.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// New error.
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            approval: None,
        }
    }

    /// Policy: owner approval is required (`antenna approve <id>`). An agent is told what happens next instead of a
    /// command for the owner (D-100): the owner decides in Antenna, not on the agent's word in its terminal.
    pub fn approval(info: ApprovalInfo) -> Self {
        let reasons = info.reasons.join(", ");
        let message = if info.requester == "owner" {
            format!(
                "the owner must approve request {} (antenna approve {}); reasons: {reasons}",
                info.id, info.id
            )
        } else if info.completes {
            format!(
                "request {} waits for the owner's approval (reasons: {reasons}); once approved, the daemon carries \
                 out exactly this call itself and reports approval_resolved: do not repeat it",
                info.id
            )
        } else {
            format!(
                "request {} waits for the owner's approval (reasons: {reasons}); the daemon reports the decision \
                 as approval_resolved, then do the same action once more",
                info.id
            )
        };
        Self {
            code: code::APPROVAL_REQUIRED,
            message,
            approval: Some(Box::new(info)),
        }
    }

    /// Control protocol error body.
    pub fn body(&self) -> ErrorBody {
        ErrorBody {
            code: self.code.into(),
            message: self.message.clone(),
            approval: self.approval.clone(),
        }
    }

    /// Internal error.
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(code::INTERNAL, message)
    }

    /// Bad request.
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(code::BAD_REQUEST, message)
    }

    /// Pairing error.
    pub fn pairing(message: impl Into<String>) -> Self {
        Self::new(code::PAIRING_FAILED, message)
    }

    /// Network.
    pub fn network(message: impl Into<String>) -> Self {
        Self::new(code::NETWORK, message)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::internal(format!("db: {e}"))
    }
}

impl From<libsignal_protocol::SignalProtocolError> for Error {
    fn from(e: libsignal_protocol::SignalProtocolError) -> Self {
        Error::internal(format!("libsignal: {e}"))
    }
}

impl From<antenna_proto::CodecError> for Error {
    fn from(e: antenna_proto::CodecError) -> Self {
        Error::new(code::BAD_REQUEST, e.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::internal(format!("io: {e}"))
    }
}

impl From<antenna_files::Error> for Error {
    // File error codes (`docs/CONTROL.md` §14): shared ones map to the control protocol codes, the rest pass as is
    fn from(e: antenna_files::Error) -> Self {
        let c = match e.code {
            antenna_files::error::code::FORBIDDEN => code::FORBIDDEN,
            antenna_files::error::code::NOT_FOUND => code::NOT_FOUND,
            antenna_files::error::code::INTERNAL => code::INTERNAL,
            antenna_files::error::code::LEVEL_FORBIDS_FILES => code::DENIED,
            other => other,
        };
        Error::new(c, e.message)
    }
}

/// Shorthand for `Err(Error::new(code, format!(...)))`.
#[macro_export]
macro_rules! bail {
    ($code:expr, $($arg:tt)*) => {
        return Err($crate::error::Error::new($code, format!($($arg)*)))
    };
}
