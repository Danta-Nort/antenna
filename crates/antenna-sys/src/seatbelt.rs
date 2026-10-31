// SPDX-License-Identifier: AGPL-3.0-only
//! macOS Seatbelt, the XNU kernel sandbox (Sandbox.kext), for the file check worker and the agent on wake
//! (DECISIONS D-P-12, D-P-13). The profile text (SBPL) is built by the callers (`antenna_files::seatbelt`,
//! `antenna_core::sandbox`); this module holds only the FFI:
//!
//! - [`apply`] (`sandbox_init(profile, 0, &err)` with an SBPL string): the current process and all its descendants stay
//!   in the sandbox forever (it cannot be lifted; `fork` and `exec` keep it). A function of the public `<sandbox.h>`:
//!   marked deprecated since 10.8, but it still works in macOS 15, and Chromium, Servo `gaol` and `birdcage` rely on
//!   it; `sandbox-exec -p` is the same kernel mechanism, only from outside the process.
//! - [`is_sandboxed`], [`allows_mach_lookup`] (`sandbox_check`, libsandbox SPI: Chromium, WebKit). It is looked up via
//!   `dlsym` at run time rather than at link time: if the symbol is missing, the answer is `None`, and the caller
//!   honestly says it cannot find the sandbox's processes (the build does not break because of it).
//!
//! The sandbox is per process, not per user: the agent and the worker run under the same uid as the owner; the
//! boundary is the profile rules (files, network, signals, IPC), which the kernel checks on every action.

use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    io,
    sync::OnceLock,
};

/// `enum sandbox_filter_type`: `SANDBOX_FILTER_NONE` (`<sandbox.h>`).
const SANDBOX_FILTER_NONE: c_int = 0;
/// `enum sandbox_filter_type`: `SANDBOX_FILTER_GLOBAL_NAME`, a Mach service name (`<sandbox.h>`, WebKit
/// `sandboxSPI.h`).
const SANDBOX_FILTER_GLOBAL_NAME: c_int = 2;

// SAFETY: the declarations repeat the macOS SDK's `<sandbox.h>` (`int sandbox_init(const char *, uint64_t, char **)`,
// `void sandbox_free_error(char *)`); both functions are exported by libSystem (libsystem_sandbox), which std always
// links.
#[allow(
    unsafe_code,
    reason = "declarations of the public <sandbox.h> functions"
)]
unsafe extern "C" {
    fn sandbox_init(profile: *const c_char, flags: u64, errorbuf: *mut *mut c_char) -> c_int;
    fn sandbox_free_error(errorbuf: *mut c_char);
}

/// Puts the current process into the Seatbelt sandbox with profile `profile` (SBPL text:
/// `(version 1) (deny default) …`). Forever: it cannot be lifted or relaxed, and descendants (including after `exec`)
/// inherit it. A process already in a sandbox gets an error. A profile compilation error is an `Err` with the
/// libsandbox text (line, position).
#[allow(unsafe_code, reason = "FFI: sandbox_init")]
pub fn apply(profile: &str) -> io::Result<()> {
    let c = CString::new(profile)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in the sandbox profile"))?;
    let mut err: *mut c_char = std::ptr::null_mut();
    // SAFETY: `c` is a NUL-terminated C string that lives until the end of the call; `err` points to a local variable:
    // on error libsandbox puts its string there (freed below), on success it leaves it alone. Flags 0: `profile` is
    // SBPL text.
    let r = unsafe { sandbox_init(c.as_ptr(), 0, &mut err) };
    if r == 0 {
        return Ok(());
    }
    let msg = if err.is_null() {
        format!("returned {r}")
    } else {
        // SAFETY: `err` is not null: a NUL-terminated string from libsandbox, valid until `sandbox_free_error`.
        let s = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: `err` was issued by libsandbox and is freed exactly once.
        unsafe { sandbox_free_error(err) };
        s
    };
    Err(io::Error::other(format!(
        "sandbox_init: {}",
        msg.trim().replace('\n', " ")
    )))
}

/// `int sandbox_check(pid_t pid, const char *operation, enum sandbox_filter_type type, ...)`.
type SandboxCheckFn = unsafe extern "C" fn(libc::pid_t, *const c_char, c_int, ...) -> c_int;

