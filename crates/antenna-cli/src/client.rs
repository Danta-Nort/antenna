// SPDX-License-Identifier: AGPL-3.0-only
//! Connection to the `antennad` daemon over the control socket (`antenna_proto::control`) as the owner or as an agent
//! (token). On Windows the control socket is a named pipe (D-135), and its server is checked before a byte is sent.

use std::path::{Path, PathBuf};

use antenna_proto::control::{
    AgentMsg, AgentRequest, CONTROL_PROTO, ClientMsg, ErrorBody, Event, Hello, HelloOk, Input,
    Reply, Request, Role, SHARE_CONTENT_FRAME, ServerMsg, to_line,
};
use antenna_proto::local;
use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::net::UnixStream;
#[cfg(windows)]
use tokio::net::windows::named_pipe::NamedPipeClient;
use zeroize::Zeroizing;

/// The two halves of a connection to the daemon: a unix socket's on Linux and macOS, a named pipe's on Windows
/// (D-135).
#[cfg(unix)]
type ReadHalf = tokio::net::unix::OwnedReadHalf;
#[cfg(unix)]
type WriteHalf = tokio::net::unix::OwnedWriteHalf;
#[cfg(windows)]
type ReadHalf = tokio::io::ReadHalf<NamedPipeClient>;
#[cfg(windows)]
type WriteHalf = tokio::io::WriteHalf<NamedPipeClient>;

/// Exit codes (D-23): 0 success; 1 failed; 2 bad arguments or no such command; 69 not implemented;
/// 75 retry later (daemon unavailable, rate limit); 77 owner needed (locked, no permission, approval).
pub const EXIT_FAIL: u8 = 1;
/// No such command or bad arguments.
pub const EXIT_USAGE: u8 = 2;
/// Not implemented.
pub const EXIT_NOT_IMPLEMENTED: u8 = 69;
/// Retry later.
pub const EXIT_TEMPFAIL: u8 = 75;
/// Owner needed.
pub const EXIT_NOPERM: u8 = 77;

/// CLI error with an exit code.
pub struct Fail {
    /// Exit code.
    pub exit: u8,
    /// Machine-readable code.
    pub code: String,
    /// Message.
    pub message: String,
    /// Approval request (for `approval_required`).
    pub approval: Option<Box<antenna_proto::control::ApprovalInfo>>,
}

impl Fail {
    /// New error.
    pub fn new(exit: u8, code: &str, message: impl Into<String>) -> Self {
        Self {
            exit,
            code: code.into(),
            message: message.into(),
            approval: None,
        }
    }

    /// From a daemon reply.
    pub fn from_daemon(e: ErrorBody) -> Self {
        let exit = match e.code.as_str() {
            "not_implemented" => EXIT_NOT_IMPLEMENTED,
            "unknown_command" => EXIT_USAGE,
            "rate_limited" | "approval_pending" | "recovering" => EXIT_TEMPFAIL,
            "locked" | "not_initialized" | "forbidden" | "approval_required" | "denied"
            | "token_invalid" | "token_bound" | "wrong_password" | "login_required"
            | "rekey_required" | "read_only" => EXIT_NOPERM,
            // v7 owner keys (CONTROL §22): the owner is needed, as for a wrong password
            "password_required" | "proof_invalid" | "challenge_invalid" | "owner_key_unknown"
            | "owner_key_refused" | "slot_invalid" => EXIT_NOPERM,
            _ => EXIT_FAIL,
        };
        Self {
            exit,
            code: e.code,
            message: e.message,
            approval: e.approval,
        }
    }
}

/// CLI result.
pub type CliResult<T> = Result<T, Fail>;

/// How to introduce ourselves to the daemon.
#[derive(Clone)]
pub enum Auth {
    /// Owner.
    Owner,
    /// Agent with a token; `bind_parent` binds the token to the parent process (the MCP host).
    Agent {
        /// Token.
        token: Zeroizing<String>,
        /// Bind to the parent.
        bind_parent: bool,
    },
}

/// Open connection.
pub struct Conn {
    lines: tokio::io::Lines<BufReader<ReadHalf>>,
    w: WriteHalf,
    /// The daemon's reply to the hello (the effective role).
    pub hello: HelloOk,
}

