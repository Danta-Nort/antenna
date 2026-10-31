// SPDX-License-Identifier: AGPL-3.0-only
//! Starting a process into a job, and into a pseudoconsole when one is given (the W2 design, Code mode's terminal
//! host):
//! - the job is set when the process is created (`PROC_THREAD_ATTRIBUTE_JOB_LIST`), so the process is in it before
//!   its first instruction and nothing it starts is ever outside it;
//! - nothing is inherited (`bInheritHandles` false, WP-12): no handle of ours reaches the program;
//! - with a pseudoconsole, the program's standard handles are the console's (`STARTF_USESTDHANDLES` with none given),
//!   never ours, which may be the pipes to the window; without one, a console program gets a console of its own with
//!   no window (`CREATE_NO_WINDOW`);
//! - the environment is exactly the one given, in UTF-16, sorted by name as Windows keeps it.
//!
//! [`command_line`] quotes arguments as the Microsoft C runtime and Rust's standard library read them back.

use std::{
    ffi::{OsStr, OsString, c_void},
    io,
    marker::PhantomData,
    os::windows::{
        ffi::{OsStrExt, OsStringExt},
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::Path,
};

use windows_sys::Win32::{
    Foundation::{HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT},
    System::{
        Console::HPCON,
        Threading::{
            CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
            DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
            INFINITE, InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
            PROC_THREAD_ATTRIBUTE_JOB_LIST, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOEXW, UpdateProcThreadAttribute,
            WaitForSingleObject,
        },
    },
};

use super::{conpty::PseudoConsole, job::Job};

#[cfg(target_pointer_width = "64")]
const _: () = assert!(std::mem::size_of::<STARTUPINFOEXW>() == 112);
#[cfg(target_pointer_width = "64")]
const _: () = assert!(std::mem::size_of::<PROCESS_INFORMATION>() == 24);

/// A process started by [`spawn`], held open: its PID is not reused while this lives.
#[derive(Debug)]
pub struct Child {
    process: OwnedHandle,
    pid: u32,
}

impl Child {
    /// Its PID.
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// Waits until it exits; its exit code.
    pub fn wait(&self) -> io::Result<u32> {
        self.wait_ms(INFINITE)?
            .ok_or_else(|| io::Error::other("the wait ended before the process"))
    }

    /// Waits up to `ms` milliseconds: its exit code, or `None` while it still runs.
    pub fn wait_timeout(&self, ms: u32) -> io::Result<Option<u32>> {
        self.wait_ms(ms.min(INFINITE - 1))
    }

    #[allow(unsafe_code, reason = "FFI: WaitForSingleObject, GetExitCodeProcess")]
    fn wait_ms(&self, ms: u32) -> io::Result<Option<u32>> {
        let h: HANDLE = self.process.as_raw_handle().cast();
        // SAFETY: `h` is our open process handle, which has SYNCHRONIZE.
        match unsafe { WaitForSingleObject(h, ms) } {
            WAIT_OBJECT_0 => {}
            WAIT_TIMEOUT => return Ok(None),
            _ => return Err(io::Error::last_os_error()),
        }
        let mut code = 0u32;
        // SAFETY: the process has exited; `code` is writable.
        if unsafe { GetExitCodeProcess(h, &mut code) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Some(code))
    }
}

/// Starts `command_line` (its program first, as a full path: see [`command_line`]) in `job`, attached to `console`
/// when one is given. `env`: exactly these variables (`None`: ours); `cwd`: its folder (`None`: ours).
#[allow(unsafe_code, reason = "FFI: CreateProcessW with an attribute list")]
pub fn spawn(
    command_line: &OsStr,
    env: Option<&[(OsString, OsString)]>,
    cwd: Option<&Path>,
    console: Option<&PseudoConsole>,
    job: &Job,
) -> io::Result<Child> {
    let mut cmd = wide(command_line)?;
    let env = env.map(env_block).transpose()?;
    let cwd = cwd.map(|p| wide(p.as_os_str())).transpose()?;
    let jobs = [job.raw()];
    let mut attrs = AttributeList::new(if console.is_some() { 2 } else { 1 })?;
    attrs.set(PROC_THREAD_ATTRIBUTE_JOB_LIST, &jobs)?;
    let mut flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
    let mut si = STARTUPINFOEXW::default();
    si.StartupInfo.cb =
        u32::try_from(std::mem::size_of::<STARTUPINFOEXW>()).map_err(io::Error::other)?;
    match console {
        Some(c) => {
            attrs.set_pseudoconsole(c)?;
            si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        }
        None => flags |= CREATE_NO_WINDOW,
    }
    si.lpAttributeList = attrs.ptr();
    let mut pi = PROCESS_INFORMATION::default();
    // SAFETY: `cmd` is a writable NUL-terminated UTF-16 string; the environment block (double-NUL-terminated UTF-16,
    // as CREATE_UNICODE_ENVIRONMENT says) and the folder (NUL-terminated) are null or live until the call returns, as
    // do the attribute list and the values it points to (`jobs`, the console); `si` and `pi` are valid for the call.
    let ok = unsafe {
        CreateProcessW(
            std::ptr::null(),
            cmd.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            flags,
            env.as_ref().map_or(std::ptr::null(), |e| e.as_ptr().cast()),
            cwd.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
            &si.StartupInfo,
            &mut pi,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both handles were just created for us and nothing else owns them.
    let (process, thread) = unsafe {
        (
            OwnedHandle::from_raw_handle(pi.hProcess.cast()),
            OwnedHandle::from_raw_handle(pi.hThread.cast()),
        )
    };
    drop(thread);
    Ok(Child {
        process,
        pid: pi.dwProcessId,
    })
}

/// A command line: `program` (a full path, in quotes) and then each argument, quoted where needed so that the
/// Microsoft C runtime's rules (which Rust's standard library and most programs use) give each one back unchanged.
pub fn command_line(program: &Path, args: &[&OsStr]) -> io::Result<OsString> {
    let p = program.as_os_str();
    if p.encode_wide().any(|c| c == u16::from(b'"') || c == 0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a program path with a quote or a NUL",
        ));
    }
    let mut cmd: Vec<u16> = Vec::new();
    cmd.push(u16::from(b'"'));
    cmd.extend(p.encode_wide());
    cmd.push(u16::from(b'"'));
    for a in args {
        cmd.push(u16::from(b' '));
        append_arg(&mut cmd, a)?;
    }
    Ok(OsString::from_wide(&cmd))
}

/// One argument: in quotes when it is empty or holds a space or a tab; a quote gets a backslash, and the backslashes
/// just before a quote (or before the closing quote) are doubled.
fn append_arg(cmd: &mut Vec<u16>, arg: &OsStr) -> io::Result<()> {
    let (quote, bs, tab, space) = (
        u16::from(b'"'),
        u16::from(b'\\'),
        u16::from(b'\t'),
        u16::from(b' '),
    );
    let w: Vec<u16> = arg.encode_wide().collect();
    if w.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "an argument with a NUL",
        ));
    }
    let quoted = w.is_empty() || w.iter().any(|&c| c == space || c == tab);
    if quoted {
        cmd.push(quote);
    }
    let mut backslashes = 0usize;
    for &c in &w {
        if c == bs {
            backslashes += 1;
        } else {
            if c == quote {
                cmd.extend(std::iter::repeat_n(bs, backslashes + 1));
            }
            backslashes = 0;
        }
        cmd.push(c);
    }
    if quoted {
        cmd.extend(std::iter::repeat_n(bs, backslashes));
        cmd.push(quote);
    }
    Ok(())
}

