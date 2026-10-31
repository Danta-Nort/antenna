// SPDX-License-Identifier: Apache-2.0
//! Profile pictures (`docs/PROTOCOL.md` §25, feature `picture/0`): a side tells its contact which picture to show for
//! the side's owner or for one of its agents.
//!
//! A drawn picture travels as its id only (`set1/fox`): the receiver draws it from its own copy of the set, and an id
//! it does not know is shown as initials, so a later set needs no protocol change. A photo travels as a small image
//! (at most [`MAX_PHOTO`] bytes) inside the signed message; the receiver never shows those bytes: it checks them in its
//! file check sandbox like any received image and shows only the pixels its daemon rebuilt (SPEC §10 step 4).

use serde::{Deserialize, Serialize};

/// The largest photo in a picture message, in bytes (as large as the largest text, `link::MAX_TEXT`).
pub const MAX_PHOTO: usize = 64 * 1024;
/// The largest side of a photo the sender makes, in pixels.
pub const PHOTO_SIDE: u32 = 512;
/// Image types a picture photo may have. A sender of this implementation writes JPEG; PNG and WebP are accepted from
/// other implementations. The receiver's check decides by content, not by this field.
pub const PHOTO_MIMES: &[&str] = &["image/jpeg", "image/png", "image/webp"];
/// The longest drawn picture id: a set id (≤ 16) and an animal id (≤ 32) with the slash.
pub const MAX_DRAWN_ID: usize = 49;

/// `control` body `{"picture": …}`: the picture of the side's owner (no `agent`) or of one of its agents. Neither
/// `drawn` nor `photo` means the picture was removed (initials again). Only the side's link-root authors it, like an
/// agent announcement (`docs/PROTOCOL.md` §21): the side vouches for its agents' pictures.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PictureBody {
    /// The side's agent by the name it announced (§21); absent for the side's owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// A drawn picture by id, `<set>/<animal>` ([`valid_drawn_id`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drawn: Option<String>,
    /// An own photo.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo: Option<PicturePhoto>,
}

/// A photo inside a picture message.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PicturePhoto {
    /// One of [`PHOTO_MIMES`].
    pub mime: String,
    /// The image, 1…[`MAX_PHOTO`] bytes.
    #[serde(with = "serde_bytes")]
    pub data: Vec<u8>,
}

impl std::fmt::Debug for PicturePhoto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PicturePhoto({}, {} bytes)", self.mime, self.data.len())
    }
}

impl PictureBody {
    /// The fields fit the format: a valid agent name, a valid drawn id, a photo of an allowed type and size, not both
    /// a drawn picture and a photo.
    pub fn valid(&self) -> bool {
        self.agent
            .as_deref()
            .is_none_or(crate::AgentAnnounce::valid_name)
            && self.drawn.as_deref().is_none_or(valid_drawn_id)
            && self.photo.as_ref().is_none_or(|p| {
                PHOTO_MIMES.contains(&p.mime.as_str())
                    && !p.data.is_empty()
                    && p.data.len() <= MAX_PHOTO
            })
            && !(self.drawn.is_some() && self.photo.is_some())
    }

    /// The picture is removed.
    pub fn is_removal(&self) -> bool {
        self.drawn.is_none() && self.photo.is_none()
    }
}

