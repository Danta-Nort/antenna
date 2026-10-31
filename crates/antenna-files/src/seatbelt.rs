// SPDX-License-Identifier: AGPL-3.0-only
//! Seatbelt profiles (the macOS sandbox, SBPL language): the file check worker and the external antivirus (DECISIONS
//! D-P-12), plus the shared parts of the agent profile for wake (`antenna_core::sandbox`, D-P-13). The text is built on
//! any OS, so its unit tests run on Linux too; it is applied only on macOS (`antenna_sys::seatbelt::apply`,
//! `sandbox_init`).
//!
//! The rules everything rests on:
//! - **`(deny default)`**: everything not explicitly allowed below is denied: files, network, starting processes,
//!   signals, IPC (Mach, POSIX shm), sysctl, IOKit. An empty path list never turns into "allow everywhere": [`allow`]
//!   without filters writes no rule at all.
//! - **Paths are real.** The kernel matches the vnode path after resolving symlinks: `/var/folders/…` is
//!   `/private/var/folders/…`, `/tmp` is `/private/tmp`, `/etc` is `/private/etc`. Every caller path is given in two
//!   forms: as passed and after `canonicalize` ([`path_forms`]).
//! - **Strings are SBPL literals** with `\` and `"` escaped; control characters and non-UTF-8 paths are refused (fail
//!   closed rather than a rule with a hole).
//! - **A profile under which programs are started** (the antivirus, the agent) carries [`exec_support`]: what dyld
//!   needs before `main` (D-P-15).

use std::path::{Path, PathBuf};

/// The start of every profile: closed by default.
pub const HEADER: &str = "(version 1)\n(deny default)\n";

/// Apple's rules for starting a process under a sandbox profile (dyld and its loader, libignition), shipped with the OS
/// since the cryptex-based system volumes (macOS 13).
pub const DYLD_SUPPORT: &str = "/System/Library/Sandbox/Profiles/dyld-support.sb";

/// What every program started under a profile needs before `main` (D-P-15). dyld's loader (libignition) opens `/` to
/// use it as the root for `openat(2)` while it looks for the shared cache; without that the process aborts inside dyld
/// (`SIGABRT`, termination namespace DYLD), before its first instruction and with no denial in the sandbox log (found
/// on macOS 26). Apple's own [`DYLD_SUPPORT`] is imported when `import` is set: Apple keeps it in step with what dyld
/// needs (cryptex graft points, file-control commands, system calls), and it allows no writes, connections, signals or
/// Mach services. The known rule is written out as well, so the profile does not depend on that file: reading the root
/// directory itself (`literal`, not `subpath`), which shows the names of the top-level directories and nothing below
/// them.
pub fn exec_support(import: bool) -> String {
    let mut p = String::new();
    if import {
        p.push_str("(import \"dyld-support.sb\")\n");
    }
    p.push_str("(allow file-read* (literal \"/\"))\n");
    p
}

/// [`exec_support`] for this system: the import if the system has [`DYLD_SUPPORT`].
pub fn exec_support_here() -> String {
    exec_support(Path::new(DYLD_SUPPORT).is_file())
}

/// System paths for the check worker (after isolation it loads nothing; this covers lazy library loading): libraries
/// and the dyld cache. No secrets here.
pub const WORKER_SYSTEM_READ: &[&str] = &[
    "/usr/lib",
    "/System/Library",
    "/System/Volumes/Preboot/Cryptexes",
    "/System/Cryptexes",
    "/private/var/db/dyld",
];

/// Read-only system paths for programs (agent, antivirus): programs, libraries, frameworks, the dyld cache, the
/// `/bin/sh` selection (`/private/var/select`), time zones, developer tools. No user data here; Homebrew data (`var/`,
/// `etc/`: databases, service configs) is excluded, see [`system_read`].
pub const SYSTEM_READ: &[&str] = &[
    "/bin",
    "/sbin",
    "/System",
    "/Library/Apple",
    "/Library/Frameworks",
    "/Library/Developer/CommandLineTools",
    "/Applications/Xcode.app",
    "/private/var/select",
    "/private/var/db/timezone",
    "/private/var/db/dyld",
    "/private/var/db/xcode_select_link",
];

