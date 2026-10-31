// SPDX-License-Identifier: AGPL-3.0-only
//! The session's channel with its agent CLI: the same fixed scripts as the window's Code mode
//! (`apps/antenna_desktop/lib/host/code_hooks.dart`, D-UI-25), byte for byte (a unit test compares them).
//!
//! Claude Code runs one fixed command per hook event (registered with `--settings` for this session only; the user's
//! and the project's own settings stay untouched): the script appends only the event's name to the `events` file and
//! keeps a valid session ID; what the hook receives on its standard input is read and dropped. Its Stop hook continues
//! a running turn with a line the waker left in the `continue` file (an [`super::lines::AllowedLine`]), once, never when
//! `stop_hook_active` is set. Codex runs its documented `notify` program when a turn completes: the second script
//! records `turn-complete` and a valid thread ID, nothing else of its argument.

use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

/// The script every Claude Code hook runs (`/bin/sh <dir>/hook.sh <word>`), the same text as the window's
/// `codeHookScript`.
pub(crate) const HOOK_SCRIPT: &str = r#"# Antenna Code mode: Claude Code calls this for its hook events. Only the event's name and a valid session ID are
# recorded for the window; the rest of what the hook receives is read and dropped. Stop: when the window left a line
# to continue with, print it once.
d=${0%/*}
if [ "$1" = stop ]; then
  p=$(cat)
else
  p=$(head -c 1024)
  cat > /dev/null
fi
case $p in
  *'"session_id"'*)
    s=${p#*'"session_id"'}
    q=${s%%'"'*}
    s=${s#*'"'}
    s=${s%%'"'*}
    case $q in ':'|': ') ;; *) s= ;; esac
    case $s in *[!0-9a-f-]*) s= ;; esac
    if [ ${#s} -eq 36 ]; then
      printf '%s\n' "$s" > "$d/session.$$" && mv -f "$d/session.$$" "$d/session"
    fi
    ;;
esac
if [ "$1" = stop ]; then
  case $p in
    *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) ;;
    *)
      if mv -f "$d/continue" "$d/continue.taken" 2>/dev/null; then
        cat "$d/continue.taken"
        rm -f "$d/continue.taken"
        printf 'continued\n' >> "$d/events"
        exit 0
      fi
      ;;
  esac
fi
printf '%s\n' "$1" >> "$d/events"
"#;

/// The program Codex runs when a turn completes (`notify`), the same text as the window's `codeNotifyScript`. Codex
/// also runs it for its own helper threads (0.160.1 names a new conversation in a thread of its own, and that thread's
/// turn completes first), so its thread ID goes into `session.notify`, which counts only when no hook recorded the
/// session itself.
pub(crate) const NOTIFY_SCRIPT: &str = r#"# Antenna Code mode: Codex runs this when a turn completes, with one JSON argument. Only that a turn completed and a
# valid thread ID are recorded for the window (the wake, and resuming the session after an update); the rest of the
# argument is dropped. The ID goes to session.notify: Codex runs this for its helper threads too, so an ID the hooks
# recorded (session) comes first.
d=${0%/*}
p=$1
case $p in
  '{"type":"agent-turn-complete"'*|'{"type": "agent-turn-complete"'*) printf 'turn-complete\n' >> "$d/events" ;;
esac
case $p in
  *'"thread-id"'*)
    s=${p#*'"thread-id"'}
    q=${s%%'"'*}
    s=${s#*'"'}
    s=${s%%'"'*}
    case $q in ':'|': ') ;; *) s= ;; esac
    case $s in *[!0-9a-f-]*) s= ;; esac
    if [ ${#s} -eq 36 ]; then
      printf '%s\n' "$s" > "$d/session.$$" && mv -f "$d/session.$$" "$d/session.notify"
    fi
    ;;
esac
exit 0
"#;

/// What the scripts write into `events`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HookEvent {
    /// SessionStart: at the prompt.
    Start,
    /// UserPromptSubmit: a turn runs.
    Prompt,
    /// PreToolUse.
    Tool,
    /// PermissionRequest: a dialog is open.
    Permission,
    /// PostToolUse.
    ToolDone,
    /// Notification `permission_prompt`.
    NotifyPermission,
    /// Notification `idle_prompt`.
    NotifyIdle,
    /// Stop: at the prompt.
    Stop,
    /// SessionEnd.
    End,
    /// The Stop hook continued the turn with the waker's line.
    Continued,
    /// Codex's `notify`: a turn completed (of some thread: Codex runs it for its helper threads too).
    TurnComplete,
    /// Codex's Interrupt hook: Esc ended a turn or closed a dialog; back at the prompt.
    Interrupt,
}

impl HookEvent {
    /// Every event the Claude Code settings register, with its hook name and matcher.
    const CLAUDE: [(HookEvent, &'static str, Option<&'static str>); 9] = [
        (HookEvent::Start, "SessionStart", None),
        (HookEvent::Prompt, "UserPromptSubmit", None),
        (HookEvent::Tool, "PreToolUse", Some("*")),
        (HookEvent::Permission, "PermissionRequest", Some("*")),
        (HookEvent::ToolDone, "PostToolUse", Some("*")),
        (
            HookEvent::NotifyPermission,
            "Notification",
            Some("permission_prompt"),
        ),
        (HookEvent::NotifyIdle, "Notification", Some("idle_prompt")),
        (HookEvent::Stop, "Stop", None),
        (HookEvent::End, "SessionEnd", None),
    ];

    /// Every event the Codex hooks register (`-c hooks.<Event>=…`; documented at learn.chatgpt.com/docs/hooks, checked
    /// on Codex 0.160.1): the same names as Claude Code's, no Notification, and Interrupt for Esc.
    const CODEX: [(HookEvent, &'static str, Option<&'static str>); 8] = [
        (HookEvent::Start, "SessionStart", None),
        (HookEvent::Prompt, "UserPromptSubmit", None),
        (HookEvent::Tool, "PreToolUse", Some("*")),
        (HookEvent::Permission, "PermissionRequest", Some("*")),
        (HookEvent::ToolDone, "PostToolUse", Some("*")),
        (HookEvent::Stop, "Stop", None),
        (HookEvent::Interrupt, "Interrupt", None),
        (HookEvent::End, "SessionEnd", None),
    ];

    /// The word in the `events` file.
    pub fn word(self) -> &'static str {
        match self {
            HookEvent::Start => "start",
            HookEvent::Prompt => "prompt",
            HookEvent::Tool => "tool",
            HookEvent::Permission => "permission",
            HookEvent::ToolDone => "tool-done",
            HookEvent::NotifyPermission => "notify-permission",
            HookEvent::NotifyIdle => "notify-idle",
            HookEvent::Stop => "stop",
            HookEvent::End => "end",
            HookEvent::Continued => "continued",
            HookEvent::TurnComplete => "turn-complete",
            HookEvent::Interrupt => "interrupt",
        }
    }

    /// The event a word names (`None`: anything else, which is ignored).
    pub fn parse(word: &str) -> Option<HookEvent> {
        [
            HookEvent::Start,
            HookEvent::Prompt,
            HookEvent::Tool,
            HookEvent::Permission,
            HookEvent::ToolDone,
            HookEvent::NotifyPermission,
            HookEvent::NotifyIdle,
            HookEvent::Stop,
            HookEvent::End,
            HookEvent::Continued,
            HookEvent::TurnComplete,
            HookEvent::Interrupt,
        ]
        .into_iter()
        .find(|e| e.word() == word)
    }
}

/// A path as one single-quoted shell word.
pub(crate) fn shell_word(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// `s` as a CLI session ID that may be passed to `claude --resume` or `codex resume`: a lower-case UUID and nothing
/// else. The hook folder is writable by the agent, so what the scripts kept is checked again.
pub(crate) fn valid_session_id(s: &str) -> Option<String> {
    let t = s.trim();
    let b = t.as_bytes();
    let ok = b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_digit() || (b'a'..=b'f').contains(c),
        });
    ok.then(|| t.to_string())
}

fn chmod(path: &Path, mode: u32) -> std::io::Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

fn write_private(path: &Path, text: &str, mode: u32) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let _ = fs::remove_file(&tmp);
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&tmp)?;
    std::io::Write::write_all(&mut f, text.as_bytes())?;
    f.sync_all()?;
    drop(f);
    chmod(&tmp, mode)?;
    fs::rename(&tmp, path)
}

/// The hook folder of one session (0700): the scripts, `events` (read from where it was last read), `session`, and
/// `continue` while a line waits for the Stop hook.
pub(crate) struct HookDir {
    dir: PathBuf,
    offset: u64,
    partial: String,
}

impl HookDir {
    /// Write the scripts and an empty `events` file into `dir` (created 0700), and drop a continuation left over from
    /// an earlier run. The `session` file stays: it is what `--resume` continues.
    pub fn prepare(dir: &Path) -> std::io::Result<HookDir> {
        fs::create_dir_all(dir)?;
        chmod(dir, 0o700)?;
        write_private(&dir.join("hook.sh"), HOOK_SCRIPT, 0o700)?;
        write_private(&dir.join("notify.sh"), NOTIFY_SCRIPT, 0o700)?;
        write_private(&dir.join("events"), "", 0o600)?;
        for stale in [
            "continue",
            "continue.taken",
            "continue.withdrawn",
            "continue.tmp",
        ] {
            let _ = fs::remove_file(dir.join(stale));
        }
        Ok(Self::open(dir))
    }

    /// The folder as it is (the pane's process: `start` prepared it).
    pub fn open(dir: &Path) -> HookDir {
        HookDir {
            dir: dir.to_path_buf(),
            offset: 0,
            partial: String::new(),
        }
    }

    /// The folder.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The command a hook runs for `e`.
    pub fn command(&self, e: HookEvent) -> String {
        format!(
            "/bin/sh {} {}",
            shell_word(&self.dir.join("hook.sh").to_string_lossy()),
            e.word()
        )
    }

    /// Codex's `notify` program.
    pub fn notify_argv(&self) -> Vec<String> {
        vec![
            "/bin/sh".into(),
            self.dir.join("notify.sh").to_string_lossy().into_owned(),
        ]
    }

    /// Events appended since the last call, in order. A partial last line waits for its newline.
    pub fn read_events(&mut self) -> Vec<HookEvent> {
        let Ok(mut f) = fs::File::open(self.dir.join("events")) else {
            return Vec::new();
        };
        let len = f.metadata().map(|m| m.len()).unwrap_or(0);
        if len < self.offset {
            // truncated by a new start
            self.offset = 0;
            self.partial.clear();
        }
        if len == self.offset || f.seek(SeekFrom::Start(self.offset)).is_err() {
            return Vec::new();
        }
        // at most 64 KiB per look: a runaway writer cannot make the waker read without end
        let mut buf = Vec::new();
        let _ = f.take(64 * 1024).read_to_end(&mut buf);
        self.offset += buf.len() as u64;
        let text = format!("{}{}", self.partial, String::from_utf8_lossy(&buf));
        let mut lines: Vec<&str> = text.split('\n').collect();
        self.partial = lines.pop().unwrap_or("").chars().take(256).collect();
        lines
            .into_iter()
            .filter_map(|l| HookEvent::parse(l.trim()))
            .collect()
    }

    /// Leave `json` (the Stop hook's answer) for the next Stop; `false` when it could not be written.
    pub fn offer_continue(&self, json: &str) -> bool {
        write_private(&self.dir.join("continue"), json, 0o600).is_ok()
    }

    /// Take back a continuation the Stop hook has not used; `true` when it was still there. A rename is atomic
    /// against the script's own `mv`: exactly one of the two gets the file.
    pub fn withdraw_continue(&self) -> bool {
        let w = self.dir.join("continue.withdrawn");
        if fs::rename(self.dir.join("continue"), &w).is_ok() {
            let _ = fs::remove_file(w);
            return true;
        }
        false
    }

    /// The CLI's session ID the scripts recorded, checked again: the hooks' (`session`) first, Codex's `notify`
    /// (`session.notify`) only without it.
    pub fn session_id(&self) -> Option<String> {
        ["session", "session.notify"].into_iter().find_map(|f| {
            let p = self.dir.join(f);
            let m = fs::symlink_metadata(&p).ok()?;
            if !m.is_file() || m.len() > 64 {
                return None;
            }
            valid_session_id(&fs::read_to_string(p).ok()?)
        })
    }

    /// The last event word in `events` (for `session list`), without moving the reader.
    pub fn last_event(dir: &Path) -> Option<HookEvent> {
        let text = fs::read_to_string(dir.join("events")).ok()?;
        text.lines().rev().find_map(|l| HookEvent::parse(l.trim()))
    }
}

/// The environment variable that names a session's hook folder for Codex's hooks: their command text stays the same
/// from one run to the next, so the owner trusts them once (Codex asks "Hooks need review" for every new or changed
/// hook definition and keeps the trust by a hash of its text in its own `config.toml`).
pub(crate) const CODEX_HOOKS_VAR: &str = "ANTENNA_CODE_HOOKS";

/// Codex's `-c` overrides that register the state hooks for one session. The command names the folder through
/// [`CODEX_HOOKS_VAR`], set in Codex's environment; hooks inherit it.
pub(crate) fn codex_hook_overrides() -> Vec<String> {
    let mut out = Vec::new();
    for (e, hook, matcher) in HookEvent::CODEX {
        let command = format!("/bin/sh \"${CODEX_HOOKS_VAR}/hook.sh\" {}", e.word());
        let command = serde_json::to_string(&command).unwrap_or_default();
        let m = matcher
            .map(|m| format!("matcher={},", serde_json::to_string(m).unwrap_or_default()))
            .unwrap_or_default();
        out.push("-c".to_string());
        out.push(format!(
            "hooks.{hook}=[{{{m}hooks=[{{type=\"command\",command={command}}}]}}]"
        ));
    }
    out
}

/// Claude Code's `--settings` for one session: the policy hooks of Code mode (`antenna hook claude-code`, CONTROL §5)
/// and the state hooks, entries of the same event side by side (Claude Code merges them with the user's and the
/// project's own).
pub(crate) fn claude_settings(antenna: &Path, hooks: &HookDir) -> serde_json::Value {
    use serde_json::{Map, Value, json};
    let x = shell_word(&antenna.to_string_lossy());
    let mut map: Map<String, Value> = Map::new();
    let mut add = |event: &str, entry: Value| {
        if let Some(a) = map
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
        {
            a.push(entry);
        }
    };
    add(
        "PreToolUse",
        json!({"matcher": "*", "hooks": [{"type": "command", "command": format!("{x} hook claude-code")}]}),
    );
    add(
        "PostToolUse",
        json!({"matcher": "Read|Grep|Glob|NotebookRead", "hooks": [{"type": "command", "command": format!("{x} hook claude-code --mark-level 5")}]}),
    );
    for (e, hook, matcher) in HookEvent::CLAUDE {
        let mut entry = Map::new();
        if let Some(m) = matcher {
            entry.insert("matcher".into(), json!(m));
        }
        entry.insert(
            "hooks".into(),
            json!([{"type": "command", "command": hooks.command(e)}]),
        );
        add(hook, Value::Object(entry));
    }
    json!({ "hooks": map })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The window and the session run the same scripts: the Dart constants hold the same text.
    #[test]
    fn the_scripts_are_the_windows_own() {
        let dart = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../apps/antenna_desktop/lib/host/code_hooks.dart");
        let Ok(src) = fs::read_to_string(&dart) else {
            eprintln!("SKIP: {} is not in this checkout", dart.display());
            return;
        };
        let constant = |name: &str| -> String {
            let head = format!("const {name} = r'''");
            let start = src.find(&head).expect("the constant") + head.len();
            let end = start + src[start..].find("''';").expect("its end");
            src[start..end].to_string()
        };
        assert_eq!(constant("codeHookScript"), HOOK_SCRIPT);
        assert_eq!(constant("codeNotifyScript"), NOTIFY_SCRIPT);
    }

    fn run_hook(dir: &Path, word: &str, input: &str) -> String {
        use std::io::Write;
        let mut c = std::process::Command::new("/bin/sh")
            .arg(dir.join("hook.sh"))
            .arg(word)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        c.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        String::from_utf8(c.wait_with_output().unwrap().stdout).unwrap()
    }

    #[test]
    fn events_session_and_a_continuation_once() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().join("a");
        let mut h = HookDir::prepare(&d).unwrap();
        assert_eq!(
            fs::metadata(&d).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let id = "0f8fad5b-d9cb-469f-a165-70867728950e";
        assert_eq!(
            run_hook(
                &d,
                "start",
                &format!(r#"{{"session_id":"{id}","source":"startup"}}"#)
            ),
            ""
        );
        assert_eq!(h.read_events(), vec![HookEvent::Start]);
        assert_eq!(h.session_id().as_deref(), Some(id));
        // a prompt's text never reaches the files
        run_hook(
            &d,
            "prompt",
            r#"{"session_id":"x","prompt":"secret plans\nstop"}"#,
        );
        assert!(
            !fs::read_to_string(d.join("events"))
                .unwrap()
                .contains("secret")
        );
        assert_eq!(
            h.session_id().as_deref(),
            Some(id),
            "an invalid ID is not kept"
        );
        assert!(h.offer_continue(r#"{"decision":"block","reason":"Approved — continue."}"#));
        assert_eq!(
            run_hook(&d, "stop", r#"{"stop_hook_active":true}"#),
            "",
            "no continuation after a continuation"
        );
        assert_eq!(
            run_hook(&d, "stop", r#"{"stop_hook_active":false}"#),
            r#"{"decision":"block","reason":"Approved — continue."}"#
        );
        assert_eq!(run_hook(&d, "stop", "{}"), "", "once");
        assert_eq!(
            h.read_events(),
            vec![
                HookEvent::Prompt,
                HookEvent::Stop,
                HookEvent::Continued,
                HookEvent::Stop
            ]
        );
        assert!(!h.withdraw_continue());
        assert!(h.offer_continue("{}") && h.withdraw_continue());
        // Codex's notify: the turn and the thread, from the start of its argument only
        let notify = |arg: &str| {
            std::process::Command::new("/bin/sh")
                .arg(d.join("notify.sh"))
                .arg(arg)
                .status()
                .unwrap()
        };
        notify(
            r#"{"type":"agent-turn-complete","thread-id":"0f8fad5b-d9cb-469f-a165-70867728950f","last-assistant-message":"x"}"#,
        );
        notify(r#"{"type":"other","last-assistant-message":"{\"type\":\"agent-turn-complete\"}"}"#);
        assert_eq!(h.read_events(), vec![HookEvent::TurnComplete]);
        // the hooks' ID comes first; Codex's notify only fills in without it
        assert_eq!(h.session_id().as_deref(), Some(id));
        fs::remove_file(d.join("session")).unwrap();
        assert_eq!(
            h.session_id().as_deref(),
            Some("0f8fad5b-d9cb-469f-a165-70867728950f")
        );
    }

    #[test]
    fn claude_settings_hold_both_kinds_of_hooks() {
        let h = HookDir::open(Path::new("/tmp/it's here"));
        let s = claude_settings(Path::new("/opt/antenna"), &h);
        let pre = s["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(
            pre[0]["hooks"][0]["command"],
            "'/opt/antenna' hook claude-code"
        );
        assert_eq!(
            pre[1]["hooks"][0]["command"],
            r#"/bin/sh '/tmp/it'\''s here/hook.sh' tool"#
        );
        assert_eq!(s["hooks"]["Notification"].as_array().unwrap().len(), 2);
        assert_eq!(
            s["hooks"]["Stop"][0]["hooks"][0]["command"],
            r#"/bin/sh '/tmp/it'\''s here/hook.sh' stop"#
        );
        assert!(s["hooks"]["Stop"][0].get("matcher").is_none());
    }

    #[test]
    fn codex_overrides_are_toml_with_a_constant_command() {
        let o = codex_hook_overrides();
        assert_eq!(o.len(), 16);
        assert_eq!(o[0], "-c");
        assert_eq!(
            o[1],
            r#"hooks.SessionStart=[{hooks=[{type="command",command="/bin/sh \"$ANTENNA_CODE_HOOKS/hook.sh\" start"}]}]"#
        );
        assert!(
            o[5].starts_with(r#"hooks.PreToolUse=[{matcher="*",hooks="#),
            "{}",
            o[5]
        );
        assert!(
            o.iter()
                .any(|a| a.contains("hooks.Interrupt=") && a.ends_with(r#"interrupt"}]}]"#))
        );
        // the same text every time: Codex keeps the owner's trust by its hash
        assert_eq!(o, codex_hook_overrides());
    }

    #[test]
    fn session_ids() {
        assert!(valid_session_id("0f8fad5b-d9cb-469f-a165-70867728950e\n").is_some());
        for bad in [
            "0F8FAD5B-D9CB-469F-A165-70867728950E",
            "0f8fad5b-d9cb-469f-a165-70867728950",
            "../../etc/passwd",
            "",
        ] {
            assert!(valid_session_id(bad).is_none(), "{bad}");
        }
    }
}
