// SPDX-License-Identifier: Apache-2.0
//! How the daemon and its clients find each other on one machine (`docs/CONTROL.md` §1): data directory, socket name
//! (on Windows the control pipe's name), environment variables. A single source for `antennad`, the `antenna` CLI and
//! third-party clients.
//!
//! Before 2026-10-02 the product was called `x` (DECISIONS, "Rename to Antenna"): the preview build used the directory
//! `~/.local/share/x`, the socket `xd.sock` and `X_*` variables. The new names are primary; the old variables are read
//! as a fallback (the caller prints a warning), and `antennad` migrates the old data directory once at startup.

use std::{ffi::OsString, path::PathBuf};

/// Name of the data directory inside `$XDG_DATA_HOME` (or `~/.local/share`).
pub const DATA_DIR_NAME: &str = "antenna";
/// Name of the data directory inside `%LOCALAPPDATA%` (Windows, WP-3).
pub const WINDOWS_DATA_DIR_NAME: &str = "Antenna";
/// Data directory of the `x` preview build.
pub const LEGACY_DATA_DIR_NAME: &str = "x";
/// Control socket in the data directory.
pub const SOCKET_NAME: &str = "antennad.sock";
/// Control socket of the `x` preview build.
pub const LEGACY_SOCKET_NAME: &str = "xd.sock";

/// Environment variable with a fallback name from the preview build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnvVar {
    /// Name (`ANTENNA_…`).
    pub name: &'static str,
    /// Name in the preview build (`X_…`): read only when the new one is not set.
    pub legacy: &'static str,
}

/// Daemon data directory.
pub const ENV_DATA_DIR: EnvVar = EnvVar {
    name: "ANTENNA_DATA_DIR",
    legacy: "X_DATA_DIR",
};
/// Control socket path (takes precedence over the data directory).
pub const ENV_SOCKET: EnvVar = EnvVar {
    name: "ANTENNA_SOCKET",
    legacy: "X_SOCKET",
};
/// Agent token for the CLI and the MCP server.
pub const ENV_AGENT_TOKEN: EnvVar = EnvVar {
    name: "ANTENNA_AGENT_TOKEN",
    legacy: "X_AGENT_TOKEN",
};
/// Link folders (`<contact>/inbox`, `<contact>/shared`).
pub const ENV_LINKS_DIR: EnvVar = EnvVar {
    name: "ANTENNA_LINKS_DIR",
    legacy: "X_LINKS_DIR",
};
/// Project folder for files from level-5 contacts.
pub const ENV_PROJECT_DIR: EnvVar = EnvVar {
    name: "ANTENNA_PROJECT_DIR",
    legacy: "X_PROJECT_DIR",
};

impl EnvVar {
    /// Value from the process environment: the new name, otherwise the old one. The second element is `true` if the
    /// old name was used (the caller warns: [`EnvVar::deprecation`]). An empty value counts as unset.
    pub fn get(&self) -> Option<(OsString, bool)> {
        self.get_in(|k| std::env::var_os(k))
    }

    /// Same, over a given environment (tests).
    pub fn get_in(&self, env: impl Fn(&str) -> Option<OsString>) -> Option<(OsString, bool)> {
        if let Some(v) = env(self.name).filter(|v| !v.is_empty()) {
            return Some((v, false));
        }
        env(self.legacy)
            .filter(|v| !v.is_empty())
            .map(|v| (v, true))
    }

    /// Only the old name, when the new one is not set: for clap fields that read the new name themselves (`env = …`).
    pub fn legacy_only(&self) -> Option<OsString> {
        match self.get() {
            Some((v, true)) => Some(v),
            _ => None,
        }
    }

    /// Warning text about the old name.
    pub fn deprecation(&self) -> String {
        format!(
            "environment variable {} is deprecated (the product is now called Antenna): use {}",
            self.legacy, self.name
        )
    }
}