/// Connects to the control socket: the two halves of the connection.
#[cfg(unix)]
async fn connect(path: &Path) -> CliResult<(ReadHalf, WriteHalf)> {
    let s = connect_retrying(path).await.map_err(|e| {
        // sun_path: 108 bytes on Linux, 104 on macOS (PORTABILITY M-14).
        let max = if cfg!(target_os = "linux") { 107 } else { 103 };
        let hint = if path.as_os_str().len() > max {
            format!(
                "the path is longer than this OS allows ({max} bytes): use a shorter --data-dir or --socket"
            )
        } else if let Some(h) = legacy_daemon_hint(path) {
            h
        } else {
            "is antennad running?".to_string()
        };
        Fail::new(
            EXIT_TEMPFAIL,
            "daemon_unavailable",
            format!("cannot connect to antennad at {}: {e} ({hint})", path.display()),
        )
    })?;
    Ok(s.into_split())
}

/// Windows (D-135): connects to the daemon's pipe at identification level, then checks its server before a byte is
/// sent: the pipe's owner first (the kernel keeps it), then the server process the pipe records (created before we
/// opened the pipe, running as us). A server that fails is refused as `daemon_untrusted`, naming the pipe and the
/// server's SID or "unreadable", never as `daemon_unavailable`: a squatter must be seen, not mistaken for a stopped
/// daemon.
#[cfg(windows)]
async fn connect(path: &Path) -> CliResult<(ReadHalf, WriteHalf)> {
    use antenna_sys::windows::{process, security::current_user};
    // A data folder stands for its pipe, named now: a long-lived caller (the window's bridge) may have resolved the
    // path before the daemon made the folder.
    let named = match path.to_str() {
        Some(n) if local::is_local_pipe_name(n) => Some(n.to_string()),
        _ if path.is_dir() => pipe_of_folder(path),
        _ => None,
    };
    let Some(name) = named else {
        let why = if path.exists() {
            format!("not a local pipe name ({}…)", local::LOCAL_PIPE_PREFIX)
        } else {
            "no data folder there yet: is antennad running?".to_string()
        };
        return Err(Fail::new(
            EXIT_TEMPFAIL,
            "daemon_unavailable",
            format!("cannot connect to antennad at {}: {why}", path.display()),
        ));
    };
    let name = name.as_str();
    let opened_at = process::now();
    let client = open_retrying(name)
        .await
        .map_err(|e| match e.raw_os_error() {
            // ERROR_FILE_NOT_FOUND: no daemon has made the pipe.
            Some(2) => Fail::new(
                EXIT_TEMPFAIL,
                "daemon_unavailable",
                format!("cannot connect to antennad at {name}: {e} (is antennad running?)"),
            ),
            // ERROR_PIPE_BUSY for the whole wait.
            Some(231) => Fail::new(
                EXIT_TEMPFAIL,
                "daemon_unavailable",
                format!("antennad at {name} stayed busy: {e}; try again"),
            ),
            _ => untrusted(name, "unreadable", &format!("it cannot be opened: {e}")),
        })?;
    let me = current_user().map_err(|e| {
        Fail::new(
            EXIT_FAIL,
            "internal",
            format!("cannot read this process's user: {e}"),
        )
    })?;
    if let Err((sid, why)) = judge_server(&me, &server_facts(&client), opened_at) {
        return Err(untrusted(name, &sid, &why));
    }
    Ok(tokio::io::split(client))
}

/// Windows: opens the pipe, waiting out `ERROR_PIPE_BUSY` for up to two seconds (the daemon is between handing off
/// one instance and making the next), in tokio's pattern.
#[cfg(windows)]
async fn open_retrying(name: &str) -> std::io::Result<NamedPipeClient> {
    let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        match antenna_sys::windows::pipe::open_client(name) {
            Err(e) if e.raw_os_error() == Some(231) && std::time::Instant::now() < until => {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            r => return r,
        }
    }
}

/// Windows: what the client learns of a pipe's server before it sends anything.
#[cfg(windows)]
struct ServerFacts {
    /// The pipe object's owner.
    owner: std::io::Result<antenna_sys::windows::security::Sid>,
    /// The server process the pipe records: its creation time and its user, both read while it is held open.
    process: std::io::Result<(u64, antenna_sys::windows::security::Sid)>,
}

#[cfg(windows)]
fn server_facts(client: &NamedPipeClient) -> ServerFacts {
    use antenna_sys::windows::{pipe, process::Process};
    ServerFacts {
        owner: pipe::pipe_owner(client),
        process: pipe::server_pid(client)
            .and_then(Process::open)
            .and_then(|p| Ok((p.creation_time()?, p.token()?.user))),
    }
}

