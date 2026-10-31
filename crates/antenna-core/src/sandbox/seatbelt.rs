// SPDX-License-Identifier: AGPL-3.0-only
//! The agent's Seatbelt profile for wake (macOS, D-P-13), modeled on the Linux sandbox (D-71). The text is built on any
//! OS (the unit tests run on Linux too); stage 2 of the supervisor applies it on macOS
//! (`antenna_sys::seatbelt::apply`).
//!
//! | What | Allowed |
//! | --- | --- |
//! | reading files | system paths ([`antenna_files::seatbelt::system_read`]), the spec's `ro` paths, the agent program, `ro_binds` sources, its own run directories and `rw` |
//! | metadata (`stat`, `readlink`) | everywhere, like Landlock on Linux; contents and directory listings are not, except the root directory's own listing, which dyld needs to start a program ([`antenna_files::seatbelt::exec_support`], D-P-15) |
//! | writing | only `cwd`, `home`, `tmp`, `rw`, without nested read-only paths (`CLAUDE.md` in the folder, etc.) |
//! | network | only `localhost:<bridge port>` (the daemon's CONNECT proxy) and the spec's unix sockets (the daemon socket); no `bind` |
//! | processes | `fork`/`exec` (descendants inherit the profile); signals and process information only within its own sandbox |
//! | Mach | user information, `notify(3)`, TLS verification (`trustd`), the run mark; no keychains, preferences, pasteboard, DNS |
//! | sysctl | CPU and OS; no process list and no other processes' arguments |
//! | `/dev` | `null`, `zero`, randomness, its own `fd`; no terminal |

use std::path::{Path, PathBuf};

use antenna_files::seatbelt as sb;

use super::SandboxSpec;

/// Mach services beyond those common to all programs: TLS certificate chain verification (Security.framework). They do
/// not hand out keychain secrets: that needs `com.apple.SecurityServer`, which is not allowed.
const TLS_MACH: &[&str] = &["com.apple.trustd", "com.apple.trustd.agent"];

