// SPDX-License-Identifier: AGPL-3.0-only
//! tmux, the terminal host of `antenna session` (D-108): a server of its own on a private socket in the data directory
//! (`<data-dir>/sessions/tmux.sock`, the folder 0700), started with a clean environment and Antenna's own small
//! configuration, so the owner's own tmux sessions and settings are never touched and nothing of the shell that ran
//! `antenna session start` (an agent's token, another CLI's session markers) reaches the agent. Only sessions Antenna
//! started live on this socket; the waker types only into its own pane (`$TMUX_PANE`).

use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Stdio,
};

use super::screen::Screen;

/// Antenna's tmux configuration: the defaults, with a short escape time (Esc reaches Claude Code and Codex at once)
/// and a long scrollback.
pub(crate) const TMUX_CONF: &str = "# Antenna sessions (antenna session): written by Antenna, read by its own tmux server only.\n\
set -s escape-time 20\n\
set -g history-limit 20000\n\
set -g remain-on-exit off\n";

/// What an agent and its terminal host keep from the environment of whoever started them: who and where the person
/// is, the locale and display, the SSH agent, proxies and certificates, and the vendor API settings a CLI reads when
/// the person set them. The same list as the window's Code mode (`agentEnvKeep`, `agent_launch.dart`), plus
/// `CLAUDE_CODE_OAUTH_TOKEN`, how a server signs Claude Code in (`claude setup-token`) where no browser is: markers of
/// other agent sessions (`CLAUDECODE`, the other `CLAUDE_CODE_*`, `CODEX_*` but `CODEX_HOME`), an agent token and the
/// Antenna variables never pass.
pub(crate) const ENV_KEEP: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "PATH",
    "TMPDIR",
    "TZ",
    "LANG",
    "__CF_USER_TEXT_ENCODING",
    "SSH_AUTH_SOCK",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_RUNTIME_DIR",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_STATE_HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "REQUESTS_CA_BUNDLE",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_CLOUD_PROJECT",
    "XAI_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    // where a CLI keeps its settings and sign-in when the person moved them (configuration, not a session marker)
    "CODEX_HOME",
    "CLAUDE_CONFIG_DIR",
];

/// `name` is kept by [`ENV_KEEP`] (and the `LC_*` locale variables).
pub(crate) fn keep_var(name: &str) -> bool {
    ENV_KEEP.contains(&name) || name.starts_with("LC_")
}

/// The kept part of `env`.
pub(crate) fn kept_env(
    env: impl Iterator<Item = (OsString, OsString)>,
) -> Vec<(OsString, OsString)> {
    env.filter(|(k, _)| k.to_str().is_some_and(keep_var))
        .collect()
}

/// The tmux session name of an agent: tmux turns `.` and `:` into `_`, so the name is mapped the same way here and
/// the agent's own record says which agent a session belongs to.
pub(crate) fn session_name(agent: &str) -> String {
    format!("antenna-{}", agent.replace(['.', ':'], "_"))
}

/// Antenna's tmux server.
#[derive(Debug, Clone)]
pub(crate) struct Tmux {
    /// The `tmux` program.
    pub bin: PathBuf,
    /// The private socket.
    pub socket: PathBuf,
    /// Antenna's configuration file.
    pub conf: PathBuf,
}

/// The cursor and mode of a pane, from `display-message`.
const PANE_FORMAT: &str =
    "#{cursor_x} #{cursor_y} #{cursor_flag} #{pane_in_mode} #{session_activity}";

impl Tmux {
    /// `tmux -S <socket> -f <conf>` with a clean environment (only [`ENV_KEEP`]).
    fn std_cmd(&self) -> std::process::Command {
        let mut c = std::process::Command::new(&self.bin);
        c.env_clear()
            .envs(kept_env(std::env::vars_os()))
            .arg("-S")
            .arg(&self.socket)
            .arg("-f")
            .arg(&self.conf)
            .stdin(Stdio::null());
        c
    }

    fn async_cmd(&self) -> tokio::process::Command {
        let mut c = tokio::process::Command::new(&self.bin);
        c.env_clear()
            .envs(kept_env(std::env::vars_os()))
            .arg("-S")
            .arg(&self.socket)
            .arg("-f")
            .arg(&self.conf)
            .stdin(Stdio::null())
            .kill_on_drop(true);
        c
    }