/// The variables as an environment block: `name=value` each NUL-terminated, sorted by name without case, and a final
/// NUL. A name is not empty, holds no `=` after its first character, and appears once whatever its case; nothing holds
/// a NUL.
fn env_block(vars: &[(OsString, OsString)]) -> io::Result<Vec<u16>> {
    let bad = |what: &str| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("an environment variable {what}"),
        )
    };
    let mut sorted: Vec<(Vec<u16>, &OsString, &OsString)> = Vec::with_capacity(vars.len());
    for (k, v) in vars {
        let name: Vec<u16> = k.encode_wide().collect();
        if name.is_empty() || name[1..].contains(&u16::from(b'=')) {
            return Err(bad("name that is empty or holds `=`"));
        }
        if name.contains(&0) || v.encode_wide().any(|c| c == 0) {
            return Err(bad("with a NUL"));
        }
        sorted.push((upper(&name), k, v));
    }
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    if sorted.windows(2).any(|p| p[0].0 == p[1].0) {
        return Err(bad("given twice"));
    }
    let mut block = Vec::new();
    for (_, k, v) in sorted {
        block.extend(k.encode_wide());
        block.push(u16::from(b'='));
        block.extend(v.encode_wide());
        block.push(0);
    }
    if block.is_empty() {
        block.push(0);
    }
    block.push(0);
    Ok(block)
}