/// Windows: the rule for the pipe's server (D-135), in this order: the pipe is ours (its owner is our SID); its server
/// process was created before we opened the pipe (a reused PID is not it) and runs as us. The error is the server's
/// SID (or "unreadable") and why.
#[cfg(windows)]
fn judge_server(
    me: &antenna_sys::windows::security::Sid,
    facts: &ServerFacts,
    opened_at: u64,
) -> Result<(), (String, String)> {
    match &facts.owner {
        Err(e) => {
            return Err((
                "unreadable".into(),
                format!("its owner cannot be read: {e}"),
            ));
        }
        Ok(o) if o != me => {
            return Err((o.to_string(), "it belongs to another user".into()));
        }
        Ok(_) => {}
    }
    match &facts.process {
        Err(e) => Err((
            "unreadable".into(),
            format!("its server process cannot be read: {e}"),
        )),
        Ok((created, _)) if *created > opened_at => Err((
            "unreadable".into(),
            "its server process started after this client opened the pipe".into(),
        )),
        Ok((_, user)) if user != me => Err((
            user.to_string(),
            "its server process runs as another user".into(),
        )),
        Ok(_) => Ok(()),
    }
}

/// Windows: the refusal of a pipe that is not our daemon's.
#[cfg(windows)]
fn untrusted(name: &str, sid: &str, why: &str) -> Fail {
    Fail::new(
        EXIT_FAIL,
        "daemon_untrusted",
        format!(
            "the pipe {name} is not your Antenna daemon's ({why}; server {sid}): nothing was sent. Another program may \
             hold the daemon's name"
        ),
    )
}

impl Conn {
    /// Connect and say hello.
    pub async fn open(path: &Path, auth: &Auth) -> CliResult<Self> {
        let (r, w) = connect(path).await?;
        let mut lines = BufReader::new(r).lines();
        let mut w = w;
        let hello = match auth {
            Auth::Owner => Hello {
                proto: CONTROL_PROTO.into(),
                role: Role::Owner,
                token: None,
                bind_parent: false,
                session: held_token(),
            },
            Auth::Agent { token, bind_parent } => Hello {
                proto: CONTROL_PROTO.into(),
                role: Role::Agent,
                // An empty token means "recognize me by the MCP host's process tree" (host hooks, D-28).
                token: (!token.is_empty()).then(|| token.to_string()),
                bind_parent: *bind_parent,
                session: None,
            },
        };
        let line = Zeroizing::new(to_line(&ClientMsg::Hello(hello)));
        w.write_all(line.as_bytes())
            .await
            .map_err(|e| Fail::new(EXIT_TEMPFAIL, "daemon_unavailable", e.to_string()))?;
        let first = recv_line(&mut lines).await?;
        match first {
            ServerMsg::HelloOk(h) => Ok(Conn { lines, w, hello: h }),
            ServerMsg::Err(e) => Err(Fail::from_daemon(e)),
            _ => Err(Fail::new(
                EXIT_FAIL,
                "protocol",
                "unexpected reply to hello",
            )),
        }
    }

    /// Send a message.
    pub async fn send<T: Serialize>(&mut self, m: &T) -> CliResult<()> {
        let line = Zeroizing::new(to_line(m));
        self.w
            .write_all(line.as_bytes())
            .await
            .map_err(|e| Fail::new(EXIT_TEMPFAIL, "daemon_unavailable", e.to_string()))
    }

    /// Send one line as is: a request with an owner proof carries the exact text that was signed (CONTROL §22.2).
    pub async fn send_line(&mut self, line: &str) -> CliResult<()> {
        let line = Zeroizing::new(format!("{line}\n"));
        self.w
            .write_all(line.as_bytes())
            .await
            .map_err(|e| Fail::new(EXIT_TEMPFAIL, "daemon_unavailable", e.to_string()))
    }

    /// Receive a message. An event of a kind this client does not know (a newer daemon) is skipped: the protocol only
    /// adds event kinds, and a client ignores what it does not know (`docs/CONTROL.md` §2).
    pub async fn recv(&mut self) -> CliResult<ServerMsg> {
        loop {
            match recv_line(&mut self.lines).await {
                Err(f) if f.code == "unknown_event" => continue,
                r => return r,
            }
        }
    }

    /// Read until the final reply (events are skipped).
    pub async fn finish(&mut self) -> CliResult<Reply> {
        loop {
            match self.recv().await? {
                ServerMsg::Ok(r) => return Ok(r),
                ServerMsg::Err(e) => return Err(Fail::from_daemon(e)),
                _ => continue,
            }
        }
    }
}

/// The transport under [`Conn::open`] without its hello: `antenna window-bridge` passes each connection's bytes through
/// as they are (D-135). The path resolves and the transport connects as for every other command, on every OS.
pub(crate) async fn connect_raw(
    path: &Path,
) -> CliResult<(
    impl tokio::io::AsyncRead + Unpin + 'static + use<>,
    impl tokio::io::AsyncWrite + Unpin + 'static + use<>,
)> {
    connect(path).await
}

