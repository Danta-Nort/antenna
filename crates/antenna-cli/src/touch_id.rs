// SPDX-License-Identifier: AGPL-3.0-only
//! Touch ID in the terminal (D-131, CONTROL §22): an owner command that takes the password is confirmed with one touch
//! when the window turned Touch ID on for this daemon on this Mac. The CLI does no cryptography itself: the window's
//! Secure Enclave key lives as a blob in the window's folder for this daemon, and a small helper next to the CLI
//! (`antenna-touchid`, Swift and CryptoKit, `apps/antenna_desktop/macos/Helper/antenna-touchid.swift`) shows the Touch
//! ID sheet and signs the D-102 message with that key; the daemon verifies the proof as it does the window's. Any
//! process of the user can ask the Secure Enclave to use the blob, each use still needs the touch (CONTROL §22.6): the
//! helper is that, said openly.
//!
//! The helper speaks JSON lines on its stdin and stdout: `{"op":"sign","nonce","request","reason","reuse"}` →
//! `{"sig"}`, `{"op":"open_slot","reason"}` → `{"slot_key"}`, or `{"error","message"}` with the Runner's codes
//! (`cancelled`, `unavailable`, `lockout`, `key_invalidated`, `not_enrolled`, `failed`). One helper process serves one
//! command, so the touch that opens the unlock slot can sign the sign-in after it (`reuse`), as in the window.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The helper's file name, next to `antenna` (`Antenna.app/Contents/Helpers/`).
pub(crate) const HELPER: &str = "antenna-touchid";

/// Debug builds only: the helper to run instead (tests run a stand-in that signs with a software key).
#[cfg(debug_assertions)]
const ENV_HELPER: &str = "ANTENNA_TOUCHID_HELPER";
/// Debug builds only: the folder of the window's Touch ID folders instead of the macOS one.
#[cfg(debug_assertions)]
const ENV_ROOT: &str = "ANTENNA_TOUCHID_ROOT";

/// The window's Touch ID key for one daemon, and the helper that uses it.
pub(crate) struct TouchId {
    helper: PathBuf,
    dir: PathBuf,
    /// The enrolled owner key's ID (as the daemon lists it).
    pub key_id: String,
    /// An unlock slot was sealed for this key on this Mac.
    pub unlock: bool,
}

/// Why a touch did not happen: the caller asks for the password instead, saying why.
#[derive(Debug)]
pub(crate) struct TouchFail {
    /// The helper's code (`cancelled`, `unavailable`, …).
    pub code: String,
    message: String,
}

impl TouchFail {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    /// The line the terminal shows before it asks for the password; `None` when the owner cancelled.
    pub(crate) fn note(&self) -> Option<String> {
        match self.code.as_str() {
            "cancelled" => None,
            "lockout" => Some("Touch ID is locked after too many tries: use your password.".into()),
            "key_invalidated" => Some(
                "Fingerprints changed since Touch ID was turned on: use your password, then turn Touch ID on again \
                 in Antenna (Settings → Security)."
                    .into(),
            ),
            "unavailable" | "not_enrolled" => Some("Touch ID is unavailable right now: use your password.".into()),
            _ => Some(format!("Touch ID did not work ({}): use your password.", self.message)),
        }
    }
}

/// The folder name for a socket path: FNV-1a 64 of its UTF-8 bytes as 16 hex, as the window names it
/// (`touchIdFolderName` in `lib/host/touch_id.dart`). Only a stable, short name, not a security function.
pub(crate) fn folder_name(socket: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in socket.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// Where the window keeps its Touch ID folders: `~/Library/Application Support/Antenna/touchid` on macOS.
fn root() -> Option<PathBuf> {
    #[cfg(debug_assertions)]
    if let Some(r) = std::env::var_os(ENV_ROOT).filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(r));
    }
    if !cfg!(target_os = "macos") {
        return None;
    }
    let home = std::env::var_os("HOME").filter(|v| !v.is_empty())?;
    Some(PathBuf::from(home).join("Library/Application Support/Antenna/touchid"))
}

/// The helper next to this `antenna`.
fn helper_path() -> Option<PathBuf> {
    #[cfg(debug_assertions)]
    if let Some(h) = std::env::var_os(ENV_HELPER).filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(h));
    }
    let exe = std::env::current_exe().ok()?;
    let h = exe.parent()?.join(HELPER);
    h.is_file().then_some(h)
}

