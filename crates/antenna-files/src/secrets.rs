// SPDX-License-Identifier: AGPL-3.0-only
//! Secret scanner (SPEC §9 "Forbidden at every level: keys, passwords, tokens, seed phrases", §10 step 3): one scanner
//! for messages (`antenna_core::policy` re-exports it) and for files (the sandbox worker).
//!
//! - [`scan_secrets`]. A pure function over text: PEM/OpenSSH/PGP/age keys, tokens by prefix and JWT, our own `xat_`,
//!   an invite link, `password=…`, a run of 12+ BIP-39 words;
//! - [`SecretStream`]. A streaming variant for agent replies (piece by piece, holding back the "tail" at the seam);
//! - for files: overlapping windows ([`scan_text`]) and printable strings of binary data ([`printable_strings`]).

/// Kinds of secrets found (without the values themselves).
pub fn scan_secrets(text: &str) -> Vec<&'static str> {
    let mut kinds = Vec::new();
    let mut add = |k: &'static str| {
        if !kinds.contains(&k) {
            kinds.push(k);
        }
    };
    if text.contains("PRIVATE KEY-----")
        || text.contains("-----BEGIN PGP PRIVATE KEY BLOCK-----")
        || text.contains("PuTTY-User-Key-File-")
        || text.contains("AGE-SECRET-KEY-1")
    {
        add("private_key");
    }
    if has_token(text) {
        add("token");
    }
    if has_credential_assignment(text) {
        add("password");
    }
    if has_seed_phrase(text) {
        add("seed_phrase");
    }
    kinds
}

fn tok_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | '+' | '=' | ':' | '#')
}

fn alnum_run(s: &str) -> usize {
    s.chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        .count()
}

fn has_token(text: &str) -> bool {
    // An invite link carries a secret: the body `<52 base32>.<52 base32>.` in any form (web address, `antenna://`,
    // `x://`, no prefix) or the invite scheme prefix; a link to the website without a body
    // (`https://antenna.contact/#beta`) is not one.
    if antenna_proto::invite::contains_invite(text)
        || [
            antenna_proto::invite::APP_PREFIX,
            antenna_proto::invite::LEGACY_PREFIX,
        ]
        .iter()
        .any(|p| text.contains(p))
    {
        return true;
    }
    for w in text.split(|c: char| !tok_char(c)) {
        if is_telegram_bot_token(w) {
            return true;
        }
        // `KEY=value`, `key: value`, `url#frag`: the value is checked separately.
        for p in w.split(['=', ':', '#']).filter(|p| p.len() >= 16) {
            if token_prefix(p) || is_jwt(p) {
                return true;
            }
        }
    }
    false
}

fn token_prefix(w: &str) -> bool {
    let after = |p: &str| w.strip_prefix(p).map(alnum_run).unwrap_or(0);
    after(antenna_proto::control::AGENT_TOKEN_PREFIX) >= 40
        || ((w.starts_with("AKIA") || w.starts_with("ASIA"))
            && w.len() >= 20
            && w[4..20]
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
        || ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]
            .iter()
            .any(|p| after(p) >= 30)
        || after("github_pat_") >= 20
        || after("glpat-") >= 20
        || ["xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-"]
            .iter()
            .any(|p| after(p) >= 10)
        || after("sk-ant-") >= 20
        || after("sk-") >= 20
        || after("AIza") >= 30
        || ["sk_live_", "rk_live_", "sk_test_"]
            .iter()
            .any(|p| after(p) >= 16)
}

fn is_jwt(w: &str) -> bool {
    let parts: Vec<&str> = w.split('.').collect();
    parts.len() == 3
        && parts[0].starts_with("eyJ")
        && parts[1].starts_with("eyJ")
        && parts.iter().all(|p| {
            p.len() >= 10
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        })
}

fn is_telegram_bot_token(w: &str) -> bool {
    let Some((id, secret)) = w.split_once(':') else {
        return false;
    };
    (8..=10).contains(&id.len())
        && id.chars().all(|c| c.is_ascii_digit())
        && secret.len() == 35
        && secret
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}

