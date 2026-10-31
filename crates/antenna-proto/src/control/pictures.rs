// SPDX-License-Identifier: Apache-2.0
//! Profile pictures (x-control/7, `docs/CONTROL.md` §28): the owner chooses a drawn picture or an own photo for
//! themselves and for each of their agents; the daemon announces it to contacts whose nodes have the feature
//! `picture/0` (`docs/PROTOCOL.md` §25) and lists the pictures contacts announced. Owner commands only.
//!
//! A photo, the owner's or a contact's, reaches the window only as the daemon's rebuilt image: pixels decoded in the
//! file check sandbox and encoded again by the daemon, never the bytes the owner chose or a contact sent.

use serde::{Deserialize, Serialize};

/// One picture the window may draw: whose it is and what it is. Neither `drawn` nor `photo`: initials.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PictureEntry {
    /// The contact's label; absent for this node's own pictures (the owner's and the owner's agents').
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// The contact's link (hex); absent for this node's own pictures.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_id: Option<String>,
    /// An agent: one of the owner's (own pictures) or one the contact announced; absent for the person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// A drawn picture by id (`set1/fox`): the window draws it from its own assets, an unknown id as initials.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drawn: Option<String>,
    /// A photo the daemon rebuilt: its id (16 hex, from the rebuilt bytes); `picture_photo` returns the bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo: Option<String>,
    /// A contact's photo that is not shown, and why: `level` (the contact is at trust level 1, where files are not
    /// taken), `refused` (it did not pass the image check), `unavailable` (no check sandbox on this computer).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub withheld: Option<String>,
    /// When the picture was chosen (own) or received, Unix ms.
    #[serde(default)]
    pub updated_ms: u64,
}

/// `pictures`, and the reply to `picture_set`: the owner's own pictures first (the person, then the agents by name),
/// then each contact's (the person, then its agents). Only entries with a picture or a withheld photo are listed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PicturesReply {
    /// Pictures.
    pub pictures: Vec<PictureEntry>,
}

/// `picture_photo`: a rebuilt photo's bytes.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PicturePhotoReply {
    /// The photo's id, as in [`PictureEntry::photo`].
    pub id: String,
    /// `image/jpeg`.
    pub mime: String,
    /// The image, base64 (at most 64 KiB of bytes: the reply stays well within a line).
    pub data_base64: String,
}

impl std::fmt::Debug for PicturePhotoReply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "PicturePhotoReply({}, {}, {} base64 chars)",
            self.id,
            self.mime,
            self.data_base64.len()
        )
    }
}

/// [`PictureEntry::withheld`]: the contact is at trust level 1 (no files from it, SPEC §9).
pub const WITHHELD_LEVEL: &str = "level";
/// [`PictureEntry::withheld`]: the photo did not pass the image check.
pub const WITHHELD_REFUSED: &str = "refused";
/// [`PictureEntry::withheld`]: this computer has no working check sandbox, so no photo from a contact is shown.
pub const WITHHELD_UNAVAILABLE: &str = "unavailable";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{Event, Reply, Request};

    #[test]
    fn requests_parse_and_unknown_fields_are_refused() {
        for (line, name) in [
            (r#"{"cmd":"pictures"}"#, "pictures"),
            (r#"{"cmd":"picture_set","drawn":"set1/fox"}"#, "picture_set"),
            (
                r#"{"cmd":"picture_set","agent":"lead","photo":"/home/u/me.jpg"}"#,
                "picture_set",
            ),
            (r#"{"cmd":"picture_set","remove":true}"#, "picture_set"),
            (
                r#"{"cmd":"picture_photo","id":"0123456789abcdef"}"#,
                "picture_photo",
            ),
        ] {
            let r: Request = serde_json::from_str(line).unwrap();
            assert_eq!(r.name(), name);
            let back = serde_json::to_string(&r).unwrap();
            assert_eq!(serde_json::from_str::<Request>(&back).unwrap(), r);
        }
        assert!(
            serde_json::from_str::<Request>(
                r#"{"cmd":"picture_set","drawn":"set1/fox","frame":"gold"}"#
            )
            .is_err()
        );
    }

    #[test]
    fn replies_and_the_event_on_the_wire() {
        let own = PictureEntry {
            drawn: Some("set1/fox".into()),
            updated_ms: 5,
            ..Default::default()
        };
        let theirs = PictureEntry {
            contact: Some("bob".into()),
            link_id: Some("ab".repeat(32)),
            agent: Some("lead".into()),
            photo: Some("0123456789abcdef".into()),
            updated_ms: 6,
            ..Default::default()
        };
        let r = Reply::Pictures(PicturesReply {
            pictures: vec![own.clone(), theirs],
        });
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["type"], "pictures");
        assert_eq!(
            v["pictures"][0],
            serde_json::json!({"drawn": "set1/fox", "updated_ms": 5})
        );
        assert_eq!(v["pictures"][1]["photo"], "0123456789abcdef");
        assert_eq!(serde_json::from_value::<Reply>(v).unwrap(), r);
        let p = Reply::PicturePhoto(PicturePhotoReply {
            id: "0123456789abcdef".into(),
            mime: "image/jpeg".into(),
            data_base64: "/9j/2Q==".into(),
        });
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["type"], "picture_photo");
        assert_eq!(serde_json::from_value::<Reply>(v).unwrap(), p);
        let e = Event::Picture(own);
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(v["kind"], "picture");
        assert_eq!(v["drawn"], "set1/fox");
        assert_eq!(serde_json::from_value::<Event>(v).unwrap(), e);
    }
}
