// SPDX-License-Identifier: AGPL-3.0-only
//! Shared harness of the integration tests: real `antennad` processes (one per node, each with its own data dir) and
//! the real `antenna` CLI. The `antennad` binary is taken from next to `antenna` (the same target directory): `cargo
//! test` from the workspace root builds both (the `antennad` package has its own integration tests).

#![allow(
    dead_code,
    reason = "shared by several test binaries, each uses a part"
)]

use std::{
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Output, Stdio},
    sync::{
        Arc, Mutex, PoisonError,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

use serde_json::Value;

/// Variables that point the CLI at a daemon or make it an agent. A test run inside an agent's session (the window's Code
/// mode gives the agent `ANTENNA_AGENT_TOKEN`, and an agent CLI may get `ANTENNA_SOCKET`) would otherwise run every
/// command as that agent, or against the owner's real daemon instead of the test's (`--socket`/`ANTENNA_SOCKET` wins
/// over `--data-dir`). Every process a test starts drops them first (TROUBLESHOOTING "macOS 27 on a real Mac").
pub const SESSION_ENV: &[&str] = &[
    "ANTENNA_DATA_DIR",
    "X_DATA_DIR",
    "ANTENNA_SOCKET",
    "X_SOCKET",
    "ANTENNA_LINKS_DIR",
    "X_LINKS_DIR",
    "ANTENNA_AGENT_TOKEN",
    "ANTENNA_AGENT_TOKEN_FILE",
    "X_AGENT_TOKEN",
];

/// [`SESSION_ENV`] removed from a command (variables set after this call stay).
pub trait CleanEnv {
    /// Drop the inherited daemon and agent variables.
    fn clean_env(&mut self) -> &mut Self;
}

impl CleanEnv for Command {
    fn clean_env(&mut self) -> &mut Self {
        for k in SESSION_ENV {
            self.env_remove(k);
        }
        self
    }
}

pub fn x_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_antenna"))
}

/// A program that exits 0 and exists on every supported OS: `/usr/bin/true` (macOS has no `/bin/true`; on Linux with a
/// merged `/usr` both exist), `/bin/true` where `/usr` is not merged.
pub fn true_bin() -> &'static str {
    if Path::new("/usr/bin/true").exists() {
        "/usr/bin/true"
    } else {
        "/bin/true"
    }
}

pub fn xd_bin() -> PathBuf {
    let p = x_bin().with_file_name("antennad");
    assert!(
        p.exists(),
        "antennad binary not found at {} — run `cargo test` from the workspace root (or `cargo build -p antennad` first)",
        p.display()
    );
    p
}

/// Network mode of the test nodes.
#[derive(Clone, Debug, PartialEq)]
pub enum Net {
    /// No relay, 127.0.0.1 only (fast tests).
    Local,
    /// Public n0 relays (tests with #[ignore]).
    RelayN0,
    /// The test's local HTTP relay ([`LocalRelay`]) + direct 127.0.0.1 addresses.
    LocalRelay(String),
}

/// A local iroh relay (HTTP, no TLS) on a separate test thread: levels 1–2 work only through a relay.
pub struct LocalRelay {
    pub url: String,
    _stop: Option<std::sync::mpsc::Sender<()>>,
}

impl LocalRelay {
    pub fn start() -> Self {
        let (url_tx, url_rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                let mut cfg = iroh_relay::server::ServerConfig::default();
                cfg.relay = Some(iroh_relay::server::RelayConfig::new(
                    "127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap(),
                ));
                let server = iroh_relay::server::Server::spawn(cfg).await.unwrap();
                let addr = server.http_addr().unwrap();
                url_tx.send(format!("http://{addr}")).unwrap();
                let _ = tokio::task::spawn_blocking(move || stop_rx.recv()).await;
                let _ = server.shutdown().await;
            });
        });
        let url = url_rx
            .recv_timeout(Duration::from_secs(20))
            .expect("local relay");
        Self {
            url,
            _stop: Some(stop_tx),
        }
    }
}

