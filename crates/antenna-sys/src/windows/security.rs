// SPDX-License-Identifier: AGPL-3.0-only
//! Windows security objects (D-135; WP-4, WP-5, WP-6): SIDs, security descriptors built from SDDL, the owner and DACL
//! of a folder or a kernel object as plain data, the facts of an access token, and a folder created with its security
//! descriptor in the same call. Which owner and which entries are acceptable is the caller's decision, in safe code.
//!
//! A SID is kept as its bytes; its string form and back are plain Rust (no FFI), so a SID never needs `LocalFree`.

use std::{
    ffi::c_void,
    fmt, io,
    mem::size_of,
    os::windows::{
        ffi::OsStrExt,
        io::{AsHandle, AsRawHandle, BorrowedHandle, FromRawHandle, OwnedHandle},
    },
    path::Path,
    ptr,
};

use windows_sys::Win32::{
    Foundation::{ERROR_INSUFFICIENT_BUFFER, HANDLE, INVALID_HANDLE_VALUE, LocalFree},
    Security::{
        ACCESS_ALLOWED_ACE, ACE_HEADER, ACL,
        Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1,
            SE_FILE_OBJECT, SE_KERNEL_OBJECT, SE_OBJECT_TYPE,
        },
        DACL_SECURITY_INFORMATION, GetAce, GetLengthSid, GetSecurityDescriptorControl,
        GetSecurityDescriptorDacl, GetSecurityDescriptorOwner, GetTokenInformation,
        IsTokenRestricted, IsValidSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        SE_DACL_PROTECTED, SECURITY_ATTRIBUTES, SID_AND_ATTRIBUTES, TOKEN_ELEVATION,
        TOKEN_INFORMATION_CLASS, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TOKEN_USER, TokenElevation,
        TokenIntegrityLevel, TokenIsAppContainer, TokenUser,
    },
    Storage::FileSystem::{
        CreateDirectoryW, CreateFileW, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
        FILE_ATTRIBUTE_TAG_INFO, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        FileAttributeTagInfo, GetFileInformationByHandleEx, OPEN_EXISTING, READ_CONTROL,
    },
    System::{
        SystemServices::{ACCESS_ALLOWED_ACE_TYPE, ACCESS_DENIED_ACE_TYPE},
        Threading::{GetCurrentProcess, OpenProcessToken},
    },
};

// The structures this module reads in place, checked against their layout in the Windows SDK (x86_64).
const _: () = assert!(size_of::<SECURITY_ATTRIBUTES>() == 24);
const _: () = assert!(size_of::<SID_AND_ATTRIBUTES>() == 16);
const _: () = assert!(size_of::<TOKEN_USER>() == 16);
const _: () = assert!(size_of::<TOKEN_MANDATORY_LABEL>() == 16);
const _: () = assert!(size_of::<TOKEN_ELEVATION>() == 4);
const _: () = assert!(size_of::<ACE_HEADER>() == 4);
const _: () = assert!(size_of::<ACCESS_ALLOWED_ACE>() == 12);
const _: () = assert!(size_of::<ACL>() == 8);
const _: () = assert!(size_of::<FILE_ATTRIBUTE_TAG_INFO>() == 8);

/// The longest token information this module asks for (a `TOKEN_USER` with its SID is under 100 bytes).
const MAX_TOKEN_INFO: u32 = 4096;

/// A security identifier, as its bytes (revision, sub-authority count, the 6-byte authority, the sub-authorities).
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Sid(Box<[u8]>);

impl Sid {
    /// Well-known `NT AUTHORITY\SYSTEM`.
    pub fn local_system() -> Sid {
        Sid::from_parts(5, &[18])
    }

    /// Well-known `BUILTIN\Administrators`.
    pub fn administrators() -> Sid {
        Sid::from_parts(5, &[32, 544])
    }

    fn from_parts(authority: u64, subs: &[u32]) -> Sid {
        let mut b = Vec::with_capacity(8 + 4 * subs.len());
        b.push(1);
        b.push(subs.len() as u8);
        b.extend_from_slice(&authority.to_be_bytes()[2..]);
        for s in subs {
            b.extend_from_slice(&s.to_le_bytes());
        }
        Sid(b.into())
    }