async fn recv_line(lines: &mut tokio::io::Lines<BufReader<ReadHalf>>) -> CliResult<ServerMsg> {
    match lines.next_line().await {
        Ok(Some(l)) => serde_json::from_str(&l).map_err(|e| {
            let unknown_event = serde_json::from_str::<serde_json::Value>(&l)
                .is_ok_and(|v| v.get("event").is_some_and(serde_json::Value::is_object));
            if unknown_event {
                Fail::new(EXIT_FAIL, "unknown_event", format!("event: {e}"))
            } else {
                Fail::new(EXIT_FAIL, "protocol", format!("bad reply: {e}"))
            }
        }),
        Ok(None) => Err(Fail::new(
            EXIT_TEMPFAIL,
            "daemon_unavailable",
            "daemon closed the connection",
        )),
        Err(e) => Err(Fail::new(
            EXIT_TEMPFAIL,
            "daemon_unavailable",
            e.to_string(),
        )),
    }
}

/// Owner request → final reply. Also returns the hello reply (the role may have turned out to be agent).
pub async fn call_owner(path: &Path, req: Request) -> CliResult<(HelloOk, Reply)> {
    let mut c = Conn::open(path, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(req)).await?;
    let r = c.finish().await;
    let h = c.hello.clone();
    match r {
        Ok(r) => Ok((h, r)),
        Err(f) => Err(explain_forced(&h, f)),
    }
}

/// The owner session this process holds for its one command (Windows, WP-10): the connection that holds it and its
/// token, which every owner connection of this process names in its hello. Unix has none: a terminal has its own
/// session there.
#[cfg(windows)]
struct HeldSession {
    _conn: Conn,
    token: Zeroizing<String>,
}

#[cfg(windows)]
static HELD: std::sync::Mutex<Option<HeldSession>> = std::sync::Mutex::new(None);

/// The held session's token, if this process holds one.
#[cfg(unix)]
fn held_token() -> Option<String> {
    None
}

/// The held session's token, if this process holds one.
#[cfg(windows)]
fn held_token() -> Option<String> {
    HELD.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .map(|h| h.token.to_string())
}

/// Windows (WP-10): a console can be joined by another process and a parent chosen, so neither names a terminal and
/// the daemon opens no terminal session there. An owner command that needs a session asks for the password and holds
/// a session for itself: `login {hold: true}` on a connection kept open for the rest of this process, its token named
/// by the command's own connections, which come from the same process (the daemon checks the holder). The session
/// ends with the process.
#[cfg(windows)]
pub async fn hold_session(path: &Path, password: Zeroizing<String>) -> CliResult<()> {
    let mut c = Conn::open(path, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(Request::Login {
        password: password.to_string(),
        hold: true,
    }))
    .await?;
    drop(password);
    loop {
        match c.recv().await? {
            ServerMsg::Event(Event::Session { token, .. }) => {
                let token = Zeroizing::new(token.0);
                *HELD
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some(HeldSession { _conn: c, token });
                return Ok(());
            }
            ServerMsg::Err(e) => return Err(Fail::from_daemon(e)),
            ServerMsg::Event(_) => continue,
            _ => {
                return Err(Fail::new(
                    EXIT_FAIL,
                    "protocol",
                    "unexpected reply to login {hold}",
                ));
            }
        }
    }
}

/// Ends the session this process holds, if any (tests; a process's session otherwise ends with it).
#[cfg(all(test, windows))]
fn release_session() {
    *HELD
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
}

/// An owner request with a proof (`{"req":…,"proof":…}`, one line as signed) → final reply.
pub async fn call_owner_line(path: &Path, line: &str) -> CliResult<(HelloOk, Reply)> {
    let mut c = Conn::open(path, &Auth::Owner).await?;
    c.send_line(line).await?;
    let r = c.finish().await;
    let h = c.hello.clone();
    match r {
        Ok(r) => Ok((h, r)),
        Err(f) => Err(explain_forced(&h, f)),
    }
}

/// Agent request → final reply.
pub async fn call_agent(path: &Path, auth: &Auth, req: AgentRequest) -> CliResult<Reply> {
    let mut c = Conn::open(path, auth).await?;
    c.send(&AgentMsg::Req(req)).await?;
    c.finish().await
}

