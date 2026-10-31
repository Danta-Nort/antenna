// SPDX-License-Identifier: Apache-2.0
//! My devices (v7, `docs/CONTROL.md` §27, experimental): the owner's own computers (contacts at trust level 5) as the
//! daemon learned them over their links (`docs/PROTOCOL.md` §24), approvals answered from another own device (D-106),
//! a lost computer, and "Lend this computer to my teams". Owner commands only; agents have none of them.

use serde::{Deserialize, Serialize};

pub use crate::device::{DeviceAgent, DeviceApproval, HealthFact, UpdateFacts};

fn is_false(b: &bool) -> bool {
    !*b
}

/// `devices` reply: this computer and every contact at trust level 5.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevicesReply {
    /// This computer, as the others see it.
    pub this: ThisDevice,
    /// The owner's other computers.
    pub devices: Vec<DeviceInfo>,
}

/// This computer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThisDevice {
    /// Its name (host name).
    pub name: String,
    /// `macos`, `linux`.
    pub os: String,
    /// The OS release, when known.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub os_version: String,
    /// `aarch64`, `x86_64`.
    pub arch: String,
    /// The daemon's version.
    pub version: String,
    /// "Lend this computer to my teams" (off by default; the teams read it).
    pub lend: bool,
    /// The keys this computer answers its other devices' approval requests with: its owner keys (Touch ID) and its own
    /// device key (used only after the password is typed here).
    pub keys: Vec<DeviceKeyInfo>,
    /// Computers removed here as lost whose keys the other devices are still told about.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lost: Vec<LostInfo>,
}

/// A key a device answers approvals with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceKeyInfo {
    /// 16 hex.
    pub key_id: String,
    /// Its label on that device.
    pub label: String,
    /// `touch_id` or `password`.
    pub kind: String,
    /// The public key, base64 of the 65-byte point.
    pub public_key: String,
    /// When this computer's owner confirmed it (only in `confirmed`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confirmed_ms: Option<u64>,
}

/// One of the owner's other computers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceInfo {
    /// Contact label.
    pub contact: String,
    /// Link ID (hex).
    pub link_id: String,
    /// `online` / `offline`.
    pub presence: String,
    /// Its node speaks own devices (`device/0`); `false`: an older Antenna there, or not known until it connects.
    pub supported: bool,
    /// What it last told this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<DeviceView>,
    /// When that arrived (this computer's clock, Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub received_ms: Option<u64>,
    /// Its keys this computer accepts approvals from (its owner confirmed them here).
    pub confirmed: Vec<DeviceKeyInfo>,
    /// Keys it announced that are not confirmed here.
    pub offered: Vec<DeviceKeyInfo>,
    /// Which of this computer's keys it accepts approvals from (it says so in its status).
    pub accepts_mine: Vec<String>,
    /// Another own device reported it as lost.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lost_by: Option<LostReport>,
    /// Its node stops its agents when this computer's owner asks (`agent-stop/0`, `device_agent_stop`, §33).
    #[serde(default, skip_serializing_if = "is_false")]
    pub stop_agents: bool,
}

/// What a device last said about itself (`docs/PROTOCOL.md` §24).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceView {
    /// When it made it (its clock, Unix ms).
    pub at_ms: u64,
    /// Its name.
    pub name: String,
    /// OS.
    pub os: String,
    /// OS release.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub os_version: String,
    /// CPU architecture.
    pub arch: String,
    /// Total memory, bytes.
    #[serde(default)]
    pub memory_bytes: u64,
    /// Its daemon's version.
    pub version: String,
    /// Updates there.
    pub update: UpdateFacts,
    /// Problems its own checks see.
    pub health: Vec<HealthFact>,
    /// Its agents.
    pub agents: Vec<DeviceAgent>,
    /// Its pending approval requests (newest first, at most 32).
    pub approvals: Vec<DeviceApproval>,
    /// How many are pending there in all.
    pub pending_approvals: u32,
    /// It lends itself to the owner's teams.
    pub lend: bool,
}

/// A computer this node removed as lost.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LostInfo {
    /// Its label here when it was removed.
    pub contact: String,
    /// Its key IDs.
    pub key_ids: Vec<String>,
    /// When (Unix ms).
    pub at_ms: u64,
}

/// Another own device reported this one as lost.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LostReport {
    /// The device that reported it (its label here).
    pub contact: String,
    /// When it was removed there (its clock, Unix ms).
    pub at_ms: u64,
}

/// `device_challenge` reply: the other device's one-time challenge, for one remote decision on the link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceChallenge {
    /// Contact label.
    pub contact: String,
    /// The link (hex): the signed request names it.
    pub link_id: String,
    /// 64 hex.
    pub nonce: String,
    /// When it expires (the other device's clock, Unix ms).
    pub expires_ms: u64,
}

