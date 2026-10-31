// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna agent-run` (Windows; D-134, Code mode on Windows): the terminal host of one Code mode run.
//! The window starts it with its stdin and stdout as pipes and speaks frames to it. The host makes a job and a
//! pseudoconsole (`antenna_sys::windows`), starts `antenna agent-run --inner` in both, and carries the console's keys,
//! screen and size. The inner starts the agent CLI in the run's folder with the run's environment and exits with its
//! exit code. Everything the agent starts is in the job, so Stop, the end of the window (the lifeline: stdin ends) and
//! the end of the host itself (killed included) end all of it.
//!
//! Frames, both ways, with the window bridge's header (`docs/CONTROL.md` §34): a `u32` LE id, always 0; a `u8` type;
//! a `u32` LE length; then that many bytes.
//! - Window → host: [`SPEC`] first and once (JSON: `program` and `folder` as full paths, `args`, `env`, `cols`,
//!   `rows`), then [`DATA`] (keys), [`RESIZE`] (`u16` LE rows, then `u16` LE cols) and [`STOP`] (nothing).
//! - Host → window: [`DATA`] (the console's output), then [`EXIT`] (`u32` LE, the agent's exit code; [`STOPPED`] after
//!   a stop or the window's end) as the last frame; or [`ERROR`] (a short UTF-8 reason) when the run cannot start.
//!
//! Anything outside the format ends the host at once with a non-zero exit, and the job with it. Frames are never
//! logged: the spec carries the agent's token, and keys may be passwords.
//!
//! The token's way: the window's pipe, the spec in the host's memory (wiped once the run has started), the inner's
//! environment block, the agent's environment. It is never on a command line, as on Linux and macOS, where it is in
//! the agent's environment only.

use std::{
    collections::BTreeMap,
    ffi::{OsStr, OsString},
    fs::File,
    io::{self, Read, Write},
    path::PathBuf,
    process::ExitCode,
    sync::{Arc, Mutex, MutexGuard, PoisonError},
};

use antenna_sys::windows::{conpty::PseudoConsole, job::Job, spawn};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::{client::EXIT_FAIL, window_bridge};

/// The subcommand's name. It is hidden from the help: the window starts it, a person has no use for it.
pub const COMMAND: &str = "agent-run";
/// The inner side's flag: `antenna agent-run --inner`, started by the host inside the console and the job.
pub const INNER: &str = "--inner";

/// Window → host, first and once: the run as JSON.
pub const SPEC: u8 = 1;
/// Both ways: keys to the console, or its output.
pub const DATA: u8 = 2;
/// Window → host: end the run and everything it started. Carries nothing.
pub const STOP: u8 = 3;
/// Host → window: why the run could not start, as short UTF-8 text; the last frame.
pub const ERROR: u8 = 4;
/// Window → host: the console's new size, `u16` LE rows and then `u16` LE cols.
pub const RESIZE: u8 = 5;
/// Host → window: the agent's exit code, `u32` LE; the last frame.
pub const EXIT: u8 = 6;

/// The exit code of a run that was stopped, or whose window went away.
pub const STOPPED: u32 = 1;
/// The longest frame: a spec with the agent's environment fits, and so does a large paste.
pub const MAX_FRAME: usize = 1 << 20;

/// Id, type and length.
const HEADER: usize = 9;
/// The most bytes of the console's output in one frame.
const READ_CHUNK: usize = 64 * 1024;
/// The longest reason an error frame carries, in bytes.
const MAX_REASON: usize = 512;
/// The variable that carries the run's program, arguments and folder to the inner; the agent never sees it.
const RUN_VAR: &str = "ANTENNA_AGENT_RUN";

/// The run, as the window sends it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Spec {
    /// The agent CLI, a full path (the window found it; an npm package runs as `node.exe` with its script).
    program: PathBuf,
    #[serde(default)]
    args: Vec<String>,
    /// The folder the agent works in, a full path.
    folder: PathBuf,
    /// The agent's whole environment, the token included.
    env: BTreeMap<String, String>,
    cols: u16,
    rows: u16,
}

impl Drop for Spec {
    fn drop(&mut self) {
        for v in self.env.values_mut() {
            v.zeroize();
        }
    }
}

/// What the inner needs: the program, its arguments and its folder.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Run {
    program: PathBuf,
    args: Vec<String>,
    folder: PathBuf,
}