    /// From its string form (`S-1-5-18`). Only revision 1 and at most 15 sub-authorities, as Windows allows.
    pub fn parse(s: &str) -> io::Result<Sid> {
        let bad = || invalid(format!("not a SID: {s:?}"));
        let mut parts = s.strip_prefix("S-1-").ok_or_else(bad)?.split('-');
        let authority = match parts.next().ok_or_else(bad)? {
            a if a.starts_with("0x") || a.starts_with("0X") => {
                u64::from_str_radix(&a[2..], 16).map_err(|_| bad())?
            }
            a => a.parse::<u64>().map_err(|_| bad())?,
        };
        if authority >= 1 << 48 {
            return Err(bad());
        }
        let subs = parts
            .map(|p| p.parse::<u32>().map_err(|_| bad()))
            .collect::<io::Result<Vec<u32>>>()?;
        if subs.is_empty() || subs.len() > 15 {
            return Err(bad());
        }
        Ok(Sid::from_parts(authority, &subs))
    }

    /// A pointer to the bytes, for a call that only reads them while `self` lives.
    #[cfg(test)]
    pub(crate) fn as_psid(&self) -> PSID {
        self.0.as_ptr().cast_mut().cast()
    }

    /// The length in bytes.
    #[cfg(test)]
    pub(crate) fn byte_len(&self) -> usize {
        self.0.len()
    }

    /// The last sub-authority (an integrity label's level, a user's RID).
    pub fn last_sub_authority(&self) -> Option<u32> {
        let n = usize::from(*self.0.get(1)?);
        let at = 8 + 4 * n.checked_sub(1)?;
        Some(u32::from_le_bytes(self.0.get(at..at + 4)?.try_into().ok()?))
    }

    /// Copies a SID out of memory Windows handed back.
    ///
    /// # Safety
    ///
    /// `p` points to a SID that stays readable for the duration of the call.
    #[allow(unsafe_code, reason = "FFI: a SID inside a buffer Windows filled")]
    unsafe fn copy_from(p: PSID) -> io::Result<Sid> {
        if p.is_null() {
            return Err(invalid("no SID"));
        }
        // SAFETY: the caller guarantees `p` points to a SID; `IsValidSid` only reads its header and sub-authorities.
        if unsafe { IsValidSid(p) } == 0 {
            return Err(invalid("not a valid SID"));
        }
        // SAFETY: as above; for a valid SID `GetLengthSid` returns its length in bytes.
        let n = unsafe { GetLengthSid(p) } as usize;
        // SAFETY: a valid SID is exactly `n` readable bytes at `p`, and the caller keeps them alive for this call.
        let bytes = unsafe { std::slice::from_raw_parts(p.cast::<u8>(), n) };
        Ok(Sid(bytes.into()))
    }
}

impl fmt::Display for Sid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let b = &self.0;
        let n = b.get(1).copied().map_or(0, usize::from);
        let auth = b.get(2..8).map_or(0, |a| {
            a.iter().fold(0u64, |acc, x| (acc << 8) | u64::from(*x))
        });
        write!(f, "S-{}-", b.first().copied().unwrap_or(0))?;
        if auth >= 1 << 32 {
            write!(f, "0x{auth:012X}")?;
        } else {
            write!(f, "{auth}")?;
        }
        for i in 0..n {
            let at = 8 + 4 * i;
            match b.get(at..at + 4).and_then(|s| <[u8; 4]>::try_from(s).ok()) {
                Some(s) => write!(f, "-{}", u32::from_le_bytes(s))?,
                None => return write!(f, "-?"),
            }
        }
        Ok(())
    }
}

impl fmt::Debug for Sid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

/// What a token says about its process or its client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenFacts {
    /// The token's user.
    pub user: Sid,
    /// The integrity level's RID (`0x1000` low, `0x2000` medium, `0x3000` high, `0x4000` system).
    pub integrity: u32,
    /// An AppContainer (or less privileged AppContainer) token.
    pub app_container: bool,
    /// The token has restricting SIDs (a restricted token, as sandboxes make).
    pub restricted: bool,
    /// An elevated token (UAC).
    pub elevated: bool,
}

