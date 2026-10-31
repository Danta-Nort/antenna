// SPDX-License-Identifier: AGPL-3.0-only
//! CLI integration tests without a daemon: every command of SPEC §12 is declared; unimplemented ones answer
//! "not implemented" (69), implemented ones without a daemon answer "daemon unavailable" (75) instead of pretending.
//! With an agent token the CLI has no owner commands at all: "no such command" (2), even without a daemon.

use std::process::{Command, Output};

/// The CLI without the daemon and agent variables of the environment the tests run in (an agent's session sets
/// `ANTENNA_AGENT_TOKEN` and may set `ANTENNA_SOCKET`: the commands would reach the owner's real daemon as that agent).
fn antenna() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_antenna"));
    for k in [
        "ANTENNA_DATA_DIR",
        "X_DATA_DIR",
        "ANTENNA_SOCKET",
        "X_SOCKET",
        "ANTENNA_LINKS_DIR",
        "X_LINKS_DIR",
        "ANTENNA_AGENT_TOKEN",
        "ANTENNA_AGENT_TOKEN_FILE",
        "X_AGENT_TOKEN",
    ] {
        c.env_remove(k);
    }
    c
}

fn x(args: &[&str]) -> Output {
    antenna().args(args).output().expect("run x")
}

/// Commands of SPEC §12 not yet available in v0.1 slice 4.
const NOT_IMPLEMENTED: &[&[&str]] = &[
    &["invite", "--code"],
    &["join", "7-tiger-orbit"],
    &["trust", "bob", "4", "--for", "24h"],
    &["rotate", "bob"],
    &["chat", "bob"],
    &["relay", "set", "https://relay.example"],
    &["init", "--key-backend", "file"],
];

/// What an implemented command answers without a daemon: its exit code, its error code and a word of its message.
struct NoDaemon {
    exit: i32,
    error: &'static str,
    says: &'static str,
}

/// Exit code 75 (EX_TEMPFAIL): neither success nor "not implemented". On Windows too: the CLI tries the control pipe
/// and finds no daemon there (D-135).
const NO_DAEMON: NoDaemon = NoDaemon {
    exit: 75,
    error: "daemon_unavailable",
    says: "daemon_unavailable",
};

/// Implemented commands: without a daemon, [NO_DAEMON].
const NEEDS_DAEMON: &[&[&str]] = &[
    &["share", "bob", "/tmp/file.txt"],
    &["request", "bob", "shared/report.pdf"],
    &["files", "pending"],
    &["files", "preview", "f1"],
    &["files", "accept", "f1"],
    &["files", "reject", "f1"],
    &["status"],
    &["lock"],
    &["contacts"],
    &["send", "bob", "hello"],
    &["inbox", "--wait"],
    &["log", "bob"],
    &["approvals"],
    &["pairing"],
    &["agent", "list"],
    &[
        "invite",
        "--trust",
        "2",
        "--ttl",
        "10m",
        "--label",
        "Bob",
        "--password-stdin",
    ],
    &["join", "x://pair#abc", "--password-stdin"],
    &["trust", "bob", "4", "--password-stdin"],
    &["approve", "r1", "--password-stdin"],
    &["deny", "r1", "--password-stdin"],
    &[
        "agent",
        "add",
        "claude",
        "--local-level",
        "5",
        "--password-stdin",
    ],
    &["revoke", "bob", "--password-stdin"],
    &["rekey", "bob", "--password-stdin"],
    &["verify", "bob"],
    &["rename", "bob", "Bob"],
    &["login", "--password-stdin"],
    &["logout"],
    &[
        "pairing",
        "confirm",
        "i1",
        "--code",
        "123456",
        "--password-stdin",
    ],
];

