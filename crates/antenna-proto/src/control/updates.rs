// SPDX-License-Identifier: Apache-2.0
//! Updates that install by themselves (x-control/7, D-103, `docs/CONTROL.md` §23): the owner's setting and what the
//! daemon did, the `update_auto` event, and the `updated` fact in `status` of a daemon that came up from such an update.
//! Also the file-name check of `file_name_check` (`docs/CONTROL.md` §14), which the window uses when a received file's
//! name is already taken in the link folder.

use serde::{Deserialize, Serialize};

/// `update_auto_status` / `update_auto_set` / `update_auto_now` / `update_auto_later`: the setting of this computer and
/// what the daemon knows about automatic installs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateAutoInfo {
    /// The owner turned on "Install signed updates by itself" on this computer (off by default).
    pub enabled: bool,
    /// This installation can replace itself (`antenna update` knows it: the macOS app, the `install.sh` layout).
    pub supported: bool,
    /// Why it cannot (a development build, the Linux window bundle, no `antenna` next to the daemon), for the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unsupported_reason: Option<String>,
    /// The daemon holds the keys for the update's restart (the setting is on and the keys are unlocked, or the owner
    /// started one install with the password, D-137): the new version will come up unlocked.
    pub keys_kept: bool,
    /// The update URL checked once a day, whatever the setting (from `ANTENNA_UPDATE_URL`,
    /// `~/.config/antenna/update-url`, or built into release builds since 0.1.0-preview.11, D-137; never set remotely),
    /// if there is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// When the update URL was last checked (Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_check_ms: Option<u64>,
    /// A verified release that waits to be installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub staged: Option<StagedUpdate>,
    /// The most recent automatic install or refusal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<UpdateRecord>,
    /// Versions whose install failed on this computer: never tried again by themselves (the owner can still install
    /// one with `antenna update --from`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failed: Vec<String>,
    /// Recent records, newest first (at most 20).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history: Vec<UpdateRecord>,
}

/// A verified release the daemon will install when agents are idle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StagedUpdate {
    /// Release version (`0.1.0-preview.8`).
    pub version: String,
    /// `link` (release files from a level-5 contact) or `url` (the daily check).
    pub source: String,
    /// The contact's label, for `source: "link"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// When it was verified and staged (Unix ms).
    pub staged_ms: u64,
    /// `waiting` (for 10 minutes without agent activity), `soon` (installs at `at_ms`; the owner may postpone it),
    /// `installing`.
    pub state: String,
    /// With `soon`: when the install starts; with `waiting` after "Later": not before then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at_ms: Option<u64>,
}

/// One automatic install, refusal or failure (the daemon's record; also written to the delivering link's audit log).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateRecord {
    /// Release version.
    pub version: String,
    /// `installed`, `failed` (the install did not finish; the old version runs), `refused` (the release did not
    /// verify or is not for this computer).
    pub result: String,
    /// For `failed` and `refused`: a code (`bad_signature`, `not_newer`, `wrong_platform`, `hash_mismatch`,
    /// `install_failed`, …) and the reason.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// `link` or `url`.
    pub source: String,
    /// The contact's label, for `source: "link"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// The version installed before (`installed`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// For `installed`: whether the keys came across the restart (`true`) or the new version came up locked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unlocked: Option<bool>,
    /// When (Unix ms).
    pub at_ms: u64,
}

/// The `update_auto` event (x-control/7, owner subscriptions only).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateAutoEvent {
    /// `staged`, `soon`, `installing`, `refused`, `failed`, `postponed`.
    pub state: String,
    /// Release version.
    pub version: String,
    /// `link` or `url`.
    pub source: String,
    /// The contact's label, for `source: "link"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// With `soon` and `postponed`: when the install starts at the earliest (Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at_ms: Option<u64>,
    /// With `refused` and `failed`: a code and the reason.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// In `status` (x-control/7): this daemon process came up from an automatic update (D-103), so a window that was
/// relaunched by the installer knows it and can restore its Code mode agents. Absent otherwise.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdatedInfo {
    /// The version before (`0.1.0-preview.7`).
    pub from: String,
    /// The version now.
    pub to: String,
    /// When the new version came up (Unix ms).
    pub at_ms: u64,
    /// The keys came across the restart (the daemon is unlocked without the password).
    pub unlocked: bool,
}

