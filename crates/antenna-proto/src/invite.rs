// SPDX-License-Identifier: Apache-2.0
//! Invite link (SPEC §6 item 1, `docs/PROTOCOL.md` §3): `https://antenna.contact/#<E_A>.<s>.<relay>[.<direct>]`.
//!
//! The link body `<E_A>.<s>.<relay>[.<direct>]` is the same in every form; only the prefix changes:
//! - **`https://antenna.contact/#…`** is what a node issues (D-74): the link can be opened anywhere, the site reads the
//!   fragment only in the browser (the browser does not send the part after `#` to the server, `docs/SITE.md`) and
//!   offers to open the app;
//! - **`antenna://pair#…`** is the same link for the app; `0.1.0-preview.1` nodes understand it too (D-57), so the node
//!   shows it alongside as a fallback;
//! - **`x://pair#…`** is the historical scheme of the working name `x`: accepted only.
//!
//! Format only: encoding and strict parsing. Checking that `E_A` is a valid Ed25519 point is done by the core
//! (this crate has no cryptographic dependencies).

use std::net::SocketAddr;

/// Prefix of the link a node issues: the site's web address, with the body in the fragment.
pub const WEB_PREFIX: &str = "https://antenna.contact/#";
/// Prefix of the link for the app (the `antenna://` scheme handler in the desktop app; `0.1.0-preview.1` nodes
/// understand it).
pub const APP_PREFIX: &str = "antenna://pair#";
/// Historical scheme of the working name `x` (D-57): accepted, never issued.
pub const LEGACY_PREFIX: &str = "x://pair#";
/// All accepted prefixes. The web address is also accepted without the `/` before `#` (that is how people type it).
pub const ACCEPTED_PREFIXES: &[&str] = &[
    WEB_PREFIX,
    "https://antenna.contact#",
    APP_PREFIX,
    LEGACY_PREFIX,
];
/// Maximum link length in characters.
pub const MAX_LEN: usize = 1024;
/// Maximum length of the encoded `relay` and `direct` fields.
pub const MAX_FIELD: usize = 512;

/// Parsed invite link.
#[derive(Clone, PartialEq, Eq)]
pub struct InviteLink {
    /// EndpointId of the invite's ephemeral endpoint (Ed25519 public key).
    pub endpoint: [u8; 32],
    /// One-time link secret.
    pub secret: [u8; 32],
    /// Relay URL, or `None` if the inviter has the relay turned off.
    pub relay: Option<String>,
    /// Direct addresses, only when the relay is turned off (tests, LAN).
    pub direct: Vec<SocketAddr>,
}

impl std::fmt::Debug for InviteLink {
    // The secret is never printed (SPEC §13: logs without keys).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InviteLink")
            .field(
                "endpoint",
                &data_encoding::HEXLOWER.encode(&self.endpoint[..4]),
            )
            .field("secret", &"<redacted>")
            .field("relay", &self.relay)
            .field("direct", &self.direct)
            .finish()
    }
}

impl Drop for InviteLink {
    fn drop(&mut self) {
        // The link secret must not stay in memory (PROTOCOL §4).
        zeroize::Zeroize::zeroize(&mut self.secret);
    }
}

/// Link parsing error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteError(pub &'static str);

impl std::fmt::Display for InviteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid invite link: {}", self.0)
    }
}

impl std::error::Error for InviteError {}

fn b32(bytes: &[u8]) -> String {
    data_encoding::BASE32_NOPAD
        .encode(bytes)
        .to_ascii_lowercase()
}

fn b32_32(s: &str, what: &'static str) -> Result<[u8; 32], InviteError> {
    if s.len() != 52 {
        return Err(InviteError(what));
    }
    let v = data_encoding::BASE32_NOPAD
        .decode(s.to_ascii_uppercase().as_bytes())
        .map_err(|_| InviteError(what))?;
    v.try_into().map_err(|_| InviteError(what))
}

fn b64(s: &str) -> String {
    data_encoding::BASE64URL_NOPAD.encode(s.as_bytes())
}

