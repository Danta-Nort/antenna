// SPDX-License-Identifier: AGPL-3.0-only
//! A pseudoconsole (ConPTY, Windows 10 1809 and later; the W2 design, Code mode's terminal host): the console an agent
//! CLI runs in while the window's terminal shows it. Keys go in through one pipe; the screen comes out of the other
//! as VT sequences. A process gets the console when it is created ([`super::spawn`]).
//!
//! Before Windows 11 24H2, closing a pseudoconsole waits until its output has been read, so the output is read on a
//! thread of its own until its end, and the console is dropped elsewhere: the end of the output comes after the drop.

use std::{
    fs::File,
    io,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
};

use windows_sys::Win32::{
    Foundation::HANDLE,
    System::{
        Console::{COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON, ResizePseudoConsole},
        Pipes::CreatePipe,
    },
};

const _: () = assert!(std::mem::size_of::<COORD>() == 4);

/// A pseudoconsole; dropping it closes it, which ends the processes still attached to it.
#[derive(Debug)]
pub struct PseudoConsole(HPCON);

impl PseudoConsole {
    /// A pseudoconsole of `cols` × `rows` (each 1 to 32767), with the pipe its keys are written to and the pipe its
    /// output is read from. Neither pipe end is inheritable.
    #[allow(unsafe_code, reason = "FFI: CreatePseudoConsole")]
    pub fn new(cols: u16, rows: u16) -> io::Result<(PseudoConsole, File, File)> {
        let size = coord(cols, rows)?;
        let (in_read, in_write) = pipe()?;
        let (out_read, out_write) = pipe()?;
        let mut hpc: HPCON = 0;
        // SAFETY: two open pipe ends, and `hpc` is writable. The console duplicates both ends for itself.
        let hr = unsafe { CreatePseudoConsole(size, raw(&in_read), raw(&out_write), 0, &mut hpc) };
        if hr < 0 {
            return Err(io::Error::other(format!(
                "CreatePseudoConsole: HRESULT {hr:#010x}"
            )));
        }
        // The console holds its own copies of its ends: ours close here, so the output ends when the console does.
        drop((in_read, out_write));
        Ok((
            PseudoConsole(hpc),
            File::from(in_write),
            File::from(out_read),
        ))
    }

    /// Gives the console a new size; the program in it sees the change as a resize.
    #[allow(unsafe_code, reason = "FFI: ResizePseudoConsole")]
    pub fn resize(&self, cols: u16, rows: u16) -> io::Result<()> {
        let size = coord(cols, rows)?;
        // SAFETY: `self.0` is an open pseudoconsole.
        let hr = unsafe { ResizePseudoConsole(self.0, size) };
        if hr < 0 {
            return Err(io::Error::other(format!(
                "ResizePseudoConsole: HRESULT {hr:#010x}"
            )));
        }
        Ok(())
    }

    pub(crate) fn raw(&self) -> HPCON {
        self.0
    }
}

impl Drop for PseudoConsole {
    #[allow(unsafe_code, reason = "FFI: ClosePseudoConsole")]
    fn drop(&mut self) {
        // SAFETY: `self.0` is an open pseudoconsole, closed once, here.
        unsafe { ClosePseudoConsole(self.0) };
    }
}

fn coord(cols: u16, rows: u16) -> io::Result<COORD> {
    match (i16::try_from(cols), i16::try_from(rows)) {
        (Ok(x), Ok(y)) if x > 0 && y > 0 => Ok(COORD { X: x, Y: y }),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("a console of {cols} x {rows}: each must be 1 to 32767"),
        )),
    }
}

/// An anonymous pipe, neither end inheritable: (read, write).
#[allow(unsafe_code, reason = "FFI: CreatePipe")]
fn pipe() -> io::Result<(OwnedHandle, OwnedHandle)> {
    let (mut r, mut w): (HANDLE, HANDLE) = (std::ptr::null_mut(), std::ptr::null_mut());
    // SAFETY: both outputs are writable; no security attributes, so neither end is inheritable.
    if unsafe { CreatePipe(&mut r, &mut w, std::ptr::null(), 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both handles were just created and nothing else owns them.
    Ok(unsafe {
        (
            OwnedHandle::from_raw_handle(r.cast()),
            OwnedHandle::from_raw_handle(w.cast()),
        )
    })
}

fn raw(h: &OwnedHandle) -> HANDLE {
    h.as_raw_handle().cast()
}