/// Labels in front of a credential value, lowercase. People label credentials in their own language, so besides
/// English the list has the word for "password" in widely used languages: Spanish, Portuguese, French, German (two
/// words), Turkish (two words; "parola" also means "word" in Italian, which costs at most an approval prompt), Polish,
/// Ukrainian and Russian (the same word), Chinese (simplified and traditional), Japanese, Korean, Arabic (two common
/// phrases) and Hindi.
const CREDENTIAL_KEYS: &[&str] = &[
    "password",
    "passwd",
    "passphrase",
    "pwd",
    "contraseña",
    "senha",
    "mot de passe",
    "passwort",
    "kennwort",
    "şifre",
    "parola",
    "hasło",
    "пароль",
    "密码",
    "密碼",
    "パスワード",
    "비밀번호",
    "كلمة المرور",
    "كلمة السر",
    "पासवर्ड",
    "secret",
    "api_key",
    "apikey",
    "api-key",
    "access_token",
    "auth_token",
    "token",
    "private_key",
    "privatekey",
    "client_secret",
];

/// Chinese, Japanese and Korean characters and full-width forms. These scripts are written without spaces between
/// words, so a CJK label needs no word boundary on the left, and a CJK character ends the value: prose after a colon
/// ("密码：稍后发给你", "the password: I will send it later") is not a credential.
fn is_cjk(c: char) -> bool {
    // CJK punctuation, Hiragana, Katakana; CJK Extension A; CJK Unified Ideographs; Hangul syllables; half-width and
    // full-width forms.
    matches!(c,
        '\u{3000}'..='\u{30FF}'
        | '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{AC00}'..='\u{D7AF}'
        | '\u{FF00}'..='\u{FFEF}')
}

fn has_credential_assignment(text: &str) -> bool {
    let lower = text.to_lowercase();
    for key in CREDENTIAL_KEYS {
        let spaced = !key.starts_with(is_cjk);
        let mut from = 0;
        while let Some(i) = lower[from..].find(key) {
            let at = from + i;
            from = at + key.len();
            // The key must be a separate word on the left (in scripts that separate words with spaces).
            if spaced
                && lower[..at]
                    .chars()
                    .next_back()
                    .is_some_and(|c| c.is_alphanumeric())
            {
                continue;
            }
            let rest = lower[from..].trim_start_matches(['"', '\'', ' ', '\t']);
            // CJK text uses the full-width colon and equals sign.
            let Some(rest) = rest.strip_prefix([':', '=', '：', '＝']) else {
                continue;
            };
            let value: String = rest
                .trim_start_matches(['"', '\'', ' ', '\t'])
                .chars()
                .take_while(|&c| {
                    !c.is_whitespace() && !matches!(c, '"' | '\'' | ',' | ';') && !is_cjk(c)
                })
                .collect();
            if value.chars().count() >= 6 {
                return true;
            }
        }
    }
    false
}

fn is_bip39(w: &str) -> bool {
    crate::bip39_english::WORDS.binary_search(&w).is_ok()
}