/// Program directories with data next to them: read everything except `var/` (Homebrew service databases: PostgreSQL,
/// Redis…) and `etc/` (their configs, which may contain passwords); from `etc/` only the root certificates.
const PREFIXES_WITH_DATA: &[&str] = &["/usr", "/opt/homebrew", "/opt/local"];

/// A selection from `/etc` (`/private/etc` on macOS), like `ETC_ALLOW` of the Linux sandbox: not the whole directory.
pub const ETC_READ: &[&str] = &[
    "/private/etc/hosts",
    "/private/etc/passwd",
    "/private/etc/group",
    "/private/etc/shells",
    "/private/etc/protocols",
    "/private/etc/services",
    "/private/etc/localtime",
    "/private/etc/ssl/cert.pem",
    "/private/etc/ssl/certs",
    "/private/etc/ssl/openssl.cnf",
    "/private/etc/zshrc",
    "/private/etc/zprofile",
    "/private/etc/bashrc",
    "/private/etc/profile",
    "/private/etc/paths",
    "/private/etc/paths.d",
];

/// sysctl names needed by libc, std and runtimes (CPU count, page size, OS version, CPU features). Not allowed:
/// `kern.proc*` (process list), `kern.procargs*` (arguments and environment of other processes of the same user, which
/// may contain agent tokens).
const SYSCTL_NAMES: &[&str] = &[
    "hw.pagesize",
    "hw.pagesize_compat",
    "hw.ncpu",
    "hw.activecpu",
    "hw.logicalcpu",
    "hw.logicalcpu_max",
    "hw.physicalcpu",
    "hw.physicalcpu_max",
    "hw.cachelinesize",
    "hw.cachelinesize_compat",
    "hw.l1dcachesize",
    "hw.l1icachesize",
    "hw.l2cachesize",
    "hw.l3cachesize",
    "hw.memsize",
    "hw.machine",
    "hw.model",
    "hw.cputype",
    "hw.cpusubtype",
    "hw.cpufamily",
    "hw.cpufrequency",
    "hw.byteorder",
    "hw.vectorunit",
    "hw.tbfrequency",
    "kern.osrelease",
    "kern.ostype",
    "kern.osversion",
    "kern.osproductversion",
    "kern.version",
];
const SYSCTL_PREFIXES: &[&str] = &["hw.optional.", "hw.perflevel"];

/// Additionally for programs (agent, antivirus): what libuv/Node, bash, coreutils ask for. `kern.hostname` is the
/// machine name (without it `os.hostname()` in Node throws); it has no network meaning, since the network goes only to
/// the provider.
const PROGRAM_SYSCTL_NAMES: &[&str] = &[
    "kern.argmax",
    "kern.boottime",
    "kern.hostname",
    "kern.maxfiles",
    "kern.maxfilesperproc",
    "kern.maxproc",
    "kern.ngroups",
    "kern.osvariant_status",
    "kern.secure_kernel",
    "kern.usrstack64",
    "kern.safeboot",
    "sysctl.proc_cputype",
    "vm.loadavg",
];

/// Mach services that ordinary programs need and that give no access to the owner's data: user and group information
/// (`getpwuid`, `getgrouplist`), libc notifications (`notify(3)`: time zone change and the like). Not allowed, among
/// others: the keychain (`com.apple.SecurityServer`), preferences (`cfprefsd`), the clipboard, DNS (`mDNSResponder`:
/// the daemon's proxy resolves names), LaunchServices, the system log.
pub const PROGRAM_MACH: &[&str] = &[
    "com.apple.system.opendirectoryd.libinfo",
    "com.apple.system.opendirectoryd.membership",
    "com.apple.system.notification_center",
];

