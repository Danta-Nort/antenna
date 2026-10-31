// SPDX-License-Identifier: AGPL-3.0-only
//! Sanitizing text that the agent and the owner see (preview, archive listing, names, finding texts).
//!
//! Invisible characters are a channel for hidden instructions to a model: tag characters U+E0000–E007F encode ASCII and
//! are invisible to a human ("ASCII smuggling"), bidi characters reorder the visible text, zero-width characters break
//! words for filters. This module has one predicate for all places: control (Cc, except `\n`, `\t`, `\x0C`), format and
//! default-ignorable characters (Default_Ignorable_Code_Point), line/paragraph separators U+2028/2029, private use and
//! noncharacters.

/// The character is invisible or controls rendering (not counting `\n`, `\t`, `\x0C`).
pub fn is_invisible(c: char) -> bool {
    if matches!(c, '\n' | '\t' | '\x0C') {
        return false;
    }
    if c.is_control() {
        return true;
    }
    let u = c as u32;
    matches!(
        u,
        0x00AD                      // soft hyphen
        | 0x034F                    // CGJ
        | 0x061C                    // ALM
        | 0x115F | 0x1160           // Hangul fillers
        | 0x17B4 | 0x17B5
        | 0x180B..=0x180F           // Mongolian variation selectors and MVS
        | 0x200B..=0x200F           // zero width, LRM, RLM
        | 0x2028 | 0x2029           // line and paragraph separators
        | 0x202A..=0x202E           // bidi embedding and override
        | 0x2060..=0x206F           // WJ, invisible operators, bidi isolates
        | 0x3164                    // Hangul filler
        | 0xFE00..=0xFE0F           // variation selectors
        | 0xFEFF                    // BOM / ZWNBSP
        | 0xFFA0                    // halfwidth filler
        | 0xFFF0..=0xFFFB           // annotations and specials
        | 0xFDD0..=0xFDEF           // noncharacters
        | 0xE000..=0xF8FF           // private use
        | 0x1BCA0..=0x1BCA3
        | 0x1D173..=0x1D17A
        | 0xE0000..=0xE0FFF         // tags and supplementary variation selectors
        | 0xF0000..=0x10FFFF        // private use (supplementary)
    ) || (u & 0xFFFE) == 0xFFFE // U+xFFFE / U+xFFFF
}

/// The character hides text from a human: tags or bidi override are a reason for a finding, not just for sanitizing.
pub fn is_smuggling(c: char) -> bool {
    matches!(c as u32, 0xE0000..=0xE007F | 0x202A..=0x202E | 0x2066..=0x2069)
}

/// How many invisible characters there are and how many of them are "smuggling" ones ([`is_smuggling`]).
pub fn count_invisible(s: &str) -> (usize, usize) {
    let mut inv = 0;
    let mut smug = 0;
    for c in s.chars() {
        if is_invisible(c) {
            inv += 1;
            if is_smuggling(c) {
                smug += 1;
            }
        }
    }
    (inv, smug)
}

/// Removes invisible characters, `\r\n` → `\n`, at most `max` bytes. Returns the text and whether it was cut.
pub fn sanitize(s: &str, max: usize) -> (String, bool) {
    let mut out = String::with_capacity(s.len().min(max));
    let mut cut = false;
    for c in s.chars() {
        if c == '\r' || is_invisible(c) {
            continue;
        }
        if out.len() + c.len_utf8() > max {
            cut = true;
            break;
        }
        out.push(c);
    }
    (out, cut)
}

/// Shows a string to a human: invisible and control characters (including `\n`, `\t`) as `\u{..}`, at most `max`
/// characters.
pub fn escape_visible(s: &str, max: usize) -> String {
    let mut out = String::new();
    for c in s.chars().take(max) {
        if is_invisible(c) || c.is_control() {
            out.push_str(&format!("\\u{{{:x}}}", c as u32));
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invisible_and_smuggling() {
        let hidden: String = "ignore"
            .chars()
            .map(|c| char::from_u32(0xE0000 + c as u32).unwrap())
            .collect();
        let s = format!("Γεια{hidden}\u{202E}gnp.exe\u{200B}\u{2028}x\u{FEFF}\u{E000}\n\tok");
        let (inv, smug) = count_invisible(&s);
        assert_eq!(smug, 7);
        assert_eq!(inv, 11);
        let (t, cut) = sanitize(&s, 1000);
        assert_eq!(t, "Γειαgnp.exex\n\tok");
        assert!(!cut);
        assert_eq!(escape_visible("a\u{202E}b\nc", 100), "a\\u{202e}b\\u{a}c");
    }
}