/// `device_approve` / `device_decide` reply: what the other device did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceDecided {
    /// Contact label.
    pub contact: String,
    /// The approval request there.
    pub id: String,
    /// Its state there now (`approved`, `denied`).
    pub state: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{Event, Reply, Request};

    #[test]
    fn requests_parse_and_are_owner_commands() {
        for (line, name) in [
            (r#"{"cmd":"devices"}"#, "devices"),
            (
                r#"{"cmd":"device_challenge","contact":"mini"}"#,
                "device_challenge",
            ),
            (
                r#"{"cmd":"device_approve","contact":"mini","request":"{}","nonce":"00","key_id":"01b3e9c533123cb8","sig":"AA=="}"#,
                "device_approve",
            ),
            (
                r#"{"cmd":"device_decide","contact":"mini","id":"k2","decision":"approve","fingerprint":"9c","password":"pw"}"#,
                "device_decide",
            ),
            (
                r#"{"cmd":"device_decide","contact":"mini","id":"k2","decision":"deny"}"#,
                "device_decide",
            ),
            (
                r#"{"cmd":"device_keys_confirm","contact":"mini","key_ids":["01b3e9c533123cb8"],"password":"pw"}"#,
                "device_keys_confirm",
            ),
            (
                r#"{"cmd":"device_keys_remove","contact":"mini","key_ids":[]}"#,
                "device_keys_remove",
            ),
            (
                r#"{"cmd":"device_lend_set","enabled":true,"password":"pw"}"#,
                "device_lend_set",
            ),
            (
                r#"{"cmd":"device_lend_set","enabled":false}"#,
                "device_lend_set",
            ),
            (
                r#"{"cmd":"device_revoke","contact":"mini","password":"pw"}"#,
                "device_revoke",
            ),
            (
                r#"{"cmd":"device_lost_dismiss","contact":"mini"}"#,
                "device_lost_dismiss",
            ),
        ] {
            let r: Request = serde_json::from_str(line).unwrap_or_else(|e| panic!("{line}: {e}"));
            assert_eq!(r.name(), name);
            // The Debug of a request names it only (passwords stay out of logs)
            assert!(!format!("{r:?}").contains("pw"));
        }
        // What asks for the password: confirming keys, turning lending on, revoking, approving by password
        let pw = |l: &str| {
            serde_json::from_str::<Request>(l)
                .unwrap()
                .owner_password()
                .is_some()
        };
        assert!(pw(
            r#"{"cmd":"device_keys_confirm","contact":"m","key_ids":[],"password":"p"}"#
        ));
        assert!(pw(
            r#"{"cmd":"device_lend_set","enabled":true,"password":"p"}"#
        ));
        assert!(!pw(r#"{"cmd":"device_lend_set","enabled":false}"#));
        assert!(pw(
            r#"{"cmd":"device_revoke","contact":"m","password":"p"}"#
        ));
        assert!(pw(
            r#"{"cmd":"device_decide","contact":"m","id":"k","decision":"approve","password":"p"}"#
        ));
        assert!(!pw(
            r#"{"cmd":"device_decide","contact":"m","id":"k","decision":"deny"}"#
        ));
        assert!(!pw(
            r#"{"cmd":"device_approve","contact":"m","request":"{}","nonce":"00","key_id":"k","sig":"s"}"#
        ));
        // The commands without a password take no local owner proof: `device_approve` carries a proof for the other
        // computer, never one for this daemon
        for l in [
            r#"{"cmd":"devices"}"#,
            r#"{"cmd":"device_approve","contact":"m","request":"{}","nonce":"00","key_id":"k","sig":"s"}"#,
            r#"{"cmd":"device_keys_remove","contact":"m","key_ids":[]}"#,
        ] {
            let r: Request = serde_json::from_str(l).unwrap();
            assert!(!r.accepts_proof(), "{l}");
        }
        // Those with the password take a local owner proof in its place (D-131)
        for l in [
            r#"{"cmd":"device_keys_confirm","contact":"m","key_ids":[],"password":""}"#,
            r#"{"cmd":"device_lend_set","enabled":true}"#,
            r#"{"cmd":"device_revoke","contact":"m","password":""}"#,
            r#"{"cmd":"device_decide","contact":"m","id":"k","decision":"approve"}"#,
        ] {
            let r: Request = serde_json::from_str(l).unwrap();
            assert!(r.accepts_proof() && !r.password_given(), "{l}");
        }
        let r: Request = serde_json::from_str(r#"{"cmd":"devices"}"#).unwrap();
        assert!(!r.allowed_without_session());
        // Strict: unknown fields are refused
        assert!(serde_json::from_str::<Request>(r#"{"cmd":"devices","x":1}"#).is_err());
    }

    #[test]
    fn replies_and_the_event_have_their_wire_shape() {
        let r = Reply::DeviceDecided(DeviceDecided {
            contact: "mini".into(),
            id: "k2".into(),
            state: "approved".into(),
        });
        let j = serde_json::to_value(&r).unwrap();
        assert_eq!(j["type"], "device_decided");
        let r = Reply::DeviceChallenge(DeviceChallenge {
            contact: "mini".into(),
            link_id: "ab".into(),
            nonce: "00".into(),
            expires_ms: 1,
        });
        assert_eq!(
            serde_json::to_value(&r).unwrap()["type"],
            "device_challenge"
        );
        let e = Event::Device {
            contact: "mini".into(),
            link_id: "ab".into(),
            change: "status".into(),
        };
        let j = serde_json::to_value(&e).unwrap();
        assert_eq!(
            (j["kind"].as_str(), j["change"].as_str()),
            (Some("device"), Some("status"))
        );
        let d = DevicesReply {
            this: ThisDevice {
                name: "mac".into(),
                os: "macos".into(),
                os_version: String::new(),
                arch: "aarch64".into(),
                version: "antennad 0.2.0".into(),
                lend: false,
                keys: vec![],
                lost: vec![],
            },
            devices: vec![],
        };
        let j = serde_json::to_string(&Reply::Devices(d.clone())).unwrap();
        assert!(j.starts_with(r#"{"type":"devices""#), "{j}");
        assert!(!j.contains("os_version") && !j.contains("lost"), "{j}");
        let back: Reply = serde_json::from_str(&j).unwrap();
        assert_eq!(back, Reply::Devices(d));
    }
}