pub struct Node {
    pub name: String,
    pub dir: PathBuf,
    pub net: Net,
    child: Option<Child>,
    /// The per-test watchdog of this node ([`Watchdog`]).
    watchdog: Watchdog,
    pub password: String,
    /// Run `antennad --allow-auto-confirm` (a test-only flag, needed for `antenna invite --confirm`).
    pub allow_auto_confirm: bool,
    /// Run `antennad` with an inherited open descriptor 9 without CLOEXEC (as when started from the Flutter window).
    pub leak_fd: bool,
    /// Link folders instead of `<dir>.links`.
    pub links_dir: Option<PathBuf>,
    /// Run `antennad` "as a user would": with this `$HOME`, without `--data-dir` and `--links-dir` (default directories
    /// and migration from the preview build `x`); `dir` must then be `<home>/.local/share/antenna`.
    pub home: Option<PathBuf>,
    /// Extra `antennad` arguments (e.g. the test-only `--wake-landlock-only`).
    pub extra_args: Vec<String>,
    /// Extra `antennad` environment variables.
    pub extra_env: Vec<(String, String)>,
    /// Directory with other `antennad`/`antenna` binaries (an older-version node in the compatibility test).
    pub bin_dir: Option<PathBuf>,
}

impl Node {
    pub fn new(root: &Path, name: &str, net: Net) -> Self {
        Self {
            name: name.into(),
            dir: root.join(name),
            net,
            child: None,
            watchdog: Watchdog::start(name, &root.join(name).with_extension("log")),
            password: format!("password-of-{name}-123"),
            allow_auto_confirm: true,
            leak_fd: false,
            links_dir: None,
            home: None,
            extra_args: Vec::new(),
            extra_env: Vec::new(),
            bin_dir: None,
        }
    }

    /// The node's link folders (`--links-dir`): `<contact>/inbox`, `<contact>/shared`.
    pub fn links(&self) -> PathBuf {
        self.links_dir
            .clone()
            .unwrap_or_else(|| self.dir.with_extension("links"))
    }