/// SBPL literal: `"…"` with `\` and `"` escaped. Control characters are refused.
pub fn quote(s: &str) -> Result<String, String> {
    if s.chars().any(char::is_control) {
        return Err(format!("sandbox profile: control character in {s:?}"));
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Ok(out)
}

/// Path forms for rules: as passed (if absolute) and real (`canonicalize`; for a missing path, the real parent plus the
/// name). Duplicates removed.
pub fn path_forms(p: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    if p.is_absolute() {
        v.push(p.to_path_buf());
    }
    let real = std::fs::canonicalize(p).ok().or_else(|| {
        let parent = std::fs::canonicalize(p.parent()?).ok()?;
        Some(parent.join(p.file_name()?))
    });
    if let Some(r) = real
        && !v.contains(&r)
    {
        v.push(r);
    }
    v
}

fn filter(kind: &str, p: &Path) -> Result<String, String> {
    let s = p
        .to_str()
        .ok_or_else(|| format!("sandbox profile: path is not UTF-8: {}", p.display()))?;
    Ok(format!("({kind} {})", quote(s)?))
}

/// `(subpath "…")`, the path and everything under it, for every form of every path.
pub fn subpaths<'a>(paths: impl IntoIterator<Item = &'a Path>) -> Result<Vec<String>, String> {
    let mut v = Vec::new();
    for p in paths {
        for f in path_forms(p) {
            v.push(filter("subpath", &f)?);
        }
    }
    Ok(v)
}

/// `(literal "…")`, exactly this path, for every form of every path.
pub fn literals<'a>(paths: impl IntoIterator<Item = &'a Path>) -> Result<Vec<String>, String> {
    let mut v = Vec::new();
    for p in paths {
        for f in path_forms(p) {
            v.push(filter("literal", &f)?);
        }
    }
    Ok(v)
}

/// `(subpath W)` minus the nested `except` paths (their forms too): `(require-all (subpath W) (require-not (subpath
/// E))…)`. This keeps "read only" inside a writable directory regardless of rule order.
pub fn subpath_except(w: &Path, except: &[PathBuf]) -> Result<Vec<String>, String> {
    let excepts: Vec<PathBuf> = except.iter().flat_map(|e| path_forms(e)).collect();
    let mut v = Vec::new();
    for f in path_forms(w) {
        let base = filter("subpath", &f)?;
        // An exception is needed only for what lies inside W (outside W the rule allows nothing anyway).
        let mut nots = Vec::new();
        for e in excepts.iter().filter(|e| e.starts_with(&f)) {
            nots.push(format!("(require-not {})", filter("subpath", e)?));
        }
        nots.dedup();
        if nots.is_empty() {
            v.push(base);
        } else {
            v.push(format!("(require-all {base} {})", nots.join(" ")));
        }
    }
    Ok(v)
}

/// Rule `(allow <ops> <filter>…)` (duplicate filters removed). Without filters, an empty string: a rule without
/// filters would allow the operations everywhere.
pub fn allow(ops: &str, filters: &[String]) -> String {
    let mut seen = std::collections::HashSet::new();
    let uniq: Vec<&str> = filters
        .iter()
        .map(String::as_str)
        .filter(|f| seen.insert(*f))
        .collect();
    if uniq.is_empty() {
        return String::new();
    }
    format!("(allow {ops}\n  {})\n", uniq.join("\n  "))
}

