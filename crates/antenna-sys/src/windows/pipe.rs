// SPDX-License-Identifier: AGPL-3.0-only
//! The control pipe (D-135; WP-5, WP-6): what it needs beyond tokio's safe API.
//!
//! - [`create_server`]: an instance with our security descriptor (tokio's constructor that takes one is `unsafe`),
//!   remote clients rejected, and on request the first instance only, so a name someone else holds fails.
//! - [`client_token`]: the client's token facts, read by impersonating it at identification level for as long as it
//!   takes to open the thread token, then reverting. If reverting fails the process aborts: a thread left wearing a
//!   client's identity must never run anything else.
//! - [`client_pid`], [`server_pid`]: the PIDs the pipe records. A client's is the client's word (Project Zero, 2019),
//!   and a server's may be too, so they only restrict or confirm (D-134 item 4).
//! - [`pipe_owner`]: the owner of the pipe object, which the kernel keeps: a client checks it before it sends a byte.
//! - [`open_client`]: a client end at identification level, set explicitly, so a server can learn who we are but never
//!   act as us.

use std::{
    io,
    os::windows::io::{AsHandle, AsRawHandle, FromRawHandle, OwnedHandle},
    ptr,
};

use tokio::net::windows::named_pipe::{
    ClientOptions, NamedPipeClient, NamedPipeServer, PipeMode, ServerOptions,
};
use windows_sys::Win32::{
    Foundation::HANDLE,
    Security::{RevertToSelf, SECURITY_ATTRIBUTES, TOKEN_QUERY},
    Storage::FileSystem::SECURITY_IDENTIFICATION,
    System::{
        Pipes::{
            GetNamedPipeClientProcessId, GetNamedPipeServerProcessId, ImpersonateNamedPipeClient,
        },
        Threading::{GetCurrentThread, OpenThreadToken},
    },
};

use super::security::{
    ObjectKind, SecurityDescriptor, Sid, TokenFacts, handle_security, token_facts,
};

/// Creates one instance of the named pipe `name` with `sd` as its security descriptor: byte mode, both directions,
/// remote clients rejected; with `first`, only if no instance of that name exists yet (anyone's), so a name someone
/// else holds fails with access denied. Every instance is created with the same descriptor. Needs a tokio runtime.
#[allow(
    unsafe_code,
    reason = "tokio: ServerOptions::create_with_security_attributes_raw"
)]
pub fn create_server(
    name: &str,
    first: bool,
    sd: &SecurityDescriptor,
) -> io::Result<NamedPipeServer> {
    let mut sa: SECURITY_ATTRIBUTES = sd.attributes();
    let mut o = ServerOptions::new();
    o.first_pipe_instance(first)
        .reject_remote_clients(true)
        .access_inbound(true)
        .access_outbound(true)
        .pipe_mode(PipeMode::Byte);
    // SAFETY: `sa` is a valid `SECURITY_ATTRIBUTES` whose descriptor `sd` outlives the call; tokio passes the pointer
    // to `CreateNamedPipeW` and keeps nothing of it.
    unsafe {
        o.create_with_security_attributes_raw(name, (&mut sa as *mut SECURITY_ATTRIBUTES).cast())
    }
}

/// Opens the client end of the pipe `name` for reading and writing, at identification level: tokio's default too, set
/// here explicitly (with `SECURITY_SQOS_PRESENT`, which tokio adds), so the server can read our identity but never
/// impersonate us. Needs a tokio runtime.
pub fn open_client(name: &str) -> io::Result<NamedPipeClient> {
    ClientOptions::new()
        .read(true)
        .write(true)
        .security_qos_flags(SECURITY_IDENTIFICATION)
        .open(name)
}

/// Reverts the thread's impersonation when dropped; aborts the process if it cannot.
struct Revert;

impl Drop for Revert {
    #[allow(unsafe_code, reason = "FFI: RevertToSelf")]
    fn drop(&mut self) {
        // SAFETY: no arguments; it ends the calling thread's impersonation.
        if unsafe { RevertToSelf() } == 0 {
            // A worker thread still wearing the client's identity must never run anything else.
            std::process::abort();
        }
    }
}

