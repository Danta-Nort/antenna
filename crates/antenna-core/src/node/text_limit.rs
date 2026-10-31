// SPDX-License-Identifier: AGPL-3.0-only
//! The size of a message's text (`link::MAX_TEXT`, 64 KiB of UTF-8): empty is a bad request, longer than a message
//! holds is its own code, `text_too_long`, so a client can offer to send the text as a file instead of matching
//! `bad_request` (0.2.0; before it, both were `bad_request`).

use antenna_proto::{control::code, link::MAX_TEXT};

use crate::error::{Error, Result};

/// Message text: 1…[`MAX_TEXT`] bytes.
pub(crate) fn check_text(text: &str) -> Result<()> {
    if text.is_empty() {
        return Err(Error::bad_request(format!(
            "text must be 1..{MAX_TEXT} bytes"
        )));
    }
    check_text_len(text.len(), MAX_TEXT)
}

/// [`code::TEXT_TOO_LONG`] when `len` bytes are over `max`; the message names both.
pub(crate) fn check_text_len(len: usize, max: usize) -> Result<()> {
    if len > max {
        return Err(Error::new(
            code::TEXT_TOO_LONG,
            format!("the text is {len} bytes and a message holds at most {max}: send it as a file"),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn too_long_has_its_own_code_and_empty_stays_a_bad_request() {
        assert!(check_text("a").is_ok());
        assert!(check_text(&"a".repeat(MAX_TEXT)).is_ok());
        let long = check_text(&"a".repeat(MAX_TEXT + 1)).unwrap_err();
        assert_eq!(long.code, code::TEXT_TOO_LONG);
        assert!(long.message.contains("65537 bytes"), "{}", long.message);
        assert!(long.message.contains("65536"), "{}", long.message);
        // Bytes, not characters: 3-byte characters reach the limit at a third of the count.
        assert_eq!(
            check_text(&"€".repeat(MAX_TEXT / 3 + 1)).unwrap_err().code,
            code::TEXT_TOO_LONG
        );
        assert_eq!(check_text("").unwrap_err().code, code::BAD_REQUEST);
    }
}
