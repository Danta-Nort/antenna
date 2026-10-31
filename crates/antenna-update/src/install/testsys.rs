// SPDX-License-Identifier: AGPL-3.0-only
//! A fake OS for the installer's unit tests: simulates `hdiutil`, `ditto`, `codesign`, `plutil`, `launchctl`,
//! `systemctl`, `ps` and `open`, keeps fake processes (the window, the daemon), and runs everything else for real
//! (`tar`, the `--version` of the test binaries, which are shell scripts).

use std::{
    cell::RefCell,
    collections::BTreeMap,
    ffi::{OsStr, OsString},
    fs, io,
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::Duration,
};

use super::{Out, Probe, Sig, Sys};

/// What the fake world looks like.
#[derive(Debug, Default)]
pub struct World {
    /// Every call, as `prog arg arg…`.
    pub calls: Vec<String>,
    /// Fake processes: pid → executable path.
    pub procs: BTreeMap<u32, PathBuf>,
    /// `codesign --verify` fails.
    pub codesign_fails: bool,
    /// The daemon does not come up after a start.
    pub start_fails: bool,
    /// Version line of the running daemon.
    pub daemon: Option<String>,
    /// PID of the running daemon.
    pub daemon_pid: Option<u32>,
    /// systemd unit state.
    pub systemd_active: bool,
    /// The systemd unit file (`systemctl start` starts its `ExecStart`).
    pub unit: Option<PathBuf>,
    /// State the running daemon reports (`locked` after a start, as a real one).
    pub daemon_state: String,
    /// The new binary exits right after the handover's `exec` (D-103).
    pub exec_fails: bool,
    /// The LaunchAgent plist last bootstrapped (`launchctl kickstart` starts its program again).
    pub plist: Option<PathBuf>,
    /// The installer's parent process (the daemon that started an automatic install).
    pub parent: Option<u32>,
    next_pid: u32,
}

/// The fake OS (cheap to clone: the world is shared).
#[derive(Debug, Clone, Default)]
pub struct FakeSys(pub Rc<RefCell<World>>);

fn ok(stdout: impl Into<String>) -> io::Result<Out> {
    Ok(Out {
        ok: true,
        stdout: stdout.into(),
        stderr: String::new(),
    })
}

fn fail(stderr: impl Into<String>) -> io::Result<Out> {
    Ok(Out {
        ok: false,
        stdout: String::new(),
        stderr: stderr.into(),
    })
}

/// Recursive copy keeping modes (the fake `ditto`).
pub fn copy_dir(src: &Path, dst: &Path) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for e in fs::read_dir(src)? {
        let e = e?;
        let to = dst.join(e.file_name());
        if e.file_type()?.is_dir() {
            copy_dir(&e.path(), &to)?;
        } else {
            fs::copy(e.path(), &to)?;
        }
    }
    Ok(())
}

fn json_get(file: &Path, key: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(&fs::read(file).ok()?).ok()?;
    let mut cur = &v;
    for k in key.split('.') {
        cur = match k.parse::<usize>() {
            Ok(i) => cur.get(i)?,
            Err(_) => cur.get(k)?,
        };
    }
    cur.as_str().map(str::to_string)
}

/// Runs a command, retrying while the kernel says "text file busy": the test binaries are shell scripts written by the
/// tests, and a parallel test's `fork` can briefly hold a just-written script open for writing (ETXTBSY on `exec`).
pub fn output(cmd: &mut Command) -> io::Result<std::process::Output> {
    let mut tries = 0;
    loop {
        match cmd.output() {
            Err(e) if e.kind() == io::ErrorKind::ExecutableFileBusy && tries < 100 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(10));
            }
            r => return r,
        }
    }
}

