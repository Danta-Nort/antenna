// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna hook-signal` (D-134), the program as Code mode's hooks run it: with the agent's token in its
//! environment and no daemon, it writes the hook folder's files and nothing else; a failure is 1, never 2 (which Claude
//! Code reads as "block the tool"). The file protocol itself is checked against the scripts in `src/hook_signal.rs`.
//!
//! T12 (Windows): cmd looks in the current folder before `Path`, so a repository holding `antenna.cmd` would run
//! instead of Antenna's hook. With `NoDefaultCurrentDirectoryInExePath` set, as in Code mode's environment, Antenna's
//! runs. The control: without it, the planted one does.

use std::{
    path::Path,
    process::{Command, Output, Stdio},
};

fn hook_signal(dir: Option<&Path>, args: &[&str], input: &str) -> Output {
    use std::io::Write as _;
    let mut c = Command::new(env!("CARGO_BIN_EXE_antenna"));
    c.arg("hook-signal")
        .args(args)
        // As in Code mode: the agent's token and an endpoint with no daemon behind it.
        .env("ANTENNA_AGENT_TOKEN", "xat_hook_signal_test")
        .env("ANTENNA_SOCKET", "/nonexistent/antennad.sock")
        .env_remove("ANTENNA_CODE_HOOKS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(d) = dir {
        c.env("ANTENNA_CODE_HOOKS", d);
    }
    let mut child = c.spawn().unwrap();
    // A hook refused for its arguments exits before it reads stdin: the write may then meet a closed pipe. That is
    // the program's answer, not a test failure; the exit code and stderr below say what it did.
    if let Err(e) = child.stdin.take().unwrap().write_all(input.as_bytes()) {
        assert_eq!(e.kind(), std::io::ErrorKind::BrokenPipe, "{e}");
    }
    child.wait_with_output().unwrap()
}

#[test]
fn the_hook_writes_its_folder_and_never_exits_2() {
    let d = tempfile::tempdir().unwrap();
    let id = "0123abcd-4567-89ef-0123-456789abcdef";
    let out = hook_signal(
        Some(d.path()),
        &["start"],
        &format!(r#"{{"session_id":"{id}"}}"#),
    );
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert!(out.stdout.is_empty() && out.stderr.is_empty(), "{out:?}");
    let out = hook_signal(
        Some(d.path()),
        &["--notify", r#"{"type":"agent-turn-complete"}"#],
        "",
    );
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert_eq!(
        std::fs::read_to_string(d.path().join("events")).unwrap(),
        "start\nturn-complete\n"
    );
    assert_eq!(
        std::fs::read_to_string(d.path().join("session")).unwrap(),
        format!("{id}\n")
    );
    // Failures: 1, said on stderr, nothing written. Never 2.
    let relative = Path::new("relative");
    for (dir, args) in [
        (None, &["tool"][..]),
        (Some(relative), &["tool"]),
        (Some(d.path()), &["Tool"]),
        (Some(d.path()), &["tool\nstop"]),
        (Some(d.path()), &[]),
        (Some(d.path()), &["tool", "extra"]),
        (Some(d.path()), &["--notify"]),
    ] {
        let out = hook_signal(dir, args, "{}");
        assert_eq!(out.status.code(), Some(1), "{args:?}: {out:?}");
        assert!(!out.stderr.is_empty(), "{args:?}");
    }
    assert_eq!(
        std::fs::read_to_string(d.path().join("events")).unwrap(),
        "start\nturn-complete\n"
    );
}

/// T12: what cmd runs for `antenna hook-signal tool` from a folder holding a planted `antenna.cmd`.
#[cfg(windows)]
#[test]
fn cmd_runs_antennas_hook_not_one_planted_in_the_folder() {
    use std::os::windows::process::CommandExt as _;

    let bin = Path::new(env!("CARGO_BIN_EXE_antenna")).parent().unwrap();
    let root = std::env::var_os("SystemRoot").unwrap();
    let system32 = Path::new(&root).join("System32");
    let run = |guarded: bool| {
        let project = tempfile::tempdir().unwrap();
        let hooks = tempfile::tempdir().unwrap();
        std::fs::write(
            project.path().join("antenna.cmd"),
            "@echo planted> \"%ANTENNA_CODE_HOOKS%\\planted\"\r\n",
        )
        .unwrap();
        let mut c = Command::new(system32.join("cmd.exe"));
        c.raw_arg("/d /c antenna hook-signal tool")
            .current_dir(project.path())
            .env("Path", format!("{};{}", bin.display(), system32.display()))
            .env("ANTENNA_CODE_HOOKS", hooks.path())
            .env_remove("NoDefaultCurrentDirectoryInExePath")
            .stdin(Stdio::null());
        if guarded {
            c.env("NoDefaultCurrentDirectoryInExePath", "1");
        }
        let out = c.output().unwrap();
        let events = std::fs::read_to_string(hooks.path().join("events")).ok();
        let planted = hooks.path().join("planted").exists();
        (out, events, planted)
    };
    let (out, events, planted) = run(true);
    assert_eq!(events.as_deref(), Some("tool\n"), "{out:?}");
    assert!(!planted, "{out:?}");
    // Control.
    let (out, events, planted) = run(false);
    assert!(
        planted,
        "the control: the planted antenna.cmd runs ({out:?})"
    );
    assert_eq!(events, None);
}