    /// Start a detached session `name` in `dir` running `argv` directly (no shell), with `env` added to the session's
    /// environment. Returns the pane's ID (`%N`), or tmux's own error text.
    pub fn new_session(
        &self,
        name: &str,
        dir: &Path,
        argv: &[OsString],
        env: &[(String, String)],
    ) -> Result<String, String> {
        let mut c = self.std_cmd();
        c.args([
            "new-session",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-x",
            "200",
            "-y",
            "50",
            "-s",
            name,
            "-c",
        ])
        .arg(dir);
        for (k, v) in env {
            c.arg("-e").arg(format!("{k}={v}"));
        }
        c.arg("--").args(argv);
        let out = c
            .output()
            .map_err(|e| format!("cannot run {}: {e}", self.bin.display()))?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    /// A session with exactly this name runs.
    pub fn has_session(&self, name: &str) -> bool {
        self.std_cmd()
            .args(["has-session", "-t", &format!("={name}")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    /// End the session (tmux closes its terminal: its processes get SIGHUP).
    pub fn kill_session(&self, name: &str) -> bool {
        self.std_cmd()
            .args(["kill-session", "-t", &format!("={name}")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    /// Replace this process with a tmux client attached to the session (the owner's terminal). Returns only on
    /// failure.
    pub fn attach(&self, name: &str) -> std::io::Error {
        use std::os::unix::process::CommandExt;
        let mut c = self.std_cmd();
        // The person's terminal type, so the client draws correctly; never TMUX (tmux refuses to nest).
        if let Some(t) = std::env::var_os("TERM") {
            c.env("TERM", t);
        }
        if let Some(t) = std::env::var_os("COLORTERM") {
            c.env("COLORTERM", t);
        }
        c.stdin(Stdio::inherit())
            .args(["attach-session", "-t", &format!("={name}")])
            .exec()
    }

    /// What `pane` shows now, and the last time a person's key reached the session (Unix seconds); `None` when tmux
    /// does not answer (the pane is gone).
    pub async fn screen(&self, pane: &str) -> Option<(Screen, u64)> {
        let cap = self
            .async_cmd()
            .args(["capture-pane", "-p", "-e", "-N", "-t", pane])
            .stderr(Stdio::null())
            .output()
            .await
            .ok()?;
        let fmt = self
            .async_cmd()
            .args(["display-message", "-p", "-t", pane, PANE_FORMAT])
            .stderr(Stdio::null())
            .output()
            .await
            .ok()?;
        if !cap.status.success() || !fmt.status.success() {
            return None;
        }
        let f = String::from_utf8_lossy(&fmt.stdout);
        let v: Vec<u64> = f
            .split_whitespace()
            .map(|x| x.parse().unwrap_or(0))
            .collect();
        if v.len() < 5 {
            return None;
        }
        let screen = Screen::from_tmux(
            &String::from_utf8_lossy(&cap.stdout),
            v[0] as usize,
            v[1] as usize,
            v[2] == 1,
            v[3] != 0,
        );
        Some((screen, v[4]))
    }

    /// Type `text` into `pane` as keys (literally: no key names), without Enter.
    pub async fn send_text(&self, pane: &str, text: &str) -> bool {
        self.async_cmd()
            .args(["send-keys", "-t", pane, "-l", "--", text])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success())
    }

    /// Press one of the keys [`super::keys::Key`] allows in `pane` (by its tmux name, never literal text).
    pub async fn send_key(&self, pane: &str, key: super::keys::Key) -> bool {
        self.async_cmd()
            .args(["send-keys", "-t", pane, key.tmux_name()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success())
    }

    /// Press Enter in `pane`.
    pub async fn send_enter(&self, pane: &str) -> bool {
        self.async_cmd()
            .args(["send-keys", "-t", pane, "Enter"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success())
    }
}

/// The `tmux` program: `--tmux`, else the first `tmux` in PATH, else the usual places (Homebrew on macOS).
pub(crate) fn find_tmux(explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = explicit {
        return p.is_file().then(|| p.to_path_buf());
    }
    find_program(
        "tmux",
        &["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"],
    )
}

/// `name` in PATH, then in `extra` folders.
pub(crate) fn find_program(name: &str, extra: &[&str]) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain(extra.iter().map(PathBuf::from))
        .map(|d| d.join(name))
        .find(|p| {
            p.is_absolute()
                && std::fs::metadata(p)
                    .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_the_environment() {
        assert_eq!(session_name("claude"), "antenna-claude");
        assert_eq!(session_name("build.bot"), "antenna-build_bot");
        for k in [
            "ANTENNA_AGENT_TOKEN",
            "ANTENNA_AGENT_TOKEN_FILE",
            "ANTENNA_SOCKET",
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CODEX_HOME_X",
            "TMUX",
        ] {
            assert!(!keep_var(k), "{k}");
        }
        for k in [
            "HOME",
            "PATH",
            "LC_ALL",
            "SSH_AUTH_SOCK",
            "ANTHROPIC_API_KEY",
        ] {
            assert!(keep_var(k), "{k}");
        }
    }
}