/// Owner commands the agent does not have: with a token the CLI answers "no such command", not "forbidden".
pub const OWNER_ONLY: &[&[&str]] = &[
    &["init"],
    &["unlock"],
    &["lock"],
    &["invite", "--trust", "5"],
    &["join", "x://pair#abc"],
    &["trust", "bob", "5"],
    &["approve", "r1"],
    &["deny", "r1"],
    &["approvals"],
    &["pairing", "confirm", "i1"],
    &["agent", "add", "evil"],
    &["rotate", "bob"],
    &["revoke", "bob"],
    &["rekey", "bob"],
    &["rename", "bob", "Mallory"],
    &["login"],
    &["logout"],
    &["update"],
    &["chat", "bob"],
    &["relay", "set", "https://relay.example"],
    &["wake", "say", "bob", "hello"],
    &["wake", "session", "bob", "reset"],
    &["local", "models"],
    &["local", "install", "qwen3.5-2b"],
    &["local", "remove", "qwen3.5-2b"],
    &["local", "add", "evil", "--model", "qwen3.5-2b"],
    &["local", "say", "helper", "hello"],
    &["local", "history", "helper"],
    &["local", "session", "helper", "reset"],
    // Where an agent's questions go, and the owner's answers (D-118)
    &["agent", "escalate", "helper", "--owner"],
    &["questions"],
    &["answer", "0123456789abcdef", "yes"],
    // Agent CLI sessions in tmux (D-108): the agent's own `session` (its taint) has none of these subcommands
    &["session", "start", "helper"],
    &["session", "list"],
    &["session", "attach", "helper"],
    &["session", "stop", "helper"],
    &["session", "wake", "helper", "off"],
    &["session", "run", "helper", "--root", "/tmp"],
    // Approver agents (PG-57): the owner names, narrows and removes them
    &["approver"],
    &["approver", "set", "helper", "--yes"],
    &["approver", "narrow", "helper"],
    &["approver", "remove", "helper"],
    // The stop switch (PG-58): the owner stops an agent here or on an own computer
    &["agent", "stop", "helper"],
    &["devices", "stop-agent", "mini", "helper"],
];

fn x_nodaemon(args: &[&str]) -> Output {
    let dir = tempfile::tempdir().unwrap();
    let mut a = vec!["--data-dir", dir.path().to_str().unwrap()];
    a.extend_from_slice(args);
    x(&a)
}

#[test]
fn unimplemented_commands_are_declared_and_honest() {
    for args in NOT_IMPLEMENTED {
        let out = x_nodaemon(args);
        assert_eq!(out.status.code(), Some(69), "antenna {args:?}: {out:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("not implemented"),
            "x {args:?}: stderr={stderr}"
        );
    }
}

/// `antenna update` (D-82) is implemented: the status needs no daemon; installing needs one for the owner check.
#[test]
fn update_status_without_daemon_and_install_needs_one() {
    let out = x_nodaemon(&["--json", "update"]);
    assert!(out.status.success(), "{out:?}");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["action"], "status");
    // A build in target/ cannot update itself, and says why.
    assert_eq!(v["install"]["kind"], "unsupported", "{v}");
}

#[test]
fn implemented_commands_without_daemon_report_unavailable() {
    // On Windows `login` opens no session at all, daemon or not (WP-10): its own test below.
    for args in NEEDS_DAEMON
        .iter()
        .filter(|a| !(cfg!(windows) && a[0] == "login"))
    {
        let out = x_nodaemon(args);
        assert_eq!(
            out.status.code(),
            Some(NO_DAEMON.exit),
            "antenna {args:?}: {out:?}"
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(NO_DAEMON.says),
            "x {args:?}: stderr={stderr}"
        );
    }
}

#[test]
fn password_gated_commands_need_a_password_not_a_terminal() {
    // Without a terminal and without --password-stdin there is nowhere to ask for the password: an argument error,
    // the daemon is not contacted.
    for args in [
        &["trust", "bob", "4"][..],
        &["approve", "r1"],
        &["agent", "add", "a", "--local-level", "0"],
        &["revoke", "bob"],
        &["rekey", "bob"],
        &["login"],
    ] {
        let out = x_nodaemon(args);
        assert_eq!(out.status.code(), Some(2), "antenna {args:?}: {out:?}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("password"));
    }
}

/// Q-15: the agent's base label is chosen explicitly, there is no default; the help text explains the choice.
#[test]
fn agent_add_requires_an_explicit_local_level() {
    let out = x_nodaemon(&["agent", "add", "claude", "--password-stdin"]);
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("--local-level"), "{err}");
    let help = x(&["agent", "add", "--help"]);
    let h = String::from_utf8_lossy(&help.stdout);
    assert!(
        h.contains("REQUIRED") && h.contains("5 = an agent with access to the owner's"),
        "{h}"
    );
    assert!(!h.contains("[default"), "no default: {h}");
}