/// The current process's user.
pub fn current_user() -> io::Result<Sid> {
    Ok(process_token_facts(None)?.user)
}

/// The facts of the current process's token (`None`) or of another process's (its handle, opened with at least
/// `PROCESS_QUERY_LIMITED_INFORMATION`).
#[allow(unsafe_code, reason = "FFI: OpenProcessToken")]
pub(crate) fn process_token_facts(process: Option<BorrowedHandle<'_>>) -> io::Result<TokenFacts> {
    // SAFETY: `GetCurrentProcess` returns a pseudo-handle that needs no closing.
    let h = process.map_or_else(
        || unsafe { GetCurrentProcess() },
        |p| p.as_raw_handle().cast(),
    );
    let mut t: HANDLE = ptr::null_mut();
    // SAFETY: `h` is a process handle valid for the call; `t` receives a new token handle on success.
    if unsafe { OpenProcessToken(h, TOKEN_QUERY, &mut t) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `t` is the token handle the call just opened; nothing else owns it.
    let token = unsafe { OwnedHandle::from_raw_handle(t.cast()) };
    token_facts(&token)
}

/// The facts of an open token (opened with `TOKEN_QUERY`).
#[allow(unsafe_code, reason = "FFI: GetTokenInformation, IsTokenRestricted")]
pub(crate) fn token_facts(token: &OwnedHandle) -> io::Result<TokenFacts> {
    let t: HANDLE = token.as_raw_handle().cast();
    let user = {
        let buf = token_info(t, TokenUser)?;
        // SAFETY: `buf` holds a `TOKEN_USER` (8-byte aligned, at least as long as the structure: `token_info` checks
        // the length Windows reported against it); its SID pointer points into `buf`, alive here.
        unsafe { Sid::copy_from(buf_as::<TOKEN_USER>(&buf)?.User.Sid)? }
    };
    let integrity = {
        let buf = token_info(t, TokenIntegrityLevel)?;
        // SAFETY: as above, for `TOKEN_MANDATORY_LABEL`.
        let label = unsafe { Sid::copy_from(buf_as::<TOKEN_MANDATORY_LABEL>(&buf)?.Label.Sid)? };
        label
            .last_sub_authority()
            .ok_or_else(|| invalid("an integrity label without a level"))?
    };
    let app_container = token_u32(t, TokenIsAppContainer)? != 0;
    let elevated = token_u32(t, TokenElevation)? != 0;
    // SAFETY: `t` is a token handle open for `TOKEN_QUERY`. The function answers nonzero for restricting SIDs and zero
    // otherwise; an error also reads as zero, so the last error is cleared first and checked after.
    let restricted = unsafe {
        windows_sys::Win32::Foundation::SetLastError(0);
        IsTokenRestricted(t) != 0
    };
    if !restricted
        && let Some(e) = io::Error::last_os_error()
            .raw_os_error()
            .filter(|e| *e != 0)
    {
        return Err(io::Error::from_raw_os_error(e));
    }
    Ok(TokenFacts {
        user,
        integrity,
        app_container,
        restricted,
        elevated,
    })
}

/// A variable-length token information class, in an 8-byte aligned buffer at least as long as `T`.
#[allow(unsafe_code, reason = "FFI: GetTokenInformation")]
fn token_info(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> io::Result<Vec<u64>> {
    let mut len = 0u32;
    // SAFETY: a null buffer of length 0 only asks for the length needed; nothing is written.
    let ok = unsafe { GetTokenInformation(token, class, ptr::null_mut(), 0, &mut len) };
    if ok == 0 {
        let e = io::Error::last_os_error();
        if e.raw_os_error() != Some(ERROR_INSUFFICIENT_BUFFER as i32) {
            return Err(e);
        }
    }
    if len == 0 || len > MAX_TOKEN_INFO {
        return Err(invalid(format!("token information of {len} bytes")));
    }
    let mut buf = vec![0u64; (len as usize).div_ceil(8)];
    // SAFETY: `buf` is at least `len` bytes, 8-byte aligned, and lives across the call; Windows writes at most `len`.
    if unsafe { GetTokenInformation(token, class, buf.as_mut_ptr().cast(), len, &mut len) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(buf)
}

/// A fixed `u32` token information class (`TokenIsAppContainer`, `TokenElevation`).
#[allow(unsafe_code, reason = "FFI: GetTokenInformation")]
fn token_u32(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> io::Result<u32> {
    let mut v = 0u32;
    let mut len = 0u32;
    // SAFETY: `v` is 4 writable bytes for the call, and 4 is the size passed.
    let ok = unsafe { GetTokenInformation(token, class, (&mut v as *mut u32).cast(), 4, &mut len) };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(v)
}

/// The structure at the start of an aligned buffer.
///
/// # Safety
///
/// The buffer was filled by Windows with a `T` at its start.
#[allow(unsafe_code, reason = "reading a structure Windows wrote")]
unsafe fn buf_as<T: Copy>(buf: &[u64]) -> io::Result<T> {
    if buf.len() * 8 < size_of::<T>() {
        return Err(invalid("token information shorter than its structure"));
    }
    // SAFETY: the buffer is 8-byte aligned (`u64`), at least `size_of::<T>()` long, and holds a `T` (the caller).
    Ok(unsafe { ptr::read(buf.as_ptr().cast::<T>()) })
}

/// A security descriptor made from SDDL, owned (freed with `LocalFree`).
pub struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

// SAFETY: the descriptor is memory this value alone owns; it is never written after creation and is freed once, in
// `Drop`, so moving it to or reading it from another thread is sound.
#[allow(unsafe_code, reason = "Send for an owned, immutable LocalAlloc buffer")]
unsafe impl Send for SecurityDescriptor {}
// SAFETY: as above; shared access only reads it.
#[allow(unsafe_code, reason = "Sync for an owned, immutable LocalAlloc buffer")]
unsafe impl Sync for SecurityDescriptor {}

impl SecurityDescriptor {
    /// From SDDL (`O:<sid>D:P(A;;FA;;;<sid>)S:(ML;;NWNR;;;ME)`).
    #[allow(
        unsafe_code,
        reason = "FFI: ConvertStringSecurityDescriptorToSecurityDescriptorW"
    )]
    pub fn from_sddl(sddl: &str) -> io::Result<SecurityDescriptor> {
        let w = wide_str(sddl)?;
        let mut sd: PSECURITY_DESCRIPTOR = ptr::null_mut();
        // SAFETY: `w` is NUL-terminated and lives across the call; `sd` receives a LocalAlloc'd descriptor on success.
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                w.as_ptr(),
                SDDL_REVISION_1,
                &mut sd,
                ptr::null_mut(),
            )
        };
        if ok == 0 || sd.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(SecurityDescriptor(sd))
    }

    /// `SECURITY_ATTRIBUTES` pointing at this descriptor (valid while `self` is), not inheritable.
    pub(crate) fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0,
            bInheritHandle: 0,
        }
    }

    /// The owner and DACL this descriptor carries.
    #[allow(unsafe_code, reason = "reading a descriptor this value owns")]
    pub fn security(&self) -> io::Result<ObjectSecurity> {
        // SAFETY: `self.0` is a valid self-relative descriptor owned by `self` for the call.
        unsafe { read_descriptor(self.0) }
    }
}

