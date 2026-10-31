// SPDX-License-Identifier: AGPL-3.0-only
//! Processes (D-134; WP-6, WP-7): a process opened by PID with the least access that reads it, held open so its PID
//! cannot be reused while it is checked, its creation time and its token's facts. The rest of WP-7 (parents, image
//! names, the user's processes) comes with the Windows `procinfo`.

use std::{
    io,
    os::windows::io::{AsHandle, AsRawHandle, FromRawHandle, OwnedHandle},
};

use windows_sys::Win32::{
    Foundation::FILETIME,
    System::{
        SystemInformation::GetSystemTimePreciseAsFileTime,
        Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
    },
};

use super::security::{TokenFacts, process_token_facts};

const _: () = assert!(std::mem::size_of::<FILETIME>() == 8);

/// An open process: while this handle lives, its PID is not given to another process.
#[derive(Debug)]
pub struct Process(OwnedHandle);

impl Process {
    /// Opens a process by PID with `PROCESS_QUERY_LIMITED_INFORMATION` (which Windows grants on the user's elevated
    /// and protected processes too).
    #[allow(unsafe_code, reason = "FFI: OpenProcess")]
    pub fn open(pid: u32) -> io::Result<Process> {
        // SAFETY: no pointers; a null handle means failure.
        let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if h.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `h` is the handle just opened; nothing else owns it.
        Ok(Process(unsafe { OwnedHandle::from_raw_handle(h.cast()) }))
    }

    /// Its creation time, in 100 ns units since 1601 (UTC), comparable with [`now`].
    #[allow(unsafe_code, reason = "FFI: GetProcessTimes")]
    pub fn creation_time(&self) -> io::Result<u64> {
        let zero = FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        };
        let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
        // SAFETY: the handle is open with `PROCESS_QUERY_LIMITED_INFORMATION`; the four outputs are writable.
        let ok = unsafe {
            GetProcessTimes(
                self.0.as_raw_handle().cast(),
                &mut created,
                &mut exited,
                &mut kernel,
                &mut user,
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(filetime(created))
    }

    /// Its token's facts (its user, integrity, AppContainer, restricted, elevated).
    pub fn token(&self) -> io::Result<TokenFacts> {
        process_token_facts(Some(self.0.as_handle()))
    }
}

/// Now, in 100 ns units since 1601 (UTC).
#[allow(unsafe_code, reason = "FFI: GetSystemTimePreciseAsFileTime")]
pub fn now() -> u64 {
    let mut t = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    // SAFETY: `t` is writable for the call.
    unsafe { GetSystemTimePreciseAsFileTime(&mut t) };
    filetime(t)
}

fn filetime(t: FILETIME) -> u64 {
    (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::windows::security::current_user;

    #[test]
    fn the_own_process_reads_back() {
        let me = Process::open(std::process::id()).unwrap();
        let created = me.creation_time().unwrap();
        assert!(created > 0 && created < now(), "{created}");
        assert_eq!(me.token().unwrap().user, current_user().unwrap());
    }

    /// The control for a server check: the System process (PID 4) is not ours, or cannot even be read.
    #[test]
    fn a_process_of_the_system_is_not_ours() {
        let me = current_user().unwrap();
        let r = Process::open(4).and_then(|p| p.token());
        eprintln!("FACT PID 4: {r:?}");
        assert!(r.is_err() || r.is_ok_and(|t| t.user != me));
    }
}