/// A frame that ends the host. None holds a frame's content.
#[derive(Debug, PartialEq, Eq)]
pub enum Violation {
    /// An id other than 0.
    BadId(u32),
    /// Not one of the window's types.
    UnknownType(u8),
    /// A length the type does not allow.
    BadLength {
        /// The type.
        kind: u8,
        /// The length.
        len: u32,
    },
    /// Longer than [`MAX_FRAME`].
    TooLong(u32),
    /// The first frame is not the spec.
    SpecFirst(u8),
    /// A second spec.
    SpecTwice,
    /// Stdin ended inside a frame.
    Short,
    /// Stdin could not be read.
    Input(io::ErrorKind),
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadId(id) => write!(f, "a frame with id {id}; the only id is 0"),
            Self::UnknownType(kind) => write!(f, "a frame of unknown type {kind}"),
            Self::BadLength { kind, len } => write!(
                f,
                "a frame of type {kind} with a length of {len} bytes, which its type does not allow"
            ),
            Self::TooLong(len) => {
                write!(f, "a frame of {len} bytes, over the limit of {MAX_FRAME}")
            }
            Self::SpecFirst(kind) => {
                write!(f, "a first frame of type {kind}; the first is the spec")
            }
            Self::SpecTwice => write!(f, "a second spec"),
            Self::Short => write!(f, "stdin ended inside a frame"),
            Self::Input(k) => write!(f, "stdin: {k}"),
        }
    }
}

type Out = Arc<Mutex<io::Stdout>>;

/// `antenna agent-run [--inner]`.
pub fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(2);
    match (args.next(), args.next()) {
        (None, _) => host(),
        (Some(a), None) if a == INNER => inner(),
        _ => {
            eprintln!("antenna {COMMAND}: the window starts this; it takes no arguments");
            ExitCode::from(2)
        }
    }
}

/// The host: the spec, the start, then keys, sizes and stops until the run ends.
fn host() -> ExitCode {
    let out: Out = Arc::new(Mutex::new(io::stdout()));
    let mut input = io::stdin().lock();
    let spec = match read_frame(&mut input) {
        // The window went away before the run started.
        Ok(None) => return ExitCode::SUCCESS,
        Ok(Some((SPEC, payload))) => match serde_json::from_slice::<Spec>(&payload) {
            Ok(s) => s,
            // The position and the kind of the error only: serde's own message can quote a value, the token included.
            Err(e) => {
                return refuse(
                    &out,
                    &format!(
                        "the spec is not valid ({:?} at line {}, column {})",
                        e.classify(),
                        e.line(),
                        e.column()
                    ),
                );
            }
        },
        Ok(Some((kind, _))) => return end(&Violation::SpecFirst(kind), None),
        Err(v) => return end(&v, None),
    };
    let started = start(&spec);
    drop(spec);
    let (job, console, mut keys, screen, child) = match started {
        Ok(s) => s,
        Err(reason) => return refuse(&out, &reason),
    };
    let job = Arc::new(job);
    let console = Arc::new(Mutex::new(Some(console)));
    let screen = std::thread::spawn({
        let (out, job) = (out.clone(), job.clone());
        move || pump_screen(screen, &out, &job)
    });
    // The run's end: the console closes, its output is read to its end, and EXIT is the last frame.
    std::thread::spawn({
        let (out, job, console) = (out.clone(), job.clone(), console.clone());
        move || {
            let code = child.wait();
            drop(lock(&console).take());
            let _ = screen.join();
            match code {
                Ok(code) => {
                    let _ = send(&out, EXIT, &code.to_le_bytes());
                    std::process::exit(0);
                }
                Err(e) => {
                    let _ = job.terminate(STOPPED);
                    let _ = send(
                        &out,
                        ERROR,
                        reason(&format!("cannot wait for the run: {e}")),
                    );
                    std::process::exit(i32::from(EXIT_FAIL));
                }
            }
        }
    });
    loop {
        match read_frame(&mut input) {
            Ok(Some((DATA, keys_in))) => {
                // The agent may have ended already: its console takes no more keys, and its end is on its way.
                let _ = keys.write_all(&keys_in);
            }
            Ok(Some((RESIZE, size))) => {
                let rows = u16::from_le_bytes([size[0], size[1]]);
                let cols = u16::from_le_bytes([size[2], size[3]]);
                if let Some(c) = lock(&console).as_ref()
                    && let Err(e) = c.resize(cols, rows)
                {
                    eprintln!("antenna {COMMAND}: resize to {cols} x {rows}: {e}");
                }
            }
            Ok(Some((STOP, _))) => stop(&job),
            Ok(Some((SPEC, _))) => return end(&Violation::SpecTwice, Some(&job)),
            Ok(Some((kind, _))) => return end(&Violation::UnknownType(kind), Some(&job)),
            // The lifeline: the window is gone, so the run ends; the run's end exits the process.
            Ok(None) => {
                stop(&job);
                loop {
                    std::thread::park();
                }
            }
            Err(v) => return end(&v, Some(&job)),
        }
    }
}