impl Drop for SecurityDescriptor {
    #[allow(unsafe_code, reason = "FFI: LocalFree")]
    fn drop(&mut self) {
        // SAFETY: `self.0` was allocated by `ConvertStringSecurityDescriptorToSecurityDescriptorW` and is freed once.
        unsafe { LocalFree(self.0) };
    }
}

/// The kind of an access control entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AceKind {
    /// `ACCESS_ALLOWED_ACE_TYPE`.
    Allow,
    /// `ACCESS_DENIED_ACE_TYPE`.
    Deny,
    /// Any other type (object, callback, audit, …), by number.
    Other(u8),
}

/// One access control entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ace {
    /// Its type.
    pub kind: AceKind,
    /// `AceFlags` (`OBJECT_INHERIT_ACE` 0x1, `CONTAINER_INHERIT_ACE` 0x2, `INHERITED_ACE` 0x10, …).
    pub flags: u8,
    /// The access mask (allow and deny entries; 0 for other types).
    pub mask: u32,
    /// The trustee (allow and deny entries; `None` for other types).
    pub sid: Option<Sid>,
}

/// A discretionary access control list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dacl {
    /// `SE_DACL_PROTECTED`: entries of the parent are not inherited.
    pub protected: bool,
    /// The entries, in order.
    pub aces: Vec<Ace>,
}