/// The agent profile. `proxy_port` is the bridge port on `127.0.0.1` (the supervisor opened it before applying the
/// profile); `mark` is this run's unique Mach service name: the profile allows it, and the supervisor and the daemon
/// use it to find the processes of exactly this sandbox (`sandbox_check`) once they have gone to launchd.
#[cfg_attr(
    not(target_os = "macos"),
    allow(
        dead_code,
        reason = "the profile text is unit-tested on every OS, used only on macOS"
    )
)]
pub(super) fn agent_profile(
    spec: &SandboxSpec,
    proxy_port: Option<u16>,
    mark: &str,
) -> Result<String, String> {
    let mut p = String::from(sb::HEADER);
    p.push_str(
        "; Antenna: agent on wake (D-P-13). Writes only to its own run directories, connections only through the\n\
         ; bridge to the daemon proxy, signals only within its own sandbox.\n",
    );
    // What dyld needs to start the agent and its programs at all (D-P-15).
    p.push_str(&sb::exec_support_here());
    // Processes: descendants inherit this profile; no signals to or information about other processes.
    p.push_str("(allow process-fork)\n(allow process-exec)\n");
    p.push_str(
        "(allow signal (target same-sandbox))\n(allow process-info* (target same-sandbox))\n",
    );
    p.push_str("(allow file-read-metadata)\n");

    let rw: Vec<&Path> = [&spec.cwd, &spec.home, &spec.tmp]
        .into_iter()
        .chain(&spec.rw)
        .map(PathBuf::as_path)
        .collect();
    let mut ro: Vec<PathBuf> = spec.ro.clone();
    ro.extend(super::common::program_paths(spec));
    ro.extend(spec.ro_binds.iter().map(|(s, _)| s.clone()));

    let mut read = sb::system_read();
    read.extend(sb::subpaths(ro.iter().map(PathBuf::as_path))?);
    read.extend(sb::subpaths(rw.iter().copied())?);
    p.push_str(&sb::allow("file-read*", &read));
    // Program libraries (dylibs) are mapped as executable.
    p.push_str(&sb::allow("file-map-executable", &read));

    // Writing: its own directories, without nested read-only paths (the link folder, `CLAUDE.md`, credentials).
    let mut write = Vec::new();
    for w in &rw {
        write.extend(sb::subpath_except(w, &ro)?);
    }
    p.push_str(&sb::allow("file-write* file-ioctl", &write));
    p.push_str(&sb::dev_rules());

    // Network: the spec's unix sockets (the daemon control socket) and the bridge to the proxy.
    let socks = sb::literals(spec.sockets.iter().map(PathBuf::as_path))?;
    p.push_str(&sb::allow("network-outbound", &socks));
    if let Some(port) = proxy_port {
        p.push_str(&format!(
            "(allow network-outbound (remote ip \"localhost:{port}\"))\n"
        ));
    }
    // The local model runtime (D-96 §3.4): it binds its one socket and accepts on it; there is no outbound rule for
    // it, since its spec has neither sockets nor a proxy. Unverified on a Mac until the runtime's first run there.
    if let Some(l) = &spec.listen {
        let lit = sb::literals(std::iter::once(l.as_path()))?;
        p.push_str(&sb::allow("network-bind network-inbound", &lit));
    }
    // Metal for the runtime: the GPU's IOKit user client and Metal's shader compiler service, the narrowest rules
    // known to let a Metal compute kernel run under Seatbelt (third-party, verified on an M4, design §13); to be
    // confirmed on a real Mac.
    if spec.gpu {
        p.push_str("(allow iokit-get-properties)\n");
        p.push_str("(allow iokit-open (iokit-user-client-class \"AGXDeviceUserClient\"))\n");
        p.push_str("(allow mach-lookup (global-name \"com.apple.MTLCompilerService\"))\n");
    }

    p.push_str(&sb::allow("sysctl-read", &sb::sysctl_filters(true)));
    let mut mach: Vec<String> = Vec::new();
    for n in sb::PROGRAM_MACH.iter().chain(TLS_MACH) {
        mach.push(format!("(global-name {})", sb::quote(n)?));
    }
    mach.push(format!("(global-name {})", sb::quote(mark)?));
    p.push_str(&sb::allow("mach-lookup", &mach));
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sandbox::{Limits, ProxyBridge, SandboxKind};

    fn balanced(p: &str) -> bool {
        let (mut depth, mut in_str, mut esc) = (0i32, false, false);
        for c in p.chars() {
            if in_str {
                match (esc, c) {
                    (true, _) => esc = false,
                    (false, '\\') => esc = true,
                    (false, '"') => in_str = false,
                    _ => {}
                }
                continue;
            }
            match c {
                '"' => in_str = true,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth < 0 {
                        return false;
                    }
                }
                _ => {}
            }
        }
        depth == 0 && !in_str
    }

    fn rule<'a>(p: &'a str, ops: &str) -> Vec<&'a str> {
        p.split("(allow ")
            .filter(|r| r.starts_with(&format!("{ops}\n")) || r.starts_with(&format!("{ops} (")))
            .collect()
    }

    #[test]
    fn agent_profile_follows_the_linux_model() {
        let t = tempfile::tempdir().unwrap();
        let base = t.path().canonicalize().unwrap();
        let mk = |p: &str| {
            let d = base.join(p);
            std::fs::create_dir_all(&d).unwrap();
            d
        };
        let (work, home, tmp, shared) = (
            mk("run/work"),
            mk("run/home"),
            mk("run/tmp"),
            mk("link/shared"),
        );
        let link = base.join("link");
        let claude_md = shared.join("CLAUDE.md");
        std::fs::write(&claude_md, "rules").unwrap();
        let cred = mk("owner/.claude").join(".credentials.json");
        std::fs::write(&cred, "{}").unwrap();
        let spec = SandboxSpec {
            argv: vec!["/bin/sh".into(), "-c".into(), "true".into()],
            env: vec![],
            cwd: work.clone(),
            home: home.clone(),
            tmp: tmp.clone(),
            rw: vec![shared.clone()],
            ro: vec![link.clone(), claude_md.clone()],
            ro_binds: vec![(cred.clone(), home.join(".claude/.credentials.json"))],
            sockets: vec![base.join("antennad.sock")],
            proxy: Some(ProxyBridge {
                unix: base.join("proxy.sock"),
                port: 0,
            }),
            limits: Limits::default(),
            kind: SandboxKind::Seatbelt,
            start_gate: false,
            agent_stdin: false,
            listen: None,
            gpu: false,
        };
        let mark = "io.github.danta-nort.antenna.wake.0123abcd";
        let p = agent_profile(&spec, Some(51234), mark).unwrap();
        // For the log: the whole profile (`--nocapture`).
        println!("{p}");
        assert!(p.starts_with(sb::HEADER), "{p}");
        assert!(balanced(&p), "{p}");
        // Writing is exactly one rule: its own directories and shared/, without the CLAUDE.md inside it.
        let w = rule(&p, "file-write* file-ioctl");
        assert_eq!(w.len(), 1, "{p}");
        let w = w[0];
        for d in [&work, &home, &tmp, &shared] {
            assert!(
                w.contains(&format!("(subpath \"{}\")", d.display())),
                "{d:?}\n{w}"
            );
        }
        assert!(
            w.contains(&format!(
                "(require-not (subpath \"{}\"))",
                claude_md.display()
            )),
            "{w}"
        );
        // The link folder (the parent of shared/) and credentials are not writable.
        assert!(
            !w.contains(&format!("(subpath \"{}\")", link.display())),
            "{w}"
        );
        assert!(!w.contains(".credentials.json"), "{w}");
        assert!(!w.contains("owner"), "{w}");
        // Reading credentials goes by the source.
        assert!(
            p.contains(&format!("(subpath \"{}\")", cred.display())),
            "{p}"
        );
        // Network: the bridge and the daemon socket, nothing else; the agent does not need the proxy socket.
        let net = rule(&p, "network-outbound");
        assert_eq!(net.len(), 2, "{p}");
        assert!(p.contains("(allow network-outbound (remote ip \"localhost:51234\"))"));
        assert!(net[0].contains("antennad.sock"), "{p}");
        assert!(!p.contains("proxy.sock"), "{p}");
        assert!(
            !p.contains("network-bind")
                && !p.contains("network-inbound")
                && !p.contains("network*")
        );
        // dyld gets the root directory itself, not everything under it.
        assert!(p.contains("(allow file-read* (literal \"/\"))"), "{p}");
        assert!(!p.contains("(subpath \"/\")"), "{p}");
        // Signals and Mach are narrow.
        assert!(p.contains("(allow signal (target same-sandbox))"));
        assert!(!p.contains("(allow signal)"));
        assert!(p.contains(&format!("(global-name \"{mark}\")")), "{p}");
        for denied in [
            "SecurityServer",
            "cfprefsd",
            "pasteboard",
            "mDNSResponder",
            "dnssd",
            "kern.proc",
            "kern.procargs",
            "(allow default",
            "/dev/tty",
            "user-preference",
            "iokit",
            "ipc-posix",
        ] {
            assert!(!p.contains(denied), "{denied} in\n{p}");
        }
    }

    #[test]
    fn the_runtime_profile_listens_on_one_socket_and_reaches_nothing() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().canonicalize().unwrap();
        let run = d.join("run");
        let model = d.join("models/m.gguf");
        let spec = SandboxSpec {
            argv: vec!["/bin/sh".into()],
            env: vec![],
            cwd: run.clone(),
            home: d.join("home"),
            tmp: d.join("tmp"),
            rw: vec![],
            ro: vec![model.clone(), d.join("llama")],
            ro_binds: vec![],
            sockets: vec![],
            proxy: None,
            limits: Limits::default(),
            kind: SandboxKind::Seatbelt,
            start_gate: false,
            agent_stdin: false,
            listen: Some(run.join("llm.sock")),
            gpu: true,
        };
        let p = agent_profile(&spec, None, "io.github.danta-nort.antenna.wake.x").unwrap();
        println!("{p}");
        assert!(balanced(&p), "{p}");
        let bind = rule(&p, "network-bind network-inbound");
        assert_eq!(bind.len(), 1, "{p}");
        assert!(bind[0].contains("llm.sock"), "{p}");
        assert!(!p.contains("network-outbound"), "{p}");
        // The model is read, never written.
        let w = rule(&p, "file-write* file-ioctl");
        assert!(
            !w.iter()
                .any(|r| r.contains("m.gguf") || r.contains("llama")),
            "{p}"
        );
        // Metal: exactly the GPU client and the compiler service, not every IOKit client or every Mach service.
        assert!(p.contains("(iokit-user-client-class \"AGXDeviceUserClient\")"));
        assert!(p.contains("(global-name \"com.apple.MTLCompilerService\")"));
        assert!(!p.contains("(allow iokit-open)\n") && !p.contains("(allow mach-lookup)\n"));
        // Without `gpu`, no IOKit at all.
        let mut cpu = spec.clone();
        cpu.gpu = false;
        let p = agent_profile(&cpu, None, "m").unwrap();
        assert!(
            !p.contains("iokit") && !p.contains("MTLCompilerService"),
            "{p}"
        );
    }

    #[test]
    fn no_proxy_means_no_network_rule_for_it() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().canonicalize().unwrap();
        let spec = SandboxSpec {
            argv: vec!["/bin/sh".into()],
            env: vec![],
            cwd: d.join("w"),
            home: d.join("h"),
            tmp: d.join("t"),
            rw: vec![],
            ro: vec![],
            ro_binds: vec![],
            sockets: vec![],
            proxy: None,
            limits: Limits::default(),
            kind: SandboxKind::Seatbelt,
            start_gate: false,
            agent_stdin: false,
            listen: None,
            gpu: false,
        };
        let p = agent_profile(&spec, None, "io.github.danta-nort.antenna.wake.x").unwrap();
        assert!(!p.contains("network"), "{p}");
        assert!(balanced(&p));
        // A path with a quote is escaped, one with a newline is refused.
        let mut s2 = spec.clone();
        s2.rw = vec![d.join("a\"b")];
        let p2 = agent_profile(&s2, None, "m").unwrap();
        assert!(p2.contains("a\\\"b"), "{p2}");
        let mut s3 = spec;
        s3.rw = vec![d.join("a\nb")];
        assert!(agent_profile(&s3, None, "m").is_err());
    }
}