/// Starts the run: the job, the console, and the inner in both, with the agent's environment and the run for the
/// inner. Returns the console's key and screen pipes and the inner; or why it cannot start.
fn start(spec: &Spec) -> Result<(Job, PseudoConsole, File, File, spawn::Child), String> {
    if !spec.program.is_absolute() || !spec.folder.is_absolute() {
        return Err("the program and the folder must be full paths".into());
    }
    if spec.env.keys().any(|k| k.eq_ignore_ascii_case(RUN_VAR)) {
        return Err(format!("{RUN_VAR} is the host's own variable"));
    }
    let run = Zeroizing::new(
        serde_json::to_string(&Run {
            program: spec.program.clone(),
            args: spec.args.clone(),
            folder: spec.folder.clone(),
        })
        .map_err(|e| format!("the run: {e}"))?,
    );
    let exe = std::env::current_exe().map_err(|e| format!("this program's path: {e}"))?;
    let line = spawn::command_line(&exe, &[OsStr::new(COMMAND), OsStr::new(INNER)])
        .map_err(|e| format!("the command line: {e}"))?;
    let mut env: Vec<(OsString, OsString)> =
        spec.env.iter().map(|(k, v)| (k.into(), v.into())).collect();
    env.push((RUN_VAR.into(), run.as_str().into()));
    let job = Job::kill_on_close().map_err(|e| format!("the job: {e}"))?;
    let (console, keys, screen) =
        PseudoConsole::new(spec.cols, spec.rows).map_err(|e| format!("the console: {e}"))?;
    let child = spawn::spawn(&line, Some(&env), None, Some(&console), &job)
        .map_err(|e| format!("cannot start the run: {e}"))?;
    Ok((job, console, keys, screen, child))
}

/// Carries the console's output to the window. When the window can no longer be written to, the run ends, and the
/// output is still read to its end, so the console can close.
fn pump_screen(mut screen: File, out: &Out, job: &Job) {
    let mut buf = Zeroizing::new(vec![0u8; READ_CHUNK]);
    let mut window = true;
    loop {
        match screen.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => {
                if window && send(out, DATA, &buf[..n]).is_err() {
                    window = false;
                    stop(job);
                }
            }
        }
    }
}

/// Ends everything in the job; each process exits with [`STOPPED`].
fn stop(job: &Job) {
    if let Err(e) = job.terminate(STOPPED) {
        eprintln!("antenna {COMMAND}: cannot end the run: {e}");
    }
}

/// A violation: said on stderr (never a frame's content), then a non-zero exit. Once the run has started the process
/// exits at once: the job's handle closes with it, which ends everything in the job, and no EXIT frame can follow.
fn end(v: &Violation, job: Option<&Job>) -> ExitCode {
    eprintln!("antenna {COMMAND}: {v}");
    if job.is_some() {
        std::process::exit(i32::from(EXIT_FAIL));
    }
    ExitCode::from(EXIT_FAIL)
}

/// The run cannot start: an error frame, then a non-zero exit.
fn refuse(out: &Out, why: &str) -> ExitCode {
    eprintln!("antenna {COMMAND}: {why}");
    let _ = send(out, ERROR, reason(why));
    ExitCode::from(EXIT_FAIL)
}

/// A reason cut at a character boundary to at most [`MAX_REASON`] bytes.
fn reason(why: &str) -> &[u8] {
    let mut end = why.len().min(MAX_REASON);
    while !why.is_char_boundary(end) {
        end -= 1;
    }
    &why.as_bytes()[..end]
}