struct Spi {
    check: SandboxCheckFn,
    /// `SANDBOX_CHECK_NO_REPORT` (a flag added to the filter type: do not log the denial) or 0.
    no_report: c_int,
}

#[allow(unsafe_code, reason = "FFI: dlsym for the sandbox_check SPI")]
fn spi() -> Option<&'static Spi> {
    static SPI: OnceLock<Option<Spi>> = OnceLock::new();
    SPI.get_or_init(|| {
        // SAFETY: `dlsym` with `RTLD_DEFAULT` and a C string literal only looks up a symbol in the loaded images.
        let f = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"sandbox_check".as_ptr()) };
        if f.is_null() {
            return None;
        }
        // SAFETY: the libsandbox symbol `sandbox_check` is a function with the C signature `SandboxCheckFn`
        // (`<sandbox.h>`, WebKit `sandboxSPI.h`); a function pointer has the same size as `*mut c_void`.
        let check = unsafe { std::mem::transmute::<*mut c_void, SandboxCheckFn>(f) };
        // SAFETY: as above, only a symbol lookup.
        let nr = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"SANDBOX_CHECK_NO_REPORT".as_ptr()) };
        let no_report = if nr.is_null() {
            0
        } else {
            // SAFETY: not null: the address of the exported constant `const enum sandbox_filter_type` (int) in the
            // libsandbox image; only 4 bytes are read.
            let v = unsafe { std::ptr::read_unaligned(nr.cast::<c_int>()) };
            // A single high flag bit is expected (WebKit ORs it with the filter type); anything else must not touch
            // the filter type.
            if v.count_ones() == 1 && v >= 0x1_0000 {
                v
            } else {
                0
            }
        };
        Some(Spi { check, no_report })
    })
    .as_ref()
}

/// Whether this system has `sandbox_check` (needed to find the sandbox's processes by a profile rule).
pub fn can_check() -> bool {
    spi().is_some()
}

/// Whether process `pid` is in a Seatbelt sandbox (any). `None`: no `sandbox_check`, or an error (no such process,
/// another uid).
#[allow(unsafe_code, reason = "FFI: sandbox_check")]
pub fn is_sandboxed(pid: i32) -> Option<bool> {
    let s = spi()?;
    // SAFETY: `sandbox_check` with type `SANDBOX_FILTER_NONE` and no operation (NULL) reads no variadic arguments;
    // it writes nothing into the process's memory.
    let r = unsafe { (s.check)(pid, std::ptr::null(), SANDBOX_FILTER_NONE) };
    match r {
        1 => Some(true),
        0 => Some(false),
        _ => None,
    }
}