/// `file_name_check`: can a received file be accepted under this name (preview.8)?
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileNameCheck {
    /// The name as it would be saved (normalized), or the name given when it is `invalid`.
    pub name: String,
    /// `free`; `taken` (another file has this name, ignoring case); `same_file` (a file with this name and the same
    /// content is already there: accepting it saves nothing new); `invalid` (the name breaks the naming rules).
    pub state: String,
    /// With `taken`: a free name in the same folder (`report (2).pdf`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
    /// With `taken` and `invalid`: why, for the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{Event, Reply, Request, StatusReply};

    #[test]
    fn a_preview7_status_still_parses_and_old_clients_ignore_updated() {
        let s: StatusReply = serde_json::from_str(
            r#"{"state":"locked","daemon":"antennad 0.1.0-preview.7 (e142081)","protocol":"x/0","relay":"n0","links":null}"#,
        )
        .unwrap();
        assert_eq!(s.updated, None);
        let line = serde_json::to_string(&s).unwrap();
        assert!(!line.contains("updated"), "{line}");
    }

    #[test]
    fn update_auto_commands_and_replies_round_trip() {
        for (line, name) in [
            (r#"{"cmd":"update_auto_status"}"#, "update_auto_status"),
            (r#"{"cmd":"update_auto_now"}"#, "update_auto_now"),
            (r#"{"cmd":"update_auto_later"}"#, "update_auto_later"),
            (
                r#"{"cmd":"update_auto_set","enabled":true,"password":"p"}"#,
                "update_auto_set",
            ),
            (r#"{"cmd":"agent_watch","agent":"claude"}"#, "agent_watch"),
            (
                r#"{"cmd":"file_name_check","id":"ab","name":"x.txt"}"#,
                "file_name_check",
            ),
        ] {
            let r: Request = serde_json::from_str(line).unwrap();
            assert_eq!(r.name(), name);
            assert_eq!(serde_json::to_string(&r).unwrap(), line);
        }
        let info = UpdateAutoInfo {
            enabled: true,
            supported: true,
            keys_kept: true,
            staged: Some(StagedUpdate {
                version: "0.1.0-preview.8".into(),
                source: "link".into(),
                contact: Some("Mac".into()),
                staged_ms: 1,
                state: "waiting".into(),
                at_ms: None,
            }),
            ..Default::default()
        };
        let r = Reply::UpdateAuto(info.clone());
        let line = serde_json::to_string(&r).unwrap();
        assert!(
            line.starts_with(r#"{"type":"update_auto","enabled":true"#),
            "{line}"
        );
        assert_eq!(serde_json::from_str::<Reply>(&line).unwrap(), r);
        let e = Event::UpdateAuto(UpdateAutoEvent {
            state: "soon".into(),
            version: "0.1.0-preview.8".into(),
            source: "url".into(),
            contact: None,
            at_ms: Some(5),
            reason: None,
        });
        let line = serde_json::to_string(&e).unwrap();
        assert_eq!(
            line,
            r#"{"kind":"update_auto","state":"soon","version":"0.1.0-preview.8","source":"url","at_ms":5}"#
        );
    }

    #[test]
    fn the_setting_needs_the_password_both_ways_and_the_rest_a_session() {
        for enabled in [true, false] {
            let r = Request::UpdateAutoSet {
                enabled,
                password: "hunter2".into(),
            };
            assert_eq!(r.owner_password(), Some("hunter2"));
            assert!(!format!("{r:?}").contains("hunter2"));
        }
        // "Install now" with the setting off opens the root key for the restart: the password, never a proof (D-137).
        let now = Request::UpdateAutoNow {
            password: Some("hunter2".into()),
        };
        assert_eq!(now.owner_password(), Some("hunter2"));
        assert!(!now.accepts_proof());
        assert!(!format!("{now:?}").contains("hunter2"));
        assert_eq!(
            serde_json::to_string(&now).unwrap(),
            r#"{"cmd":"update_auto_now","password":"hunter2"}"#
        );
        for r in [
            Request::UpdateAutoStatus {},
            Request::UpdateAutoNow { password: None },
            Request::UpdateAutoLater {},
            Request::FileNameCheck {
                id: "ab".into(),
                name: None,
            },
        ] {
            assert_eq!(r.owner_password(), None);
            assert!(!r.allowed_without_session(), "{}", r.name());
        }
        // The window that started an agent watches its facts before anyone signed in; the daemon checks the process
        // tree instead (CONTROL §23).
        let w = Request::AgentWatch {
            agent: "claude".into(),
        };
        assert!(w.allowed_without_session());
        assert_eq!(w.owner_password(), None);
    }
}