/// Read-only system paths for programs ([`SYSTEM_READ`], program directories without `var/` and `etc/`, [`ETC_READ`]).
pub fn system_read() -> Vec<String> {
    let q = |s: &str| quote(s).expect("constant path");
    // `subpath` also matches the path itself, so it works for files too.
    let mut v: Vec<String> = SYSTEM_READ
        .iter()
        .chain(ETC_READ)
        .map(|p| format!("(subpath {})", q(p)))
        .collect();
    for pre in PREFIXES_WITH_DATA {
        let local = if *pre == "/usr" { "/usr/local" } else { pre };
        v.push(format!(
            "(require-all (subpath {}) (require-not (subpath {})) (require-not (subpath {})))",
            q(pre),
            q(&format!("{local}/var")),
            q(&format!("{local}/etc")),
        ));
        for ca in [
            "etc/ca-certificates",
            "etc/openssl@3/cert.pem",
            "etc/openssl@3/certs",
            "etc/openssl@3/openssl.cnf",
            "etc/openssl/cert.pem",
        ] {
            v.push(format!("(subpath {})", q(&format!("{local}/{ca}"))));
        }
    }
    v
}

/// `sysctl-read` filters: common to all; `programs` adds what ordinary programs ask for.
pub fn sysctl_filters(programs: bool) -> Vec<String> {
    let q = |s: &str| quote(s).expect("constant name");
    let names = SYSCTL_NAMES
        .iter()
        .chain(if programs { PROGRAM_SYSCTL_NAMES } else { &[] });
    names
        .map(|n| format!("(sysctl-name {})", q(n)))
        .chain(
            SYSCTL_PREFIXES
                .iter()
                .map(|p| format!("(sysctl-name-prefix {})", q(p))),
        )
        .collect()
}

/// Devices for programs: `/dev/null` and `/dev/zero` (read and write), randomness sources (read), own descriptors
/// (`/dev/fd`). No terminal (`/dev/tty`): a program cannot reach the owner's terminal (TIOCSTI).
pub fn dev_rules() -> String {
    let mut p = String::new();
    p.push_str(
        "(allow file-read* file-write-data file-ioctl\n  (literal \"/dev/null\")\n  (literal \"/dev/zero\"))\n",
    );
    p.push_str(
        "(allow file-read*\n  (literal \"/dev/random\")\n  (literal \"/dev/urandom\")\n  (literal \"/dev/dtracehelper\"))\n",
    );
    p.push_str("(allow file-read* file-write*\n  (subpath \"/dev/fd\"))\n");
    p
}

/// File check worker profile (D-P-12): after it is applied the worker reads only stdin and writes only stdout/stderr
/// (pipes opened by the daemon). Denied: files (except reading system libraries and its own binary), writing anywhere,
/// network (TCP/UDP/unix, including `bind`), starting programs and `fork`, signals to other processes, Mach services,
/// POSIX IPC, sysctl except CPU and OS information.
pub fn worker_profile(exe: &Path) -> Result<String, String> {
    let mut p = String::from(HEADER);
    p.push_str(
        "; antenna-files: file check worker (DECISIONS D-P-12). File content comes only from stdin, the report\n\
         ; goes only to stdout; no files, processes or IPC; offline.\n",
    );
    let mut read = subpaths(WORKER_SYSTEM_READ.iter().map(Path::new))?;
    read.extend(literals([exe])?);
    p.push_str(&allow("file-read*", &read));
    p.push_str(&allow("sysctl-read", &sysctl_filters(false)));
    // abort() on out of memory and panic sends a signal to itself; information only about itself (it is alone in its
    // sandbox).
    p.push_str("(allow signal (target self))\n(allow process-info* (target same-sandbox))\n");
    Ok(p)
}