fn has_seed_phrase(text: &str) -> bool {
    let mut run = 0;
    for w in text.split(|c: char| !c.is_alphabetic()) {
        if w.is_empty() {
            continue;
        }
        let lw = w.to_ascii_lowercase();
        if w.is_ascii() && is_bip39(&lw) {
            run += 1;
            if run >= 12 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

/// Secret scanner for a stream of text pieces (preparation for streaming agent replies in v0.2; the stream itself is
/// not implemented).
///
/// For each piece it returns the text that **may be released** further and holds back the "tail" where a secret could
/// start at the seam: the last unfinished word (a token, a `password=` value), the last 48 bytes (PEM markers) and an
/// unfinished run of BIP-39 words. The window checked is "released context (up to 256 bytes) + held text", using the
/// same pure function [`scan_secrets`]. Once a secret is found, the scanner releases nothing more: the whole message
/// goes through approval (SPEC §9). Holding is capped at 8 KiB: a longer word is released in parts (the limit is
/// recorded in DECISIONS D-38).
#[derive(Debug, Default)]
pub struct SecretStream {
    context: String,
    pending: String,
    found: Vec<&'static str>,
}

/// Step of the streaming scanner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamStep {
    /// May be released further (contains no start of a possible secret).
    pub release: String,
    /// Kinds of secrets found (cumulative). Non-empty means the stream must stop until approval.
    pub findings: Vec<&'static str>,
}

const STREAM_CONTEXT: usize = 256;
const STREAM_MARKER_HOLD: usize = 48;
const STREAM_MAX_HOLD: usize = 8192;

/// The nearest UTF-8 character boundary not to the right of `i` (cutting a stream into pieces).
pub fn floor_boundary(s: &str, mut i: usize) -> usize {
    i = i.min(s.len());
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

impl SecretStream {
    /// New scanner.
    pub fn new() -> Self {
        Self::default()
    }

    /// Next piece.
    pub fn push(&mut self, chunk: &str) -> StreamStep {
        self.pending.push_str(chunk);
        if !self.rescan() {
            return self.blocked();
        }
        let hold = self.hold_from();
        let release: String = self.pending[..hold].to_string();
        self.pending.drain(..hold);
        self.context.push_str(&release);
        if self.context.len() > STREAM_CONTEXT {
            let cut = floor_boundary(&self.context, self.context.len() - STREAM_CONTEXT);
            self.context.drain(..cut);
        }
        StreamStep {
            release,
            findings: Vec::new(),
        }
    }

    /// End of stream: releases the rest if there are no secrets.
    pub fn finish(&mut self) -> StreamStep {
        if !self.rescan() {
            return self.blocked();
        }
        StreamStep {
            release: std::mem::take(&mut self.pending),
            findings: Vec::new(),
        }
    }

    /// `false` means a secret was found.
    fn rescan(&mut self) -> bool {
        if self.found.is_empty() {
            let window = format!("{}{}", self.context, self.pending);
            self.found = scan_secrets(&window);
        }
        self.found.is_empty()
    }

    fn blocked(&self) -> StreamStep {
        StreamStep {
            release: String::new(),
            findings: self.found.clone(),
        }
    }

    /// From which byte of `pending` to hold back.
    fn hold_from(&self) -> usize {
        let p = &self.pending;
        // Unfinished word (a token, a value after `password=`, the start of an x://pair# link).
        let word = p
            .char_indices()
            .rev()
            .find(|(_, c)| c.is_whitespace())
            .map_or(0, |(i, c)| i + c.len_utf8());
        // PEM/PGP/age markers contain spaces: the last 48 bytes.
        let marker = floor_boundary(p, p.len().saturating_sub(STREAM_MARKER_HOLD));
        // An unfinished run of BIP-39 words (fewer than 12) may become a seed phrase.
        let run = {
            let window = format!("{}{}", self.context, p);
            let mut start = None;
            let mut count = 0;
            let mut end = window.len();
            for (i, w) in word_spans(&window).into_iter().rev() {
                let lw = w.to_ascii_lowercase();
                // The word must be adjacent to the previous one through non-letters.
                if !window[i + w.len()..end].chars().all(|c| !c.is_alphabetic()) {
                    break;
                }
                if w.is_ascii() && is_bip39(&lw) {
                    count += 1;
                    start = Some(i);
                    end = i;
                } else {
                    break;
                }
            }
            match start {
                Some(i) if count < 12 => i.saturating_sub(self.context.len()),
                _ => p.len(),
            }
        };
        let hold = word.min(marker).min(run);
        hold.max(floor_boundary(p, p.len().saturating_sub(STREAM_MAX_HOLD)))
    }
}

/// Words made of letters with their positions (as in [`has_seed_phrase`]).
fn word_spans(s: &str) -> Vec<(usize, &str)> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, c) in s.char_indices() {
        match (c.is_alphabetic(), start) {
            (true, None) => start = Some(i),
            (false, Some(st)) => {
                out.push((st, &s[st..i]));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(st) = start {
        out.push((st, &s[st..]));
    }
    out
}

/// Scanner function: kinds of secrets found (without values). In stages A and B it is
/// `antenna_core::policy::scan_secrets`.
pub type TextScanner = fn(&str) -> Vec<&'static str>;

/// Window size.
pub const WINDOW: usize = 256 * 1024;
/// Window overlap: longer than any rule (a run of 12 BIP-39 words ≤ 12 × 9 bytes, a PEM marker, a token ≤ 1 KiB).
pub const OVERLAP: usize = 8 * 1024;
/// How much text to scan in one call: everything the worker holds in memory (`worker::MAX_DEEP`); the rest of a large
/// file is scanned in the worker's windows.
pub const MAX_SCAN: usize = 256 << 20;

/// Finds secrets in text using windows. Returns the unique kinds and whether not everything was scanned.
pub fn scan_text(text: &str, scanner: TextScanner) -> (Vec<&'static str>, bool) {
    let mut kinds: Vec<&'static str> = Vec::new();
    let limit = text.len().min(MAX_SCAN);
    let mut start = 0usize;
    while start < limit {
        let mut end = (start + WINDOW).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        for k in scanner(&text[start..end]) {
            if !kinds.contains(&k) {
                kinds.push(k);
            }
        }
        if end >= limit {
            break;
        }
        let mut next = end.saturating_sub(OVERLAP).max(start + 1);
        while !text.is_char_boundary(next) {
            next += 1;
        }
        start = next;
    }
    (kinds, text.len() > MAX_SCAN)
}

/// Printable ASCII strings of binary data (≥ `min` characters), separated by newlines, at most `cap` bytes.
pub fn printable_strings(data: &[u8], min: usize, cap: usize) -> String {
    let mut out = String::new();
    let mut run = String::new();
    for &b in data {
        if (0x20..0x7F).contains(&b) || b == b'\t' {
            run.push(b as char);
        } else {
            if run.len() >= min {
                out.push_str(&run);
                out.push('\n');
                if out.len() >= cap {
                    return out;
                }
            }
            run.clear();
        }
    }
    if run.len() >= min {
        out.push_str(&run);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake(text: &str) -> Vec<&'static str> {
        if text.contains("PRIVATE KEY-----") {
            vec!["private_key"]
        } else {
            vec![]
        }
    }

    #[test]
    fn secret_on_a_window_boundary_is_found() {
        let marker = "-----BEGIN OPENSSH PRIVATE KEY-----";
        for cut in [WINDOW - 10, WINDOW - 1, WINDOW, WINDOW + 3] {
            let mut t = "x".repeat(cut);
            t.push_str(marker);
            t.push_str(&"y".repeat(1000));
            assert_eq!(scan_text(&t, fake).0, vec!["private_key"], "cut {cut}");
        }
        assert!(scan_text(&"z".repeat(3 * WINDOW), fake).0.is_empty());
    }

    /// Password labels in other languages: the same rule as `password: …` (a label, `:` or `=`, a value of 6+
    /// characters); CJK labels also work inside a sentence and with full-width punctuation.
    #[test]
    fn credential_labels_in_other_languages() {
        for t in [
            "contraseña: Hunter2024",
            "Senha=segredo123",
            "mot de passe : hunter2hunter2",
            "Passwort: geheim12345",
            "WLAN-Kennwort = geheim12345",
            "şifre: gizli12345",
            "Parola=gizli12345",
            "Hasło: tajne12345",
            "密码：hunter2024",
            "我的密码是这个，密码：hunter2024",
            "密碼: hunter2024",
            "パスワード＝hunter2024",
            "비밀번호: hunter2024",
            "كلمة المرور: hunter2024",
            "كلمة السر=hunter2024",
            "पासवर्ड: hunter2024",
        ] {
            assert_eq!(scan_secrets(t), vec!["password"], "{t}");
        }
        for t in [
            "密码：稍后发给你",
            "비밀번호: 나중에 알려줄게",
            "パスワード：あとで送ります",
            "Uma resenha: excelente livro",
            "Passwort vergessen? Klicken Sie hier.",
            "La parola chiave è sicurezza.",
            "contraseña: abc",
        ] {
            assert!(scan_secrets(t).is_empty(), "{t}: {:?}", scan_secrets(t));
        }
    }

    #[test]
    fn strings_of_binary() {
        let mut b = vec![0u8, 1, 2];
        b.extend_from_slice(b"-----BEGIN RSA PRIVATE KEY-----");
        b.extend_from_slice(&[0xFF, 0]);
        let s = printable_strings(&b, 8, 1 << 20);
        assert!(s.contains("PRIVATE KEY-----"));
    }
}
