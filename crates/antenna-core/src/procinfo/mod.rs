// SPDX-License-Identifier: AGPL-3.0-only
//! Process information for binding agent tokens (SPEC §9, §13: "the daemon checks the token against the process
//! credentials"; D-28).
//!
//! Read-only, no ptrace: parent, session, terminal, name and "start time", which protects against PID reuse.
//! - **Linux**: `/proc/<pid>/stat` (no `unsafe` here); the start time is field 22 (ticks since boot).
//! - **macOS**: `proc_pidinfo` through the `antenna-sys` crate (PORTABILITY M-3…M-5, M-9, M-10; D-P-2): flavors the
//!   kernel returns for a process of any uid (the chain goes through the root processes `login` and `launchd`); instead
//!   of a start time, `p_uniqueid` (a 64-bit process number that does not repeat until reboot); the link to the parent
//!   is checked with `p_puniqueid`, the socket client process with the audit token (`pidversion`).
//!
//! On other OSes the functions return `None` ([`SUPPORTED`] = `false`): process binding does not apply, and only the
//! uid check (`getpeereid`) remains. Windows (D-135) reads a process by PID alone, its creation time as the start
//! (`windows.rs`); the control pipe's chain is the client alone, which restricts a connection and never gives a role.
//!
//! The reads of each OS live in their own file (`linux.rs`, `darwin.rs`, `windows.rs`); this one holds the types and
//! what is the same everywhere.

#[cfg(target_os = "macos")]
pub mod darwin;
#[cfg(not(any(target_os = "macos", windows)))]
mod linux;
#[cfg(windows)]
mod windows;

#[cfg(not(any(target_os = "macos", windows)))]
use self::linux as os;
#[cfg(windows)]
use self::windows as os;

/// Whether the process chain can be read on this OS (Linux, macOS). Otherwise there is no process binding, only the
/// uid.
pub const SUPPORTED: bool = cfg!(any(target_os = "linux", target_os = "macos"));

/// The process a token is bound to: PID + start time, a unique pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Anchor {
    /// PID.
    pub pid: i32,
    /// Linux: field 22 of `/proc/<pid>/stat` (starttime); macOS: `p_uniqueid`; Windows: the creation time.
    pub start: u64,
}

/// A parsed `/proc/<pid>/stat` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcStat {
    /// PID.
    pub pid: i32,
    /// Executable name (`comm`, up to 15 characters).
    pub comm: String,
    /// Parent PID.
    pub ppid: i32,
    /// Session ID (`setsid`).
    pub sid: i32,
    /// Controlling terminal (Linux: `tty_nr`, field 7; macOS: `e_tdev`, only for processes of the same uid; 0 means no
    /// terminal or unknown).
    pub tty: i32,
    /// Start time (Linux: ticks since boot; macOS: `p_uniqueid`; Windows: the creation time, 100 ns units since 1601).
    pub start: u64,
}

/// Parses the contents of `/proc/<pid>/stat`. `comm` may contain spaces and parentheses, so split at the last `)`.
pub fn parse_stat(s: &str) -> Option<ProcStat> {
    let open = s.find('(')?;
    let close = s.rfind(')')?;
    let pid: i32 = s[..open].trim().parse().ok()?;
    let comm = s.get(open + 1..close)?.to_string();
    let rest: Vec<&str> = s.get(close + 1..)?.split_whitespace().collect();
    // rest[0] = state (field 3), rest[1] = ppid (4), rest[3] = session (6), rest[4] = tty_nr (7), …,
    // rest[19] = starttime (22)
    let ppid: i32 = rest.get(1)?.parse().ok()?;
    let sid: i32 = rest.get(3)?.parse().ok()?;
    let tty: i32 = rest.get(4)?.parse().ok()?;
    let start: u64 = rest.get(19)?.parse().ok()?;
    Some(ProcStat {
        pid,
        comm,
        ppid,
        sid,
        tty,
        start,
    })
}

/// Process information (Linux: `/proc/<pid>/stat`).
#[cfg(not(target_os = "macos"))]
pub fn stat(pid: i32) -> Option<ProcStat> {
    os::stat(pid)
}