/// External antivirus profile (`av-exec`, D-P-12): the program and its directories (`ro`) and system paths: read and
/// execute; write only to the check's temporary directory `rw`; no network; signals only to its own processes (the same
/// sandbox).
pub fn av_exec_profile(ro: &[PathBuf], rw: &Path, program: &Path) -> Result<String, String> {
    let mut p = String::from(HEADER);
    p.push_str(
        "; antenna-files av-exec: external antivirus (DECISIONS D-P-12), offline, writes only to the check directory.\n",
    );
    p.push_str(&exec_support_here());
    let mut read = system_read();
    read.extend(subpaths(ro.iter().map(PathBuf::as_path))?);
    read.extend(literals([program])?);
    let mut exec = read.clone();
    read.extend(subpaths([rw])?);
    p.push_str(&allow("file-read*", &read));
    p.push_str(&allow("file-map-executable", &exec));
    exec.retain(|f| !f.contains("/private/etc/"));
    p.push_str(&allow("process-exec", &exec));
    p.push_str("(allow process-fork)\n(allow file-read-metadata)\n");
    p.push_str(&allow("file-write* file-ioctl", &subpaths([rw])?));
    p.push_str(&dev_rules());
    p.push_str(
        "(allow signal (target same-sandbox))\n(allow process-info* (target same-sandbox))\n",
    );
    p.push_str(&allow("sysctl-read", &sysctl_filters(true)));
    p.push_str(&allow(
        "mach-lookup",
        &PROGRAM_MACH
            .iter()
            .map(|n| format!("(global-name {})", quote(n).expect("constant")))
            .collect::<Vec<_>>(),
    ));
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Parentheses are balanced outside strings: the profile at least parses (real compilation happens in CI on macOS).
    pub(crate) fn balanced(p: &str) -> bool {
        let (mut depth, mut in_str, mut esc) = (0i32, false, false);
        for c in p.chars() {
            match (in_str, esc, c) {
                (true, true, _) => esc = false,
                (true, false, '\\') => esc = true,
                (true, false, '"') => in_str = false,
                (true, false, _) => {}
                (false, _, '"') => in_str = true,
                (false, _, '(') => depth += 1,
                (false, _, ')') => {
                    depth -= 1;
                    if depth < 0 {
                        return false;
                    }
                }
                (false, _, ';') => {}
                _ => {}
            }
        }
        depth == 0 && !in_str
    }

    #[test]
    fn quoting_escapes_and_refuses_control_characters() {
        assert_eq!(quote(r#"/a "b"\c"#).unwrap(), r#""/a \"b\"\\c""#);
        assert_eq!(quote("/Users/Zoë").unwrap(), "\"/Users/Zoë\"");
        assert!(quote("/a\nb").is_err());
        assert!(quote("/a\u{7f}").is_err());
    }

    #[test]
    fn empty_filters_never_allow_everything() {
        assert_eq!(allow("file-write*", &[]), "");
        assert!(
            allow("file-write*", &["(subpath \"/x\")".into()]).starts_with("(allow file-write*")
        );
    }

    // Seatbelt profiles hold unix paths (macOS, checked on Linux too); Windows paths never go into one.
    #[cfg(unix)]
    #[test]
    fn paths_come_in_given_and_real_forms() {
        let t = tempfile::tempdir().unwrap();
        let real = t.path().canonicalize().unwrap();
        let link = t.path().join("link");
        std::fs::create_dir(real.join("dir")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(real.join("dir"), &link).unwrap();
        let f = path_forms(&link);
        assert_eq!(f[0], link);
        assert_eq!(f.last().unwrap(), &real.join("dir"));
        // A missing file: the real parent + the name.
        let missing = link.join("new.txt");
        assert_eq!(
            path_forms(&missing).last().unwrap(),
            &real.join("dir").join("new.txt")
        );
        // A relative path itself does not go into the rules.
        assert!(path_forms(Path::new("rel")).iter().all(|p| p.is_absolute()));
    }

    // Seatbelt profiles hold unix paths (macOS, checked on Linux too); Windows paths never go into one.
    #[cfg(unix)]
    #[test]
    fn worker_profile_is_closed_and_balanced() {
        let p = worker_profile(Path::new("/opt/antenna/antennad")).unwrap();
        assert!(p.starts_with(HEADER), "{p}");
        assert!(balanced(&p), "{p}");
        for forbidden in [
            "network",
            "process-exec",
            "process-fork",
            "file-write",
            "mach-lookup",
            "(allow default",
            "kern.proc",
            "(allow file-read*)",
        ] {
            assert!(!p.contains(forbidden), "{forbidden} in\n{p}");
        }
        assert!(p.contains("(literal \"/opt/antenna/antennad\")"), "{p}");
        assert!(p.contains("(allow signal (target self))"), "{p}");
        // The worker isolates itself after dyld has run, so it does not get the root directory: its probe lists `/`.
        assert!(
            !p.contains("(literal \"/\")") && !p.contains("dyld-support"),
            "{p}"
        );
    }

    #[test]
    fn programs_get_what_dyld_needs_and_nothing_wider() {
        let explicit = exec_support(false);
        assert_eq!(explicit, "(allow file-read* (literal \"/\"))\n");
        let imported = exec_support(true);
        assert!(
            imported.starts_with("(import \"dyld-support.sb\")\n"),
            "{imported}"
        );
        assert!(imported.ends_with(&explicit), "{imported}");
        assert!(balanced(&imported));
        // Only the root directory itself, never everything under it.
        assert!(!imported.contains("(subpath \"/\")"), "{imported}");
        let t = tempfile::tempdir().unwrap();
        let p = av_exec_profile(&[], t.path(), Path::new("/usr/bin/true")).unwrap();
        assert_eq!(p.matches("(literal \"/\")").count(), 1, "{p}");
        assert_eq!(
            p.contains("dyld-support"),
            Path::new(DYLD_SUPPORT).is_file(),
            "{p}"
        );
    }

    // Seatbelt profiles hold unix paths (macOS, checked on Linux too); Windows paths never go into one.
    #[cfg(unix)]
    #[test]
    fn av_profile_writes_only_to_its_scratch() {
        let t = tempfile::tempdir().unwrap();
        let rw = t.path().join("scratch");
        std::fs::create_dir(&rw).unwrap();
        let p = av_exec_profile(
            &[PathBuf::from("/opt/homebrew/Cellar/clamav")],
            &rw,
            Path::new("/opt/homebrew/bin/clamscan"),
        )
        .unwrap();
        assert!(balanced(&p), "{p}");
        assert!(!p.contains("network"), "{p}");
        let writes: Vec<&str> = p
            .split("(allow ")
            .filter(|r| r.starts_with("file-write* file-ioctl"))
            .collect();
        assert_eq!(writes.len(), 1, "{p}");
        let real = rw.canonicalize().unwrap();
        assert!(writes[0].contains(&*real.to_string_lossy()), "{p}");
        assert!(!writes[0].contains("homebrew"), "{p}");
        // Homebrew service data is not readable.
        assert!(
            p.contains("(require-not (subpath \"/opt/homebrew/var\"))"),
            "{p}"
        );
        assert!(
            p.contains("(require-not (subpath \"/usr/local/etc\"))"),
            "{p}"
        );
    }

    // Seatbelt profiles hold unix paths (macOS, checked on Linux too); Windows paths never go into one.
    #[cfg(unix)]
    #[test]
    fn read_only_inside_writable_is_carved_out() {
        let t = tempfile::tempdir().unwrap();
        let w = t.path().join("work");
        let ro = w.join("CLAUDE.md");
        std::fs::create_dir(&w).unwrap();
        std::fs::write(&ro, "x").unwrap();
        let f = subpath_except(&w, &[ro.clone(), PathBuf::from("/elsewhere/x")]).unwrap();
        let real = w.canonicalize().unwrap();
        let last = f.last().unwrap();
        assert!(last.starts_with("(require-all (subpath"), "{f:?}");
        assert!(
            last.contains(&format!(
                "(require-not (subpath \"{}\"))",
                real.join("CLAUDE.md").display()
            )),
            "{f:?}"
        );
        assert!(!last.contains("elsewhere"), "{f:?}");
        assert!(f.iter().all(|x| balanced(x)), "{f:?}");
    }
}