    pub fn start(&mut self) {
        assert!(self.child.is_none());
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.with_extension("log"))
            .unwrap();
        let mut cmd = if self.leak_fd {
            // sh opens fd 9 (without CLOEXEC) and execs antennad: same PID, the descriptor is inherited.
            let mut c = Command::new("sh");
            c.arg("-c")
                .arg(r#"exec 9<"$0"; exec "$0" "$@""#)
                .arg(xd_bin());
            c
        } else {
            Command::new(
                self.bin_dir
                    .as_ref()
                    .map_or_else(xd_bin, |d| d.join("antennad")),
            )
        };
        cmd.clean_env();
        match &self.home {
            Some(home) => {
                cmd.env("HOME", home).env_remove("XDG_DATA_HOME");
            }
            None => {
                cmd.arg("--data-dir")
                    .arg(&self.dir)
                    .arg("--links-dir")
                    .arg(self.links());
            }
        }
        cmd.args(["--retry-max-ms", "1000", "--dial-timeout-ms", "3000"])
            .env("ANTENNAD_LOG", "warn,antenna_core=debug,antennad=info")
            .stdout(Stdio::null())
            .stderr(log);
        if self.allow_auto_confirm {
            cmd.arg("--allow-auto-confirm");
        }
        cmd.args(&self.extra_args);
        cmd.envs(self.extra_env.iter().map(|(k, v)| (k, v)));
        match &self.net {
            Net::Local => {
                cmd.args(["--relay", "disabled", "--bind-ip", "127.0.0.1"]);
            }
            Net::RelayN0 => {
                cmd.args(["--relay", "n0"]);
            }
            Net::LocalRelay(url) => {
                cmd.args(["--relay", url, "--bind-ip", "127.0.0.1"]);
            }
        }
        let child = cmd.spawn().expect("spawn antennad");
        let sock = self.dir.join("antennad.sock");
        let t = Instant::now();
        while !sock.exists() {
            assert!(
                t.elapsed() < Duration::from_secs(30),
                "antennad {} did not start",
                self.name
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        self.watchdog.set_pid(Some(child.id()));
        self.child = Some(child);
    }

    /// Graceful stop (SIGTERM): the daemon closes its endpoints and removes the socket.
    pub fn stop(&mut self) {
        self.watchdog.set_pid(None);
        if let Some(mut c) = self.child.take() {
            let pid = rustix::process::Pid::from_raw(c.id() as i32).unwrap();
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::TERM);
            let t = Instant::now();
            loop {
                if c.try_wait().unwrap().is_some() {
                    break;
                }
                if t.elapsed() > Duration::from_secs(15) {
                    let _ = c.kill();
                    let _ = c.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }

    /// A crash (SIGKILL, by PID): the daemon cleans nothing up; its child processes are ended by their own lifelines.
    pub fn kill(&mut self) {
        self.watchdog.set_pid(None);
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    pub fn cmd(&self) -> Command {
        let mut c = Command::new(
            self.bin_dir
                .as_ref()
                .map_or_else(x_bin, |d| d.join("antenna")),
        );
        c.clean_env().arg("--data-dir").arg(&self.dir);
        c
    }

    pub fn x(&self, args: &[&str]) -> Output {
        self.cmd().args(args).output().expect("run x")
    }

    pub fn x_stdin(&self, args: &[&str], input: &str) -> Output {
        let mut c = self
            .cmd()
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // The CLI may exit before it reads its input (an error it reports on stderr): then the write fails with
        // EPIPE. The caller's check of the output says what went wrong; a panic here would hide it.
        if let Err(e) = c.stdin.take().unwrap().write_all(input.as_bytes()) {
            assert_eq!(
                e.kind(),
                std::io::ErrorKind::BrokenPipe,
                "writing to antenna {args:?}: {e}"
            );
        }
        c.wait_with_output().unwrap()
    }

    /// `antenna --json <args>`: a successful JSON reply (panics with the output on error).
    pub fn json(&self, args: &[&str]) -> Value {
        let mut a = vec!["--json"];
        a.extend_from_slice(args);
        let out = self.x(&a);
        assert!(
            out.status.success(),
            "{} antenna {:?}: {:?}",
            self.name,
            args,
            out
        );
        last_json(&out.stdout)
    }

    pub fn init(&self) {
        let out = self.x_stdin(
            &["init", "--password-stdin"],
            &format!("{}\n", self.password),
        );
        assert!(out.status.success(), "init {}: {:?}", self.name, out);
        self.login();
    }

    pub fn unlock(&self) {
        let out = self.x_stdin(
            &["unlock", "--password-stdin"],
            &format!("{}\n", self.password),
        );
        assert!(out.status.success(), "unlock {}: {:?}", self.name, out);
        self.login();
    }

    /// Owner session (Q-14b) for the `antenna` processes this test starts: without a terminal the session is bound to
    /// the parent, the test process, for 15 minutes after the last command.
    pub fn login(&self) {
        let out = self.x_stdin(
            &["--json", "login", "--password-stdin"],
            &format!("{}\n", self.password),
        );
        assert!(out.status.success(), "login {}: {:?}", self.name, out);
    }

    /// An owner session held by a connection (like the window): a token for `hello.session` of this process's
    /// connections.
    pub fn held_session(&self) -> Held {
        let mut s =
            std::os::unix::net::UnixStream::connect(self.dir.join("antennad.sock")).unwrap();
        let hello = serde_json::json!({"hello": {"proto": "x-control/3", "role": "owner"}});
        let req =
            serde_json::json!({"req": {"cmd": "login", "password": self.password, "hold": true}});
        s.write_all(format!("{hello}\n{req}\n").as_bytes()).unwrap();
        let mut r = BufReader::new(s.try_clone().unwrap());
        let mut token = None;
        for _ in 0..3 {
            let mut l = String::new();
            r.read_line(&mut l).unwrap();
            let v: Value = serde_json::from_str(&l).unwrap();
            if v["event"]["kind"] == "session" {
                token = v["event"]["token"].as_str().map(str::to_string);
                break;
            }
            assert!(v.get("err").is_none(), "held login: {v}");
        }
        Held {
            _s: s,
            token: token.expect("session token"),
        }
    }

    pub fn contacts(&self) -> Vec<Value> {
        self.json(&["contacts"])["contacts"]
            .as_array()
            .unwrap()
            .clone()
    }

    pub fn contact(&self, label: &str) -> Value {
        self.contacts()
            .into_iter()
            .find(|c| c["label"] == label)
            .unwrap_or_else(|| panic!("{}: no contact {label}", self.name))
    }

    pub fn send(&self, to: &str, text: &str) -> Value {
        self.json(&["send", to, text])
    }

    /// The owner writes to one agent of the contact (v6, CONTROL §20): only that agent of the contact's node reads it.
    pub fn send_to_agent(&self, to: &str, agent: &str, text: &str) -> Value {
        self.json(&["send", "--to-agent", agent, to, text])
    }

    /// The owner writes to everyone on the contact's side (v6): the contact's agents that may read such messages too.
    pub fn send_to_everyone(&self, to: &str, text: &str) -> Value {
        self.json(&["send", "--to", "everyone", to, text])
    }

    pub fn inbox(&self) -> Vec<Value> {
        self.json(&["inbox"])["messages"]
            .as_array()
            .unwrap()
            .clone()
    }

    pub fn inbox_wait(&self, secs: u64) -> Vec<Value> {
        self.json(&["inbox", "--wait", "--timeout", &format!("{secs}s")])["messages"]
            .as_array()
            .unwrap()
            .clone()
    }

    pub fn log(&self) -> String {
        std::fs::read_to_string(self.dir.with_extension("log")).unwrap_or_default()
    }

    /// An owner command with the password (`--password-stdin`).
    pub fn owner(&self, args: &[&str]) -> Output {
        let mut a = vec!["--json"];
        a.extend_from_slice(args);
        a.push("--password-stdin");
        self.x_stdin(&a, &format!("{}\n", self.password))
    }

    /// An owner command with the password: a successful JSON reply.
    pub fn owner_json(&self, args: &[&str]) -> Value {
        let out = self.owner(args);
        assert!(
            out.status.success(),
            "{} antenna {:?}: {:?}",
            self.name,
            args,
            out
        );
        last_json(&out.stdout)
    }

    /// `antenna agent add <name>` → token.
    pub fn agent_add(&self, name: &str, extra: &[&str]) -> String {
        let mut a = vec!["agent", "add", name];
        a.extend_from_slice(extra);
        let v = self.owner_json(&a);
        assert_eq!(v["type"], "agent_added", "{v}");
        let t = v["token"].as_str().unwrap().to_string();
        assert!(t.starts_with("xat_"), "{t}");
        t
    }

    /// Agent CLI with a token.
    pub fn agent_cmd(&self, token: &str) -> Command {
        let mut c = self.cmd();
        c.env("ANTENNA_AGENT_TOKEN", token);
        c
    }

    /// `antenna --json <args>` as the agent: (exit code, last JSON).
    pub fn agent(&self, token: &str, args: &[&str]) -> (i32, Value) {
        let mut a = vec!["--json"];
        a.extend_from_slice(args);
        let out = self.agent_cmd(token).args(&a).output().expect("run x");
        (out.status.code().unwrap_or(-1), last_json(&out.stdout))
    }

    /// A successful agent command.
    pub fn agent_ok(&self, token: &str, args: &[&str]) -> Value {
        let (c, v) = self.agent(token, args);
        assert_eq!(c, 0, "{} agent antenna {:?}: {v}", self.name, args);
        v
    }
}

/// An owner session in a connection: the session is open while this object is alive.
pub struct Held {
    _s: std::os::unix::net::UnixStream,
    pub token: String,
}

/// An MCP client over stdio (JSON-RPC 2.0, one line per message): `antenna mcp` runs under `sh -c`, so that the MCP
/// host (the parent of `antenna mcp`, which the daemon binds the token to) is a separate process and not the test
/// itself.
pub struct Mcp {
    proc: Proc,
    next_id: u64,
    /// The `initialize` result (server info, capabilities, instructions).
    pub init: Value,
}

impl Mcp {
    pub fn start(node: &Node, token: &str) -> Self {
        Self::start_with(node, &[], &[("ANTENNA_AGENT_TOKEN", token)])
    }

    /// `antenna mcp` with extra arguments after `mcp` (e.g. `--token-file <path>`) and environment variables; the
    /// token variables of the test process are not inherited.
    pub fn start_with(node: &Node, args: &[&str], env: &[(&str, &str)]) -> Self {
        let mut c = Command::new("sh");
        c.clean_env()
            .arg("-c")
            .arg(r#""$X_BIN" --data-dir "$X_DIR" mcp "$@"; e=$?; exit $e"#)
            .arg("sh")
            .args(args)
            .env("X_BIN", x_bin())
            .env("X_DIR", &node.dir)
            .env_remove("ANTENNA_AGENT_TOKEN")
            .env_remove("ANTENNA_AGENT_TOKEN_FILE")
            .env_remove("X_AGENT_TOKEN");
        for (k, v) in env {
            c.env(k, v);
        }
        let mut m = Self {
            proc: Proc::spawn(c),
            next_id: 1,
            init: Value::Null,
        };
        let init = m.request(
            "initialize",
            serde_json::json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "x-test", "version": "0"}
            }),
        );
        assert!(
            init["result"]["capabilities"]["tools"].is_object(),
            "{init}"
        );
        m.init = init;
        m.notify("notifications/initialized");
        m
    }

    /// PID of the MCP host: the `sh` that runs `antenna mcp` (the daemon binds the token to it). Compare the bound
    /// process by this PID, not by its name: on macOS `/bin/sh` runs bash (the process is named `bash` there).
    pub fn host_pid(&self) -> u32 {
        self.proc.child.id()
    }

    /// The server's `initialize` instructions.
    pub fn instructions(&self) -> String {
        self.init["result"]["instructions"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    }

    pub fn notify(&mut self, method: &str) {
        let line = serde_json::json!({"jsonrpc": "2.0", "method": method}).to_string();
        self.proc.write_line(&line);
    }

    pub fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let line =
            serde_json::json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
                .to_string();
        self.proc.write_line(&line);
        self.proc
            .wait_for(method, Duration::from_secs(90), move |v| v["id"] == id)
    }

    /// `tools/call` → (isError, structuredContent).
    pub fn call(&mut self, tool: &str, args: Value) -> (bool, Value) {
        let r = self.request(
            "tools/call",
            serde_json::json!({"name": tool, "arguments": args}),
        );
        if r.get("error").is_some() {
            return (true, r["error"].clone());
        }
        let res = &r["result"];
        (
            res["isError"].as_bool().unwrap_or(false),
            res["structuredContent"].clone(),
        )
    }

    pub fn tool_names(&mut self) -> Vec<String> {
        let r = self.request("tools/list", serde_json::json!({}));
        r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    pub fn stop(mut self) {
        self.proc.close_stdin();
        let _ = self.proc.finish(Duration::from_secs(10));
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        self.watchdog.done();
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        // A failing test shows the end of each daemon's log (libtest prints the captured output of failed tests only):
        // the temporary directory with the log is gone once the test ends.
        if std::thread::panicking() {
            eprintln!(
                "{}",
                log_tail(&self.name, &self.dir.with_extension("log"), 60)
            );
            // The stderr tails of agents started on wake (the sandbox's own notes and the agent's errors).
            if let Ok(rd) = std::fs::read_dir(self.dir.join("wake").join("logs")) {
                for e in rd.flatten() {
                    eprintln!(
                        "{}",
                        log_tail(&format!("{} wake log", self.name), &e.path(), 30)
                    );
                }
            }
        }
    }
}

/// The last `lines` lines of a daemon log, with a header.
fn log_tail(name: &str, log: &Path, lines: usize) -> String {
    let text = std::fs::read_to_string(log).unwrap_or_default();
    let all: Vec<&str> = text.lines().collect();
    let from = all.len().saturating_sub(lines);
    format!(
        "--- antennad {name}: last {} lines of {} ---\n{}\n--- end of {name} ---",
        all.len() - from,
        log.display(),
        all[from..].join("\n")
    )
}

/// How long one test may run before its watchdog acts: `ANTENNA_TEST_TIMEOUT_SECS`, 600 s by default.
fn test_limit() -> Duration {
    Duration::from_secs(
        std::env::var("ANTENNA_TEST_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(600),
    )
}

/// A per-test watchdog, one per [`Node`]: a hung test becomes a failure, never a hung `cargo test` (a hang on a Mac cost
/// an hour, TROUBLESHOOTING "macOS 27 on a real Mac"). When the node outlives the limit, the watchdog writes the test's
/// name and the node's log tail to stderr (directly, past libtest's capture) and kills the node's daemon: every call
/// waiting on it then fails and the test panics with its own message. If the test is still not done a minute later
/// (it waits on something else), the whole test process exits with 124, like `timeout`.
struct Watchdog(Arc<WatchState>);

struct WatchState {
    done: AtomicBool,
    pid: Mutex<Option<u32>>,
}

impl Watchdog {
    fn start(node: &str, log: &Path) -> Self {
        let st = Arc::new(WatchState {
            done: AtomicBool::new(false),
            pid: Mutex::new(None),
        });
        let test = std::thread::current()
            .name()
            .unwrap_or("<unnamed test>")
            .to_string();
        let (s2, node, log) = (st.clone(), node.to_string(), log.to_path_buf());
        let limit = test_limit();
        let _ = std::thread::Builder::new()
            .name(format!("watchdog {node}"))
            .spawn(move || {
                let t = Instant::now();
                while !s2.done.load(Ordering::SeqCst) {
                    if t.elapsed() >= limit {
                        let pid = *s2.pid.lock().unwrap_or_else(PoisonError::into_inner);
                        let _ = writeln!(
                            std::io::stderr(),
                            "WATCHDOG: test {test} is still running after {} s; killing antennad {node} (pid {pid:?})\n{}",
                            limit.as_secs(),
                            log_tail(&node, &log, 60)
                        );
                        if let Some(p) = pid.and_then(|p| rustix::process::Pid::from_raw(p as i32)) {
                            let _ = rustix::process::kill_process(p, rustix::process::Signal::KILL);
                        }
                        let t2 = Instant::now();
                        while !s2.done.load(Ordering::SeqCst) {
                            if t2.elapsed() >= Duration::from_secs(60) {
                                let _ = writeln!(
                                    std::io::stderr(),
                                    "WATCHDOG: test {test} did not end after its daemon was killed: exiting with 124"
                                );
                                std::process::exit(124);
                            }
                            std::thread::sleep(Duration::from_millis(500));
                        }
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(500));
                }
            });
        Self(st)
    }

    fn set_pid(&self, pid: Option<u32>) {
        *self.0.pid.lock().unwrap_or_else(PoisonError::into_inner) = pid;
    }

    fn done(&self) {
        self.0.done.store(true, Ordering::SeqCst);
    }
}

pub fn last_json(stdout: &[u8]) -> Value {
    let s = String::from_utf8_lossy(stdout);
    let line = s.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
    serde_json::from_str(line).unwrap_or_else(|e| panic!("not json ({e}): {s}"))
}

/// A process with line-by-line stdout reading (JSON lines) and writing to stdin.
pub struct Proc {
    pub child: Child,
    stdin: Option<ChildStdin>,
    lines: mpsc::Receiver<String>,
    pub seen: Vec<Value>,
}

impl Proc {
    pub fn spawn(mut cmd: Command) -> Self {
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for l in BufReader::new(stdout).lines() {
                match l {
                    Ok(l) => {
                        if tx.send(l).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        let stdin = child.stdin.take();
        Self {
            child,
            stdin,
            lines: rx,
            seen: Vec::new(),
        }
    }

    /// Waits for a JSON line that satisfies the condition.
    pub fn wait_for(&mut self, what: &str, timeout: Duration, f: impl Fn(&Value) -> bool) -> Value {
        if let Some(v) = self.seen.iter().find(|v| f(v)) {
            return v.clone();
        }
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(l) => {
                    let v: Value = serde_json::from_str(&l).unwrap_or(Value::String(l));
                    self.seen.push(v.clone());
                    if f(&v) {
                        return v;
                    }
                }
                Err(_) => panic!("timeout waiting for {what}; seen: {:?}", self.seen),
            }
        }
    }

    pub fn event(&mut self, kind: &str, timeout: Duration) -> Value {
        let k = kind.to_string();
        self.wait_for(kind, timeout, move |v| v["kind"] == k)
    }

    pub fn write_line(&mut self, s: &str) {
        let w = self.stdin.as_mut().expect("stdin");
        w.write_all(s.as_bytes()).unwrap();
        w.write_all(b"\n").unwrap();
        w.flush().unwrap();
    }

    pub fn close_stdin(&mut self) {
        self.stdin.take();
    }

    /// Wait for exit: (exit code, every JSON line seen).
    pub fn finish_all(mut self, timeout: Duration) -> (i32, Vec<Value>) {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(st) = self.child.try_wait().unwrap() {
                while let Ok(l) = self.lines.recv_timeout(Duration::from_millis(200)) {
                    let v: Value = serde_json::from_str(&l).unwrap_or(Value::String(l));
                    self.seen.push(v);
                }
                return (st.code().unwrap_or(-1), self.seen);
            }
            if Instant::now() > deadline {
                let _ = self.child.kill();
                panic!("process did not finish; seen: {:?}", self.seen);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Wait for exit: (exit code, last JSON).
    pub fn finish(mut self, timeout: Duration) -> (i32, Value) {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(st) = self.child.try_wait().unwrap() {
                // Read the rest.
                while let Ok(l) = self.lines.recv_timeout(Duration::from_millis(200)) {
                    let v: Value = serde_json::from_str(&l).unwrap_or(Value::String(l));
                    self.seen.push(v);
                }
                let last = self.seen.last().cloned().unwrap_or(Value::Null);
                return (st.code().unwrap_or(-1), last);
            }
            if Instant::now() > deadline {
                let _ = self.child.kill();
                panic!("process did not finish; seen: {:?}", self.seen);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

pub const T: Duration = Duration::from_secs(30);

/// Starts `antenna invite` at `a`. Returns the process and the link.
pub fn invite(a: &Node, trust: u8, label: &str, confirm: bool) -> (Proc, String) {
    let mut cmd = a.cmd();
    cmd.args([
        "--json",
        "invite",
        "--trust",
        &trust.to_string(),
        "--label",
        label,
        "--ttl",
        "2m",
        "--password-stdin",
    ]);
    if confirm {
        cmd.arg("--confirm");
    }
    if trust == 5 {
        cmd.arg("--yes"); // The level-5 warning, accepted (D-99)
    }
    let mut p = Proc::spawn(cmd);
    p.write_line(&a.password); // Owner password (Q-12a): the first line of stdin.
    let ev = p.event("invite_created", T);
    let link = ev["link"].as_str().unwrap().to_string();
    (p, link)
}

/// Starts `antenna join` at `b` (the code is entered on stdin, as a human would).
pub fn join(b: &Node, link: &str, trust: u8, label: &str) -> Proc {
    let mut cmd = b.cmd();
    cmd.args([
        "--json",
        "join",
        link,
        "--trust",
        &trust.to_string(),
        "--label",
        label,
        "--connect-timeout",
        "5s",
        "--password-stdin",
    ]);
    if trust == 5 {
        cmd.arg("--yes"); // The level-5 warning, accepted (D-99)
    }
    let mut p = Proc::spawn(cmd);
    p.write_line(&b.password); // Owner password (Q-12a).
    p
}

/// Result of a successful pairing.
pub struct Pairing {
    pub link_id: String,
    pub sas: String,
    pub pairing_ms_a: u64,
    pub pairing_ms_b: u64,
    pub link: String,
    pub wall_ms: u128,
}

/// Full pairing: A invites (and confirms itself after B enters the correct code), B enters the code as told by A.
pub fn pair(a: &Node, b: &Node, trust: u8) -> Pairing {
    let t = Instant::now();
    let (mut inv, link) = invite(a, trust, &b.name, true);
    let mut j = join(b, &link, trust, &a.name);
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas);
    let (ca, ra) = inv.finish(T);
    let (cb, rb) = j.finish(T);
    assert_eq!(ca, 0, "invite: {ra}");
    assert_eq!(cb, 0, "join: {rb}");
    assert_eq!(ra["type"], "linked");
    assert_eq!(rb["type"], "linked");
    assert_eq!(
        ra["link_id"], rb["link_id"],
        "both sides derive the same link_id"
    );
    Pairing {
        link_id: ra["link_id"].as_str().unwrap().to_string(),
        sas,
        pairing_ms_a: ra["pairing_ms"].as_u64().unwrap(),
        pairing_ms_b: rb["pairing_ms"].as_u64().unwrap(),
        link,
        wall_ms: t.elapsed().as_millis(),
    }
}

/// A wrong but plausible code (guaranteed ≠ SAS).
pub fn wrong_code(sas: &str) -> String {
    let n: u32 = sas.parse().unwrap();
    format!("{:06}", (n + 1) % 1_000_000)
}

pub fn stats(v: &mut [u128]) -> (u128, u128, u128) {
    v.sort();
    (v[0], v[v.len() / 2], v[v.len() - 1])
}