/// Process information (macOS: `proc_pidinfo`, see `darwin::stat`).
#[cfg(target_os = "macos")]
pub fn stat(pid: i32) -> Option<ProcStat> {
    darwin::stat(pid).map(|d| d.stat)
}

/// Anchor of process `pid` (if it is alive).
pub fn anchor_of(pid: i32) -> Option<(Anchor, String)> {
    let s = stat(pid)?;
    Some((
        Anchor {
            pid: s.pid,
            start: s.start,
        },
        s.comm,
    ))
}

/// Whether this exact process is alive (not another one with the same PID).
pub fn is_alive(a: &Anchor) -> bool {
    stat(a.pid).is_some_and(|s| s.start == a.start)
}

/// The chain of a process and all its ancestors up to and including PID 1. `None` if the chain could not be read in
/// full (the process or an ancestor exited, no `/proc`, depth > 4096): the caller must treat this as "unknown" and fail
/// closed, not as "not an agent".
pub fn ancestry(pid: i32) -> Option<Vec<ProcStat>> {
    #[cfg(target_os = "macos")]
    return darwin::ancestry(pid);
    #[cfg(not(target_os = "macos"))]
    os::ancestry(pid)
}

/// The process chain of a unix socket client (the client itself and its ancestors), read right at connect time.
/// - Linux: the PID from `SO_PEERCRED` (`cred_pid`, tokio `peer_cred`), the process at the time of `connect`.
/// - macOS: the PID and PID version from the socket's audit token (`LOCAL_PEERTOKEN`); the version is checked against
///   the process read, so PID reuse between connecting and reading gives `None`, not someone else's chain (M-10).
///
/// Windows reads the pipe client's PID in `control` instead (D-135): the chain there is the client alone.
#[cfg(unix)]
pub fn peer_ancestry(
    sock: std::os::fd::BorrowedFd<'_>,
    cred_pid: Option<i32>,
) -> Option<Vec<ProcStat>> {
    #[cfg(target_os = "macos")]
    {
        let _ = cred_pid;
        darwin::peer_ancestry(sock)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = sock;
        cred_pid.and_then(ancestry)
    }
}

/// Whether the anchor is in the chain (the process itself or an ancestor).
pub fn in_chain(chain: &[ProcStat], a: &Anchor) -> bool {
    chain_position(chain, a).is_some()
}

/// Position of the anchor in the chain: 0 is the client itself, 1 its parent, …; `None` if the anchor is not in the
/// chain. With nested anchors (Claude Code in the built-in terminal of a GUI app that is bound itself) a process
/// belongs to the anchor **nearest** to it (D-P-10).
pub fn chain_position(chain: &[ProcStat], a: &Anchor) -> Option<usize> {
    chain
        .iter()
        .position(|s| s.pid == a.pid && s.start == a.start)
}

/// Current OS boot ID (D-P-9): a process binding is valid only in the boot it was made in; after a reboot PIDs and
/// start times (`p_uniqueid` on macOS) start over and may match another process. Linux:
/// `/proc/sys/kernel/random/boot_id`, macOS: `kern.bootsessionuuid`. `None` if it could not be read (the binding is
/// then stored without it, as before).
pub fn boot_id() -> Option<&'static str> {
    static B: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    B.get_or_init(|| {
        #[cfg(target_os = "macos")]
        let id = antenna_sys::darwin::boot_session_uuid().ok();
        #[cfg(not(target_os = "macos"))]
        let id = os::boot_id();
        id.filter(|s| !s.is_empty())
    })
    .as_deref()
}

/// Every live process of this user (the stop switch, PG-58): Linux `/proc` (zombies, state `Z`, left out: they have
/// exited already), macOS `proc_listallpids` (only processes of the daemon's uid). A process that exits while it is
/// read is skipped.
pub fn all_mine() -> Vec<ProcStat> {
    #[cfg(target_os = "macos")]
    return darwin::all_mine();
    #[cfg(not(target_os = "macos"))]
    os::all_mine()
}