/// An object's owner and DACL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectSecurity {
    /// The owner (`None`: the descriptor has none).
    pub owner: Option<Sid>,
    /// The DACL (`None`: a NULL DACL, which grants everyone everything).
    pub dacl: Option<Dacl>,
}

/// What kind of object a handle is, for [`handle_security`].
#[derive(Debug, Clone, Copy)]
pub enum ObjectKind {
    /// A file or folder.
    File,
    /// A kernel object (a named pipe, an event, a process).
    Kernel,
}

/// The owner and DACL of an open object (the handle needs `READ_CONTROL`).
#[allow(unsafe_code, reason = "FFI: GetSecurityInfo")]
pub fn handle_security(handle: BorrowedHandle<'_>, kind: ObjectKind) -> io::Result<ObjectSecurity> {
    let kind: SE_OBJECT_TYPE = match kind {
        ObjectKind::File => SE_FILE_OBJECT,
        ObjectKind::Kernel => SE_KERNEL_OBJECT,
    };
    let mut sd: PSECURITY_DESCRIPTOR = ptr::null_mut();
    // SAFETY: `handle` is open for the call; the out pointers for owner, group, DACL and SACL may be null when the
    // whole descriptor is asked for, which Windows allocates with LocalAlloc into `sd`.
    let e = unsafe {
        GetSecurityInfo(
            handle.as_raw_handle().cast(),
            kind,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut sd,
        )
    };
    if e != 0 {
        return Err(io::Error::from_raw_os_error(e as i32));
    }
    if sd.is_null() {
        return Err(invalid("no security descriptor"));
    }
    // SAFETY: `sd` is the descriptor Windows just allocated; it is read, then freed once.
    let r = unsafe { read_descriptor(sd) };
    // SAFETY: as above.
    unsafe { LocalFree(sd) };
    r
}

