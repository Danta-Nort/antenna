// SPDX-License-Identifier: AGPL-3.0-only
//! Level rules for files (SPEC §9 table, "Files" column; §10 steps 1 and 5).
//!
//! | Level | Files | Where | Who accepts | Daily volume |
//! | --- | --- | --- | --- | --- |
//! | 1 | none at all | — | — | 0 |
//! | 2 | received into quarantine | `inbox/` | owner only | 100 MiB |
//! | 3 | exchange | `shared/` | agent or owner | 1 GiB |
//! | 4 | exchange | `shared/` | agent or owner | 10 GiB |
//! | 5 | project folder | set by the owner; without one, `shared/` (D-99) | agent or owner | configurable (default 100 GiB) |
//!
//! The daemon decides, not the model (SPEC §9): these functions are called before the download (from the manifest)
//! and on `accept`. Limits are in binary units (the spec says "100 MB/day"): a file of exactly 1 GiB passes at level 3
//! (DECISIONS D-F-4).

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result, code};
use crate::report::Verdict;

/// 1 MiB.
pub const MIB: u64 = 1 << 20;
/// 1 GiB.
pub const GIB: u64 = 1 << 30;
/// Default level 5 volume.
pub const LEVEL5_DEFAULT_DAILY: u64 = 100 * GIB;

/// Where an accepted file goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Destination {
    /// `~/Antenna/links/<contact>/inbox/` (level 2).
    Inbox,
    /// `~/Antenna/links/<contact>/shared/` (levels 3–4).
    Shared,
    /// The project folder set by the owner (level 5); without one, the link's `shared/` (D-99).
    Project,
}

/// Level rule for incoming files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LevelFiles {
    /// Daily volume, bytes.
    pub daily_bytes: u64,
    /// Where to accept into.
    pub dest: Destination,
    /// Whether the agent may accept a clean file by itself.
    pub agent_may_accept: bool,
}

/// Level rule; `None` means no files at all (level 1 and anything below).
pub fn level_files(level: u8, level5_daily: Option<u64>) -> Option<LevelFiles> {
    match level {
        2 => Some(LevelFiles {
            daily_bytes: 100 * MIB,
            dest: Destination::Inbox,
            agent_may_accept: false,
        }),
        3 => Some(LevelFiles {
            daily_bytes: GIB,
            dest: Destination::Shared,
            agent_may_accept: true,
        }),
        4 => Some(LevelFiles {
            daily_bytes: 10 * GIB,
            dest: Destination::Shared,
            agent_may_accept: true,
        }),
        5 => Some(LevelFiles {
            daily_bytes: level5_daily.unwrap_or(LEVEL5_DEFAULT_DAILY),
            dest: Destination::Project,
            agent_may_accept: true,
        }),
        _ => None,
    }
}

/// Decision from the manifest before the download (SPEC §10 step 1): may this file be downloaded at all from a contact
/// at level `level`.
pub fn admit(
    level: u8,
    size: u64,
    used_today: u64,
    level5_daily: Option<u64>,
) -> Result<LevelFiles> {
    let Some(rule) = level_files(level, level5_daily) else {
        return Err(Error::new(
            code::LEVEL_FORBIDS_FILES,
            format!("trust level {level} gets no files"),
        ));
    };
    if used_today.saturating_add(size) > rule.daily_bytes {
        return Err(Error::new(
            code::QUOTA,
            format!(
                "daily file volume of level {level} is {} bytes; used {used_today}, file {size}",
                rule.daily_bytes
            ),
        ));
    }
    Ok(rule)
}

/// Owner confirmation for `--force`. Only the daemon creates it, **after** checking the owner's password (Q-12a). There
/// is no way to check the password here: this is an API boundary, not a security boundary (within one process there is
/// none).
#[derive(Debug)]
pub struct OwnerForce(());

impl OwnerForce {
    /// Call only after a successful owner password check.
    pub fn after_owner_password_check() -> Self {
        Self(())
    }

    /// Call only after the daemon verified that the file is an asset of a release signed by a key it pins (the
    /// signed update flow, D-103): the owner's standing word at level 5 for the program or installer it is (D-130).
    pub fn signed_release() -> Self {
        Self(())
    }
}

/// Who accepts the file.
#[derive(Debug)]
pub enum Acceptor<'a> {
    /// The agent (with its own token).
    Agent,
    /// The owner.
    Owner,
    /// The owner with `--force` and the password: may accept both a threat and an unchecked file (SPEC §10 step 5).
    OwnerForce(&'a OwnerForce),
}

