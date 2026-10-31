// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna hook-signal` (D-134, Code mode on Windows): Code mode's two hook scripts, `hook.sh` and
//! `notify.sh` (`session/hooks.rs`, `apps/antenna_desktop/lib/host/code_hooks.dart`), as one command of the CLI, so the
//! hooks need no shell on Windows. It keeps the scripts' file protocol to the byte, so the window reads it unchanged.
//!
//! - `antenna hook-signal <word>`: Claude Code's (and Codex's) hook for one event. It reads the hook's input: all of it
//!   for `stop`, otherwise the first 1024 bytes, and the rest is read and dropped. It keeps a valid session ID in
//!   `session`. On `stop`, unless `stop_hook_active` is set, it continues the turn once with the line the window left
//!   in `continue`: it prints it and records `continued`. Otherwise it appends the word to `events`.
//! - `antenna hook-signal --notify <json>`: Codex's `notify` program. An `agent-turn-complete` appends
//!   `turn-complete`, and a valid thread ID goes to `session.notify`; the rest of the argument is dropped.
//!
//! The folder is `ANTENNA_CODE_HOOKS`, set by Code mode. The command never talks to the daemon and reads no token. A
//! word is lowercase letters and `-`, starting with a letter (the scripts took any word). It never exits with 2, which
//! Claude Code reads as "block the tool": a failure is 1, said on stderr. `--notify` exits 0, as `notify.sh` does.

use std::{
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::ExitCode,
};

/// The subcommand's name. It is hidden from the help: Code mode's hooks run it, a person has no use for it.
pub const COMMAND: &str = "hook-signal";
/// The variable that names the run's hook folder.
pub const DIR_VAR: &str = "ANTENNA_CODE_HOOKS";
/// How much of a hook's input is looked at, except on `stop` (the scripts' `head -c 1024`).
const HEAD: u64 = 1024;
/// The longest word.
const MAX_WORD: usize = 32;

/// `antenna hook-signal <word>` or `antenna hook-signal --notify <json>`.
pub fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(2).collect();
    let Some(dir) = std::env::var_os(DIR_VAR)
        .map(PathBuf::from)
        .filter(|d| d.is_absolute())
    else {
        eprintln!("antenna {COMMAND}: {DIR_VAR} names no folder (Code mode sets it)");
        return ExitCode::FAILURE;
    };
    let done = match args.as_slice() {
        [flag, json] if flag == "--notify" => {
            notify(&dir, json.to_string_lossy().as_bytes());
            return ExitCode::SUCCESS;
        }
        [word] => match word.to_str().filter(|w| valid_word(w)) {
            Some(w) => hook(&dir, w, &mut io::stdin().lock(), &mut io::stdout().lock()),
            None => Err(io::Error::other(
                "a word is lowercase letters and `-`, at most 32",
            )),
        },
        _ => Err(io::Error::other(
            "usage: antenna hook-signal <word> | antenna hook-signal --notify <json>",
        )),
    };
    match done {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("antenna {COMMAND}: {e}");
            ExitCode::FAILURE
        }
    }
}

/// A word starts with a lowercase letter, so an option (`--notify` alone) is never taken for one.
fn valid_word(w: &str) -> bool {
    w.len() <= MAX_WORD
        && w.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
        && w.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
}

/// `hook.sh <word>` with `input` as its standard input and `out` as its standard output.
pub fn hook(dir: &Path, word: &str, input: &mut impl Read, out: &mut impl Write) -> io::Result<()> {
    let mut p = Vec::new();
    if word == "stop" {
        input.read_to_end(&mut p)?;
    } else {
        input.by_ref().take(HEAD).read_to_end(&mut p)?;
        io::copy(input, &mut io::sink())?;
    }
    if let Some(id) = quoted_id(&p, b"\"session_id\"") {
        // As in the script, a session that cannot be written does not stop the event.
        let _ = write_atomic(dir, "session", id);
    }
    if word == "stop"
        && !contains(&p, b"\"stop_hook_active\":true")
        && !contains(&p, b"\"stop_hook_active\": true")
        && fs::rename(dir.join("continue"), dir.join("continue.taken")).is_ok()
    {
        let line = fs::read(dir.join("continue.taken"))?;
        out.write_all(&line)?;
        out.flush()?;
        let _ = fs::remove_file(dir.join("continue.taken"));
        return append(dir, "continued");
    }
    append(dir, word)
}

/// `notify.sh <json>`. Like the script, it reports a failure on stderr and goes on.
pub fn notify(dir: &Path, p: &[u8]) {
    if (p.starts_with(b"{\"type\":\"agent-turn-complete\"")
        || p.starts_with(b"{\"type\": \"agent-turn-complete\""))
        && let Err(e) = append(dir, "turn-complete")
    {
        eprintln!("antenna {COMMAND}: {e}");
    }
    if let Some(id) = quoted_id(p, b"\"thread-id\"") {
        let _ = write_atomic(dir, "session.notify", id);
    }
}