/// A name in upper case for sorting and comparing, as Windows compares variable names (ASCII letters; other
/// characters as they are).
fn upper(name: &[u16]) -> Vec<u16> {
    name.iter()
        .map(|&c| {
            if (u16::from(b'a')..=u16::from(b'z')).contains(&c) {
                c - 32
            } else {
                c
            }
        })
        .collect()
}

/// `s` as a NUL-terminated UTF-16 string; a NUL inside is refused.
fn wide(s: &OsStr) -> io::Result<Vec<u16>> {
    let mut w: Vec<u16> = s.encode_wide().collect();
    if w.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a string with a NUL",
        ));
    }
    w.push(0);
    Ok(w)
}

/// A process-thread attribute list. It keeps pointers to the values set in it, so it borrows them (`'a`) and is
/// deleted when dropped.
struct AttributeList<'a> {
    buf: Vec<usize>,
    _values: PhantomData<&'a ()>,
}

impl<'a> AttributeList<'a> {
    #[allow(unsafe_code, reason = "FFI: InitializeProcThreadAttributeList")]
    fn new(count: u32) -> io::Result<AttributeList<'a>> {
        let mut size = 0usize;
        // SAFETY: a null list only asks for the size one needs (the call then fails, as documented).
        unsafe { InitializeProcThreadAttributeList(std::ptr::null_mut(), count, 0, &mut size) };
        if size == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut buf = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
        // SAFETY: `buf` is writable for at least `size` bytes and aligned for the pointers the list holds.
        if unsafe {
            InitializeProcThreadAttributeList(buf.as_mut_ptr().cast(), count, 0, &mut size)
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(AttributeList {
            buf,
            _values: PhantomData,
        })
    }

    fn ptr(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.buf.as_mut_ptr().cast()
    }

    /// An attribute whose value is `value` itself: the list keeps its address, and `value` outlives the list (`'a`).
    fn set<T>(&mut self, attribute: u32, value: &'a T) -> io::Result<()> {
        let p: *const c_void = std::ptr::from_ref(value).cast();
        self.update(attribute, p, std::mem::size_of::<T>())
    }

    /// The pseudoconsole attribute, whose "value" is the console's handle itself, as its documentation says. The
    /// handle stays open while `console` is borrowed (`'a`).
    fn set_pseudoconsole(&mut self, console: &'a PseudoConsole) -> io::Result<()> {
        let hpc: HPCON = console.raw();
        let p = std::ptr::without_provenance::<c_void>(hpc as usize);
        self.update(
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            p,
            std::mem::size_of::<HPCON>(),
        )
    }

