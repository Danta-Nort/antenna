// SPDX-License-Identifier: AGPL-3.0-only
//! The console (WP-28, WP-35).
//!
//! - [`echo_off`]: a password typed without echo. Only the echo is switched off, for as long as the returned guard
//!   lives; the caller reads the line itself, so the password never passes through this crate.
//! - [`attach_parent_console`]: a GUI-subsystem program (the release `antennad.exe`) started from a terminal prints
//!   into that terminal, when nobody gave it a standard error of its own.
//! - [`survive_ctrl_c`]: a process that shares its console with the program it started (Code mode's `agent-run
//!   --inner`) lives through Ctrl+C and Ctrl+Break, which the console sends to every process attached to it.

use std::{
    io,
    os::windows::io::{AsRawHandle, RawHandle},
};

use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::System::Console::{
    ATTACH_PARENT_PROCESS, AttachConsole, CONSOLE_MODE, CTRL_BREAK_EVENT, CTRL_C_EVENT,
    ENABLE_ECHO_INPUT, GetConsoleMode, GetStdHandle, STD_ERROR_HANDLE, SetConsoleCtrlHandler,
    SetConsoleMode,
};

/// The console's echo, off until this is dropped; then the mode it had comes back.
#[derive(Debug)]
pub struct EchoOff {
    input: RawHandle,
    old: CONSOLE_MODE,
}

/// Switches the echo of the console behind standard input off. Fails when standard input is not a console (a pipe, a
/// file): the caller then reads no password from it.
#[allow(unsafe_code, reason = "FFI: GetConsoleMode, SetConsoleMode")]
pub fn echo_off() -> io::Result<EchoOff> {
    let input = io::stdin().as_raw_handle();
    let mut old: CONSOLE_MODE = 0;
    // SAFETY: `input` is this process's standard input handle, open for the process's life; `old` is writable.
    if unsafe { GetConsoleMode(input.cast(), &mut old) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above; the new mode only clears one flag of the mode just read.
    if unsafe { SetConsoleMode(input.cast(), old & !ENABLE_ECHO_INPUT) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(EchoOff { input, old })
}

/// Attaches to the console of the parent process (the terminal it was started from) when this process has no standard
/// error: a GUI-subsystem program then prints `--version`, `--help` and its errors there. A standard error the starter
/// gave (the window's pipe into its log) is kept. Returns whether a console was attached.
#[allow(unsafe_code, reason = "FFI: GetStdHandle, AttachConsole")]
pub fn attach_parent_console() -> bool {
    // SAFETY: no pointers; the handle is only compared, never used.
    let err = unsafe { GetStdHandle(STD_ERROR_HANDLE) };
    if !err.is_null() && err != INVALID_HANDLE_VALUE {
        return false;
    }
    // SAFETY: no pointers; it fails when the parent has no console, which is fine.
    unsafe { AttachConsole(ATTACH_PARENT_PROCESS) != 0 }
}

/// This process lives through Ctrl+C and Ctrl+Break in its console: a handler of its own says they are handled. Not
/// `SetConsoleCtrlHandler(NULL, TRUE)`, whose "ignore Ctrl+C" flag the processes it starts would inherit: the program
/// it starts still gets both as usual. The console closing still ends it.
#[allow(unsafe_code, reason = "FFI: SetConsoleCtrlHandler")]
pub fn survive_ctrl_c() -> io::Result<()> {
    extern "system" fn handled(kind: u32) -> windows_sys::core::BOOL {
        i32::from(kind == CTRL_C_EVENT || kind == CTRL_BREAK_EVENT)
    }
    // SAFETY: `handled` is a function of the signature the console calls, alive for the whole process.
    if unsafe { SetConsoleCtrlHandler(Some(handled), 1) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

impl EchoOff {
    /// Whether the console's echo is off now (a check for tests).
    #[allow(unsafe_code, reason = "FFI: GetConsoleMode")]
    pub fn is_off(&self) -> bool {
        let mut mode: CONSOLE_MODE = 0;
        // SAFETY: `self.input` is standard input, open for the process's life; `mode` is writable.
        unsafe {
            GetConsoleMode(self.input.cast(), &mut mode) != 0 && mode & ENABLE_ECHO_INPUT == 0
        }
    }
}

impl Drop for EchoOff {
    #[allow(unsafe_code, reason = "FFI: SetConsoleMode")]
    fn drop(&mut self) {
        // SAFETY: `self.input` is standard input, open for the process's life; `self.old` is the mode read from it.
        unsafe { SetConsoleMode(self.input.cast(), self.old) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// With a console behind standard input the echo goes off and comes back; without one (a test runner's pipe) it
    /// is refused, so no password is ever read with the echo on.
    #[test]
    fn the_echo_goes_off_and_comes_back_or_is_refused() {
        match echo_off() {
            Ok(g) => {
                assert!(g.is_off());
                let old = g.old;
                drop(g);
                assert!(old & ENABLE_ECHO_INPUT != 0 || old == 0);
                eprintln!("FACT a console: echo off and back");
            }
            Err(e) => eprintln!("FACT no console behind stdin: {e}"),
        }
    }
}
