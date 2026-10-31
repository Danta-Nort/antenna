// SPDX-License-Identifier: Apache-2.0
//! Representations of the SAS verification code (`docs/PROTOCOL.md` §7, Q-6).
//!
//! There is one code: 6 decimal digits from the transcript hash. Emoji are **another representation of the same
//! code**: each digit maps to one emoji from the fixed table [`EMOJI`] (the first ten emoji of the Matrix SAS table,
//! all of them animals that are easy to name aloud). The entropy is the same (10⁶) and the protocol does not change:
//! the digits are compared.
//!
//! Owner B can enter the code as digits, as the same emoji or as animal names (in English or Russian):
//! [`parse_input`] turns the input into digits. Ambiguous or incomplete input gives `None` (that is, "code mismatch").

/// Emoji for digits 0–9: (digit, emoji, English name, Russian name). One code point per emoji.
///
/// The Russian names are protocol behavior, not leftover text. The desktop app shows the animals in its UI language
/// (English or Russian, `sasAnimal0…9` in `lib/l10n`), and owner A reads them aloud to owner B. B's daemon must accept
/// the names A read out whatever language B's own UI uses, so [`parse_input`] knows both columns; dropping one would
/// make pairing fail between nodes with different UI languages. A new UI language adds a column here first.
pub const EMOJI: [(u8, char, &str, &str); 10] = [
    (0, '\u{1F436}', "dog", "собака"),
    (1, '\u{1F431}', "cat", "кошка"),
    (2, '\u{1F981}', "lion", "лев"),
    (3, '\u{1F40E}', "horse", "лошадь"),
    (4, '\u{1F984}', "unicorn", "единорог"),
    (5, '\u{1F437}', "pig", "свинья"),
    (6, '\u{1F418}', "elephant", "слон"),
    (7, '\u{1F430}', "rabbit", "кролик"),
    (8, '\u{1F43C}', "panda", "панда"),
    (9, '\u{1F413}', "rooster", "петух"),
];

/// Number of digits (and emoji) in a code.
pub const LEN: usize = 6;

/// Emoji representation of a 6-digit code. Anything other than digits gives `None`.
pub fn to_emoji(code: &str) -> Option<String> {
    if code.len() != LEN || !code.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(code.bytes().map(|b| EMOJI[(b - b'0') as usize].1).collect())
}

/// Emoji representation of any digit string using the same table (the 3-character history fingerprint,
/// `docs/PROTOCOL.md` §16). Non-digits or an empty string give `None`.
pub fn digits_to_emoji(digits: &str) -> Option<String> {
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(
        digits
            .bytes()
            .map(|b| EMOJI[(b - b'0') as usize].1)
            .collect(),
    )
}

/// Animal names of the code (for reading aloud): `"elephant unicorn …"`, or the Russian names.
pub fn to_names(code: &str, russian: bool) -> Option<String> {
    to_emoji(code)?;
    Some(
        code.bytes()
            .map(|b| {
                let e = &EMOJI[(b - b'0') as usize];
                if russian { e.3 } else { e.2 }
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// Turns the owner's input into 6 digits: digits, emoji from [`EMOJI`] or names (Russian or English,
/// case-insensitive); spaces, `-`, `,` and `.` are separators. Any other character, or anything other than exactly
/// 6 digits, gives `None`.
pub fn parse_input(input: &str) -> Option<String> {
    let mut out = String::with_capacity(LEN);
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| -> bool {
        if word.is_empty() {
            return true;
        }
        let w = word.to_lowercase();
        word.clear();
        match EMOJI.iter().find(|e| e.2 == w || e.3 == w) {
            Some(e) => {
                out.push((b'0' + e.0) as char);
                true
            }
            None => false,
        }
    };
    for c in input.chars() {
        if c.is_alphabetic() {
            word.push(c);
            continue;
        }
        if !flush(&mut word, &mut out) {
            return None;
        }
        if c.is_ascii_digit() {
            out.push(c);
        } else if let Some(e) = EMOJI.iter().find(|e| e.1 == c) {
            out.push((b'0' + e.0) as char);
        } else if c.is_whitespace() || matches!(c, '-' | ',' | '.' | '\u{FE0F}') {
            // Separator; U+FE0F (variation selector) follows an emoji when it is copied.
        } else {
            return None;
        }
    }
    if !flush(&mut word, &mut out) {
        return None;
    }
    (out.len() == LEN).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test vector from PROTOCOL.md, appendix A (pairing v1): SAS = 169264.
    #[test]
    fn vector_from_protocol_appendix_a() {
        assert_eq!(
            to_emoji("169264").unwrap(),
            "\u{1F431}\u{1F418}\u{1F413}\u{1F981}\u{1F418}\u{1F984}"
        );
        assert_eq!(
            to_emoji("645826").unwrap(),
            "\u{1F418}\u{1F984}\u{1F437}\u{1F43C}\u{1F981}\u{1F418}"
        );
        assert_eq!(
            to_names("645826", false).unwrap(),
            "elephant unicorn pig panda lion elephant"
        );
        // Russian names: input and output are supported in both languages.
        assert_eq!(
            to_names("645826", true).unwrap(),
            "слон единорог свинья панда лев слон"
        );
    }

    #[test]
    fn table_is_a_bijection() {
        for (i, e) in EMOJI.iter().enumerate() {
            assert_eq!(e.0 as usize, i);
            assert_eq!(e.1.len_utf8(), 4, "one code point");
        }
        let mut chars: Vec<char> = EMOJI.iter().map(|e| e.1).collect();
        chars.sort();
        chars.dedup();
        assert_eq!(chars.len(), 10);
    }

    #[test]
    fn input_in_any_representation_gives_the_same_digits() {
        for s in [
            "645826",
            "645 826",
            "645-826",
            "\u{1F418}\u{1F984}\u{1F437}\u{1F43C}\u{1F981}\u{1F418}",
            "\u{1F418}\u{FE0F} \u{1F984} \u{1F437} \u{1F43C} \u{1F981} \u{1F418}",
            "elephant unicorn pig panda lion elephant",
            // Russian names and mixed representations are accepted as well.
            "Слон, единорог, свинья, панда, лев, слон",
            "слон 4 pig \u{1F43C} 2 6",
        ] {
            assert_eq!(parse_input(s).as_deref(), Some("645826"), "{s}");
        }
    }

    #[test]
    fn bad_input_is_none() {
        for s in [
            "",
            "64582",
            "6458261",
            "elephant unicorn pig panda lion",
            // An unknown Russian word (giraffe) is rejected like an unknown English one.
            "слон единорог свинья панда лев жираф",
            "645826!",
            "64582x",
        ] {
            assert_eq!(parse_input(s), None, "{s}");
        }
        assert_eq!(to_emoji("12345"), None);
        assert_eq!(to_emoji("12345a"), None);
    }
}