    #[allow(unsafe_code, reason = "FFI: UpdateProcThreadAttribute")]
    fn update(&mut self, attribute: u32, value: *const c_void, size: usize) -> io::Result<()> {
        let list = self.ptr();
        // SAFETY: `list` was initialized; `value` and `size` are what the attribute takes, and stay valid for `'a`.
        let ok = unsafe {
            UpdateProcThreadAttribute(
                list,
                0,
                attribute as usize,
                value,
                size,
                std::ptr::null_mut(),
                std::ptr::null(),
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for AttributeList<'_> {
    #[allow(unsafe_code, reason = "FFI: DeleteProcThreadAttributeList")]
    fn drop(&mut self) {
        let list = self.ptr();
        // SAFETY: the list was initialized in `new` and is deleted once, here.
        unsafe { DeleteProcThreadAttributeList(list) };
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::Read as _,
        sync::mpsc,
        time::{Duration, Instant},
    };

    use windows_sys::Win32::{
        Foundation::{CloseHandle, ERROR_ACCESS_DENIED},
        Security::SECURITY_ATTRIBUTES,
        System::{
            Pipes::CreatePipe,
            Threading::{
                CREATE_BREAKAWAY_FROM_JOB, OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
                TerminateProcess,
            },
        },
    };

    use super::*;

    const MODE: &str = "ANTENNA_SYS_TEST_CHILD";
    const OUT: &str = "ANTENNA_SYS_TEST_OUT";
    const PIPE: &str = "ANTENNA_SYS_TEST_PIPE";

    /// This test binary again, running only [`child`] (an ignored test) with `extra` after its own arguments.
    fn child_line(extra: &[&OsStr]) -> OsString {
        let exe = std::env::current_exe().unwrap();
        let mut args: Vec<&OsStr> = [
            "windows::spawn::tests::child",
            "--exact",
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ]
        .iter()
        .map(OsStr::new)
        .collect();
        args.extend_from_slice(extra);
        command_line(&exe, &args).unwrap()
    }

    /// Our environment, with the child's mode and the given variables.
    fn env_with(mode: &str, more: &[(&str, &OsStr)]) -> Vec<(OsString, OsString)> {
        let ours = [MODE, OUT, PIPE];
        let mut v: Vec<(OsString, OsString)> = std::env::vars_os()
            .filter(|(k, _)| !ours.iter().any(|o| k.eq_ignore_ascii_case(o)))
            .collect();
        v.push((MODE.into(), mode.into()));
        v.extend(
            more.iter()
                .map(|(k, val)| (OsString::from(*k), (*val).to_owned())),
        );
        v
    }

    /// A file for a child's answer, named after this process and `tag` (and not after `antenna-`).
    fn out_file(tag: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("asys-test-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_file(&p);
        p
    }

    fn wait_for<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
        let end = Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(t) = f() {
                return t;
            }
            assert!(Instant::now() < end, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[allow(unsafe_code, reason = "test: OpenProcess, WaitForSingleObject")]
    fn alive(pid: u32) -> bool {
        // SAFETY: no pointers; a null handle means the process is gone (or was never there).
        let h = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
        if h.is_null() {
            return false;
        }
        // SAFETY: `h` was just opened with SYNCHRONIZE and is closed right after.
        let running = unsafe { WaitForSingleObject(h, 0) } == WAIT_TIMEOUT;
        // SAFETY: as above.
        unsafe { CloseHandle(h) };
        running
    }

    #[allow(unsafe_code, reason = "test: OpenProcess, TerminateProcess")]
    fn kill_pid(pid: u32) {
        // SAFETY: no pointers; a null handle means there is nothing to end.
        let h = unsafe { OpenProcess(PROCESS_TERMINATE, 0, pid) };
        if !h.is_null() {
            // SAFETY: `h` was just opened with PROCESS_TERMINATE and is closed right after.
            unsafe {
                TerminateProcess(h, 1);
                CloseHandle(h);
            }
        }
    }

    /// Starts the "sleep" child in `job` and waits for the PID of the grandchild it starts.
    fn sleeper(job: &Job, tag: &str) -> (Child, u32) {
        let out = out_file(tag);
        let child = spawn(
            &child_line(&[]),
            Some(&env_with("sleep", &[(OUT, out.as_os_str())])),
            None,
            None,
            job,
        )
        .unwrap();
        let grandchild = wait_for("the grandchild's PID", || {
            std::fs::read_to_string(&out)
                .ok()?
                .trim()
                .parse::<u32>()
                .ok()
        });
        let _ = std::fs::remove_file(&out);
        assert!(alive(grandchild));
        (child, grandchild)
    }

    /// The other tests' child: what it does is in its environment.
    #[test]
    #[ignore = "a child of the other tests, which run it"]
    #[allow(
        unsafe_code,
        reason = "test child: CreateProcessW with CREATE_BREAKAWAY_FROM_JOB, a handle by its value"
    )]
    fn child() {
        let Ok(mode) = std::env::var(MODE) else {
            return;
        };
        let out = std::env::var_os(OUT);
        match mode.as_str() {
            // A grandchild of the test (a long ping), its PID written down; then it waits for the grandchild.
            "sleep" => {
                let mut g = std::process::Command::new(system32("PING.EXE"))
                    .args(["-n", "120", "127.0.0.1"])
                    .stdout(std::process::Stdio::null())
                    .spawn()
                    .unwrap();
                std::fs::write(out.unwrap(), g.id().to_string()).unwrap();
                let _ = g.wait();
            }
            // A process started with CREATE_BREAKAWAY_FROM_JOB: "allowed", or "refused <error>".
            "breakaway" => {
                let mut cmd = wide(
                    &command_line(
                        &system32("cmd.exe"),
                        &[OsStr::new("/c"), OsStr::new("exit")],
                    )
                    .unwrap(),
                )
                .unwrap();
                let si = windows_sys::Win32::System::Threading::STARTUPINFOW {
                    cb: u32::try_from(std::mem::size_of::<
                        windows_sys::Win32::System::Threading::STARTUPINFOW,
                    >())
                    .unwrap(),
                    ..Default::default()
                };
                let mut pi = PROCESS_INFORMATION::default();
                // SAFETY: `cmd` is writable and NUL-terminated; `si` and `pi` are valid for the call.
                let ok = unsafe {
                    CreateProcessW(
                        std::ptr::null(),
                        cmd.as_mut_ptr(),
                        std::ptr::null(),
                        std::ptr::null(),
                        0,
                        CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW,
                        std::ptr::null(),
                        std::ptr::null(),
                        &si,
                        &mut pi,
                    )
                };
                let answer = if ok == 0 {
                    format!(
                        "refused {}",
                        io::Error::last_os_error().raw_os_error().unwrap_or(0)
                    )
                } else {
                    // SAFETY: both handles were just created for us.
                    unsafe {
                        CloseHandle(pi.hThread);
                        CloseHandle(pi.hProcess);
                    }
                    "allowed".to_owned()
                };
                std::fs::write(out.unwrap(), answer).unwrap();
            }
            // Writes "x" to the handle value it was given; whether that handle reached it is the test.
            "write-pipe" => {
                use std::io::Write as _;
                let h: usize = std::env::var(PIPE).unwrap().parse().unwrap();
                // SAFETY: a handle value that may or may not be open here: a failed write is the expected answer, and
                // the handle is never closed (ManuallyDrop), as this file does not own it.
                let f = std::mem::ManuallyDrop::new(unsafe {
                    std::fs::File::from_raw_handle(std::ptr::without_provenance_mut(h))
                });
                let _ = (&*f).write(b"x");
            }
            // Its own arguments after the fixed ones, each as UTF-16 code units in hex, one per line.
            "args" => {
                let args: Vec<OsString> = std::env::args_os().skip(6).collect();
                let lines: Vec<String> = args
                    .iter()
                    .map(|a| {
                        a.encode_wide()
                            .map(|c| format!("{c:04x}"))
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .collect();
                std::fs::write(out.unwrap(), lines.join("\n")).unwrap();
            }
            m => panic!("unknown child mode {m}"),
        }
    }

    fn system32(exe: &str) -> std::path::PathBuf {
        let root = std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\Windows".into());
        std::path::Path::new(&root).join("System32").join(exe)
    }

    /// The job's guarantee: terminating it ends the child and the grandchild it started. The control: ending only the
    /// child (what killing a PID does, as dart:io's `killPid` on Windows) leaves the grandchild running.
    #[test]
    fn terminating_the_job_ends_every_process_in_it() {
        let job = Job::kill_on_close().unwrap();
        let (child, grandchild) = sleeper(&job, "t1");
        let pids = job.pids().unwrap();
        assert!(
            pids.contains(&child.pid()) && pids.contains(&grandchild),
            "{pids:?}"
        );
        job.terminate(7).unwrap();
        assert_eq!(child.wait_timeout(10_000).unwrap(), Some(7));
        wait_for("the grandchild to end", || {
            (!alive(grandchild)).then_some(())
        });
        assert!(job.pids().unwrap().is_empty());

        // Control.
        let plain = Job::plain().unwrap();
        let (child, grandchild) = sleeper(&plain, "t1c");
        kill_pid(child.pid());
        assert!(child.wait_timeout(10_000).unwrap().is_some());
        std::thread::sleep(Duration::from_millis(500));
        let survived = alive(grandchild);
        plain.terminate(1).unwrap();
        assert!(
            survived,
            "the control: the grandchild outlives its parent without the job"
        );
    }

    /// The host is gone: when the job's last handle closes, every process in it ends (KILL_ON_JOB_CLOSE). The control:
    /// a job without that limit leaves them running.
    #[test]
    fn closing_the_last_handle_ends_every_process_in_it() {
        let job = Job::kill_on_close().unwrap();
        let (child, grandchild) = sleeper(&job, "t2");
        drop(job);
        assert!(child.wait_timeout(10_000).unwrap().is_some());
        wait_for("the grandchild to end", || {
            (!alive(grandchild)).then_some(())
        });

        // Control.
        let plain = Job::plain().unwrap();
        let (child, grandchild) = sleeper(&plain, "t2c");
        drop(plain);
        std::thread::sleep(Duration::from_millis(500));
        let survived = (alive(child.pid()), alive(grandchild));
        kill_pid(child.pid());
        kill_pid(grandchild);
        assert_eq!(
            survived,
            (true, true),
            "the control: without KILL_ON_JOB_CLOSE they outlive the job's handle"
        );
    }

    /// No process in the job can start one outside it. The control: the same job with BREAKAWAY_OK lets it.
    #[test]
    fn nothing_breaks_away_from_the_job() {
        let ask = |job: &Job, tag: &str| {
            let out = out_file(tag);
            let child = spawn(
                &child_line(&[]),
                Some(&env_with("breakaway", &[(OUT, out.as_os_str())])),
                None,
                None,
                job,
            )
            .unwrap();
            assert_eq!(
                child.wait_timeout(30_000).unwrap(),
                Some(0),
                "the child test failed"
            );
            let answer = std::fs::read_to_string(&out).unwrap();
            let _ = std::fs::remove_file(&out);
            answer
        };
        let refused = ask(&Job::kill_on_close().unwrap(), "t3");
        eprintln!("FACT breakaway from our job: {refused}");
        assert_eq!(refused, format!("refused {ERROR_ACCESS_DENIED}"));
        let control = ask(&Job::kill_on_close_breakaway_ok().unwrap(), "t3c");
        eprintln!("FACT breakaway from a job with BREAKAWAY_OK: {control}");
        assert_eq!(control, "allowed", "the control");
    }

    /// No handle of ours reaches the program, not even an inheritable one. The control: std's Command, which passes
    /// inheritable handles on, hands the same pipe to its child.
    #[test]
    #[allow(unsafe_code, reason = "test: an inheritable pipe end")]
    fn no_handle_is_inherited() {
        let try_with = |ours: bool| -> Vec<u8> {
            let sa = SECURITY_ATTRIBUTES {
                nLength: u32::try_from(std::mem::size_of::<SECURITY_ATTRIBUTES>()).unwrap(),
                lpSecurityDescriptor: std::ptr::null_mut(),
                bInheritHandle: 1,
            };
            let (mut r, mut w): (HANDLE, HANDLE) = (std::ptr::null_mut(), std::ptr::null_mut());
            // SAFETY: both outputs are writable and `sa` is valid for the call: both ends are inheritable.
            assert_ne!(unsafe { CreatePipe(&mut r, &mut w, &sa, 0) }, 0);
            // SAFETY: both handles were just created and nothing else owns them.
            let (r, w) = unsafe {
                (
                    OwnedHandle::from_raw_handle(r.cast()),
                    OwnedHandle::from_raw_handle(w.cast()),
                )
            };
            let value = OsString::from((w.as_raw_handle() as usize).to_string());
            let env = env_with("write-pipe", &[(PIPE, value.as_os_str())]);
            if ours {
                let job = Job::kill_on_close().unwrap();
                let child = spawn(&child_line(&[]), Some(&env), None, None, &job).unwrap();
                drop(w);
                assert!(child.wait_timeout(30_000).unwrap().is_some());
            } else {
                let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
                cmd.args([
                    "windows::spawn::tests::child",
                    "--exact",
                    "--ignored",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env_clear()
                .envs(env)
                .stdout(std::process::Stdio::null());
                let mut c = cmd.spawn().unwrap();
                drop(w);
                c.wait().unwrap();
            }
            let mut got = Vec::new();
            std::fs::File::from(r).read_to_end(&mut got).unwrap();
            got
        };
        assert_eq!(
            try_with(true),
            b"",
            "our child never had the pipe: the read ends at once"
        );
        assert_eq!(
            try_with(false),
            b"x",
            "the control: std's child had it and wrote"
        );
    }

    /// Each argument comes back unchanged in the program (Rust's std reads them by the C runtime's rules): spaces,
    /// quotes, backslashes before a quote and at the end, an empty one, non-ASCII. The control: joining with spaces
    /// unquoted (as flutter_pty 0.4.2 does on Windows) gives back something else.
    #[test]
    fn arguments_come_back_unchanged() {
        let args: Vec<OsString> = [
            "plain",
            "two words",
            "a\"quote",
            r"back\slash",
            r"trail\",
            r#"both \"x"#,
            "\u{416}\u{dc}\u{1f600}",
            "\ttab",
            "",
        ]
        .iter()
        .map(OsString::from)
        .collect();
        let refs: Vec<&OsStr> = args.iter().map(OsString::as_os_str).collect();
        let hex = |a: &OsStr| {
            a.encode_wide()
                .map(|c| format!("{c:04x}"))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let run = |line: OsString, tag: &str| -> Vec<String> {
            let out = out_file(tag);
            let job = Job::kill_on_close().unwrap();
            let child = spawn(
                &line,
                Some(&env_with("args", &[(OUT, out.as_os_str())])),
                None,
                None,
                &job,
            )
            .unwrap();
            assert!(child.wait_timeout(30_000).unwrap().is_some());
            let got = std::fs::read_to_string(&out).unwrap_or_default();
            let _ = std::fs::remove_file(&out);
            got.split('\n').map(str::to_owned).collect()
        };
        let want: Vec<String> = refs.iter().map(|a| hex(a)).collect();
        assert_eq!(run(child_line(&refs), "args"), want);

        // Control: the same arguments joined unquoted.
        let mut naive = child_line(&[]);
        for a in &refs {
            naive.push(" ");
            naive.push(a);
        }
        assert_ne!(run(naive, "argsc"), want, "the control");
    }

    #[test]
    fn command_lines_quote_as_the_c_runtime_reads() {
        let line = |args: &[&str]| {
            let a: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
            command_line(Path::new(r"C:\Program Files\Antenna\antenna.exe"), &a)
                .unwrap()
                .into_string()
                .unwrap()
        };
        assert_eq!(
            line(&["agent-run", "--inner"]),
            r#""C:\Program Files\Antenna\antenna.exe" agent-run --inner"#
        );
        assert_eq!(
            line(&["a b"]),
            r#""C:\Program Files\Antenna\antenna.exe" "a b""#
        );
        assert_eq!(line(&[""]), r#""C:\Program Files\Antenna\antenna.exe" """#);
        assert_eq!(
            line(&[r#"a"b"#]),
            r#""C:\Program Files\Antenna\antenna.exe" a\"b"#
        );
        assert_eq!(
            line(&[r#"a\\"b"#]),
            r#""C:\Program Files\Antenna\antenna.exe" a\\\\\"b"#
        );
        assert_eq!(
            line(&[r"a b\"]),
            r#""C:\Program Files\Antenna\antenna.exe" "a b\\""#
        );
        assert_eq!(
            line(&[r"a\b"]),
            r#""C:\Program Files\Antenna\antenna.exe" a\b"#
        );
        assert!(command_line(Path::new(r#"C:\a"b.exe"#), &[]).is_err());
        assert!(command_line(Path::new(r"C:\a.exe"), &[OsStr::new("a\0b")]).is_err());
    }

    #[test]
    fn environment_blocks_are_sorted_checked_and_terminated() {
        let block = |vars: &[(&str, &str)]| {
            let v: Vec<(OsString, OsString)> = vars
                .iter()
                .map(|(k, v)| ((*k).into(), (*v).into()))
                .collect();
            env_block(&v)
        };
        let text = |b: Vec<u16>| String::from_utf16(&b).unwrap();
        assert_eq!(
            text(block(&[("b", "2"), ("A", "1"), ("Path", r"C:\x")]).unwrap()),
            "A=1\0b=2\0Path=C:\\x\0\0"
        );
        assert_eq!(text(block(&[]).unwrap()), "\0\0");
        assert_eq!(text(block(&[("=C:", r"C:\")]).unwrap()), "=C:=C:\\\0\0");
        assert!(
            block(&[("PATH", "a"), ("Path", "b")]).is_err(),
            "one name, two cases"
        );
        assert!(block(&[("", "x")]).is_err());
        assert!(block(&[("a=b", "x")]).is_err());
        assert!(block(&[("a", "x\0y")]).is_err());
    }

    /// A program in a pseudoconsole writes to the console, and its output reaches us through the console's pipe even
    /// though our own standard handles are elsewhere; the output ends after the console is closed.
    #[test]
    fn a_program_in_a_pseudoconsole_writes_to_it() {
        let (console, input, mut output) = PseudoConsole::new(100, 30).unwrap();
        console.resize(120, 40).unwrap();
        assert!(console.resize(0, 40).is_err());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut all = Vec::new();
            let _ = output.read_to_end(&mut all);
            let _ = tx.send(all);
        });
        let job = Job::kill_on_close().unwrap();
        let line = command_line(
            &system32("cmd.exe"),
            &[
                OsStr::new("/d"),
                OsStr::new("/c"),
                OsStr::new("echo antenna-conpty-ok"),
            ],
        )
        .unwrap();
        let child = spawn(&line, None, None, Some(&console), &job).unwrap();
        assert_eq!(child.wait_timeout(30_000).unwrap(), Some(0));
        drop((console, input));
        let all = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("the output ends after the console closes");
        let text = String::from_utf8_lossy(&all);
        assert!(text.contains("antenna-conpty-ok"), "{text:?}");
    }
}
