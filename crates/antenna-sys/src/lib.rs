// SPDX-License-Identifier: AGPL-3.0-only
//! Minimal OS FFI wrappers for the `antenna` daemon (docs/PORTABILITY.md M-6, DECISIONS D-P-1).
//!
//! The only crate of the workspace that has `unsafe`: the root has `unsafe_code = "forbid"`, here it is `deny` with
//! `#[allow(unsafe_code)]` on each wrapper and a `// SAFETY:` comment on each block (clippy
//! `undocumented_unsafe_blocks = "deny"`). Only safe functions are exported. Existing crates do not cover what is
//! needed: `libproc` reads `PROC_PIDTBSDINFO` (fails with `EPERM` on processes of another uid) and builds its bindings
//! with `bindgen`; `nix` has neither `proc_pidinfo` nor `LOCAL_PEERTOKEN` (PORTABILITY §2.2).
//!
//! - [`fds`] (Linux, macOS): mark inherited descriptors > 2 CLOEXEC, either in the whole process at daemon startup
//!   (D-P-8) or only in the child when starting a file check worker (D-61), so that they do not reach the worker.
//! - [`darwin`] (macOS only): process information (`proc_pidinfo`), the peer's audit token over a unix socket
//!   (`LOCAL_PEERTOKEN`), debugger attach denial (`PT_DENY_ATTACH`), the boot session ID (`kern.bootsessionuuid`),
//!   the process list and memory footprint (`proc_listallpids`, `proc_pid_rusage`).
//! - [`seatbelt`] (macOS only): the Seatbelt sandbox: `sandbox_init` (file check worker, agent on wake)
//!   and `sandbox_check` (find the processes of one's own sandbox), D-P-12, D-P-13.
//! - [`windows`] (Windows only, D-134, D-135): the control pipe's security and the peer's identity (WP-5, WP-6),
//!   process information (WP-7), the DACLs (WP-4, WP-11), the console, and Code mode's terminal host: a job, a
//!   pseudoconsole and a process started into both (WP-14, WP-15).
//!
//! On Linux processes are read from `/proc` and `prctl` without `unsafe` (rustix), so `darwin` is not needed there.

#[cfg(target_os = "macos")]
pub mod darwin;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod fds;
#[cfg(target_os = "macos")]
pub mod seatbelt;
#[cfg(windows)]
pub mod windows;