/// A drawn picture id: `<set>/<animal>`, the set `[a-z0-9]{1,16}`, the animal `[a-z0-9_-]{1,32}` starting with a
/// letter or digit.
pub fn valid_drawn_id(id: &str) -> bool {
    let Some((set, animal)) = id.split_once('/') else {
        return false;
    };
    let lower_digit = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit();
    !set.is_empty()
        && set.len() <= 16
        && set.chars().all(lower_digit)
        && !animal.is_empty()
        && animal.len() <= 32
        && animal.starts_with(lower_digit)
        && animal
            .chars()
            .all(|c| lower_digit(c) || c == '-' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Body, EnvelopeCore, MessageId, MessageType, from_cbor, to_cbor};

    fn core(body: Body) -> EnvelopeCore {
        EnvelopeCore {
            salt: [2; 32],
            author: [3; 32],
            parents: vec![MessageId([4; 32])],
            lamport: 9,
            ts: 1_790_000_000_000,
            n: 3,
            kind: MessageType::Control,
            body,
            to: None,
            topic: None,
            urgent: None,
        }
    }

    fn get<'a>(v: &'a ciborium::Value, k: &str) -> Option<&'a ciborium::Value> {
        v.as_map()?
            .iter()
            .find(|(kk, _)| kk.as_text() == Some(k))
            .map(|(_, v)| v)
    }

    #[test]
    fn a_drawn_picture_travels_as_its_id_only() {
        let c = core(Body::Picture(PictureBody {
            agent: None,
            drawn: Some("set1/fox".into()),
            photo: None,
        }));
        let bytes = to_cbor(&c).unwrap();
        let back: EnvelopeCore = from_cbor(&bytes).unwrap();
        assert_eq!(back, c);
        // PROTOCOL §25: "body": {"picture": {"drawn": "set1/fox"}}, nothing else
        let v: ciborium::Value = from_cbor(&bytes).unwrap();
        let body = get(&v, "body").unwrap();
        let pic = get(body, "picture").unwrap();
        assert_eq!(pic.as_map().unwrap().len(), 1);
        assert_eq!(get(pic, "drawn").unwrap().as_text(), Some("set1/fox"));
        assert_eq!(get(&v, "type").unwrap().as_text(), Some("control"));
    }

    #[test]
    fn a_photo_and_an_agent_round_trip_and_the_photo_is_bytes() {
        let c = core(Body::Picture(PictureBody {
            agent: Some("front-desk".into()),
            drawn: None,
            photo: Some(PicturePhoto {
                mime: "image/jpeg".into(),
                data: vec![0xff, 0xd8, 0xff, 0xd9],
            }),
        }));
        let bytes = to_cbor(&c).unwrap();
        assert_eq!(from_cbor::<EnvelopeCore>(&bytes).unwrap(), c);
        let v: ciborium::Value = from_cbor(&bytes).unwrap();
        let pic = get(get(&v, "body").unwrap(), "picture").unwrap();
        assert_eq!(get(pic, "agent").unwrap().as_text(), Some("front-desk"));
        assert!(get(get(pic, "photo").unwrap(), "data").unwrap().is_bytes());
    }

    #[test]
    fn unknown_fields_are_refused() {
        // A future field must come with a new feature, never inside this body (D-63, D-75).
        let v = ciborium::Value::Map(vec![(
            ciborium::Value::Text("picture".into()),
            ciborium::Value::Map(vec![
                (
                    ciborium::Value::Text("drawn".into()),
                    ciborium::Value::Text("set1/fox".into()),
                ),
                (
                    ciborium::Value::Text("frame".into()),
                    ciborium::Value::Text("gold".into()),
                ),
            ]),
        )]);
        let bytes = to_cbor(&v).unwrap();
        assert!(from_cbor::<Body>(&bytes).is_err());
    }

    #[test]
    fn validity() {
        let ok = |agent: Option<&str>, drawn: Option<&str>, photo: Option<(&str, usize)>| {
            PictureBody {
                agent: agent.map(Into::into),
                drawn: drawn.map(Into::into),
                photo: photo.map(|(m, n)| PicturePhoto {
                    mime: m.into(),
                    data: vec![1; n],
                }),
            }
            .valid()
        };
        assert!(ok(None, Some("set1/fox"), None));
        assert!(ok(None, Some("set9/snow-leopard"), None));
        assert!(ok(Some("lead"), None, Some(("image/jpeg", MAX_PHOTO))));
        assert!(ok(None, None, None), "a removal");
        assert!(!ok(None, None, Some(("image/jpeg", MAX_PHOTO + 1))));
        assert!(!ok(None, None, Some(("image/jpeg", 0))));
        assert!(!ok(None, None, Some(("image/svg+xml", 10))));
        assert!(
            !ok(None, Some("set1/fox"), Some(("image/jpeg", 10))),
            "both"
        );
        assert!(
            !ok(Some("owner"), Some("set1/fox"), None),
            "a reserved name"
        );
        assert!(!ok(Some("a b"), Some("set1/fox"), None));
        for bad in [
            "",
            "fox",
            "set1/",
            "/fox",
            "Set1/fox",
            "set1/Fox",
            "set1/-fox",
            "set1/fox/x",
            "set1/../fox",
            "set1/fox.png",
            "set1/\u{43b}\u{438}\u{441}\u{430}",
            "set12345678901234/fox",
        ] {
            assert!(!valid_drawn_id(bad), "{bad:?}");
        }
        assert!(valid_drawn_id(&format!(
            "{}/{}",
            "s".repeat(16),
            "a".repeat(32)
        )));
        assert_eq!(16 + 1 + 32, MAX_DRAWN_ID);
    }
}