fn unb64(s: &str, what: &'static str) -> Result<String, InviteError> {
    if s.len() > MAX_FIELD {
        return Err(InviteError(what));
    }
    let v = data_encoding::BASE64URL_NOPAD
        .decode(s.as_bytes())
        .map_err(|_| InviteError(what))?;
    String::from_utf8(v).map_err(|_| InviteError(what))
}

impl InviteLink {
    /// Link body without a prefix: `<E_A>.<s>.<relay>[.<direct>]`.
    pub fn body(&self) -> String {
        let mut s = String::with_capacity(200);
        s.push_str(&b32(&self.endpoint));
        s.push('.');
        s.push_str(&b32(&self.secret));
        s.push('.');
        if let Some(r) = &self.relay {
            s.push_str(&b64(r));
        }
        if !self.direct.is_empty() {
            let list: Vec<String> = self.direct.iter().map(|a| a.to_string()).collect();
            s.push('.');
            s.push_str(&b64(&list.join(",")));
        }
        s
    }

    /// The link a node issues: `https://antenna.contact/#<body>`.
    pub fn encode(&self) -> String {
        format!("{WEB_PREFIX}{}", self.body())
    }

    /// The same link for the app: `antenna://pair#<body>` (`0.1.0-preview.1` nodes understand it too).
    pub fn encode_app(&self) -> String {
        format!("{APP_PREFIX}{}", self.body())
    }

    /// Historical form `x://pair#<body>` (only for compatibility checks: a node never issues it).
    pub fn encode_legacy(&self) -> String {
        format!("{LEGACY_PREFIX}{}", self.body())
    }

    /// Strict parsing of a link in any of the [`ACCEPTED_PREFIXES`] forms. Whitespace and line breaks inside mean
    /// nothing (a mail client wraps the link); the scheme and domain are case-insensitive. One more scheme is allowed
    /// inside the web address (`https://antenna.contact/#antenna://pair#…`): the site accepts it the same way.
    pub fn parse(link: &str) -> Result<Self, InviteError> {
        if link.len() > MAX_LEN * 2 {
            return Err(InviteError("too long"));
        }
        let link: String = link.chars().filter(|c| !c.is_whitespace()).collect();
        if link.len() > MAX_LEN {
            return Err(InviteError("too long"));
        }
        let mut rest = strip_any_prefix(&link).ok_or(InviteError(
            "must start with https://antenna.contact/# (or antenna://pair#, x://pair#)",
        ))?;
        if let Some(inner) = strip_any_prefix(rest) {
            rest = inner;
        }
        Self::parse_body(rest)
    }

    /// Parses the link body (without a prefix).
    pub fn parse_body(rest: &str) -> Result<Self, InviteError> {
        let parts: Vec<&str> = rest.split('.').collect();
        if parts.len() != 3 && parts.len() != 4 {
            return Err(InviteError("expected 3 or 4 dot-separated fields"));
        }
        let endpoint = b32_32(parts[0], "endpoint key")?;
        let secret = b32_32(parts[1], "secret")?;
        let relay = if parts[2].is_empty() {
            None
        } else {
            let r = unb64(parts[2], "relay")?;
            if !(r.starts_with("https://") || r.starts_with("http://")) {
                return Err(InviteError("relay must be an http(s) URL"));
            }
            Some(r)
        };
        let mut direct = Vec::new();
        if let Some(d) = parts.get(3) {
            let d = unb64(d, "direct addresses")?;
            for a in d.split(',') {
                direct.push(
                    a.parse::<SocketAddr>()
                        .map_err(|_| InviteError("direct address"))?,
                );
            }
            if relay.is_some() {
                return Err(InviteError(
                    "direct addresses are only allowed without relay",
                ));
            }
        }
        if relay.is_none() && direct.is_empty() {
            return Err(InviteError("neither relay nor direct address"));
        }
        Ok(InviteLink {
            endpoint,
            secret,
            relay,
            direct,
        })
    }
}