/// Whether `pid` is the anchor itself or its descendant.
pub fn is_descendant_or_self(pid: i32, a: &Anchor) -> bool {
    ancestry(pid).is_some_and(|c| in_chain(&c, a))
}

/// Ancestors of the daemon itself (tokens are never bound to them: otherwise the daemon itself and the owner's terminal
/// it was started from would fall into the "agent tree").
pub fn daemon_ancestors() -> &'static [Anchor] {
    static A: std::sync::OnceLock<Vec<Anchor>> = std::sync::OnceLock::new();
    A.get_or_init(|| {
        ancestry(std::process::id() as i32)
            .unwrap_or_default()
            .iter()
            .map(|s| Anchor {
                pid: s.pid,
                start: s.start,
            })
            .collect()
    })
}

/// Whether a process can be an agent anchor: not PID 1, not systemd (the session subreaper), not a session leader
/// (terminal, tmux), not an ancestor of the daemon (otherwise the owner's processes would become "the agent").
///
/// macOS (D-P-3): the session must be known (`sid > 0`), not `launchd`; a session leader qualifies only as a GUI host:
/// the main process of an `.app` started by launchd, with no controlling terminal (`darwin::gui_host`).
pub fn valid_anchor(s: &ProcStat) -> bool {
    #[cfg(target_os = "macos")]
    let session_ok = s.sid > 0 && s.comm != "launchd" && (s.sid != s.pid || darwin::gui_host(s));
    #[cfg(not(target_os = "macos"))]
    let session_ok = s.sid != s.pid;
    s.pid > 1
        && s.comm != "systemd"
        && session_ok
        && !daemon_ancestors()
            .iter()
            .any(|a| a.pid == s.pid && a.start == s.start)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_comm_with_spaces_and_parens() {
        let s = "4242 (my (weird) proc) S 17 4242 4240 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 10";
        let p = parse_stat(s).unwrap();
        assert_eq!(p.pid, 4242);
        assert_eq!(p.comm, "my (weird) proc");
        assert_eq!(p.ppid, 17);
        assert_eq!(p.sid, 4240);
        assert_eq!(p.tty, 0);
        assert_eq!(p.start, 987654);
        assert_eq!(parse_stat("garbage"), None);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn own_process_is_alive_and_descends_from_parent() {
        let me = std::process::id() as i32;
        let (a, _) = anchor_of(me).unwrap();
        assert!(is_alive(&a));
        assert!(is_descendant_or_self(me, &a));
        let chain = ancestry(me).unwrap();
        assert_eq!(chain.last().unwrap().pid, 1, "the chain ends at PID 1");
        let parent = chain[1].pid;
        let (pa, _) = anchor_of(parent).unwrap();
        assert!(is_descendant_or_self(me, &pa));
        assert!(
            !is_descendant_or_self(parent, &a),
            "parent is not our descendant"
        );
        let fake = Anchor {
            pid: me,
            start: a.start + 1,
        };
        assert!(
            !is_alive(&fake),
            "same pid, other start time = other process"
        );
    }

    /// The socket client's chain: on Linux by the PID from `SO_PEERCRED`, on macOS by the audit token (the PID argument
    /// is not used).
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn peer_chain_of_socketpair_is_self() {
        use std::os::fd::AsFd;
        let me = std::process::id() as i32;
        let (a, _b) = std::os::unix::net::UnixStream::pair().unwrap();
        let chain = peer_ancestry(a.as_fd(), Some(me)).unwrap();
        assert_eq!(chain[0].pid, me);
        assert_eq!(chain.last().unwrap().pid, 1);
    }

    #[cfg(target_os = "macos")]
    mod macos {
        use std::process::{Command, Stdio};

        use super::super::*;

        fn python() -> Option<&'static str> {
            [
                "/usr/bin/python3",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
            ]
            .into_iter()
            .find(|p| std::path::Path::new(p).exists())
        }

        /// M-3: the root process `launchd` can be read as a regular user; it never becomes an anchor.
        #[test]
        fn launchd_is_readable_and_never_an_anchor() {
            let s = stat(1).unwrap();
            assert_eq!((s.pid, s.ppid, s.comm.as_str()), (1, 0, "launchd"));
            assert!(!valid_anchor(&s));
            let me = stat(std::process::id() as i32).unwrap();
            assert!(me.sid > 0, "getsid of own process: {me:?}");
            eprintln!("FACT own process {me:?}; launchd {s:?}");
        }

        /// A regular child (not a session leader) qualifies as an anchor, a session leader without `.app` does not
        /// (M-5, D-P-3).
        #[test]
        fn child_is_an_anchor_session_leader_is_not() {
            let mut c = Command::new("/bin/sleep").arg("30").spawn().unwrap();
            let s = stat(c.id() as i32).unwrap();
            let ok = valid_anchor(&s);
            c.kill().unwrap();
            c.wait().unwrap();
            assert!(ok, "{s:?}");
            let Some(py) = python() else {
                eprintln!("SKIP: no python3");
                return;
            };
            let mut c = Command::new(py)
                .args(["-c", "import os,time; os.setsid(); time.sleep(30)"])
                .stdin(Stdio::null())
                .spawn()
                .unwrap();
            let pid = c.id() as i32;
            let t = std::time::Instant::now();
            let s = loop {
                let s = stat(pid).unwrap();
                if s.sid == pid || t.elapsed().as_secs() > 10 {
                    break s;
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            };
            let (leader, gui) = (valid_anchor(&s), darwin::gui_host(&s));
            c.kill().unwrap();
            c.wait().unwrap();
            assert_eq!(s.sid, pid, "setsid");
            assert!(
                !leader && !gui,
                "a session leader that is not an app is not an anchor: {s:?}"
            );
        }

        #[test]
        fn app_main_executable_paths() {
            use std::path::Path;
            let yes = [
                "/Applications/Claude.app/Contents/MacOS/Claude",
                "/Users/me/Applications/Cursor.app/Contents/MacOS/Cursor",
            ];
            let no = [
                "/bin/zsh",
                "/usr/bin/login",
                "/opt/homebrew/bin/tmux",
                "/Applications/Antenna.app/Contents/Helpers/antennad",
                "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS",
                "Claude.app/Contents/MacOS/Claude",
                "/.app/Contents/MacOS/x",
            ];
            for p in yes {
                assert!(darwin::is_app_main_executable(Path::new(p)), "{p}");
            }
            for p in no {
                assert!(!darwin::is_app_main_executable(Path::new(p)), "{p}");
            }
        }

        /// D-P-3 on a real app: start Calculator through launchd (`open`); it is a session leader without a terminal,
        /// parent 1. Needs a graphical session, hence `#[ignore]` (CI runs it separately).
        #[test]
        #[ignore = "needs a GUI login session: cargo test -p antenna-core gui_host -- --ignored"]
        fn gui_host_accepts_a_launched_app() {
            let st = Command::new("/usr/bin/open")
                .args(["-g", "-j", "-a", "Calculator"])
                .status()
                .unwrap();
            assert!(st.success());
            let t = std::time::Instant::now();
            let pid = loop {
                let out = Command::new("/usr/bin/pgrep")
                    .args(["-x", "Calculator"])
                    .output()
                    .unwrap();
                if let Some(p) = String::from_utf8_lossy(&out.stdout).lines().next() {
                    break p.trim().parse::<i32>().unwrap();
                }
                assert!(t.elapsed().as_secs() < 20, "Calculator did not start");
                std::thread::sleep(std::time::Duration::from_millis(100));
            };
            let s = stat(pid).unwrap();
            let (gui, anchor) = (darwin::gui_host(&s), valid_anchor(&s));
            let _ = Command::new("/bin/kill").arg(pid.to_string()).status();
            eprintln!("FACT Calculator {s:?}: gui_host {gui}, valid_anchor {anchor}");
            assert_eq!(s.ppid, 1);
            assert!(gui && anchor);
        }
    }
}