/// Whether the file may be accepted (SPEC §10 step 5): level, check verdict, who accepts, whether the name needs a
/// separate approval (dot files and auto-executable names).
pub fn may_accept(
    level: u8,
    verdict: Verdict,
    acceptor: &Acceptor<'_>,
    special_name: bool,
    special_approved: bool,
) -> Result<()> {
    let Some(rule) = level_files(level, None) else {
        return Err(Error::new(
            code::LEVEL_FORBIDS_FILES,
            format!("trust level {level} gets no files"),
        ));
    };
    let forced = matches!(acceptor, Acceptor::OwnerForce(_));
    match verdict {
        Verdict::Threat | Verdict::Failed if !forced => {
            return Err(Error::new(
                code::FORBIDDEN,
                format!(
                    "check verdict is {}: only the owner with --force and password may accept",
                    verdict.as_str()
                ),
            ));
        }
        Verdict::Suspicious if matches!(acceptor, Acceptor::Agent) => {
            return Err(Error::new(
                code::FORBIDDEN,
                "check verdict is suspicious: the owner decides",
            ));
        }
        Verdict::Clean if matches!(acceptor, Acceptor::Agent) && !rule.agent_may_accept => {
            return Err(Error::new(
                code::FORBIDDEN,
                format!("trust level {level}: files are accepted only by the owner"),
            ));
        }
        _ => {}
    }
    if special_name && !special_approved && !forced {
        return Err(Error::new(
            code::APPROVAL_REQUIRED,
            "dot-files and auto-executed names need a separate approve of the owner",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_one_gets_nothing_and_quotas_hold() {
        assert_eq!(
            admit(1, 1, 0, None).unwrap_err().code,
            code::LEVEL_FORBIDS_FILES
        );
        assert_eq!(
            admit(0, 1, 0, None).unwrap_err().code,
            code::LEVEL_FORBIDS_FILES
        );
        assert_eq!(
            admit(2, 100 * MIB, 0, None).unwrap().dest,
            Destination::Inbox
        );
        assert_eq!(admit(2, 1, 100 * MIB, None).unwrap_err().code, code::QUOTA);
        assert_eq!(admit(3, GIB, 0, None).unwrap().dest, Destination::Shared);
        assert_eq!(admit(3, GIB + 1, 0, None).unwrap_err().code, code::QUOTA);
        assert!(admit(4, 10 * GIB, 0, None).is_ok());
        assert_eq!(admit(5, 2, 0, Some(1)).unwrap_err().code, code::QUOTA);
        assert_eq!(
            admit(3, u64::MAX, u64::MAX, None).unwrap_err().code,
            code::QUOTA
        );
    }

    #[test]
    fn who_may_accept_what() {
        let force = OwnerForce::after_owner_password_check();
        let f = Acceptor::OwnerForce(&force);
        // Level 2: owner only.
        assert!(may_accept(2, Verdict::Clean, &Acceptor::Agent, false, false).is_err());
        assert!(may_accept(2, Verdict::Clean, &Acceptor::Owner, false, false).is_ok());
        // Level 3: clean, the agent; suspicious, the owner.
        assert!(may_accept(3, Verdict::Clean, &Acceptor::Agent, false, false).is_ok());
        assert!(may_accept(3, Verdict::Suspicious, &Acceptor::Agent, false, false).is_err());
        assert!(may_accept(3, Verdict::Suspicious, &Acceptor::Owner, false, false).is_ok());
        // Threat and unchecked: only --force.
        for v in [Verdict::Threat, Verdict::Failed] {
            assert!(may_accept(5, v, &Acceptor::Agent, false, false).is_err());
            assert!(may_accept(5, v, &Acceptor::Owner, false, false).is_err());
            assert!(may_accept(5, v, &f, false, false).is_ok());
        }
        // Level 1: nobody, not even --force.
        assert!(may_accept(1, Verdict::Clean, &f, false, false).is_err());
        // Special name: separate approval.
        assert_eq!(
            may_accept(4, Verdict::Clean, &Acceptor::Agent, true, false)
                .unwrap_err()
                .code,
            code::APPROVAL_REQUIRED
        );
        assert!(may_accept(4, Verdict::Clean, &Acceptor::Agent, true, true).is_ok());
    }
}