/// Base data directory: `$XDG_DATA_HOME`, otherwise `$HOME/.local/share` (without `$HOME`, relative to the current
/// directory). Windows: `%LOCALAPPDATA%`, never the roaming `%APPDATA%` (keys and ratchet state must not follow the
/// profile to another PC), likewise relative without it; `XDG_DATA_HOME` is not read there (WP-3).
fn data_base_in(windows: bool, env: &impl Fn(&str) -> Option<OsString>) -> PathBuf {
    if windows {
        return env("LOCALAPPDATA")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
    }
    if let Some(x) = env("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        return PathBuf::from(x);
    }
    env("HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".local/share")
}

/// Default data directory: `$XDG_DATA_HOME/antenna` or `~/.local/share/antenna` (Linux and macOS, D-P-5),
/// `%LOCALAPPDATA%\Antenna` (Windows, WP-3).
pub fn default_data_dir() -> PathBuf {
    default_data_dir_in(|k| std::env::var_os(k))
}

/// Same, over a given environment.
pub fn default_data_dir_in(env: impl Fn(&str) -> Option<OsString>) -> PathBuf {
    data_dir_in(cfg!(windows), &env)
}

/// The default data directory of the one system or the other.
fn data_dir_in(windows: bool, env: &impl Fn(&str) -> Option<OsString>) -> PathBuf {
    let name = if windows {
        WINDOWS_DATA_DIR_NAME
    } else {
        DATA_DIR_NAME
    };
    data_base_in(windows, env).join(name)
}

/// Data directory of the `x` preview build (next to the new one): `antennad` migrates it.
pub fn legacy_data_dir_in(env: impl Fn(&str) -> Option<OsString>) -> PathBuf {
    data_base_in(cfg!(windows), &env).join(LEGACY_DATA_DIR_NAME)
}

/// The start of a local named pipe's name (Windows, D-135). `ANTENNA_SOCKET` on Windows names a pipe with this prefix;
/// a pipe on another host (`\\host\pipe\…`) is never used.
pub const LOCAL_PIPE_PREFIX: &str = r"\\.\pipe\";

/// The longest pipe name Windows accepts, in UTF-16 units, prefix included.
pub const MAX_PIPE_NAME: usize = 256;

/// The control pipe on Windows (D-135, `docs/CONTROL.md` §1): `\\.\pipe\antenna-<SID>-<h>`. Pipe names are global
/// across the machine's sessions: the user's SID keeps two users apart and shows up in errors, and `h` keeps one user's
/// data folders apart, as the socket inside the data folder does on unix.
///
/// `h` is 16 lowercase hex digits of FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the
/// UTF-16LE bytes of the data folder's canonical path in lower case (Rust's `str::to_lowercase`). The canonical path is
/// what `std::fs::canonicalize` returns on Windows (`GetFinalPathNameByHandleW`, with its `\\?\` prefix kept): the
/// caller canonicalizes, so this crate does no I/O. `h` has no security role: the pipe's DACL, its first instance and
/// the client's owner check carry that (D-135).
pub fn control_pipe_name(user_sid: &str, canonical_data_dir: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for unit in canonical_data_dir.to_lowercase().encode_utf16() {
        for b in unit.to_le_bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
    }
    format!("{LOCAL_PIPE_PREFIX}antenna-{user_sid}-{h:016x}")
}

/// Whether `name` is a local named pipe that Windows can open: [`LOCAL_PIPE_PREFIX`] (in any case), then a non-empty
/// name without a backslash or NUL, at most [`MAX_PIPE_NAME`] units in all.
pub fn is_local_pipe_name(name: &str) -> bool {
    let Some(head) = name.get(..LOCAL_PIPE_PREFIX.len()) else {
        return false;
    };
    let rest = &name[LOCAL_PIPE_PREFIX.len()..];
    head.eq_ignore_ascii_case(LOCAL_PIPE_PREFIX)
        && !rest.is_empty()
        && !rest.contains(['\\', '\0'])
        && name.encode_utf16().count() <= MAX_PIPE_NAME
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let m: HashMap<String, OsString> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), OsString::from(v)))
            .collect();
        move |k| m.get(k).cloned()
    }

    #[test]
    fn new_name_wins_old_is_fallback() {
        let both = env(&[("ANTENNA_SOCKET", "/new"), ("X_SOCKET", "/old")]);
        assert_eq!(ENV_SOCKET.get_in(&both), Some(("/new".into(), false)));
        let old = env(&[("X_SOCKET", "/old")]);
        assert_eq!(ENV_SOCKET.get_in(&old), Some(("/old".into(), true)));
        let empty_new = env(&[("ANTENNA_SOCKET", ""), ("X_SOCKET", "/old")]);
        assert_eq!(ENV_SOCKET.get_in(&empty_new), Some(("/old".into(), true)));
        assert_eq!(ENV_SOCKET.get_in(env(&[])), None);
        assert!(ENV_SOCKET.deprecation().contains("X_SOCKET"));
        assert!(ENV_SOCKET.deprecation().contains("ANTENNA_SOCKET"));
    }

    // The unix lookup: on Windows the defaults are the test below.
    #[cfg(unix)]
    #[test]
    fn data_dirs() {
        let home = env(&[("HOME", "/home/u")]);
        assert_eq!(
            default_data_dir_in(&home),
            PathBuf::from("/home/u/.local/share/antenna")
        );
        assert_eq!(
            legacy_data_dir_in(&home),
            PathBuf::from("/home/u/.local/share/x")
        );
        let xdg = env(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "/data")]);
        assert_eq!(default_data_dir_in(&xdg), PathBuf::from("/data/antenna"));
        assert_eq!(legacy_data_dir_in(&xdg), PathBuf::from("/data/x"));
    }

    /// Windows: `%LOCALAPPDATA%\Antenna`, whatever `XDG_DATA_HOME`, `HOME` and the roaming `APPDATA` say (WP-3). The
    /// lookup of either system is checked on both.
    #[test]
    fn windows_data_dir_is_local_app_data() {
        let local = r"C:\Users\u\AppData\Local";
        let all = env(&[
            ("LOCALAPPDATA", r"C:\Users\u\AppData\Local"),
            ("APPDATA", r"C:\Users\u\AppData\Roaming"),
            ("XDG_DATA_HOME", "/data"),
            ("HOME", "/home/u"),
        ]);
        assert_eq!(
            data_dir_in(true, &all),
            PathBuf::from(local).join("Antenna")
        );
        assert_eq!(
            data_dir_in(false, &all),
            PathBuf::from("/data").join("antenna")
        );
        let none = env(&[
            ("APPDATA", r"C:\Users\u\AppData\Roaming"),
            ("LOCALAPPDATA", ""),
        ]);
        assert_eq!(data_dir_in(true, &none), PathBuf::from(".").join("Antenna"));
        if cfg!(windows) {
            assert_eq!(
                default_data_dir_in(&all),
                PathBuf::from(local).join("Antenna")
            );
        }
    }

    /// Fixed vectors for other clients to check against (`docs/CONTROL.md` §1), worked out apart from this code.
    #[test]
    fn control_pipe_names_are_fixed() {
        let sid = "S-1-5-21-1004336348-1177238915-682003330-1001";
        assert_eq!(
            control_pipe_name(sid, r"\\?\C:\Users\u\AppData\Local\Antenna"),
            r"\\.\pipe\antenna-S-1-5-21-1004336348-1177238915-682003330-1001-07b5ec919f8bafd7"
        );
        assert_eq!(
            control_pipe_name(sid, "\\\\?\\D:\\\u{dc}nal\\Antenna-\u{416}"),
            r"\\.\pipe\antenna-S-1-5-21-1004336348-1177238915-682003330-1001-a229c088b3833f3f"
        );
        // FNV-1a over nothing is its offset basis.
        assert!(control_pipe_name("S-1-5-18", "").ends_with("-cbf29ce484222325"));
    }

    /// One folder spelled in another case is the same pipe (Windows paths ignore case); another folder, or another
    /// user, is another pipe.
    #[test]
    fn control_pipe_names_follow_the_folder_and_the_user() {
        let sid = "S-1-5-21-1-2-3-1001";
        let a = control_pipe_name(sid, r"\\?\C:\Users\u\AppData\Local\Antenna");
        assert_eq!(
            a,
            control_pipe_name(sid, r"\\?\c:\users\U\APPDATA\local\antenna")
        );
        assert_eq!(
            control_pipe_name(sid, "\\\\?\\D:\\\u{fc}nal\\antenna-\u{436}"),
            control_pipe_name(sid, "\\\\?\\d:\\\u{dc}NAL\\ANTENNA-\u{416}")
        );
        assert_ne!(
            a,
            control_pipe_name(sid, r"\\?\C:\Users\u\AppData\Local\Antenna-test")
        );
        assert_ne!(
            a,
            control_pipe_name(
                "S-1-5-21-1-2-3-1002",
                r"\\?\C:\Users\u\AppData\Local\Antenna"
            )
        );
        assert!(is_local_pipe_name(&a));
        assert!(a.encode_utf16().count() <= MAX_PIPE_NAME);
    }

    #[test]
    fn only_local_pipe_names_are_accepted() {
        assert!(is_local_pipe_name(r"\\.\pipe\antenna-test"));
        assert!(is_local_pipe_name(r"\\.\PIPE\antenna-test"));
        for bad in [
            r"\\host\pipe\antenna",
            r"\\?\pipe\antenna",
            r"\\.\pipe\",
            r"\\.\pipe\a\b",
            "\\\\.\\pipe\\a\0b",
            r"C:\Users\u\antennad.sock",
            r"\\.\pip",
            "",
        ] {
            assert!(!is_local_pipe_name(bad), "{bad:?}");
        }
        let long = format!("{LOCAL_PIPE_PREFIX}{}", "a".repeat(MAX_PIPE_NAME));
        assert!(!is_local_pipe_name(&long));
        let just = format!(
            "{LOCAL_PIPE_PREFIX}{}",
            "a".repeat(MAX_PIPE_NAME - LOCAL_PIPE_PREFIX.len())
        );
        assert!(is_local_pipe_name(&just));
    }
}