#[test]
fn agent_token_cli_has_no_owner_commands() {
    let dir = tempfile::tempdir().unwrap();
    for args in OWNER_ONLY {
        let mut a = vec!["--json", "--data-dir", dir.path().to_str().unwrap()];
        a.extend_from_slice(args);
        let out = antenna()
            .args(&a)
            .env("ANTENNA_AGENT_TOKEN", "xat_fake")
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(2), "antenna {args:?}: {out:?}");
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(v["error"], "unknown_command", "antenna {args:?}: {v}");
        assert!(!String::from_utf8_lossy(&out.stderr).contains("forbidden"));
    }
    // And the agent help does not have them either.
    let out = antenna()
        .args(["--agent-token", "xat_fake", "--help"])
        .output()
        .unwrap();
    let help = String::from_utf8_lossy(&out.stdout);
    let cmds: Vec<&str> = help
        .lines()
        .skip_while(|l| !l.starts_with("Commands:"))
        .skip(1)
        .take_while(|l| !l.trim().is_empty())
        .filter_map(|l| l.split_whitespace().next())
        .collect();
    assert!(cmds.contains(&"send") && cmds.contains(&"mcp"), "{help}");
    for owner in [
        "init",
        "unlock",
        "lock",
        "invite",
        "join",
        "trust",
        "approve",
        "deny",
        "approvals",
        "pairing",
        "agent",
        "rotate",
        "revoke",
        "update",
        "wake",
    ] {
        assert!(!cmds.contains(&owner), "agent help lists {owner}: {cmds:?}");
    }
}

#[test]
fn mcp_without_token_is_refused() {
    let out = x_nodaemon(&["--json", "mcp"]);
    assert_eq!(out.status.code(), Some(77), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("token_invalid"));
}

#[test]
fn json_mode_reports_errors_on_stdout() {
    let out = x_nodaemon(&["--json", "send", "bob", "hi"]);
    assert_eq!(out.status.code(), Some(NO_DAEMON.exit));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains(&format!(r#""error":"{}""#, NO_DAEMON.error)),
        "{stdout}"
    );
    assert!(stdout.contains(r#""command":"send""#), "{stdout}");
}

/// `antenna doctor` without a daemon: the finding `daemon_down` and the "daemon unavailable" exit code (75), the
/// report printed anyway (D-96). On Windows as well, where the daemon is behind the control pipe (D-135).
#[test]
fn doctor_without_a_daemon_reports_daemon_down() {
    let out = x_nodaemon(&["--json", "doctor"]);
    assert_eq!(out.status.code(), Some(75), "{out:?}");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["state"], "unreachable", "{v}");
    assert_eq!(v["findings"][0]["code"], "daemon_down", "{v}");
    let out = x_nodaemon(&["doctor"]);
    assert_eq!(out.status.code(), Some(75), "{out:?}");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("daemon_down (error): "), "{text}");
    assert!(text.contains("what to do: Start Antenna"), "{text}");
    // The way to start it on this system: on Windows the window (no service), elsewhere also the user service.
    if cfg!(windows) {
        assert!(
            text.contains("Start menu") && !text.contains("systemctl"),
            "{text}"
        );
    } else {
        assert!(text.contains("systemctl --user start antennad"), "{text}");
    }
}

/// `antenna connect` without a daemon: the agent comes first, so it stops at "daemon unavailable" (75) and writes
/// nothing into the folder, the folder setup (`--instructions`) included.
#[test]
fn connect_without_a_daemon_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let out = x_nodaemon(&[
        "--json",
        "connect",
        "claude-code",
        "--agent",
        "dev",
        "--dir",
        dir.path().to_str().unwrap(),
        "--instructions",
        "--yes",
    ]);
    assert_eq!(out.status.code(), Some(NO_DAEMON.exit), "{out:?}");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["error"], NO_DAEMON.error, "{v}");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}

/// Windows: `antenna login` opens no session and says why, before any daemon is asked (WP-10): a console can be joined
/// by another process, so it names no terminal. Each owner command asks for the password itself.
#[cfg(windows)]
#[test]
fn on_windows_login_opens_no_session_and_says_why() {
    let out = x_nodaemon(&["login", "--password-stdin"]);
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("opens no session") && !err.contains("daemon_unavailable"),
        "{err}"
    );
}