/// `share_file_content`: the request, then (once the daemon has checked what it can without the data and asked with
/// `need_input`) the bytes in base64 frames of [`SHARE_CONTENT_FRAME`] bytes, each within the socket's line limit, and
/// `end`. If the daemon refuses midway it closes the connection: writing stops and its error is read.
pub async fn share_content(
    path: &Path,
    auth: &Auth,
    contact: String,
    name: String,
    data: &[u8],
    approval_id: Option<String>,
    (to, to_agent): (Option<String>, Option<String>),
) -> CliResult<Reply> {
    let mut c = Conn::open(path, auth).await?;
    c.send(&AgentMsg::Req(AgentRequest::ShareFileContent {
        contact,
        name,
        size: data.len() as u64,
        approval_id,
        to,
        to_agent,
    }))
    .await?;
    loop {
        match c.recv().await? {
            ServerMsg::Event(Event::NeedInput { what, .. }) if what == "data" => break,
            ServerMsg::Err(e) => return Err(Fail::from_daemon(e)),
            ServerMsg::Ok(r) => return Ok(r),
            _ => continue,
        }
    }
    for piece in data.chunks(SHARE_CONTENT_FRAME) {
        let frame = AgentMsg::Input(Input::Data {
            b64: data_encoding::BASE64.encode(piece),
        });
        if c.send(&frame).await.is_err() {
            break;
        }
    }
    let _ = c.send(&AgentMsg::Input(Input::End {})).await;
    c.finish().await
}

/// A process from an agent's tree introduced itself as the owner and the daemon gave it the agent role: explain this to
/// the human.
pub fn explain_forced(h: &HelloOk, mut f: Fail) -> Fail {
    if h.forced && f.code == "unknown_command" {
        f.message = format!(
            "no such command here: this process runs inside the process tree of agent {:?}, so owner \
             commands do not exist for it; run them from a separate terminal",
            h.agent.as_deref().unwrap_or("?")
        );
    }
    f
}

/// The legacy environment variable (from the preview build `x`) if the new one is not set: its value, and one
/// warning on stderr per process.
pub fn legacy_env(var: &local::EnvVar) -> Option<std::ffi::OsString> {
    static WARNED: std::sync::Mutex<Vec<&'static str>> = std::sync::Mutex::new(Vec::new());
    let v = var.legacy_only()?;
    let mut w = WARNED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !w.contains(&var.legacy) {
        w.push(var.legacy);
        eprintln!("antenna: warning: {}", var.deprecation());
    }
    Some(v)
}

/// Socket path: `--socket` / `ANTENNA_SOCKET` → `--data-dir` / `ANTENNA_DATA_DIR` → the default directory
/// (`docs/CONTROL.md` §1); the legacy `X_SOCKET` / `X_DATA_DIR` are fallbacks.
pub fn socket_path(socket: &Option<PathBuf>, data_dir: &Option<PathBuf>) -> PathBuf {
    if let Some(s) = socket {
        return s.clone();
    }
    if let Some(s) = legacy_env(&local::ENV_SOCKET) {
        return PathBuf::from(s);
    }
    let dir = data_dir
        .clone()
        .or_else(|| legacy_env(&local::ENV_DATA_DIR).map(PathBuf::from))
        .unwrap_or_else(local::default_data_dir);
    default_socket(dir)
}

/// The socket in the data folder.
#[cfg(unix)]
fn default_socket(dir: PathBuf) -> PathBuf {
    dir.join(local::SOCKET_NAME)
}

/// Windows (D-135): the daemon's pipe for this data folder (see [`pipe_of_folder`]). A folder that does not exist has
/// no daemon yet: the folder itself is returned, and [`Conn::open`] names its pipe once the folder is there, or says
/// the daemon is unavailable.
#[cfg(windows)]
fn default_socket(dir: PathBuf) -> PathBuf {
    pipe_of_folder(&dir).map(PathBuf::from).unwrap_or(dir)
}

/// Windows (D-135): the pipe of the daemon of the data folder `dir`, from the user's SID and the folder's canonical
/// path (`control_pipe_name`); `None` while the folder does not exist.
#[cfg(windows)]
fn pipe_of_folder(dir: &Path) -> Option<String> {
    let me = antenna_sys::windows::security::current_user().ok()?;
    let real = std::fs::canonicalize(dir).ok()?;
    Some(local::control_pipe_name(&me.to_string(), real.to_str()?))
}