/// Strips any of the accepted prefixes (scheme and domain are case-insensitive).
fn strip_any_prefix(s: &str) -> Option<&str> {
    ACCEPTED_PREFIXES.iter().find_map(|p| {
        let head = s.get(..p.len())?;
        head.eq_ignore_ascii_case(p).then(|| &s[p.len()..])
    })
}

/// Whether the text contains an invite link (it carries a secret): the body `<52 base32>.<52 base32>.`, with any prefix
/// or without one (outgoing secret scanner, SPEC §9). A link to the site without an invite body
/// (`https://antenna.contact/#beta`) is not an invite.
pub fn contains_invite(text: &str) -> bool {
    // Link parsing drops whitespace and line breaks inside, so the scanner must too: otherwise a link broken by a space
    // or U+2028 would slip past the scanner but still parse.
    contains_body(text) || {
        let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        compact.len() != text.len() && contains_body(&compact)
    }
}

fn contains_body(text: &str) -> bool {
    let b = text.as_bytes();
    let is_b32 = |c: u8| c.is_ascii_alphabetic() || (b'2'..=b'7').contains(&c);
    let run = |from: usize| b[from..].iter().take_while(|c| is_b32(**c)).count();
    let mut i = 0;
    while i < b.len() {
        if !is_b32(b[i]) || (i > 0 && is_b32(b[i - 1])) {
            i += 1;
            continue;
        }
        let first = run(i);
        if first == 52
            && b.get(i + 52) == Some(&b'.')
            && run(i + 53) == 52
            && b.get(i + 105) == Some(&b'.')
        {
            return true;
        }
        i += first.max(1);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn relay_link() -> InviteLink {
        InviteLink {
            endpoint: [7; 32],
            secret: [9; 32],
            relay: Some("https://euc1-1.relay.n0.iroh-canary.iroh.link./".into()),
            direct: vec![],
        }
    }

    #[test]
    fn roundtrip_relay_and_direct() {
        let l = relay_link();
        let s = l.encode();
        assert!(s.starts_with("https://antenna.contact/#"), "{s}");
        assert_eq!(s.split('.').count(), 4, "antenna.contact + 3 fields: {s}");
        assert_eq!(InviteLink::parse(&s).unwrap(), l);

        let mut d = relay_link();
        d.relay = None;
        d.direct = vec![
            "127.0.0.1:4242".parse().unwrap(),
            "[::1]:5".parse().unwrap(),
        ];
        let s = d.encode();
        assert!(s.contains(".."), "empty relay field: {s}");
        assert_eq!(InviteLink::parse(&s).unwrap(), d);
    }

    /// All three forms are the same invite: the web address (issued), `antenna://` (fallback, understood by preview.1
    /// nodes) and the historical `x://` (D-57, D-74).
    #[test]
    fn three_forms_are_one_invite() {
        let l = relay_link();
        let web = l.encode();
        let app = l.encode_app();
        let legacy = l.encode_legacy();
        assert_eq!(web, format!("https://antenna.contact/#{}", l.body()));
        assert_eq!(app, format!("antenna://pair#{}", l.body()));
        assert_eq!(legacy, format!("x://pair#{}", l.body()));
        for f in [&web, &app, &legacy] {
            assert_eq!(InviteLink::parse(f).unwrap(), l, "{f}");
        }
        // Without `/` before `#`, scheme and domain in another case, nested scheme (the site accepts these too).
        for f in [
            format!("https://antenna.contact#{}", l.body()),
            format!("HTTPS://Antenna.Contact/#{}", l.body()),
            format!("https://antenna.contact/#antenna://pair#{}", l.body()),
            format!("https://antenna.contact/#x://pair#{}", l.body()),
            format!("Antenna://Pair#{}", l.body()),
        ] {
            assert_eq!(InviteLink::parse(&f).unwrap(), l, "{f}");
        }
        // The link was wrapped by a mail client.
        let wrapped = format!("  {}\n{}\r\n", &web[..60], &web[60..]);
        assert_eq!(InviteLink::parse(&wrapped).unwrap(), l);
        // Foreign forms.
        for f in [
            format!("antenna://join#{}", l.body()),
            format!("https://evil.example/#{}", l.body()),
            format!("http://antenna.contact/#{}", l.body()),
            format!("https://antenna.contact/invite#{}", l.body()),
            format!("https://antenna.contact.evil/#{}", l.body()),
            l.body(),
        ] {
            assert!(InviteLink::parse(&f).is_err(), "accepted: {f}");
        }
    }

    #[test]
    fn invite_inside_text_is_found_in_every_form() {
        let l = relay_link();
        for f in [l.encode(), l.encode_app(), l.encode_legacy(), l.body()] {
            assert!(
                contains_invite(&format!("here you go: {f} — see you")),
                "{f}"
            );
        }
        let mut d = relay_link();
        d.relay = None;
        d.direct = vec!["10.0.0.1:1".parse().unwrap()];
        assert!(contains_invite(&d.encode()));
        // Broken by spaces, a line break, NBSP, U+2028, " . ": parsing accepts it, so the scanner must find it.
        let body = l.body();
        for torn in [
            format!("{} {}", &body[..30], &body[30..]),
            format!("{}\n{}", &body[..60], &body[60..]),
            format!("{}\u{a0}{}", &body[..10], &body[10..]),
            format!("{}\u{2028}{}", &body[..70], &body[70..]),
            body.replace('.', " . "),
        ] {
            assert!(
                InviteLink::parse_body(
                    &torn
                        .chars()
                        .filter(|c| !c.is_whitespace())
                        .collect::<String>()
                )
                .is_ok()
            );
            assert!(contains_invite(&format!("join: {torn}")), "{torn:?}");
        }
        // Not an invite: a link to the beta form, plain text, a long base32 run without structure.
        for t in [
            "https://antenna.contact/#beta".to_string(),
            "open https://antenna.contact/ and join".into(),
            "a".repeat(52),
            format!("{}.{}", "a".repeat(52), "b".repeat(51)),
            format!("{}.{}.", "a".repeat(53), "b".repeat(52)),
        ] {
            assert!(!contains_invite(&t), "flagged: {t}");
        }
    }

    #[test]
    fn field_lengths() {
        let body = relay_link().body();
        let parts: Vec<&str> = body.split('.').collect();
        assert_eq!(parts[0].len(), 52);
        assert_eq!(parts[1].len(), 52);
        assert!(
            parts[0]
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        );
    }

    #[test]
    fn case_insensitive_keys() {
        let l = relay_link();
        let mut parts: Vec<String> = l.body().split('.').map(str::to_string).collect();
        parts[0] = parts[0].to_ascii_uppercase();
        let up = format!("{WEB_PREFIX}{}", parts.join("."));
        assert_eq!(InviteLink::parse(&up).unwrap(), l);
    }

    #[test]
    fn rejects_garbage() {
        let good = relay_link().encode();
        let bad = [
            String::new(),
            WEB_PREFIX.into(),
            "x://pair#".into(),
            good.replace(WEB_PREFIX, "x://join#"),
            good.replace('.', ","),
            format!("{good}.AAAA.BBBB"),
            good[..good.len() - 60].to_string(),
            format!("{}.{}", good, "not-base64!"),
            "x://pair#aaaa.bbbb.".into(),
            "antenna://pair#".into(),
            "x".repeat(2000),
            format!("{WEB_PREFIX}{}", " ".repeat(5000)),
        ];
        for b in bad {
            assert!(InviteLink::parse(&b).is_err(), "accepted: {b}");
        }
        // Relay is not http(s).
        let mut l = relay_link();
        l.relay = Some("ftp://relay".into());
        assert!(InviteLink::parse(&l.encode()).is_err());
        // Direct addresses together with a relay are forbidden.
        let mut l = relay_link();
        l.direct = vec!["127.0.0.1:1".parse().unwrap()];
        assert!(InviteLink::parse(&l.encode()).is_err());
    }

    #[test]
    fn debug_does_not_leak_secret() {
        let dbg = format!("{:?}", relay_link());
        assert!(dbg.contains("redacted"));
        assert!(!dbg.contains("9, 9, 9"));
    }
}