impl TouchId {
    /// Touch ID for the daemon at [socket], when the window turned it on here: its record names an enrolled key, the
    /// key's blob is there, and the helper is next to the CLI. `None` otherwise (Linux, no window, Touch ID off).
    pub(crate) fn find(socket: &Path) -> Option<Self> {
        let dir = root()?.join(folder_name(&socket.to_string_lossy()));
        let rec: Value =
            serde_json::from_slice(&std::fs::read(dir.join("owner_key.json")).ok()?).ok()?;
        let key_id = rec["key_id"].as_str()?.to_string();
        if key_id.len() != 16
            || !key_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return None;
        }
        if !dir.join("signing.key").is_file() {
            return None;
        }
        Some(Self {
            helper: helper_path()?,
            dir,
            key_id,
            unlock: rec["unlock"].as_bool() == Some(true),
        })
    }

    /// Start the helper for one command.
    pub(crate) fn start(&self) -> Result<Helper, TouchFail> {
        let mut child = Command::new(&self.helper)
            .arg(&self.dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                TouchFail::new(
                    "unavailable",
                    format!("the Touch ID helper did not start: {e}"),
                )
            })?;
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(TouchFail::new("failed", "no pipes to the Touch ID helper"));
        };
        Ok(Helper {
            child,
            stdin: Some(stdin),
            stdout: BufReader::new(stdout),
        })
    }
}

/// One running helper.
pub(crate) struct Helper {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
}

impl Helper {
    fn ask(&mut self, msg: &Value) -> Result<Value, TouchFail> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| TouchFail::new("failed", "the Touch ID helper is closed"))?;
        let line = Zeroizing::new(format!("{msg}\n"));
        stdin
            .write_all(line.as_bytes())
            .and_then(|()| stdin.flush())
            .map_err(|e| TouchFail::new("failed", format!("the Touch ID helper: {e}")))?;
        let mut out = Zeroizing::new(String::new());
        let n = self
            .stdout
            .read_line(&mut out)
            .map_err(|e| TouchFail::new("failed", format!("the Touch ID helper: {e}")))?;
        if n == 0 {
            return Err(TouchFail::new("failed", "the Touch ID helper stopped"));
        }
        let v: Value = serde_json::from_str(&out)
            .map_err(|_| TouchFail::new("failed", "the Touch ID helper's reply"))?;
        if let Some(code) = v["error"].as_str() {
            return Err(TouchFail::new(
                code,
                v["message"].as_str().unwrap_or_default(),
            ));
        }
        Ok(v)
    }

    /// One touch with [reason] on the sheet signs the D-102 message of [nonce] (64 hex) and [request] (its exact
    /// text). [reuse]: the touch of the `open_slot` just before (within 30 s, once). Base64 of `r ‖ s`.
    pub(crate) fn sign(
        &mut self,
        nonce: &str,
        request: &str,
        reason: &str,
        reuse: bool,
    ) -> Result<String, TouchFail> {
        let v = self.ask(&json!({"op": "sign", "nonce": nonce, "request": request, "reason": reason, "reuse": reuse}))?;
        v["sig"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| TouchFail::new("failed", "no signature from the Touch ID helper"))
    }

    /// One touch opens the sealed unlock slot's key (base64 of 32 bytes).
    pub(crate) fn open_slot(&mut self, reason: &str) -> Result<Zeroizing<String>, TouchFail> {
        let v = self.ask(&json!({"op": "open_slot", "reason": reason}))?;
        v["slot_key"]
            .as_str()
            .map(|s| Zeroizing::new(s.to_string()))
            .ok_or_else(|| TouchFail::new("failed", "no slot key from the Touch ID helper"))
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        // End of input ends the helper; it holds no state worth waiting long for.
        drop(self.stdin.take());
        let _ = self.child.wait();
    }
}

/// The Touch ID sheet's reason for a terminal command (macOS shows "“antenna-touchid” is trying to …"): the command's
/// words, on one line, at most 80 characters, without control characters.
pub(crate) fn reason_for(words: &[String]) -> String {
    let cmd: String = format!("antenna {}", words.join(" "))
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let cmd = if cmd.chars().count() > 80 {
        format!("{}…", cmd.chars().take(79).collect::<String>())
    } else {
        cmd
    };
    format!("confirm “{cmd}” in the terminal")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The window's `touchIdFolderName` gives the same names (`test/host/touch_id_test.dart`).
    #[test]
    fn folder_names_match_the_window() {
        assert_eq!(folder_name(""), "cbf29ce484222325");
        assert_eq!(folder_name("a"), "af63dc4c8601ec8c");
        // Computed by the window's Dart function for the same path.
        assert_eq!(
            folder_name("/Users/emily/.local/share/antenna/antennad.sock"),
            "38ecf408c459be07"
        );
    }

    #[test]
    fn reasons_are_one_short_line() {
        let r = reason_for(&["trust".into(), "bob".into(), "5".into()]);
        assert_eq!(r, "confirm “antenna trust bob 5” in the terminal");
        let long = reason_for(&["x".repeat(200)]);
        assert!(long.chars().count() < 110, "{long}");
        assert!(!reason_for(&["a\nb".into()]).contains('\n'));
    }

    #[test]
    fn notes_say_why_the_password_is_asked() {
        assert!(TouchFail::new("cancelled", "").note().is_none());
        assert!(
            TouchFail::new("lockout", "")
                .note()
                .unwrap()
                .contains("locked")
        );
        assert!(
            TouchFail::new("key_invalidated", "")
                .note()
                .unwrap()
                .contains("Fingerprints")
        );
    }
}