/// Windows: a token file that another account may read is refused before it is read, naming who may read it
/// (`read_token_file`, D-135). The control: the same file without that entry is read, and the command goes on to the
/// daemon, which is not there.
#[cfg(windows)]
#[test]
fn on_windows_a_token_file_others_may_read_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("token");
    std::fs::write(&file, "xat_fake\n").unwrap();
    let inbox = || {
        antenna()
            .args(["--json", "--data-dir"])
            .arg(dir.path().join("data"))
            .args(["--token-file", file.to_str().unwrap(), "inbox"])
            .output()
            .unwrap()
    };
    // Control: the file as the temporary folder made it (the user, SYSTEM and the Administrators).
    let out = inbox();
    assert_eq!(
        out.status.code(),
        Some(NO_DAEMON.exit),
        "the control: {out:?}"
    );
    // The Users group may read it now.
    let root = std::env::var_os("SystemRoot").unwrap();
    let granted = Command::new(
        std::path::Path::new(&root)
            .join("System32")
            .join("icacls.exe"),
    )
    .arg(&file)
    .args(["/grant", "*S-1-5-32-545:R"])
    .output()
    .unwrap();
    assert!(granted.status.success(), "{granted:?}");
    let out = inbox();
    assert_eq!(out.status.code(), Some(77), "{out:?}");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["error"], "token_invalid", "{v}");
    let message = v["message"].as_str().unwrap();
    assert!(
        message.contains("S-1-5-32-545") && message.contains("may read it"),
        "{v}"
    );
    assert!(
        !message.contains("xat_fake"),
        "the token is never shown: {v}"
    );
}

#[test]
fn help_and_version_succeed() {
    assert_eq!(x(&["--help"]).status.code(), Some(0));
    assert_eq!(x(&["--version"]).status.code(), Some(0));
}

#[test]
fn invalid_trust_level_is_rejected_by_parser() {
    let out = x(&["trust", "bob", "9"]);
    assert_eq!(out.status.code(), Some(2)); // A clap parse error is 2, not 69.
    assert!(!String::from_utf8_lossy(&out.stderr).contains("not implemented"));
}

#[test]
fn unknown_command_is_an_error() {
    let out = x(&["make-me-level-5"]);
    assert_ne!(out.status.code(), Some(0));
}

#[test]
fn version_names_package_version_and_commit() {
    let out = x(&["--version"]);
    let v = String::from_utf8_lossy(&out.stdout);
    let prefix = format!("antenna {} (", env!("CARGO_PKG_VERSION"));
    assert!(v.starts_with(&prefix), "{v}");
    // Build commit: 12 hex characters (git) or `unknown` (a build from an archive without .git).
    let commit = v.trim().trim_start_matches(&prefix).trim_end_matches(')');
    assert!(
        commit == "unknown"
            || (commit.len() == 12 && commit.chars().all(|c| c.is_ascii_hexdigit())),
        "{v}"
    );
}

/// Variables of the preview build `x` (`X_SOCKET`, `X_AGENT_TOKEN`, …) work as fallbacks with a warning on stderr;
/// the new `ANTENNA_*` take precedence (D-55).
#[test]
fn legacy_environment_variables_are_a_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let (old, new) = (dir.path().join("old.sock"), dir.path().join("new.sock"));
    let run = |envs: &[(&str, &std::path::Path)], args: &[&str]| -> Output {
        let mut c = antenna();
        for k in [
            "ANTENNA_SOCKET",
            "X_SOCKET",
            "ANTENNA_DATA_DIR",
            "X_DATA_DIR",
            "ANTENNA_AGENT_TOKEN",
            "X_AGENT_TOKEN",
        ] {
            c.env_remove(k);
        }
        for (k, v) in envs {
            c.env(k, v);
        }
        c.args(args).output().unwrap()
    };
    let out = run(&[("X_SOCKET", &old)], &["--json", "status"]);
    assert_eq!(out.status.code(), Some(NO_DAEMON.exit), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("old.sock"),
        "{out:?}"
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("X_SOCKET is deprecated") && err.contains("ANTENNA_SOCKET"),
        "{err}"
    );

    let out = run(
        &[("X_SOCKET", &old), ("ANTENNA_SOCKET", &new)],
        &["--json", "status"],
    );
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("new.sock"),
        "{out:?}"
    );
    assert!(
        !String::from_utf8_lossy(&out.stderr).contains("deprecated"),
        "{out:?}"
    );

    // The data folder's endpoint: its socket, or on Windows its pipe (D-135).
    let out = run(&[("X_DATA_DIR", dir.path())], &["--json", "status"]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let endpoint = if cfg!(windows) {
        r"\\.\pipe\antenna-"
    } else {
        "antennad.sock"
    };
    assert!(v["message"].as_str().unwrap().contains(endpoint), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stderr).contains("X_DATA_DIR is deprecated"));

    // An old agent token: the agent CLI (no owner commands), with a warning.
    let out = run(
        &[
            ("X_SOCKET", &old),
            ("X_AGENT_TOKEN", std::path::Path::new("xat_fake")),
        ],
        &["--json", "trust", "bob", "5"],
    );
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("unknown_command"));
    assert!(String::from_utf8_lossy(&out.stderr).contains("X_AGENT_TOKEN is deprecated"));
}