fn version_of(bin: &Path) -> Option<String> {
    let o = output(Command::new(bin).arg("--version")).ok()?;
    o.status
        .success()
        .then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

impl FakeSys {
    /// Starts a fake process.
    pub fn spawn(&self, exe: &Path) -> u32 {
        let mut w = self.0.borrow_mut();
        w.next_pid += 1;
        let pid = 50_000 + w.next_pid;
        w.procs.insert(pid, exe.to_path_buf());
        pid
    }

    /// Starts the fake daemon from a binary (it answers with what that binary prints for `--version`).
    pub fn start_daemon(&self, bin: &Path) {
        let fails = self.0.borrow().start_fails;
        let pid = self.spawn(bin);
        let mut w = self.0.borrow_mut();
        w.daemon = if fails { None } else { version_of(bin) };
        w.daemon_pid = Some(pid);
        w.daemon_state = "locked".into();
    }

    fn stop_daemon(&self) {
        let mut w = self.0.borrow_mut();
        if let Some(p) = w.daemon_pid.take() {
            w.procs.remove(&p);
        }
        w.daemon = None;
    }

    /// Calls whose program is `prog`.
    pub fn calls_of(&self, prog: &str) -> Vec<String> {
        self.0
            .borrow()
            .calls
            .iter()
            .filter(|c| c.split(' ').next() == Some(prog))
            .cloned()
            .collect()
    }
}

impl Sys for FakeSys {
    fn run(&self, prog: &OsStr, args: &[OsString]) -> io::Result<Out> {
        let a: Vec<String> = args
            .iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect();
        let p = prog.to_string_lossy().into_owned();
        self.0
            .borrow_mut()
            .calls
            .push(format!("{p} {}", a.join(" ")));
        let arg = |i: usize| a.get(i).map(String::as_str).unwrap_or("");
        match p.as_str() {
            "hdiutil" if arg(0) == "attach" => {
                // The fake disk image holds the path of the app folder it "contains".
                let mnt = Path::new(arg(5));
                let src = fs::read_to_string(arg(6))?;
                let src = src.trim().strip_prefix("FAKE-DMG:").unwrap_or("");
                copy_dir(Path::new(src), &mnt.join("Antenna.app"))?;
                ok("")
            }
            "hdiutil" => {
                let mnt = Path::new(a.last().map(String::as_str).unwrap_or(""));
                let _ = fs::remove_dir_all(mnt.join("Antenna.app"));
                ok("")
            }
            "ditto" => {
                copy_dir(Path::new(arg(1)), Path::new(arg(2)))?;
                ok("")
            }
            "codesign" => {
                if self.0.borrow().codesign_fails {
                    fail("a sealed resource is missing or invalid")
                } else {
                    ok("")
                }
            }
            "plutil" => match json_get(Path::new(arg(5)), arg(1)) {
                Some(v) => ok(format!("{v}\n")),
                None => fail("No value at that key path"),
            },
            "launchctl" => match arg(0) {
                "bootout" => {
                    self.stop_daemon();
                    ok("")
                }
                "bootstrap" => {
                    let bin = json_get(Path::new(arg(2)), "ProgramArguments.0").unwrap_or_default();
                    self.0.borrow_mut().plist = Some(PathBuf::from(arg(2)));
                    self.start_daemon(Path::new(&bin));
                    ok("")
                }
                // `kickstart -k`: kill the running instance and start the job's program again.
                "kickstart" => {
                    let plist = self.0.borrow().plist.clone().unwrap_or_default();
                    let bin = json_get(&plist, "ProgramArguments.0").unwrap_or_default();
                    self.stop_daemon();
                    self.start_daemon(Path::new(&bin));
                    ok("")
                }
                _ => ok(""),
            },
            "systemctl" => match arg(1) {
                "is-active" => ok(if self.0.borrow().systemd_active {
                    "active\n"
                } else {
                    "inactive\n"
                }),
                "stop" => {
                    self.stop_daemon();
                    self.0.borrow_mut().systemd_active = false;
                    ok("")
                }
                "start" | "restart" => {
                    if arg(1) == "restart" {
                        self.stop_daemon();
                    }
                    let unit = self.0.borrow().unit.clone().unwrap_or_default();
                    let text = fs::read_to_string(unit).unwrap_or_default();
                    let bin = text
                        .lines()
                        .find_map(|l| l.strip_prefix("ExecStart="))
                        .and_then(|l| l.split_whitespace().next())
                        .unwrap_or("")
                        .to_string();
                    self.start_daemon(Path::new(&bin));
                    self.0.borrow_mut().systemd_active = true;
                    ok("")
                }
                _ => ok(""),
            },
            "ps" => {
                let w = self.0.borrow();
                ok(w.procs
                    .iter()
                    .map(|(p, e)| format!("{p:>6} {}\n", e.display()))
                    .collect::<String>())
            }
            "open" => {
                self.spawn(&Path::new(arg(0)).join("Contents/MacOS/Antenna"));
                ok("")
            }
            _ => {
                let o = output(Command::new(prog).args(args))?;
                Ok(Out {
                    ok: o.status.success(),
                    stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
                })
            }
        }
    }

    fn kill(&self, pid: u32, sig: Sig) -> io::Result<()> {
        self.0
            .borrow_mut()
            .calls
            .push(format!("kill {sig:?} {pid}"));
        let mut w = self.0.borrow_mut();
        w.procs.remove(&pid);
        if w.daemon_pid == Some(pid) {
            w.daemon_pid = None;
            w.daemon = None;
        }
        Ok(())
    }

    fn alive(&self, pid: u32) -> bool {
        self.0.borrow().procs.contains_key(&pid)
    }

    fn sleep(&self, _d: Duration) {}

    fn spawn_detached(
        &self,
        prog: &OsStr,
        args: &[OsString],
        _cwd: Option<&Path>,
    ) -> io::Result<u32> {
        let a: Vec<String> = args
            .iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect();
        self.0
            .borrow_mut()
            .calls
            .push(format!("spawn {} {}", prog.to_string_lossy(), a.join(" ")));
        self.start_daemon(Path::new(prog));
        Ok(self.0.borrow().daemon_pid.unwrap_or(0))
    }

    fn exe_of(&self, pid: u32) -> Option<PathBuf> {
        self.0.borrow().procs.get(&pid).cloned()
    }

    fn is_parent(&self, pid: u32) -> bool {
        self.0.borrow().parent == Some(pid)
    }
}

impl Probe for FakeSys {
    fn daemon_version(&self) -> Option<String> {
        self.0.borrow().daemon.clone()
    }

    fn daemon_state(&self) -> Option<(String, String)> {
        let w = self.0.borrow();
        Some((w.daemon.clone()?, w.daemon_state.clone()))
    }
}

impl FakeSys {
    /// The daemon replaces itself with the binary now at `path` (D-103): the same PID answers with that binary's
    /// version, unlocked when the key came across. A binary that does not run leaves no daemon (the process exited).
    pub fn exec_daemon(&self, path: &Path, unlocked: bool) {
        let v = version_of(path);
        let mut w = self.0.borrow_mut();
        let Some(pid) = w.daemon_pid else { return };
        w.calls.push(format!("exec {}", path.display()));
        match v.filter(|_| !w.exec_fails) {
            Some(v) => {
                w.daemon = Some(v);
                w.daemon_state = if unlocked { "unlocked" } else { "locked" }.into();
                w.procs.insert(pid, path.to_path_buf());
            }
            None => {
                w.daemon = None;
                w.daemon_pid = None;
                w.procs.remove(&pid);
            }
        }
    }
}