/// Connect to the control socket. A listening socket whose accept backlog is momentarily full refuses the connection
/// (macOS answers `ECONNREFUSED`, Linux `EAGAIN`): seen right after a daemon started on a loaded Mac. While the socket
/// file exists, retry those two errors a few times (about 0.75 s in all); a socket that nobody listens on still fails
/// within that time with the same error.
#[cfg(unix)]
async fn connect_retrying(path: &Path) -> std::io::Result<UnixStream> {
    let mut wait_ms = 50;
    loop {
        match UnixStream::connect(path).await {
            Ok(s) => return Ok(s),
            Err(e)
                if wait_ms <= 400
                    && matches!(
                        e.kind(),
                        std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::WouldBlock
                    )
                    && path.exists() =>
            {
                tokio::time::sleep(std::time::Duration::from_millis(wait_ms)).await;
                wait_ms *= 2;
            }
            Err(e) => return Err(e),
        }
    }
}

/// Hint when the socket is missing: whether a daemon of the preview build `x` is still running (its socket is at
/// the old location).
#[cfg(unix)]
fn legacy_daemon_hint(path: &Path) -> Option<String> {
    if path != local::default_data_dir().join(local::SOCKET_NAME) {
        return None;
    }
    let old = local::legacy_data_dir_in(|k| std::env::var_os(k)).join(local::LEGACY_SOCKET_NAME);
    std::os::unix::net::UnixStream::connect(&old).ok()?;
    Some(format!(
        "the daemon of the preview build `x` is still running at {}: stop it (macOS: open the Antenna window; \
         Linux: systemctl --user disable --now xd) and start antennad — it moves the data to the new place once",
        old.display()
    ))
}

/// Windows (D-135): the client end of the control pipe and the checks of its server.
#[cfg(all(test, windows))]
mod windows_tests {
    use std::time::{Duration, Instant};

    use antenna_sys::windows::{
        pipe::create_server,
        security::{SecurityDescriptor, Sid, current_user},
    };
    use tokio::io::AsyncReadExt;

    use super::*;

    fn name(tag: &str) -> String {
        format!(r"\\.\pipe\antenna-cli-test-{}-{tag}", std::process::id())
    }