/// Reads a descriptor's owner, DACL and protection.
///
/// # Safety
///
/// `sd` is a valid security descriptor that stays alive for the call.
#[allow(unsafe_code, reason = "FFI: reading a security descriptor")]
unsafe fn read_descriptor(sd: PSECURITY_DESCRIPTOR) -> io::Result<ObjectSecurity> {
    let mut control = 0u16;
    let mut revision = 0u32;
    // SAFETY: `sd` is valid (the caller); the outputs are local.
    if unsafe { GetSecurityDescriptorControl(sd, &mut control, &mut revision) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut owner: PSID = ptr::null_mut();
    let mut defaulted = 0;
    // SAFETY: as above; `owner` receives a pointer into `sd` (or null).
    if unsafe { GetSecurityDescriptorOwner(sd, &mut owner, &mut defaulted) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let owner = if owner.is_null() {
        None
    } else {
        // SAFETY: `owner` points to a SID inside `sd`, alive for the call.
        Some(unsafe { Sid::copy_from(owner)? })
    };
    let mut present = 0;
    let mut acl: *mut ACL = ptr::null_mut();
    // SAFETY: as above; `acl` receives a pointer into `sd` (or null for a NULL DACL).
    if unsafe { GetSecurityDescriptorDacl(sd, &mut present, &mut acl, &mut defaulted) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if present == 0 || acl.is_null() {
        return Ok(ObjectSecurity { owner, dacl: None });
    }
    // SAFETY: `acl` points to a valid ACL inside `sd`, alive for the call.
    let count = unsafe { (*acl).AceCount };
    let mut aces = Vec::with_capacity(usize::from(count));
    for i in 0..u32::from(count) {
        let mut p: *mut c_void = ptr::null_mut();
        // SAFETY: `i` is below the ACL's count; `p` receives a pointer to the entry inside the ACL.
        if unsafe { GetAce(acl, i, &mut p) } == 0 || p.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: every entry starts with an `ACE_HEADER` (4 bytes, 2-byte aligned fields read unaligned-safe).
        let header = unsafe { ptr::read_unaligned(p.cast::<ACE_HEADER>()) };
        let kind = match u32::from(header.AceType) {
            ACCESS_ALLOWED_ACE_TYPE => AceKind::Allow,
            ACCESS_DENIED_ACE_TYPE => AceKind::Deny,
            _ => AceKind::Other(header.AceType),
        };
        let (mask, sid) = if matches!(kind, AceKind::Other(_)) {
            (0, None)
        } else {
            if usize::from(header.AceSize) < size_of::<ACCESS_ALLOWED_ACE>() {
                return Err(invalid("an access entry shorter than its structure"));
            }
            // SAFETY: allow and deny entries share the `ACCESS_ALLOWED_ACE` layout, and the size was checked.
            let ace = unsafe { ptr::read_unaligned(p.cast::<ACCESS_ALLOWED_ACE>()) };
            // SAFETY: the SID starts at `SidStart` inside the entry, within `AceSize` (Windows built it).
            let sid = unsafe {
                Sid::copy_from(
                    p.cast::<u8>()
                        .add(std::mem::offset_of!(ACCESS_ALLOWED_ACE, SidStart))
                        .cast(),
                )?
            };
            (ace.Mask, Some(sid))
        };
        aces.push(Ace {
            kind,
            flags: header.AceFlags,
            mask,
            sid,
        });
    }
    Ok(ObjectSecurity {
        owner,
        dacl: Some(Dacl {
            protected: control & SE_DACL_PROTECTED != 0,
            aces,
        }),
    })
}

/// A folder as found, for the data folder's check: what it is, and its owner and DACL.
#[derive(Debug, Clone)]
pub struct DirFacts {
    /// A directory (not a file).
    pub directory: bool,
    /// A reparse point (a junction or a symbolic link), not followed.
    pub reparse_point: bool,
    /// Its owner and DACL.
    pub security: ObjectSecurity,
}

/// Reads a folder without following a reparse point at its name.
#[allow(unsafe_code, reason = "FFI: CreateFileW, GetFileInformationByHandleEx")]
pub fn dir_facts(path: &Path) -> io::Result<DirFacts> {
    let w = wide_path(path)?;
    // SAFETY: `w` is NUL-terminated and lives across the call; no security attributes, no template.
    let h = unsafe {
        CreateFileW(
            w.as_ptr(),
            READ_CONTROL | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            ptr::null_mut(),
        )
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `h` is the handle just opened; nothing else owns it.
    let file = unsafe { OwnedHandle::from_raw_handle(h.cast()) };
    let mut info = FILE_ATTRIBUTE_TAG_INFO {
        FileAttributes: 0,
        ReparseTag: 0,
    };
    // SAFETY: `info` is a writable `FILE_ATTRIBUTE_TAG_INFO` of the size passed, for the call.
    let ok = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle().cast(),
            FileAttributeTagInfo,
            (&mut info as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(DirFacts {
        directory: info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0,
        reparse_point: info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0,
        security: handle_security(file.as_handle(), ObjectKind::File)?,
    })
}

/// Creates a folder with this security descriptor, so it never exists with inherited entries. Fails if it exists.
#[allow(unsafe_code, reason = "FFI: CreateDirectoryW")]
pub fn create_dir(path: &Path, sd: &SecurityDescriptor) -> io::Result<()> {
    let w = wide_path(path)?;
    let sa = sd.attributes();
    // SAFETY: `w` is NUL-terminated; `sa` points at `sd`'s descriptor, both alive across the call.
    if unsafe { CreateDirectoryW(w.as_ptr(), &sa) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn wide_str(s: &str) -> io::Result<Vec<u16>> {
    if s.contains('\0') {
        return Err(invalid("a NUL inside a string for Windows"));
    }
    Ok(s.encode_utf16().chain(Some(0)).collect())
}

fn wide_path(p: &Path) -> io::Result<Vec<u16>> {
    let w: Vec<u16> = p.as_os_str().encode_wide().collect();
    if w.contains(&0) {
        return Err(invalid("a NUL inside a path"));
    }
    Ok(w.into_iter().chain(Some(0)).collect())
}

fn invalid(msg: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sids_read_and_print_as_windows_does() {
        let system = Sid::parse("S-1-5-18").unwrap();
        assert_eq!(&*system.0, &[1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0]);
        assert_eq!(system, Sid::local_system());
        assert_eq!(Sid::administrators().to_string(), "S-1-5-32-544");
        let user = Sid::parse("S-1-5-21-1004336348-1177238915-682003330-512").unwrap();
        assert_eq!(
            user.to_string(),
            "S-1-5-21-1004336348-1177238915-682003330-512"
        );
        assert_eq!(user.last_sub_authority(), Some(512));
        assert_eq!(
            Sid::parse("S-1-16-8192").unwrap().last_sub_authority(),
            Some(0x2000)
        );
        for bad in [
            "",
            "S-1",
            "S-1-5",
            "S-2-5-18",
            "S-1-x-18",
            "S-1-5-18-",
            "1-5-18",
            "S-1-5-4294967296",
        ] {
            assert!(Sid::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_own_token_is_read() {
        let me = process_token_facts(None).unwrap();
        assert_eq!(current_user().unwrap(), me.user);
        assert!(me.user.to_string().starts_with("S-1-"), "{me:?}");
        assert!(me.integrity >= 0x2000, "{me:?}");
        assert!(!me.app_container && !me.restricted, "{me:?}");
        eprintln!("FACT own token {me:?}");
    }

    #[test]
    fn a_descriptor_from_sddl_reads_back() {
        let me = current_user().unwrap();
        let sd = SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;OICI;FA;;;{me})")).unwrap();
        let s = sd.security().unwrap();
        assert_eq!(s.owner.as_ref(), Some(&me));
        let dacl = s.dacl.unwrap();
        assert!(dacl.protected);
        assert_eq!(
            dacl.aces,
            [Ace {
                kind: AceKind::Allow,
                flags: 0x3,
                mask: 0x1f_01ff,
                sid: Some(me.clone()),
            }]
        );
        let open = SecurityDescriptor::from_sddl("D:(A;;GR;;;WD)(D;;GW;;;BA)")
            .unwrap()
            .security()
            .unwrap();
        let dacl = open.dacl.unwrap();
        assert!(!dacl.protected);
        assert_eq!(dacl.aces[0].sid, Some(Sid::parse("S-1-1-0").unwrap()));
        assert_eq!(dacl.aces[1].kind, AceKind::Deny);
        let null = SecurityDescriptor::from_sddl("D:NO_ACCESS_CONTROL")
            .unwrap()
            .security()
            .unwrap();
        assert_eq!(null.dacl, None);
    }

    #[test]
    fn a_folder_is_created_with_its_descriptor_and_read_back() {
        let me = current_user().unwrap();
        let t = std::env::temp_dir().join(format!("antenna-sys-dir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&t);
        let sd = SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;OICI;FA;;;{me})")).unwrap();
        create_dir(&t, &sd).unwrap();
        let f = dir_facts(&t).unwrap();
        let _ = std::fs::remove_dir_all(&t);
        assert!(f.directory && !f.reparse_point, "{f:?}");
        assert_eq!(f.security.owner.as_ref(), Some(&me));
        let dacl = f.security.dacl.unwrap();
        assert!(dacl.protected, "{dacl:?}");
        assert_eq!(dacl.aces.len(), 1, "{dacl:?}");
        assert_eq!(dacl.aces[0].sid.as_ref(), Some(&me));
        // The control: a folder made the ordinary way inherits from %TEMP%, unprotected.
        let plain = std::env::temp_dir().join(format!("antenna-sys-plain-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&plain);
        std::fs::create_dir(&plain).unwrap();
        let p = dir_facts(&plain).unwrap();
        let _ = std::fs::remove_dir_all(&plain);
        let dacl = p.security.dacl.unwrap();
        assert!(
            !dacl.protected && dacl.aces.iter().any(|a| a.flags & 0x10 != 0),
            "{dacl:?}"
        );
        eprintln!("FACT a plain %TEMP% folder: {dacl:?}");
    }
}
