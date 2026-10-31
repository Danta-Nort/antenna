// SPDX-License-Identifier: AGPL-3.0-only
//! Windows FFI through `windows-sys` (D-134, D-135, `docs/PORTABILITY-WINDOWS.md`), each `unsafe` block with its
//! `// SAFETY:` and the structures read in place checked for size at compile time. Never AF_UNIX (D-135).
//!
//! - [`security`]: SIDs, security descriptors from SDDL, an object's owner and DACL as data, token facts, a folder
//!   created with its descriptor (WP-4, WP-6).
//! - [`pipe`]: the control pipe's instances with our descriptor, the client's token by impersonation, the PIDs a pipe
//!   records and the pipe object's owner (WP-5, WP-6).
//! - [`process`]: a process held open by PID, its creation time and its token (WP-6; WP-7 adds the rest).
//! - [`console`]: a password typed without echo, and the parent's console for a GUI-subsystem program (WP-28, WP-35).
//! - [`job`], [`conpty`], [`spawn`]: Code mode's terminal host (the W2 design): a job that ends everything in it and
//!   lets nothing break away, a pseudoconsole, and a process started into both with nothing inherited (WP-12, WP-14,
//!   WP-15).
//!
//! W1 adds the rest of process information (WP-7), the own process's DACL (WP-11) and the named stop event (WP-13).

pub mod conpty;
pub mod console;
pub mod job;
pub mod pipe;
pub mod process;
pub mod security;
pub mod spawn;