    fn ours(me: &Sid) -> SecurityDescriptor {
        SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GRGW;;;{me})S:(ML;;NWNR;;;ME)"))
            .unwrap()
    }

    fn facts(owner: std::io::Result<Sid>, process: std::io::Result<(u64, Sid)>) -> ServerFacts {
        ServerFacts { owner, process }
    }

    /// The rule, each case alone: our pipe and our earlier process pass; a pipe owned by another SID is refused and
    /// named before the process is looked at; an unreadable owner or process, a process started after our open, and a
    /// process of another user are refused.
    #[test]
    fn client_refuses_pipe_owned_by_another_sid() {
        let me = Sid::parse("S-1-5-21-1-2-3-1001").unwrap();
        let other = Sid::parse("S-1-5-21-1-2-3-1002").unwrap();
        let gone = || std::io::Error::from_raw_os_error(5);
        assert_eq!(
            judge_server(&me, &facts(Ok(me.clone()), Ok((10, me.clone()))), 20),
            Ok(())
        );
        let cases = [
            (
                facts(Ok(other.clone()), Ok((10, me.clone()))),
                "S-1-5-21-1-2-3-1002",
                "another user",
            ),
            (
                facts(Ok(other.clone()), Err(gone())),
                "S-1-5-21-1-2-3-1002",
                "another user",
            ),
            (
                facts(Err(gone()), Ok((10, me.clone()))),
                "unreadable",
                "owner cannot be read",
            ),
            (
                facts(Ok(me.clone()), Err(gone())),
                "unreadable",
                "process cannot be read",
            ),
            (
                facts(Ok(me.clone()), Ok((30, me.clone()))),
                "unreadable",
                "started after",
            ),
            (
                facts(Ok(me.clone()), Ok((10, other.clone()))),
                "S-1-5-21-1-2-3-1002",
                "runs as another user",
            ),
        ];
        for (f, sid, why) in cases {
            let (s, w) = judge_server(&me, &f, 20).unwrap_err();
            assert_eq!(s, sid, "{w}");
            assert!(w.contains(why), "{w}");
        }
        let f = untrusted(
            r"\\.\pipe\x",
            "S-1-5-21-1-2-3-1002",
            "it belongs to another user",
        );
        assert_eq!((f.exit, f.code.as_str()), (EXIT_FAIL, "daemon_untrusted"));
        assert!(
            f.message.contains(r"\\.\pipe\x") && f.message.contains("S-1-5-21-1-2-3-1002"),
            "{}",
            f.message
        );
    }

    /// A pipe this process serves as the daemon would passes the checks, and what the client sends arrives.
    #[tokio::test]
    async fn our_own_pipe_is_reached() {
        let me = current_user().unwrap();
        let n = name("ours");
        let mut server = create_server(&n, true, &ours(&me)).unwrap();
        let (_r, mut w) = connect(Path::new(&n))
            .await
            .unwrap_or_else(|f| panic!("{}", f.message));
        server.connect().await.unwrap();
        w.write_all(b"x").await.unwrap();
        let mut b = [0u8; 1];
        server.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"x");
    }

    /// No pipe, or no data folder yet: the daemon is unavailable, said quickly.
    #[tokio::test]
    async fn no_pipe_is_daemon_unavailable() {
        let t = Instant::now();
        let Err(f) = connect(Path::new(&name("missing"))).await else {
            panic!("connected to nothing");
        };
        assert_eq!(
            (f.exit, f.code.as_str()),
            (EXIT_TEMPFAIL, "daemon_unavailable"),
            "{}",
            f.message
        );
        assert!(
            t.elapsed() < Duration::from_millis(500),
            "{:?}",
            t.elapsed()
        );
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("Antenna");
        let socket = socket_path(&None, &Some(missing.clone()));
        assert_eq!(socket, missing, "no folder, no pipe name");
        let Err(f) = connect(&socket).await else {
            panic!("connected to nothing");
        };
        assert_eq!(f.code, "daemon_unavailable", "{}", f.message);
        assert!(f.message.contains("is antennad running"), "{}", f.message);
    }

    /// A path resolved while the data folder did not exist yet (the window's bridge starts before the daemon makes it)
    /// reaches the daemon once the folder and its pipe are there: the folder names its pipe at connect time. The
    /// control: before the folder exists the same path is "unavailable".
    #[tokio::test]
    async fn a_folder_resolved_before_it_existed_names_its_pipe_later() {
        let me = current_user().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("Antenna");
        let early = socket_path(&None, &Some(data.clone()));
        assert_eq!(early, data);
        let Err(f) = connect(&early).await else {
            panic!("connected before the folder existed");
        };
        assert_eq!(f.code, "daemon_unavailable", "{}", f.message);
        std::fs::create_dir(&data).unwrap();
        let pipe = pipe_of_folder(&data).unwrap();
        assert_eq!(
            socket_path(&None, &Some(data.clone())),
            PathBuf::from(&pipe)
        );
        let mut server = create_server(&pipe, true, &ours(&me)).unwrap();
        let (_r, mut w) = connect(&early)
            .await
            .unwrap_or_else(|f| panic!("{}", f.message));
        server.connect().await.unwrap();
        w.write_all(b"y").await.unwrap();
        let mut b = [0u8; 1];
        server.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"y");
    }

    /// The daemon this test binary sits next to (`target/<profile>/antennad.exe`), started on a scratch folder; `None`
    /// when it is not built.
    fn start_daemon(data: &Path) -> Option<std::process::Child> {
        let exe = std::env::current_exe().ok()?;
        let antennad = exe.parent()?.parent()?.join("antennad.exe");
        if !antennad.exists() {
            eprintln!("antennad.exe not built next to the tests: skipped");
            return None;
        }
        std::process::Command::new(antennad)
            .args(["--data-dir"])
            .arg(data)
            .arg("--links-dir")
            .arg(data.with_file_name("links"))
            .args(["--relay", "disabled", "--bind-ip", "127.0.0.1"])
            .env_remove("ANTENNA_SOCKET")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()
    }

    /// WP-10: in a Windows terminal an owner command holds a session for itself. Without one, an owner request is
    /// login_required (the control); with `hold_session` the same request from this process passes; a wrong password
    /// holds nothing; once the holding connection is gone, the session is gone too.
    #[tokio::test]
    async fn an_owner_command_holds_a_session_for_itself() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let Some(mut daemon) = start_daemon(&data) else {
            return;
        };
        let t = Instant::now();
        let path = loop {
            let p = socket_path(&None, &Some(data.clone()));
            if local::is_local_pipe_name(&p.to_string_lossy()) && connect(&p).await.is_ok() {
                break p;
            }
            assert!(
                t.elapsed() < Duration::from_secs(30),
                "antennad did not start"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        };
        let pw = "test-password-wp10";
        call_owner(
            &path,
            Request::Init {
                password: pw.into(),
            },
        )
        .await
        .unwrap_or_else(|f| panic!("{}", f.message));
        let contacts = || call_owner(&path, Request::Contacts {});
        let Err(f) = contacts().await else {
            panic!("an owner request without a session");
        };
        assert_eq!(f.code, "login_required", "{}", f.message);
        let Err(f) = hold_session(&path, Zeroizing::new("wrong".into())).await else {
            panic!("held a session with a wrong password");
        };
        assert_eq!(f.code, "wrong_password", "{}", f.message);
        hold_session(&path, Zeroizing::new(pw.into()))
            .await
            .unwrap_or_else(|f| panic!("{}", f.message));
        contacts().await.unwrap_or_else(|f| panic!("{}", f.message));
        release_session();
        let t = Instant::now();
        loop {
            match contacts().await {
                Err(f) if f.code == "login_required" => break,
                r => assert!(
                    t.elapsed() < Duration::from_secs(5),
                    "the session outlived its connection: {:?}",
                    r.map(|_| ()).map_err(|f| f.message)
                ),
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let _ = daemon.kill();
        let _ = daemon.wait();
    }

    /// A pipe behind a DACL that keeps us out is not "unavailable": it is refused as untrusted, its owner unreadable,
    /// and nothing is sent. The control: the same name with our descriptor is reached (`our_own_pipe_is_reached`).
    #[tokio::test]
    async fn a_pipe_that_shuts_us_out_is_untrusted() {
        let me = current_user().unwrap();
        let n = name("shut");
        let system_only = SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GA;;;SY)")).unwrap();
        let _server = create_server(&n, true, &system_only).unwrap();
        let Err(f) = connect(Path::new(&n)).await else {
            panic!("connected through a DACL that shuts us out");
        };
        eprintln!("FACT a pipe that shuts us out: {}", f.message);
        assert_eq!(
            (f.exit, f.code.as_str()),
            (EXIT_FAIL, "daemon_untrusted"),
            "{}",
            f.message
        );
        assert!(
            f.message.contains(&n) && f.message.contains("server unreadable"),
            "{}",
            f.message
        );
    }

    /// A pipe whose only instance is taken is waited for, and reached once the server makes the next one.
    #[tokio::test]
    async fn a_busy_pipe_is_waited_for() {
        let me = current_user().unwrap();
        let n = name("busy");
        let sd = ours(&me);
        let first = create_server(&n, true, &sd).unwrap();
        let _taken = antenna_sys::windows::pipe::open_client(&n).unwrap();
        first.connect().await.unwrap();
        let (n2, sd2) = (n.clone(), ours(&me));
        let later = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let s = create_server(&n2, false, &sd2).unwrap();
            s.connect().await.unwrap();
            s
        });
        let t = Instant::now();
        connect(Path::new(&n))
            .await
            .unwrap_or_else(|f| panic!("{}", f.message));
        assert!(
            t.elapsed() >= Duration::from_millis(150),
            "{:?}",
            t.elapsed()
        );
        drop(later.await.unwrap());
    }
}