/// Whether the sandbox of process `pid` allows looking up the Mach service `name` (`mach-lookup` with `global-name`).
/// A process outside a sandbox also gets `Some(true)` (it may do anything): the caller tells them apart with
/// [`is_sandboxed`]. `None`: no `sandbox_check`, or an error.
#[allow(unsafe_code, reason = "FFI: sandbox_check")]
pub fn allows_mach_lookup(pid: i32, name: &str) -> Option<bool> {
    let s = spi()?;
    let n = CString::new(name).ok()?;
    // SAFETY: for type `SANDBOX_FILTER_GLOBAL_NAME` libsandbox reads exactly one variadic argument, the name's
    // `const char *`; `n` and the operation literal are C strings that live until the end of the call; the function
    // writes nothing through them.
    let r = unsafe {
        (s.check)(
            pid,
            c"mach-lookup".as_ptr(),
            SANDBOX_FILTER_GLOBAL_NAME | s.no_report,
            n.as_ptr(),
        )
    };
    match r {
        0 => Some(true),
        1 => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    //! Seatbelt facts on real macOS (CI `release.yml`, job `core`, `--nocapture`): the profile is applied in a
    //! child process (the test runner does not end up in the sandbox), and `sandbox_check` sees the child's sandbox and
    //! its profile rule.

    use std::{
        io::{BufRead, BufReader, Read},
        process::{Command, Stdio},
    };

    use super::*;

    const CHILD: &str = "ANTENNA_SYS_SEATBELT_CHILD";

    fn rerun(test: &str, arg: &str) -> std::process::Child {
        Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test, "--nocapture", "--test-threads=1"])
            .env(CHILD, arg)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap()
    }

    /// Child: the profile forbids reading one file, so the read is denied while a neighboring file is readable; a
    /// broken profile is an error with the libsandbox text, not a silent success.
    #[test]
    fn apply_denies_what_the_profile_denies() {
        if let Some(dir) = std::env::var_os(CHILD) {
            let dir = std::path::PathBuf::from(dir);
            let secret = dir.join("secret").canonicalize().unwrap();
            let bad = apply("(version 1) (allow default) (no-such-operation)");
            println!("FACT seatbelt bad profile: {bad:?}");
            if bad.is_ok() {
                std::process::exit(10);
            }
            apply(&format!(
                "(version 1) (allow default) (deny file-read-data (literal \"{}\"))",
                secret.display()
            ))
            .unwrap();
            let denied = std::fs::read(&secret);
            let other = std::fs::read(dir.join("other"));
            let again = apply("(version 1) (allow default)");
            println!(
                "FACT seatbelt child: secret={:?} other_ok={} second_apply={:?}",
                denied.as_ref().map(Vec::len).map_err(|e| e.to_string()),
                other.is_ok(),
                again.as_ref().map_err(|e| e.to_string())
            );
            let ok = denied.is_err_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
                && other.is_ok()
                && again.is_err();
            std::process::exit(if ok { 0 } else { 11 });
        }
        let t = std::env::temp_dir().join(format!("antenna-sys-seatbelt-{}", std::process::id()));
        std::fs::create_dir_all(&t).unwrap();
        std::fs::write(t.join("secret"), "s").unwrap();
        std::fs::write(t.join("other"), "o").unwrap();
        let out = rerun(
            "seatbelt::tests::apply_denies_what_the_profile_denies",
            t.to_str().unwrap(),
        )
        .wait_with_output()
        .unwrap();
        let _ = std::fs::remove_dir_all(&t);
        let text = String::from_utf8_lossy(&out.stdout);
        println!("{text}");
        assert!(out.status.success(), "child: {:?}\n{text}", out.status);
    }

    /// `sandbox_check` from outside: the child is in a sandbox, the test is not; the child's profile rule
    /// (`mach-lookup` of one name is denied) is visible by name: this is how the supervisor finds its sandbox's
    /// processes (D-P-13).
    #[test]
    fn sandbox_check_sees_the_child_profile() {
        const DENIED: &str = "io.github.danta-nort.antenna.test.denied";
        const OTHER: &str = "io.github.danta-nort.antenna.test.other";
        if std::env::var_os(CHILD).is_some() {
            apply(&format!(
                "(version 1) (allow default) (deny mach-lookup (global-name \"{DENIED}\"))"
            ))
            .unwrap();
            println!("READY");
            // Wait until the parent closes stdin.
            let _ = std::io::stdin().read_to_end(&mut Vec::new());
            std::process::exit(0);
        }
        println!("FACT sandbox_check available={}", can_check());
        assert!(can_check(), "sandbox_check is not exported on this system");
        let mut child = rerun("seatbelt::tests::sandbox_check_sees_the_child_profile", "1");
        let pid = child.id() as i32;
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        // With --nocapture libtest prints `test <name> ... ` without a newline, so READY ends that line rather than
        // standing alone. An exact match never fires and both processes wait for each other forever.
        assert!(
            lines.any(|l| l.is_ok_and(|l| l.trim_end().ends_with("READY"))),
            "child did not start"
        );
        let me = std::process::id() as i32;
        let facts = (
            is_sandboxed(pid),
            is_sandboxed(me),
            allows_mach_lookup(pid, OTHER),
            allows_mach_lookup(pid, DENIED),
            allows_mach_lookup(me, DENIED),
        );
        drop(child.stdin.take());
        let _ = child.wait();
        println!(
            "FACT sandbox_check: child sandboxed={:?} self sandboxed={:?} child allows other={:?} child allows denied={:?} self allows denied={:?}",
            facts.0, facts.1, facts.2, facts.3, facts.4
        );
        assert_eq!(
            facts,
            (Some(true), Some(false), Some(true), Some(false), Some(true))
        );
    }
}