/// The connected client's token facts. The thread impersonates the client only between the two calls that open its
/// token, synchronously (no await inside), then reverts; a failed revert aborts the process.
#[allow(
    unsafe_code,
    reason = "FFI: ImpersonateNamedPipeClient, OpenThreadToken"
)]
pub fn client_token(server: &NamedPipeServer) -> io::Result<TokenFacts> {
    // SAFETY: the handle is the server end of a pipe, owned by `server` for the call.
    if unsafe { ImpersonateNamedPipeClient(server.as_raw_handle().cast()) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let revert = Revert;
    let mut t: HANDLE = ptr::null_mut();
    // SAFETY: `GetCurrentThread` is a pseudo-handle; `OpenAsSelf` = TRUE checks access as the process, not as the
    // client; `t` receives the new token handle on success.
    let ok = unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut t) };
    let err = io::Error::last_os_error();
    drop(revert);
    if ok == 0 {
        return Err(err);
    }
    // SAFETY: `t` is the token handle just opened; nothing else owns it.
    let token = unsafe { OwnedHandle::from_raw_handle(t.cast()) };
    token_facts(&token)
}

/// The client PID the pipe records: the client's word, used only to restrict.
#[allow(unsafe_code, reason = "FFI: GetNamedPipeClientProcessId")]
pub fn client_pid(server: &NamedPipeServer) -> io::Result<u32> {
    let mut pid = 0u32;
    // SAFETY: the handle is owned by `server` for the call; `pid` is writable.
    if unsafe { GetNamedPipeClientProcessId(server.as_raw_handle().cast(), &mut pid) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(pid)
}

/// The server PID the pipe records: a consistency check, until a FACT test shows the server cannot choose it.
#[allow(unsafe_code, reason = "FFI: GetNamedPipeServerProcessId")]
pub fn server_pid(client: &NamedPipeClient) -> io::Result<u32> {
    let mut pid = 0u32;
    // SAFETY: the handle is owned by `client` for the call; `pid` is writable.
    if unsafe { GetNamedPipeServerProcessId(client.as_raw_handle().cast(), &mut pid) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(pid)
}

/// The owner of the pipe object, as the kernel keeps it (a non-administrator cannot make another user's SID the owner
/// of an object it creates).
pub fn pipe_owner(client: &NamedPipeClient) -> io::Result<Sid> {
    handle_security(client.as_handle(), ObjectKind::Kernel)?
        .owner
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "the pipe has no owner"))
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use windows_sys::Win32::Storage::FileSystem::SECURITY_ANONYMOUS;

    use super::*;
    use crate::windows::security::{AceKind, current_user};

    fn name(tag: &str) -> String {
        format!(r"\\.\pipe\antenna-sys-test-{}-{tag}", std::process::id())
    }

    fn ours() -> SecurityDescriptor {
        let me = current_user().unwrap();
        SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GRGW;;;{me})S:(ML;;NWNR;;;ME)"))
            .unwrap()
    }

    /// The DACL of an instance: protected, one entry, ours. The control: an instance made without a descriptor gets
    /// the default DACL, with Everyone or Anonymous in it.
    #[tokio::test]
    async fn the_pipe_is_ours_alone() {
        let me = current_user().unwrap();
        let n = name("dacl");
        let sd = ours();
        let first = create_server(&n, true, &sd).unwrap();
        let later = create_server(&n, false, &sd).unwrap();
        for s in [&first, &later] {
            let sec = handle_security(s.as_handle(), ObjectKind::Kernel).unwrap();
            assert_eq!(sec.owner.as_ref(), Some(&me), "{sec:?}");
            let dacl = sec.dacl.unwrap();
            assert!(dacl.protected, "{dacl:?}");
            assert_eq!(dacl.aces.len(), 1, "{dacl:?}");
            assert_eq!(
                (dacl.aces[0].kind, dacl.aces[0].sid.as_ref()),
                (AceKind::Allow, Some(&me))
            );
        }
        let plain = ServerOptions::new().create(name("plain")).unwrap();
        let dacl = handle_security(plain.as_handle(), ObjectKind::Kernel)
            .unwrap()
            .dacl
            .unwrap();
        eprintln!("FACT the default pipe DACL: {dacl:?}");
        let anyone = [
            Sid::parse("S-1-1-0").unwrap(),
            Sid::parse("S-1-5-7").unwrap(),
        ];
        assert!(
            dacl.aces
                .iter()
                .any(|a| a.sid.as_ref().is_some_and(|s| anyone.contains(s)))
        );
    }

    /// A name that already has an instance (anyone's) is refused as the first instance; the control: without the flag
    /// a further instance is made.
    #[tokio::test]
    async fn a_held_name_refuses_the_first_instance() {
        let n = name("held");
        let sd = ours();
        let _holder = create_server(&n, true, &sd).unwrap();
        let e = create_server(&n, true, &sd).unwrap_err();
        eprintln!("FACT first instance of a held name: {e}");
        assert_eq!(e.raw_os_error(), Some(5), "{e}");
        assert!(create_server(&n, false, &sd).is_ok());
    }

    /// The client's identity, its PIDs and the pipe's owner, over a real connection in this process.
    #[tokio::test]
    async fn the_client_and_the_server_read_each_other() {
        let me = current_user().unwrap();
        let n = name("who");
        let server = create_server(&n, true, &ours()).unwrap();
        let mut client = open_client(&n).unwrap();
        server.connect().await.unwrap();
        assert_eq!(pipe_owner(&client).unwrap(), me);
        assert_eq!(server_pid(&client).unwrap(), std::process::id());
        assert_eq!(client_pid(&server).unwrap(), std::process::id());
        let before = client_token(&server);
        eprintln!("FACT impersonation before the client wrote: {before:?}");
        client.write_all(b"hello\n").await.unwrap();
        let mut server = server;
        let mut buf = [0u8; 6];
        server.read_exact(&mut buf).await.unwrap();
        let t = client_token(&server).unwrap();
        assert_eq!(t.user, me);
        assert!(
            t.integrity >= 0x2000 && !t.app_container && !t.restricted,
            "{t:?}"
        );
    }

    /// A client that opens at anonymous level is not its user: the server reads the anonymous identity or fails.
    #[tokio::test]
    async fn an_anonymous_client_is_not_its_user() {
        let me = current_user().unwrap();
        let n = name("anon");
        let mut server = create_server(&n, true, &ours()).unwrap();
        let mut client = ClientOptions::new()
            .security_qos_flags(SECURITY_ANONYMOUS)
            .open(&n)
            .unwrap();
        server.connect().await.unwrap();
        client.write_all(b"x").await.unwrap();
        let mut b = [0u8; 1];
        server.read_exact(&mut b).await.unwrap();
        let t = client_token(&server);
        eprintln!("FACT an anonymous-level client: {t:?}");
        assert!(t.is_err() || t.is_ok_and(|t| t.user != me));
    }

    const CHILD_ENV: &str = "ANTENNA_SYS_TEST_OPEN_PIPE";

    /// Not a test of its own: the low-integrity child of `a_low_integrity_process_cannot_open_the_pipe` runs this test
    /// binary with only this test selected; it tries the pipe named in its environment and exits with what it got:
    /// 4 (it ran), plus 1 if it opened the pipe for reading, plus 2 if for reading and writing.
    #[test]
    fn low_integrity_child() {
        let Some(name) = std::env::var_os(CHILD_ENV) else {
            return;
        };
        let read = std::fs::OpenOptions::new().read(true).open(&name).is_ok();
        let rw = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&name)
            .is_ok();
        std::process::exit(4 | i32::from(read) | (i32::from(rw) << 1));
    }

    /// Runs `low_integrity_child` of this test binary at low integrity (our token, lowered), with `pipe` in its
    /// environment, and returns its exit code.
    #[allow(
        unsafe_code,
        reason = "test: a low-integrity child through CreateProcessAsUserW"
    )]
    fn run_low_integrity_child(pipe: &str) -> u32 {
        use std::os::windows::ffi::OsStrExt;

        use windows_sys::Win32::{
            Foundation::CloseHandle,
            Security::{
                DuplicateTokenEx, SID_AND_ATTRIBUTES, SecurityImpersonation, SetTokenInformation,
                TOKEN_ADJUST_DEFAULT, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_MANDATORY_LABEL,
                TokenIntegrityLevel, TokenPrimary,
            },
            System::{
                SystemServices::SE_GROUP_INTEGRITY,
                Threading::{
                    CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, GetCurrentProcess,
                    GetExitCodeProcess, OpenProcessToken, PROCESS_INFORMATION, STARTUPINFOW,
                    WaitForSingleObject,
                },
            },
        };

        let exe = std::env::current_exe().unwrap();
        let mut cmd: Vec<u16> = format!(
            "\"{}\" --exact windows::pipe::tests::low_integrity_child --test-threads=1",
            exe.display()
        )
        .encode_utf16()
        .chain(Some(0))
        .collect();
        let mut vars: Vec<(std::ffi::OsString, std::ffi::OsString)> = std::env::vars_os()
            .filter(|(k, _)| k != CHILD_ENV)
            .collect();
        vars.push((CHILD_ENV.into(), pipe.into()));
        vars.sort_by_key(|(k, _)| k.to_string_lossy().to_uppercase());
        let mut env: Vec<u16> = Vec::new();
        for (k, v) in &vars {
            env.extend(k.encode_wide());
            env.push(u16::from(b'='));
            env.extend(v.encode_wide());
            env.push(0);
        }
        env.push(0);

        let mut own: HANDLE = ptr::null_mut();
        // SAFETY: a pseudo-handle for this process; `own` receives a token handle.
        let ok = unsafe {
            OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY, &mut own)
        };
        assert_ne!(ok, 0, "{}", io::Error::last_os_error());
        let mut low: HANDLE = ptr::null_mut();
        let access = TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY;
        // SAFETY: `own` is open for duplication; `low` receives a new primary token.
        let ok = unsafe {
            DuplicateTokenEx(
                own,
                access,
                ptr::null(),
                SecurityImpersonation,
                TokenPrimary,
                &mut low,
            )
        };
        assert_ne!(ok, 0, "{}", io::Error::last_os_error());
        let sid = Sid::parse("S-1-16-4096").unwrap();
        let label = TOKEN_MANDATORY_LABEL {
            Label: SID_AND_ATTRIBUTES {
                Sid: sid.as_psid(),
                Attributes: SE_GROUP_INTEGRITY as u32,
            },
        };
        let len = (std::mem::size_of::<TOKEN_MANDATORY_LABEL>() + sid.byte_len()) as u32;
        // SAFETY: `label` points at `sid`'s bytes, both alive across the call, and `len` covers the structure and SID.
        let ok = unsafe {
            SetTokenInformation(
                low,
                TokenIntegrityLevel,
                (&label as *const TOKEN_MANDATORY_LABEL).cast(),
                len,
            )
        };
        assert_ne!(ok, 0, "{}", io::Error::last_os_error());
        // SAFETY: an all-zero `STARTUPINFOW` and `PROCESS_INFORMATION` are valid (no handles, no strings).
        let (mut si, mut pi): (STARTUPINFOW, PROCESS_INFORMATION) =
            unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        // SAFETY: `low` is a primary token for the child; `cmd` is a writable NUL-terminated command line and `env` a
        // double-NUL-terminated Unicode block, both alive across the call; no handles are inherited.
        let ok = unsafe {
            CreateProcessAsUserW(
                low,
                ptr::null(),
                cmd.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                CREATE_UNICODE_ENVIRONMENT,
                env.as_ptr().cast(),
                ptr::null(),
                &si,
                &mut pi,
            )
        };
        assert_ne!(ok, 0, "{}", io::Error::last_os_error());
        let mut code = 0u32;
        // SAFETY: `pi` holds the child's process and thread handles, closed once below; the other handles likewise.
        unsafe {
            WaitForSingleObject(pi.hProcess, 60_000);
            GetExitCodeProcess(pi.hProcess, &mut code);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            CloseHandle(low);
            CloseHandle(own);
        }
        code
    }

    /// The pipe's label (`NWNR` at medium) keeps a low-integrity process of the same user out, for reading too. The
    /// control: with the default policy (`NW` only) the same child opens it for reading.
    #[tokio::test]
    async fn a_low_integrity_process_cannot_open_the_pipe() {
        let me = current_user().unwrap();
        let n = name("lowil");
        let sd = ours();
        let _a = create_server(&n, true, &sd).unwrap();
        let _b = create_server(&n, false, &sd).unwrap();
        let got = run_low_integrity_child(&n);
        eprintln!("FACT a low-integrity child against NWNR: exit {got}");
        assert_eq!(got, 4, "the child ran and opened nothing");
        let c = name("lowil-nw");
        let nw =
            SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GRGW;;;{me})S:(ML;;NW;;;ME)"))
                .unwrap();
        let _c = create_server(&c, true, &nw).unwrap();
        let _d = create_server(&c, false, &nw).unwrap();
        let got = run_low_integrity_child(&c);
        eprintln!("FACT a low-integrity child against NW only: exit {got}");
        assert_eq!(
            got, 5,
            "the control: without NR it reads, and still cannot write"
        );
    }

    /// The control for the owner check: a pipe of the system is not owned by us.
    #[tokio::test]
    async fn a_system_pipe_is_not_ours() {
        let me = current_user().unwrap();
        for p in [
            r"\\.\pipe\lsass",
            r"\\.\pipe\ntsvcs",
            r"\\.\pipe\InitShutdown",
        ] {
            match ClientOptions::new().open(p) {
                Ok(c) => {
                    let owner = pipe_owner(&c);
                    eprintln!("FACT {p} owner {owner:?}");
                    assert!(owner.is_ok_and(|o| o != me), "{p}");
                    return;
                }
                Err(e) => eprintln!("FACT {p} not opened: {e}"),
            }
        }
        panic!("no system pipe could be opened");
    }
}
