// SPDX-License-Identifier: AGPL-3.0-only
//! Job objects (WP-14; the W2 design, Code mode's terminal host): every process an agent run starts is in one job, so
//! ending the job ends all of them, whatever parent each one chose. [`Job::kill_on_close`] ends its processes when its
//! last handle closes (the host that holds it is gone, killed included), lets none break away, and ends a process that
//! crashes instead of leaving an error dialog behind. Processes are put in a job when they are created
//! ([`super::spawn`]), never afterwards.

use std::{
    io,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
};

use windows_sys::Win32::{
    Foundation::{ERROR_MORE_DATA, HANDLE},
    System::JobObjects::{
        CreateJobObjectW, JOB_OBJECT_LIMIT, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_BASIC_PROCESS_ID_LIST,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectBasicProcessIdList,
        JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
        TerminateJobObject,
    },
};

#[cfg(target_pointer_width = "64")]
const _: () = assert!(std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() == 144);
#[cfg(target_pointer_width = "64")]
const _: () = assert!(std::mem::size_of::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() == 16);

/// A job object. Its handle is never inherited.
#[derive(Debug)]
pub struct Job(OwnedHandle);

impl Job {
    /// A job that ends every process in it when its last handle closes, and ends a process that crashes. No process
    /// in it may break away (`JOB_OBJECT_LIMIT_BREAKAWAY_OK` and `…_SILENT_BREAKAWAY_OK` are not set).
    pub fn kill_on_close() -> io::Result<Job> {
        Job::with_limits(
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
        )
    }

    #[allow(unsafe_code, reason = "FFI: CreateJobObjectW, SetInformationJobObject")]
    fn with_limits(limits: JOB_OBJECT_LIMIT) -> io::Result<Job> {
        // SAFETY: no security attributes (the default descriptor, not inheritable) and no name.
        let h = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if h.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `h` is the handle just created; nothing else owns it.
        let job = Job(unsafe { OwnedHandle::from_raw_handle(h.cast()) });
        if limits != 0 {
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = limits;
            // SAFETY: the handle is a job; `info` is the structure its class names, with that structure's size.
            let ok = unsafe {
                SetInformationJobObject(
                    job.raw(),
                    JobObjectExtendedLimitInformation,
                    (&raw const info).cast(),
                    size_of_u32::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>(),
                )
            };
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(job)
    }

    /// Ends every process in the job now; each exits with `code`.
    #[allow(unsafe_code, reason = "FFI: TerminateJobObject")]
    pub fn terminate(&self, code: u32) -> io::Result<()> {
        // SAFETY: the handle is a job, open with all access.
        if unsafe { TerminateJobObject(self.raw(), code) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// The PIDs of the processes in the job that have not exited.
    #[allow(unsafe_code, reason = "FFI: QueryInformationJobObject")]
    pub fn pids(&self) -> io::Result<Vec<u32>> {
        let head = std::mem::offset_of!(JOBOBJECT_BASIC_PROCESS_ID_LIST, ProcessIdList);
        let word = std::mem::size_of::<usize>();
        let mut cap = 64usize;
        loop {
            let bytes = head + cap * word;
            // In `usize` units, so the list is aligned as its structure needs.
            let mut buf = vec![0usize; bytes.div_ceil(word)];
            let len = u32::try_from(buf.len() * word).map_err(io::Error::other)?;
            // SAFETY: the handle is a job; `buf` is writable for `len` bytes and aligned for the structure.
            let ok = unsafe {
                QueryInformationJobObject(
                    self.raw(),
                    JobObjectBasicProcessIdList,
                    buf.as_mut_ptr().cast(),
                    len,
                    std::ptr::null_mut(),
                )
            };
            if ok == 0 {
                let e = io::Error::last_os_error();
                if e.raw_os_error() == i32::try_from(ERROR_MORE_DATA).ok() && cap < 1 << 16 {
                    cap *= 4;
                    continue;
                }
                return Err(e);
            }
            let list: *const JOBOBJECT_BASIC_PROCESS_ID_LIST = buf.as_ptr().cast();
            // SAFETY: the call filled the structure at the start of `buf`.
            let n = unsafe { (*list).NumberOfProcessIdsInList } as usize;
            let ids = &buf[head / word..];
            return Ok(ids[..n.min(ids.len())]
                .iter()
                .filter_map(|&pid| u32::try_from(pid).ok())
                .collect());
        }
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.0.as_raw_handle().cast()
    }
}

fn size_of_u32<T>() -> u32 {
    u32::try_from(std::mem::size_of::<T>()).unwrap_or(u32::MAX)
}

#[cfg(test)]
impl Job {
    /// A job with no limits: the controls' "without the job's guarantees".
    pub(crate) fn plain() -> io::Result<Job> {
        Job::with_limits(0)
    }

    /// [`Job::kill_on_close`], except that its processes may break away: the breakaway control.
    pub(crate) fn kill_on_close_breakaway_ok() -> io::Result<Job> {
        use windows_sys::Win32::System::JobObjects::JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        Job::with_limits(
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
                | JOB_OBJECT_LIMIT_BREAKAWAY_OK,
        )
    }
}