/// The value after `key`, as the scripts take it: the text after the key's first appearance up to its first quote must
/// be `:` or `: `; the value is what stands between that quote and the next; it counts only as 36 characters of
/// `0-9a-f-`.
fn quoted_id<'a>(p: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let at = p.windows(key.len()).position(|w| w == key)?;
    let s = &p[at + key.len()..];
    let between = before_quote(s);
    let value = before_quote(after_quote(s));
    let id_byte = |c: &u8| c.is_ascii_digit() || (b'a'..=b'f').contains(c) || *c == b'-';
    ((between == b":" || between == b": ") && value.len() == 36 && value.iter().all(id_byte))
        .then_some(value)
}

/// The text before the first quote (`${s%%'"'*}`); all of it without one.
fn before_quote(s: &[u8]) -> &[u8] {
    s.iter().position(|&c| c == b'"').map_or(s, |i| &s[..i])
}

/// The text after the first quote (`${s#*'"'}`); all of it without one.
fn after_quote(s: &[u8]) -> &[u8] {
    s.iter().position(|&c| c == b'"').map_or(s, |i| &s[i + 1..])
}

fn contains(p: &[u8], needle: &[u8]) -> bool {
    p.windows(needle.len()).any(|w| w == needle)
}

/// `name` replaced at once by `id` and a newline, through a file of this process's own.
fn write_atomic(dir: &Path, name: &str, id: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!("{name}.{}", std::process::id()));
    let mut line = id.to_vec();
    line.push(b'\n');
    fs::write(&tmp, &line)?;
    fs::rename(&tmp, dir.join(name)).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