// Unix sockets and their errors; the Windows pipe has its own tests (`windows_tests`).
#[cfg(all(test, unix))]
mod tests {
    use std::time::{Duration, Instant};

    use super::connect_retrying;

    /// A socket file left by a listener that is gone: `connect` gets `ECONNREFUSED` (a plain file would give
    /// `ENOTSOCK` on macOS, which is not a full backlog).
    fn stale_socket(path: &std::path::Path) {
        drop(std::os::unix::net::UnixListener::bind(path).expect("bind"));
        assert!(path.exists());
    }

    /// A socket file nobody listens on (as a full backlog, `connect` is refused: `ECONNREFUSED` on Linux and macOS)
    /// that listens a moment later is reached, not reported as "daemon unavailable".
    #[tokio::test]
    async fn a_socket_that_listens_a_moment_later_is_reached() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("antennad.sock");
        stale_socket(&path);
        let p = path.clone();
        let listener = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(120)).await;
            std::fs::remove_file(&p).expect("remove placeholder");
            let l = tokio::net::UnixListener::bind(&p).expect("bind");
            let _ = l.accept().await;
        });
        connect_retrying(&path)
            .await
            .expect("reached after the retries");
        listener.abort();
    }

    /// Nobody listens: the error comes back within about a second, and no file means no retries at all.
    #[tokio::test]
    async fn nobody_listening_fails_quickly() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("antennad.sock");
        stale_socket(&path);
        let t = Instant::now();
        assert!(connect_retrying(&path).await.is_err());
        assert!(
            t.elapsed() < Duration::from_millis(1500),
            "{:?}",
            t.elapsed()
        );
        let t = Instant::now();
        assert!(
            connect_retrying(&dir.path().join("missing.sock"))
                .await
                .is_err()
        );
        assert!(
            t.elapsed() < Duration::from_millis(100),
            "{:?}",
            t.elapsed()
        );
    }
}