fn send(out: &Out, kind: u8, payload: &[u8]) -> io::Result<()> {
    let frame = window_bridge::encode(0, kind, payload);
    let mut o = out.lock().unwrap_or_else(PoisonError::into_inner);
    o.write_all(&frame)?;
    o.flush()
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A frame's type and content.
type Frame = (u8, Zeroizing<Vec<u8>>);

/// One frame from the window; `None` when stdin ends between two frames.
pub fn read_frame(r: &mut impl Read) -> Result<Option<Frame>, Violation> {
    let mut head = [0u8; HEADER];
    let mut got = 0;
    while got < HEADER {
        match r.read(&mut head[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(Violation::Short),
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(Violation::Input(e.kind())),
        }
    }
    let id = u32::from_le_bytes([head[0], head[1], head[2], head[3]]);
    let kind = head[4];
    let len = u32::from_le_bytes([head[5], head[6], head[7], head[8]]);
    if id != 0 {
        return Err(Violation::BadId(id));
    }
    let allowed = match kind {
        SPEC | DATA => len > 0,
        RESIZE => len == 4,
        STOP => len == 0,
        _ => return Err(Violation::UnknownType(kind)),
    };
    if len as usize > MAX_FRAME {
        return Err(Violation::TooLong(len));
    }
    if !allowed {
        return Err(Violation::BadLength { kind, len });
    }
    let mut payload = Zeroizing::new(vec![0u8; len as usize]);
    r.read_exact(&mut payload).map_err(|e| match e.kind() {
        io::ErrorKind::UnexpectedEof => Violation::Short,
        k => Violation::Input(k),
    })?;
    Ok(Some((kind, payload)))
}

/// The inner: inside the console and the job, it starts the agent CLI in the run's folder and exits with its exit
/// code. It lives through Ctrl+C, which the console gives every process in it, so it can report the agent's end.
fn inner() -> ExitCode {
    if let Err(e) = antenna_sys::windows::console::survive_ctrl_c() {
        eprintln!("antenna: Ctrl+C would end this run's host: {e}");
    }
    let run = std::env::var_os(RUN_VAR)
        .and_then(|raw| raw.into_string().ok())
        .map(Zeroizing::new)
        .and_then(|raw| serde_json::from_str::<Run>(&raw).ok());
    let Some(run) = run else {
        eprintln!(
            "antenna {COMMAND} {INNER}: started without its run; `antenna {COMMAND}` starts it"
        );
        return ExitCode::from(2);
    };
    if !run.folder.is_dir() {
        eprintln!("antenna: cannot open the folder {}", run.folder.display());
        return ExitCode::from(126);
    }
    let started = std::process::Command::new(&run.program)
        .args(&run.args)
        .current_dir(&run.folder)
        .env_remove(RUN_VAR)
        .spawn();
    let mut agent = match started {
        Ok(a) => a,
        Err(e) => {
            eprintln!("antenna: cannot start {}: {e}", run.program.display());
            return ExitCode::from(127);
        }
    };
    match agent.wait() {
        // Windows exit codes are 32 bits; `exit` passes them on whole.
        Ok(status) => std::process::exit(status.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("antenna: cannot wait for {}: {e}", run.program.display());
            ExitCode::from(EXIT_FAIL)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(id: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
        window_bridge::encode(id, kind, payload).to_vec()
    }

    /// The format's rules, each with the frame that breaks it; the controls are the well-formed frames.
    #[test]
    fn frames_outside_the_format_are_refused() {
        let read = |bytes: Vec<u8>| read_frame(&mut bytes.as_slice());
        assert_eq!(read(vec![]), Ok(None));
        assert_eq!(read(frame(0, SPEC, b"{}")).unwrap().unwrap().0, SPEC);
        assert_eq!(read(frame(0, DATA, b"x")).unwrap().unwrap().0, DATA);
        assert_eq!(
            read(frame(0, RESIZE, &[1, 0, 2, 0])).unwrap().unwrap().0,
            RESIZE
        );
        assert_eq!(read(frame(0, STOP, b"")).unwrap().unwrap().0, STOP);
        assert_eq!(read(frame(1, DATA, b"x")), Err(Violation::BadId(1)));
        assert_eq!(read(frame(0, 9, b"x")), Err(Violation::UnknownType(9)));
        assert_eq!(
            read(frame(0, EXIT, &[0; 4])),
            Err(Violation::UnknownType(EXIT))
        );
        assert_eq!(
            read(frame(0, ERROR, b"x")),
            Err(Violation::UnknownType(ERROR))
        );
        assert_eq!(
            read(frame(0, DATA, b"")),
            Err(Violation::BadLength { kind: DATA, len: 0 })
        );
        assert_eq!(
            read(frame(0, SPEC, b"")),
            Err(Violation::BadLength { kind: SPEC, len: 0 })
        );
        assert_eq!(
            read(frame(0, RESIZE, &[1, 0, 2])),
            Err(Violation::BadLength {
                kind: RESIZE,
                len: 3
            })
        );
        assert_eq!(
            read(frame(0, STOP, b"x")),
            Err(Violation::BadLength { kind: STOP, len: 1 })
        );
        // The length is refused before any of the content is read.
        let mut huge = frame(0, DATA, b"");
        huge[5..9].copy_from_slice(&(MAX_FRAME as u32 + 1).to_le_bytes());
        assert_eq!(read(huge), Err(Violation::TooLong(MAX_FRAME as u32 + 1)));
        let mut cut = frame(0, DATA, b"abc");
        cut.pop();
        assert_eq!(read(cut), Err(Violation::Short));
        assert_eq!(
            read(frame(0, DATA, b"x")[..4].to_vec()),
            Err(Violation::Short)
        );
    }

    /// A reason is cut at a character boundary, never in the middle of one.
    #[test]
    fn reasons_are_cut_at_a_character() {
        let long = "\u{416}".repeat(MAX_REASON);
        let r = reason(&long);
        assert!(r.len() <= MAX_REASON && std::str::from_utf8(r).is_ok());
        assert_eq!(reason("short"), b"short");
    }
}