/// Appends `word` and a newline to `events`.
fn append(dir: &Path, word: &str) -> io::Result<()> {
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("events"))?
        .write_all(format!("{word}\n").as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123abcd-4567-89ef-0123-456789abcdef";

    /// The folder's files, apart from the scripts, by name.
    #[cfg(unix)]
    fn files(dir: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
        fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap())
            .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
            .filter(|(n, _)| n != "hook.sh" && n != "notify.sh")
            .map(|(n, p)| (n, fs::read(p).unwrap()))
            .collect()
    }

    fn run(dir: &Path, word: &str, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        hook(dir, word, &mut &input[..], &mut out).unwrap();
        out
    }

    /// What the window reads, from the hooks' inputs: the word, a valid session ID, the continuation once. The
    /// controls are the IDs that do not count.
    #[test]
    fn events_sessions_and_the_continuation() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path();
        run(
            dir,
            "start",
            format!(r#"{{"session_id":"{ID}","x":1}}"#).as_bytes(),
        );
        assert_eq!(fs::read(dir.join("events")).unwrap(), b"start\n");
        assert_eq!(
            fs::read(dir.join("session")).unwrap(),
            format!("{ID}\n").as_bytes()
        );
        // Controls: none of these replaces the session.
        let other = "ffffffff-ffff-ffff-ffff-ffffffffffff";
        for bad in [
            format!(r#"{{"session_id":"{}"}}"#, &other[..35]),
            format!(r#"{{"session_id":"{}"}}"#, other.to_uppercase()),
            format!(r#"{{"session_id" : "{other}"}}"#),
            format!(r#"{{"session_id":"{other}x"}}"#),
            format!(r#"{{"pad":"{}","session_id":"{other}"}}"#, "p".repeat(1024)),
        ] {
            run(dir, "tool", bad.as_bytes());
            assert_eq!(
                fs::read(dir.join("session")).unwrap(),
                format!("{ID}\n").as_bytes(),
                "{bad}"
            );
        }
        // Beyond 1024 bytes the stop hook still finds it (it reads all of its input), and `: ` counts.
        run(
            dir,
            "stop",
            format!(
                r#"{{"pad":"{}","session_id": "{other}"}}"#,
                "p".repeat(1024)
            )
            .as_bytes(),
        );
        assert_eq!(
            fs::read(dir.join("session")).unwrap(),
            format!("{other}\n").as_bytes()
        );

        // The continuation: printed once, `continued` recorded, the file gone; never while stop_hook_active.
        fs::write(
            dir.join("continue"),
            b"{\"decision\":\"block\",\"reason\":\"go on\"}\n",
        )
        .unwrap();
        assert!(run(dir, "stop", br#"{"stop_hook_active":true}"#).is_empty());
        assert!(run(dir, "stop", br#"{"stop_hook_active": true}"#).is_empty());
        assert_eq!(
            run(dir, "stop", b"{}"),
            b"{\"decision\":\"block\",\"reason\":\"go on\"}\n"
        );
        assert!(!dir.join("continue").exists() && !dir.join("continue.taken").exists());
        assert!(run(dir, "stop", b"{}").is_empty());
        let events = String::from_utf8(fs::read(dir.join("events")).unwrap()).unwrap();
        assert_eq!(
            events,
            "start\ntool\ntool\ntool\ntool\ntool\nstop\nstop\nstop\ncontinued\nstop\n"
        );
    }

    #[test]
    fn notify_records_the_turn_and_the_thread() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path();
        notify(
            dir,
            format!(r#"{{"type":"agent-turn-complete","thread-id":"{ID}"}}"#).as_bytes(),
        );
        notify(dir, br#"{"type": "agent-turn-complete"}"#);
        // Controls: another type, and a type that only appears later, record nothing.
        notify(dir, br#"{"type":"other"}"#);
        notify(dir, br#"{"x":1,"type":"agent-turn-complete"}"#);
        assert_eq!(
            fs::read(dir.join("events")).unwrap(),
            b"turn-complete\nturn-complete\n"
        );
        assert_eq!(
            fs::read(dir.join("session.notify")).unwrap(),
            format!("{ID}\n").as_bytes()
        );
        assert!(!dir.join("session").exists());
    }

    #[test]
    fn words_are_code_modes_own() {
        for w in ["start", "tool-done", "notify-permission", "turn-complete"] {
            assert!(valid_word(w), "{w}");
        }
        for w in [
            "",
            "Tool",
            "tool\nstop",
            "tool done",
            "../x",
            "--notify",
            "-x",
            &"a".repeat(33),
        ] {
            assert!(!valid_word(w), "{w:?}");
        }
    }

    /// T11: the command and the scripts it replaces, on the same inputs, leave the same files and print the same
    /// continuation (the scripts run under `/bin/sh`, so on Linux and macOS).
    #[cfg(unix)]
    #[test]
    fn the_command_and_the_scripts_leave_the_same_files() {
        use std::process::{Command, Stdio};

        use crate::session::hooks::{HOOK_SCRIPT, NOTIFY_SCRIPT};

        let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        fs::write(a.path().join("hook.sh"), HOOK_SCRIPT).unwrap();
        fs::write(a.path().join("notify.sh"), NOTIFY_SCRIPT).unwrap();
        let sh = |args: &[&str], input: &[u8]| -> Vec<u8> {
            let mut c = Command::new("/bin/sh")
                .args(args)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            c.stdin.take().unwrap().write_all(input).unwrap();
            c.wait_with_output().unwrap().stdout
        };
        let hook_sh = a.path().join("hook.sh");
        let notify_sh = a.path().join("notify.sh");
        let other = "ffffffff-ffff-ffff-ffff-ffffffffffff";
        let long = format!(r#"{{"pad":"{}","session_id":"{other}"}}"#, "p".repeat(1024));
        let steps: Vec<(&str, String)> = vec![
            ("start", format!(r#"{{"session_id":"{ID}"}}"#)),
            (
                "prompt",
                format!(r#"{{"session_id": "{other}","prompt":"hi"}}"#),
            ),
            ("tool", format!(r#"{{"session_id":"{}"}}"#, &ID[..35])),
            (
                "tool",
                format!(r#"{{"session_id":"{}"}}"#, ID.to_uppercase()),
            ),
            ("tool", format!(r#"{{"session_id" : "{ID}"}}"#)),
            ("tool-done", long.clone()),
            ("stop", long),
            ("stop", r#"{"stop_hook_active":true}"#.into()),
            (
                "continue",
                "{\"decision\":\"block\",\"reason\":\"go on\"}\n".into(),
            ),
            ("stop", r#"{"stop_hook_active": true}"#.into()),
            ("stop", "{}".into()),
            ("stop", "{}".into()),
            (
                "notify",
                format!(r#"{{"type":"agent-turn-complete","thread-id":"{ID}"}}"#),
            ),
            (
                "notify",
                r#"{"type": "agent-turn-complete","thread-id":"short"}"#.into(),
            ),
            ("notify", r#"{"type":"other"}"#.into()),
            ("end", String::new()),
        ];
        for (word, input) in steps {
            let (by_script, by_command) = match word {
                "continue" => {
                    fs::write(a.path().join("continue"), &input).unwrap();
                    fs::write(b.path().join("continue"), &input).unwrap();
                    continue;
                }
                "notify" => {
                    sh(&[notify_sh.to_str().unwrap(), &input], b"");
                    notify(b.path(), input.as_bytes());
                    (Vec::new(), Vec::new())
                }
                _ => (
                    sh(&[hook_sh.to_str().unwrap(), word], input.as_bytes()),
                    run(b.path(), word, input.as_bytes()),
                ),
            };
            assert_eq!(by_command, by_script, "{word} {input}: printed");
            assert_eq!(files(b.path()), files(a.path()), "{word} {input}: files");
        }
    }
}
