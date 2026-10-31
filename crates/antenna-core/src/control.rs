// SPDX-License-Identifier: AGPL-3.0-only
//! The daemon's control unix socket (SPEC §9, §11, §13): permissions `0600`, same uid only (`SO_PEERCRED`; on macOS
//! `getpeereid` and the audit token), JSON lines per `antenna_proto::control`.
//!
//! Windows (D-135): a named pipe instead, never AF_UNIX. Its name follows the user and the data folder
//! (`antenna_proto::local::control_pipe_name`); the daemon makes its first instance or does not start (a name someone
//! holds is named with its owner); every instance has the same descriptor (the user alone, read and write; a medium
//! label, so nothing below reads or writes); remote clients are rejected. Each client's token is read by impersonating
//! it at identification level: the same user, medium integrity or above, not an AppContainer, not restricted. Its PID
//! is the client's word, so it only restricts: the chain is the client alone, and process binding (D-28) does not
//! apply.
//!
//! Two roles, two different request parsers:
//! - **owner** ([`Request`]): requires an open owner session (`login`, Q-14b: terminal, parent process or the window's
//!   connection); commands that change trust and links additionally check the owner password (Argon2id over the
//!   keystore) on every call (Q-12a);
//! - **agent** ([`AgentRequest`]): by token (`antenna agent add`) or by the process tree of its MCP host (D-28).
//!   An agent request is parsed **only** as an [`AgentRequest`]: owner commands do not exist for an agent, so the
//!   answer is `unknown_command`, not `forbidden`.

use std::sync::PoisonError;
use std::{path::Path, sync::Arc, time::Duration};

use antenna_proto::control::{
    AgentMsg, AgentRequest, CONTROL_SUPPORTED, ClientMsg, ESCALATION_OPEN, ESCALATION_SENT, Event,
    HelloMsg, HelloOk, Input, LinkedReply, MAX_LINE, Reply, Request, Role, ServerMsg, code,
    to_line,
};
#[cfg(windows)]
use antenna_sys::windows::security::{SecurityDescriptor, Sid, TokenFacts};
#[cfg(windows)]
use tokio::net::windows::named_pipe::NamedPipeServer;
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    sync::mpsc,
};
use zeroize::Zeroizing;

use crate::{
    addressing::AddrReq,
    agents::AgentCtx,
    error::{Error, Result},
    events::NodeEvent,
    invites,
    node::{Node, Session},
    now_ms, owner,
    pairing::{self, Ui},
    procinfo::ProcStat,
    stream::Author,
};

/// The longest unix socket path in bytes: `sun_path` is 108 bytes on Linux, 104 on macOS and BSD, including the
/// terminating zero (PORTABILITY M-14).
pub const MAX_SOCKET_PATH: usize = if cfg!(any(target_os = "linux", target_os = "android")) {
    107
} else {
    103
};

/// The two halves of a control connection: a unix socket's on Linux and macOS, a named pipe instance's on Windows
/// (D-135).
#[cfg(unix)]
type ReadHalf = tokio::net::unix::OwnedReadHalf;
#[cfg(unix)]
type WriteHalf = tokio::net::unix::OwnedWriteHalf;
#[cfg(windows)]
type ReadHalf = tokio::io::ReadHalf<NamedPipeServer>;
#[cfg(windows)]
type WriteHalf = tokio::io::WriteHalf<NamedPipeServer>;

/// The listening control socket.
#[cfg(unix)]
pub type Listener = UnixListener;

/// Windows: the control pipe (D-135): its name, the descriptor every instance gets, the daemon's user, and the
/// instance waiting for the next client.
#[cfg(windows)]
pub struct Listener {
    name: String,
    sd: SecurityDescriptor,
    me: Sid,
    next: Option<NamedPipeServer>,
}

#[cfg(windows)]
impl Listener {
    /// The pipe's name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// A further instance of the pipe, with the same descriptor.
    fn instance(&self) -> std::io::Result<NamedPipeServer> {
        antenna_sys::windows::pipe::create_server(&self.name, false, &self.sd)
    }
}

/// The descriptor of every instance of the control pipe (D-135): owned by the user; a protected DACL with one entry,
/// the user, generic read and write (no SYSTEM, no Administrators, none of the default DACL's Everyone or Anonymous
/// read); a medium mandatory label that keeps lower integrity from reading and writing.
#[cfg(windows)]
fn pipe_descriptor(me: &Sid) -> std::io::Result<SecurityDescriptor> {
    SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GRGW;;;{me})S:(ML;;NWNR;;;ME)"))
}

/// Brings up the socket: removes a stale file (if the daemon does not answer), sets permissions 0600.
#[cfg(unix)]
pub async fn bind(path: &Path) -> Result<Listener> {
    use std::os::unix::fs::PermissionsExt;
    let n = path.as_os_str().len();
    if n > MAX_SOCKET_PATH {
        return Err(Error::bad_request(format!(
            "socket path {} is {n} bytes, this OS allows at most {MAX_SOCKET_PATH}: use a shorter --data-dir or \
             --socket (for example /tmp/x-$USER.sock)",
            path.display()
        )));
    }
    if path.exists() {
        if UnixStream::connect(path).await.is_ok() {
            return Err(Error::bad_request(format!(
                "another antennad is already listening on {}",
                path.display()
            )));
        }
        std::fs::remove_file(path)?;
    }
    let l = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(l)
}

/// Windows: makes the control pipe's first instance (D-135); `path` is the pipe's name. A name that already has an
/// instance, anyone's, stops the daemon, and the message names who holds it: the pipe owner's SID, or "unreadable".
#[cfg(windows)]
pub async fn bind(path: &Path) -> Result<Listener> {
    use antenna_sys::windows::{pipe, security::current_user};
    let name = path
        .to_str()
        .filter(|n| antenna_proto::local::is_local_pipe_name(n))
        .ok_or_else(|| {
            Error::bad_request(format!(
                "{} is not a local pipe name ({}…)",
                path.display(),
                antenna_proto::local::LOCAL_PIPE_PREFIX
            ))
        })?
        .to_string();
    let me = current_user()?;
    let sd = pipe_descriptor(&me)?;
    match pipe::create_server(&name, true, &sd) {
        Ok(first) => Ok(Listener {
            name,
            sd,
            me,
            next: Some(first),
        }),
        // ERROR_ACCESS_DENIED: an instance exists (FILE_FLAG_FIRST_PIPE_INSTANCE); ERROR_PIPE_BUSY likewise.
        Err(e) if matches!(e.raw_os_error(), Some(5 | 231)) => Err(held(&name, &me)),
        Err(e) => Err(Error::internal(format!("control pipe {name}: {e}"))),
    }
}

/// Why a held pipe name stops the daemon, naming the holder: the pipe's owner as the kernel keeps it, read through a
/// client handle at identification level with nothing sent, or "unreadable".
#[cfg(windows)]
fn held(name: &str, me: &Sid) -> Error {
    use antenna_sys::windows::pipe::{open_client, pipe_owner};
    let owner = open_client(name).and_then(|c| pipe_owner(&c));
    Error::bad_request(match owner {
        Ok(o) if o == *me => format!("another antennad is already listening on {name}"),
        Ok(o) => format!(
            "the pipe {name} is held by {o}, not by you ({me}): another user's process took its name, and antennad \
             does not start"
        ),
        Err(e) => format!(
            "the pipe {name} is already held, and its owner is unreadable ({e}): antennad does not start"
        ),
    })
}

/// Maximum number of simultaneous socket connections (subscriptions are long-lived connections).
const MAX_CONNECTIONS: usize = 256;
/// How long to wait for `hello`.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

/// Serves connections until the task is stopped.
#[cfg(unix)]
pub async fn serve(listener: Listener, node: Arc<Node>) {
    let slots = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                // EMFILE and the like: do not spin in an empty loop
                tracing::warn!("control accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            tracing::warn!("control: too many connections ({MAX_CONNECTIONS}), refusing");
            continue;
        };
        let node = node.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(stream, node).await {
                tracing::debug!("control connection: {e}");
            }
            drop(slot);
        });
    }
}

/// Windows: the same loop over the pipe's clients, in tokio's pattern: when a client connects, the next instance is
/// made before this one is handed off, so the name never lapses (D-135).
#[cfg(windows)]
pub async fn serve(mut listener: Listener, node: Arc<Node>) {
    let slots = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));
    loop {
        let server = match listener.next.take() {
            Some(s) => s,
            None => match listener.instance() {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!("control pipe: no instance for the next client: {e}");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let connected = server.connect().await;
        let at = antenna_sys::windows::process::now();
        listener.next = listener
            .instance()
            .inspect_err(|e| tracing::warn!("control pipe: no instance for the next client: {e}"))
            .ok();
        if let Err(e) = connected {
            tracing::warn!("control pipe connect: {e}");
            continue;
        }
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            tracing::warn!("control: too many connections ({MAX_CONNECTIONS}), refusing");
            continue;
        };
        let (node, me) = (node.clone(), listener.me.clone());
        tokio::spawn(async move {
            if let Err(e) = handle(server, at, &me, node).await {
                tracing::debug!("control connection: {e}");
            }
            drop(slot);
        });
    }
}

struct Out(WriteHalf);

impl Out {
    async fn send(&mut self, m: &ServerMsg) -> Result<()> {
        self.0.write_all(to_line(m).as_bytes()).await?;
        Ok(())
    }

    async fn err(&mut self, e: &Error) -> Result<()> {
        self.send(&ServerMsg::Err(e.body())).await
    }

    async fn reply(&mut self, r: Result<Reply>) -> Result<()> {
        match r {
            Ok(reply) => self.send(&ServerMsg::Ok(reply)).await,
            Err(e) => self.err(&e).await,
        }
    }
}

/// Reads lines with a length limit enforced **before** the whole line is in memory.
struct Lines(BufReader<ReadHalf>);

impl Lines {
    async fn next_line(&mut self) -> std::io::Result<Option<Zeroizing<String>>> {
        use tokio::io::AsyncBufReadExt as _;
        let mut buf = Zeroizing::new(Vec::new());
        loop {
            let avail = self.0.fill_buf().await?;
            if avail.is_empty() {
                if buf.is_empty() {
                    return Ok(None);
                }
                break;
            }
            if let Some(i) = avail.iter().position(|b| *b == b'\n') {
                buf.extend_from_slice(&avail[..i]);
                self.0.consume(i + 1);
                break;
            }
            let n = avail.len();
            buf.extend_from_slice(avail);
            self.0.consume(n);
            if buf.len() > MAX_LINE {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "line too long",
                ));
            }
        }
        if buf.len() > MAX_LINE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "line too long",
            ));
        }
        let s = std::str::from_utf8(&buf)
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "not UTF-8"))?;
        Ok(Some(Zeroizing::new(s.to_string())))
    }
}

async fn read_line(lines: &mut Lines) -> Result<Option<Zeroizing<String>>> {
    lines
        .next_line()
        .await
        .map_err(|e| Error::bad_request(format!("bad line: {e}")))
}

fn parse<T: serde::de::DeserializeOwned>(l: &str) -> Result<T> {
    serde_json::from_str(l).map_err(|e| Error::bad_request(format!("bad message: {e}")))
}

async fn read_msg(lines: &mut Lines) -> Result<Option<ClientMsg>> {
    match read_line(lines).await? {
        None => Ok(None),
        Some(l) => parse(&l).map(Some),
    }
}

#[cfg(unix)]
fn own_uid() -> u32 {
    rustix::process::geteuid().as_raw()
}

enum Who {
    /// Owner: session (`tty` / `parent` / `held`, `None` without a session), the client's process chain, session token.
    Owner {
        session: Option<&'static str>,
        chain: Option<Vec<ProcStat>>,
        token: Option<String>,
    },
    Agent(AgentCtx),
}

#[cfg(unix)]
async fn handle(stream: UnixStream, node: Arc<Node>) -> Result<()> {
    // Only the same user as the daemon (permissions 0600 + SO_PEERCRED)
    let cred = stream.peer_cred()?;
    // The client's process chain is read right on connect (before hello): the client has no time to pass the socket
    // on and exit (on macOS by the socket's audit token, not by PID: PORTABILITY M-10)
    let chain = crate::procinfo::peer_ancestry(std::os::fd::AsFd::as_fd(&stream), cred.pid());
    let (r, w) = stream.into_split();
    let mut out = Out(w);
    if cred.uid() != own_uid() {
        out.err(&Error::new(code::FORBIDDEN, "different user"))
            .await?;
        return Ok(());
    }
    serve_conn(chain, r, out, node).await
}

/// Windows: who the client is, read right on connect, before a byte of it is acted on (D-135): its token, by
/// impersonation at identification level; then its PID, which is the client's word and only restricts. The client's
/// process (PID and creation time) is its chain if it was created before the connection.
#[cfg(windows)]
async fn handle(server: NamedPipeServer, at: u64, me: &Sid, node: Arc<Node>) -> Result<()> {
    use antenna_sys::windows::pipe;
    let token = pipe::client_token(&server);
    let pid = pipe::client_pid(&server).ok();
    let chain = pid
        .and_then(|p| i32::try_from(p).ok())
        .and_then(crate::procinfo::stat)
        .filter(|s| s.start <= at)
        .map(|s| vec![s]);
    let (r, w) = tokio::io::split(server);
    let mut out = Out(w);
    if let Err(why) = admit(token, me) {
        tracing::info!("control: client refused (pid {pid:?}): {why}");
        out.err(&Error::new(code::FORBIDDEN, why)).await?;
        return Ok(());
    }
    serve_conn(chain, r, out, node).await
}

/// The rule for a pipe client's token (D-135): the daemon's user, at medium integrity or above, not an AppContainer,
/// not restricted. An elevated client of the same user passes: refusing it protects nothing. Anything unreadable is a
/// refusal.
#[cfg(windows)]
fn admit(token: std::io::Result<TokenFacts>, me: &Sid) -> std::result::Result<(), String> {
    /// `SECURITY_MANDATORY_MEDIUM_RID`.
    const MEDIUM: u32 = 0x2000;
    let t = token.map_err(|e| format!("cannot read the client's identity: {e}"))?;
    if t.user != *me {
        return Err(format!("different user ({})", t.user));
    }
    if t.integrity < MEDIUM {
        return Err(format!(
            "the client runs below medium integrity ({:#x})",
            t.integrity
        ));
    }
    if t.app_container {
        return Err("the client runs in an AppContainer".into());
    }
    if t.restricted {
        return Err("the client runs with a restricted token".into());
    }
    Ok(())
}

/// A connection of the daemon's own user, with the client's process chain read on connect: hello, then the request
/// under the role it gets.
async fn serve_conn(
    chain: Option<Vec<ProcStat>>,
    r: ReadHalf,
    mut out: Out,
    node: Arc<Node>,
) -> Result<()> {
    // A process of a team's check sandbox gets no role at all (D-111): checks run the workers' code.
    if node
        .session_opt()
        .await
        .is_some_and(|s| s.is_jailed(tree(chain.as_deref())))
    {
        out.err(&Error::new(
            code::FORBIDDEN,
            "a check sandbox has no access to the daemon",
        ))
        .await?;
        return Ok(());
    }
    let mut lines = Lines(BufReader::new(r));
    let first = match tokio::time::timeout(HELLO_TIMEOUT, read_line(&mut lines)).await {
        Ok(r) => r?,
        Err(_) => return Ok(()),
    };
    let hello = match first {
        Some(l) => match parse::<HelloMsg>(&l) {
            Ok(HelloMsg::Hello(h)) => h,
            Err(_) => {
                out.err(&Error::bad_request("expected hello")).await?;
                return Ok(());
            }
        },
        None => return Ok(()),
    };
    if !CONTROL_SUPPORTED.contains(&hello.proto.as_str()) {
        out.err(&Error::bad_request(format!(
            "unsupported control protocol {}",
            hello.proto
        )))
        .await?;
        return Ok(());
    }
    let who = match hello.role {
        Role::Agent => {
            let Some(token) = hello.token.as_deref() else {
                // Without a token an agent is recognized only by the process tree of a bound MCP host (the host's
                // hooks are launched by it and do not see the `antenna mcp` environment); otherwise refused
                let by_tree = match node.session_opt().await {
                    Some(s) if !hello.bind_parent => s.agent_for_process(tree(chain.as_deref())),
                    _ => Ok(None),
                };
                match by_tree {
                    Ok(Some(mut ctx)) => {
                        ctx.forced = false;
                        let who = Who::Agent(ctx);
                        return finish_hello(who, hello.proto, node, lines, out).await;
                    }
                    Ok(None) => {
                        out.err(&Error::new(
                            code::TOKEN_INVALID,
                            "the agent role needs a token (ANTENNA_AGENT_TOKEN) or a process tree of a bound MCP host; \
                             the owner issues tokens with `antenna agent add`",
                        ))
                        .await?;
                    }
                    Err(e) => out.err(&e).await?,
                }
                return Ok(());
            };
            // On Windows no token is bound to a process: there is no tree to bind to, and the PID is the client's word
            // (D-135, WP-9). `bind_parent` asks nothing there, and the token alone admits its agent.
            let login = match node.session().await {
                Ok(s) => s.agent_login(
                    token,
                    tree(chain.as_deref()),
                    hello.bind_parent && !cfg!(windows),
                ),
                Err(e) => Err(e),
            };
            match login {
                Ok(ctx) => Who::Agent(ctx),
                Err(e) => {
                    out.err(&e).await?;
                    return Ok(());
                }
            }
        }
        Role::Owner => {
            if hello.token.is_some() || hello.bind_parent {
                out.err(&Error::bad_request("the owner role takes no token"))
                    .await?;
                return Ok(());
            }
            let chain = chain.clone();
            // A process in the tree of a bound agent is an agent, whatever it calls itself (D-28)
            let forced = match node.session_opt().await {
                Some(s) => s.agent_for_process(tree(chain.as_deref())),
                None => Ok(None),
            };
            match forced {
                Ok(Some(ctx)) => Who::Agent(ctx),
                Ok(None) => {
                    // Owner session (Q-14b): without it, a process with the same uid is not the owner
                    let session = node
                        .owner_sessions
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .check(chain.as_deref(), hello.session.as_deref(), now_ms());
                    Who::Owner {
                        session,
                        chain,
                        token: hello.session.clone(),
                    }
                }
                Err(e) => {
                    out.err(&e).await?;
                    return Ok(());
                }
            }
        }
    };
    finish_hello(who, hello.proto, node, lines, out).await
}

/// The client's process tree for what gives or keeps a role by process: the check sandbox (D-111), an agent by its
/// MCP host's tree (D-28), a token bound to a process. On Windows the chain is the client alone and its PID is the
/// client's word (D-135), so these see no chain there and decide as without one: agents come by token only.
fn tree(chain: Option<&[ProcStat]>) -> Option<&[ProcStat]> {
    if cfg!(windows) { None } else { chain }
}

/// Reply to hello and parse the request according to the effective role.
async fn finish_hello(
    who: Who,
    proto: String,
    node: Arc<Node>,
    mut lines: Lines,
    mut out: Out,
) -> Result<()> {
    let (role, agent, forced, session) = match &who {
        Who::Owner { session, .. } => (
            Role::Owner,
            None,
            false,
            Some(session.unwrap_or("none").to_string()),
        ),
        Who::Agent(c) => (Role::Agent, Some(c.name.clone()), c.forced, None),
    };
    out.send(&ServerMsg::HelloOk(HelloOk {
        daemon: node.daemon_version().to_string(),
        protocol: crate::PROTOCOL_VERSION.to_string(),
        state: node.state_name().await.into(),
        role,
        agent,
        forced,
        proto: proto.clone(),
        session,
    }))
    .await?;
    // The request must come right after hello: an idle connection does not take up a slot
    let line = match tokio::time::timeout(HELLO_TIMEOUT, read_line(&mut lines)).await {
        Ok(r) => r?,
        Err(_) => return Ok(()),
    };
    let Some(line) = line else {
        return Ok(());
    };
    match who {
        Who::Owner {
            session,
            chain,
            token,
        } => match auth::parse_owner_line(&line) {
            Ok((ClientMsg::Req(Request::Subscribe {}), Some(_))) => {
                out.err(&Error::bad_request("subscribe takes no proof"))
                    .await
            }
            Ok((ClientMsg::Req(Request::Subscribe {}), None)) if session.is_none() => {
                match node.session().await {
                    Ok(_) => out.err(&login_required()).await,
                    Err(e) => out.err(&e).await,
                }
            }
            Ok((ClientMsg::Req(Request::Subscribe {}), None)) => match node.session().await {
                Ok(s) => {
                    // Long-lived connection: the session is rechecked (without extending it), any kind, not only `held`
                    let recheck = Recheck::Owner {
                        node: node.clone(),
                        chain: chain.clone(),
                        token: token.clone(),
                    };
                    subscribe(s, None, proto, lines, out, recheck).await
                }
                Err(e) => out.err(&e).await,
            },
            Ok((ClientMsg::Req(Request::AgentWatch { .. }), Some(_))) => {
                out.err(&Error::bad_request("agent_watch takes no proof"))
                    .await
            }
            // The window that started an agent watches that agent's facts without an owner session (D-103)
            Ok((ClientMsg::Req(Request::AgentWatch { agent }), None)) => match node.session().await
            {
                Ok(s) => match s.agent_watch(&agent, chain.as_deref()) {
                    Ok(ctx) => {
                        let recheck = Recheck::Watch {
                            agent,
                            chain: chain.unwrap_or_default(),
                        };
                        subscribe(s, Some(ctx), proto, lines, out, recheck).await
                    }
                    Err(e) => out.err(&e).await,
                },
                Err(e) => out.err(&e).await,
            },
            Ok((ClientMsg::Req(req), proven)) => {
                let ctx = OwnerCtx {
                    session,
                    chain,
                    token,
                };
                owner(req, proven, node, lines, out, ctx).await
            }
            Ok(_) => out.err(&Error::bad_request("expected req")).await,
            Err(e) => out.err(&e).await,
        },
        Who::Agent(ctx) => {
            // Every request of this agent passes here (MCP, the CLI with the token, hooks by the process tree): the
            // one place that knows the agent is active (`last_seen_ms`)
            node.note_agent_seen(ctx.id);
            let v: serde_json::Value = match parse(&line) {
                Ok(v) => v,
                Err(e) => return out.err(&e).await,
            };
            let cmd = v["req"]["cmd"].as_str().unwrap_or("").to_string();
            if !AgentRequest::NAMES.contains(&cmd.as_str()) {
                // An agent does not have this command at all (SPEC §9): not "forbidden" but "no such command"
                return out
                    .err(&Error::new(
                        code::UNKNOWN_COMMAND,
                        format!("no such command: {cmd:?}"),
                    ))
                    .await;
            }
            match serde_json::from_value::<AgentMsg>(v) {
                Ok(AgentMsg::Req(AgentRequest::Subscribe {})) => match node.session().await {
                    Ok(s) => subscribe(s, Some(ctx), proto, lines, out, Recheck::Agent).await,
                    Err(e) => out.err(&e).await,
                },
                Ok(AgentMsg::Req(AgentRequest::SendStream {
                    contact,
                    wait_ms,
                    to,
                    to_agent,
                    topic,
                    topic_id,
                })) => match node.session().await {
                    Ok(s) => {
                        let req = AddrReq::new(to, to_agent, topic, topic_id);
                        send_stream(s, Author::Agent(ctx), contact, wait_ms, req, lines, out).await
                    }
                    Err(e) => out.err(&e).await,
                },
                Ok(AgentMsg::Req(AgentRequest::ShareFileContent {
                    contact,
                    name,
                    size,
                    approval_id,
                    to,
                    to_agent,
                })) => match (
                    node.session().await,
                    crate::addressing::file_addr(to, to_agent),
                ) {
                    (Ok(s), Ok(addr)) => {
                        let req = ContentReq {
                            contact,
                            name,
                            size,
                            approval_id,
                            addr,
                        };
                        share_content(s, ctx, req, lines, out).await
                    }
                    (Err(e), _) | (_, Err(e)) => out.err(&e).await,
                },
                Ok(AgentMsg::Req(req)) => agent_req(ctx, req, node, out).await,
                Ok(_) => out.err(&Error::bad_request("expected req")).await,
                Err(e) => {
                    out.err(&Error::bad_request(format!("bad message: {e}")))
                        .await
                }
            }
        }
    }
}

// Owner

mod auth;
mod requests;
mod watch;

/// Session of an owner connection.
struct OwnerCtx {
    session: Option<&'static str>,
    chain: Option<Vec<ProcStat>>,
    token: Option<String>,
}

fn login_required() -> Error {
    Error::new(
        code::LOGIN_REQUIRED,
        "no owner session: run `antenna login` in this terminal (a script: `antenna login --password-stdin`; a window: \
         `login {hold: true}`); the session lasts 15 minutes after the last command",
    )
}

async fn owner(
    req: Request,
    proven: Option<auth::Proven>,
    node: Arc<Node>,
    lines: Lines,
    mut out: Out,
    ctx: OwnerCtx,
) -> Result<()> {
    tracing::debug!("control (owner): {req:?}");
    // The session, then the password (Q-14b, Q-12a), or an owner proof in place of the password (v7, D-102)
    let auth = match auth::authorize(&req, proven.as_ref(), &node, &ctx).await {
        Ok(a) => a,
        Err(e) => return out.err(&e).await,
    };
    match req {
        Request::Invite { .. } => invite(req, node, lines, out).await,
        Request::Join { .. } => join_dialog(req, node, lines, out).await,
        Request::SendStream {
            contact,
            wait_ms,
            to,
            to_agent,
            topic,
            topic_id,
        } => match node.session().await {
            Ok(s) => {
                let req = AddrReq::new(to, to_agent, topic, topic_id);
                send_stream(s, Author::Owner, contact, wait_ms, req, lines, out).await
            }
            Err(e) => out.err(&e).await,
        },
        Request::WakeSay {
            contact,
            text,
            to_contact,
            interrupt,
            timeout_ms,
        } => match node.session().await {
            Ok(s) => wake_say(s, contact, text, to_contact, interrupt, timeout_ms, out).await,
            Err(e) => out.err(&e).await,
        },
        Request::LocalSay {
            agent,
            text,
            interrupt,
            timeout_ms,
        } => match node.session().await {
            Ok(s) => local_say(s, agent, text, interrupt, timeout_ms, out).await,
            Err(e) => out.err(&e).await,
        },
        Request::TeamWatch(r) => match node.session().await {
            Ok(s) => watch::team_watch(s, r.team, &node, ctx, lines, out).await,
            Err(e) => out.err(&e).await,
        },
        Request::Login { password, hold } => {
            let proven = auth == auth::Auth::Proof;
            login(node, lines, out, &ctx, password, hold, proven).await
        }
        other => {
            let r = execute_owner(other, &node, &ctx).await;
            match r {
                Ok(reply) => out.send(&ServerMsg::Ok(reply)).await,
                Err(body) => out.send(&ServerMsg::Err(body)).await,
            }
        }
    }
}

/// Terminal session after a correct password (only for a client with a terminal: scripts get sessions by an explicit
/// `login`).
fn open_tty_session(node: &Node, chain: Option<&[ProcStat]>) {
    if matches!(owner::timed_key(chain), Some(owner::TimedKey::Tty { .. })) {
        let _ = node
            .owner_sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .open_timed(chain, now_ms());
    }
}

/// `login`: owner password (or, v7, an owner proof checked in `authorize`) → a terminal/parent session for 15
/// minutes or a session in this connection (`hold`).
async fn login(
    node: Arc<Node>,
    mut lines: Lines,
    mut out: Out,
    ctx: &OwnerCtx,
    password: String,
    hold: bool,
    proven: bool,
) -> Result<()> {
    let pw = Zeroizing::new(password);
    if !proven && let Err(e) = node.verify_password(&pw).await {
        return out.err(&e).await;
    }
    if !hold {
        let r = node
            .owner_sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .open_timed(ctx.chain.as_deref(), now_ms());
        return match r {
            Ok((kind, expires_ms)) => {
                out.send(&ServerMsg::Ok(Reply::OwnerSession(
                    antenna_proto::control::OwnerSession {
                        kind: kind.into(),
                        expires_ms,
                    },
                )))
                .await
            }
            Err(e) => out.err(&e).await,
        };
    }
    let held = node
        .owner_sessions
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .open_held(ctx.chain.as_deref());
    let guard = match held {
        Ok(g) => g,
        Err(e) => return out.err(&e).await,
    };
    // An automatic install is announced to a window that holds a session before it starts (D-103).
    let _window = node.auto_window();
    out.send(&ServerMsg::Event(Event::Session {
        token: antenna_proto::control::SecretString(guard.token.to_string()),
        mode: "held".into(),
    }))
    .await?;
    // The session lives while the client holds the connection (or until `antenna lock`)
    let session = node.session_opt().await;
    loop {
        tokio::select! {
            r = read_line(&mut lines) => match r {
                Ok(Some(_)) => continue,
                _ => break,
            },
            _ = async {
                match &session {
                    Some(s) => s.closed_wait().await,
                    None => std::future::pending().await,
                }
            } => {
                let _ = out.err(&Error::new(code::LOCKED, "keystore was locked")).await;
                break;
            }
        }
    }
    node.owner_sessions
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .drop_held(&guard.hash());
    drop(guard);
    Ok(())
}

/// The owner's one-reply requests (the checks of [`owner`] have passed): one handler per command, in `requests`.
async fn execute_owner(req: Request, node: &Node, ctx: &OwnerCtx) -> requests::Answer {
    use requests::{
        agents, approvals, chats, devices, files, links, local, messages, owner_keys, pairing,
        pictures, teams, wake,
    };
    match req {
        Request::Status {} => Ok(Reply::Status(node.status().await)),
        Request::Init { password } => requests::node::init(node, ctx, password).await,
        Request::Unlock {
            password,
            key_id,
            slot_key,
        } => requests::node::unlock(node, ctx, password, key_id, slot_key).await,
        Request::Lock {} => requests::node::lock(node).await,
        Request::Logout {} => requests::node::logout(node, ctx),
        Request::Login { .. } => Err(Error::internal("handled by the login dialog").body()),
        Request::LanSet { enabled, .. } => requests::node::lan_set(node, enabled).await,
        Request::LanStatus {} => requests::node::lan_status(node).await,
        Request::UpdateAuthorize {
            action, version, ..
        } => requests::node::update_authorize(node, action, version),
        Request::OwnerChallenge { enroll } => owner_keys::challenge(node, ctx, enroll).await,
        Request::OwnerKeyAdd {
            public_key,
            label,
            unlock,
            password,
        } => owner_keys::add(node, public_key, label, unlock, password).await,
        Request::OwnerKeyList {} => owner_keys::list(node).await,
        Request::OwnerKeyRemove { key_id } => owner_keys::remove(node, key_id).await,
        Request::Pairings {
            wait,
            timeout_ms,
            password,
        } => pairing::pairings(node, wait, timeout_ms, password).await,
        Request::PairingConfirm { id, code, .. } => pairing::pairing_confirm(node, id, code).await,
        Request::PairingCancel { id, .. } => pairing::pairing_cancel(node, id).await,
        Request::Contacts {} => links::contacts(node).await,
        Request::Trust { contact, level, .. } => links::trust(node, contact, level).await,
        Request::Rename { contact, label } => links::rename(node, contact, label).await,
        Request::Revoke {
            contact,
            delete_history,
            ..
        } => links::revoke(node, contact, delete_history).await,
        Request::HistoryStatus { contact } => links::history_status(node, contact).await,
        Request::Verify {
            contact,
            accept,
            repair,
            ..
        } => links::verify(node, contact, accept, repair).await,
        Request::Rekey { contact, code, .. } => links::rekey(node, contact, code).await,
        Request::Send { .. } => messages::send(node, req).await,
        Request::Inbox {
            wait,
            timeout_ms,
            contact,
        } => messages::inbox(node, wait, timeout_ms, contact).await,
        Request::History {
            contact,
            before,
            limit,
            chat,
        } => messages::history(node, contact, before, limit, chat).await,
        Request::MarkRead {
            contact,
            up_to_seq,
            ids,
            chat,
        } => messages::mark_read(node, contact, up_to_seq, ids, chat).await,
        Request::Topics { contact } => messages::topics(node, contact).await,
        Request::Chats { contact } => chats::list(node, contact).await,
        Request::ChatSet { .. } => chats::set(node, req).await,
        Request::Pictures {} => pictures::list(node).await,
        Request::PictureSet { .. } => pictures::set(node, req).await,
        Request::PicturePhoto { id } => pictures::photo(node, id).await,
        Request::Log { contact, limit } => messages::log(node, contact, limit).await,
        Request::Streams {} => messages::streams(node).await,
        Request::SendStream { .. } => Err(Error::bad_request("send_stream is a dialog").body()),
        Request::Approvals { all } => approvals::approvals(node, all).await,
        Request::Approve {
            id, fingerprint, ..
        } => approvals::approve(node, id, fingerprint).await,
        Request::ApproveMany { items, .. } => approvals::approve_many(node, items).await,
        Request::Deny { id, hour, .. } => approvals::deny(node, id, hour).await,
        Request::DenyMany { ids, hour } => approvals::deny_many(node, ids, hour).await,
        Request::AgentAdd {
            name,
            links,
            local_level,
            everyone,
            token_file,
            ..
        } => agents::add(node, name, links, local_level, everyone, token_file).await,
        Request::AgentSet { name, everyone, .. } => agents::set(node, name, everyone).await,
        Request::AgentList {} => agents::list(node).await,
        Request::AgentReset { name, .. } => agents::reset(node, name).await,
        Request::AgentToken {
            name, token_file, ..
        } => agents::token(node, name, token_file).await,
        Request::AgentTasks { name, contacts, .. } => agents::tasks(node, name, contacts).await,
        Request::AgentEscalate { name, to, .. } => agents::escalate_to(node, name, to).await,
        Request::Escalations { all } => agents::escalations(node, all).await,
        Request::EscalationAnswer {
            id,
            answer,
            dismiss,
        } => agents::escalation_answer(node, id, answer, dismiss).await,
        Request::AgentRemove { name, .. } => agents::remove(node, name).await,
        Request::AgentConnect(r) => agents::connect(node, r).await,
        Request::AgentDisconnect(r) => agents::disconnect(node, r).await,
        Request::AgentTraffic(r) => agents::traffic(node, r).await,
        Request::ApproverSet(r) => approvals::approver_set(node, r).await,
        Request::ApproverNarrow(r) => approvals::approver_narrow(node, r).await,
        Request::ApproverRemove(r) => approvals::approver_remove(node, r).await,
        Request::Approvers(_) => approvals::approvers(node).await,
        Request::AgentTerminal(r) => requests::stop::terminal(node, ctx, r).await,
        Request::AgentStop(r) => requests::stop::stop(node, ctx, r).await,
        Request::DeviceAgentStop(r) => requests::stop::device_stop(node, r).await,
        Request::ShareFile {
            contact,
            path,
            name,
            approval_id,
            to,
            to_agent,
        } => {
            let addr = crate::addressing::file_addr(to, to_agent).map_err(|e| e.body())?;
            files::share(node, contact, path, name, approval_id, addr).await
        }
        Request::RequestFile { contact, path } => files::request(node, contact, path).await,
        Request::FilesPending { contact, all } => files::pending(node, contact, all).await,
        Request::FilePreview { id } => files::preview(node, id).await,
        Request::FileAccept {
            id,
            name,
            force,
            allow_special,
            ..
        } => files::accept(node, id, name, force, allow_special).await,
        Request::FileReject { id } => files::reject(node, id).await,
        Request::FileWithdraw { id } => files::withdraw(node, id).await,
        Request::WakeSet { .. } => wake::set(node, req).await,
        Request::WakeList {} => wake::list(node).await,
        Request::WakeOff { contact } => wake::off(node, contact).await,
        Request::WakeSession {
            contact, action, ..
        } => wake::resident_session(node, contact, action).await,
        Request::WakeSay { .. } => Err(Error::bad_request("wake_say is a dialog").body()),
        Request::LocalModels {} => local::models(node).await,
        Request::ModelInstall { model, from_file } => local::install(node, model, from_file).await,
        Request::ModelRemove { model } => local::remove(node, model).await,
        Request::LocalAgentAdd { name, model, .. } => local::agent_add(node, name, model).await,
        Request::LocalHistory {
            agent,
            limit,
            before,
        } => local::history(node, agent, limit, before).await,
        Request::LocalSession { agent, action } => local::local_session(node, agent, action).await,
        Request::LocalSay { .. } => Err(Error::bad_request("local_say is a dialog").body()),
        Request::UpdateAutoSet { enabled, password } => {
            requests::node::update_auto_set(node, enabled, password).await
        }
        Request::UpdateAutoStatus {} => requests::node::update_auto_status(node).await,
        Request::UpdateAutoNow { password } => {
            requests::node::update_auto_now(node, password).await
        }
        Request::UpdateAutoLater {} => requests::node::update_auto_later(node).await,
        Request::FileNameCheck { id, name } => files::name_check(node, id, name).await,
        Request::FileAllow {
            contact, entries, ..
        } => files::allow(node, contact, entries).await,
        Request::FileDisallow { contact, entries } => files::disallow(node, contact, entries).await,
        Request::FileSaveDir {
            contact,
            agent,
            path,
            ..
        } => files::save_dir(node, contact, agent, path).await,
        Request::TeamCreate(r) => teams::create(node, *r).await,
        Request::TeamSet(r) => teams::set(node, *r).await,
        Request::TeamList(_) => teams::list(node).await,
        Request::TeamShow(r) => teams::show(node, r).await,
        Request::TeamAddWorker(r) => teams::add_worker(node, r).await,
        Request::TeamStop(r) => teams::stop(node, r).await,
        Request::TeamRemove(r) => teams::remove(node, r).await,
        Request::TeamApply(r) => teams::apply(node, r).await,
        Request::TeamLog(r) => teams::log(node, r).await,
        Request::TaskNew(r) => teams::task_new(node, r).await,
        Request::TaskList(r) => teams::task_list(node, r).await,
        Request::TaskShow(r) => teams::task_show(node, r).await,
        Request::TaskDiff(r) => teams::task_diff(node, r).await,
        Request::TaskReview(r) => teams::task_review(node, r).await,
        Request::TaskApply(r) => teams::task_apply(node, r).await,
        Request::TaskAssign(r) => teams::task_assign(node, r).await,
        Request::TeamCapacity(r) => teams::capacity(node, r).await,
        Request::TeamWatch(_) => Err(Error::bad_request("team_watch is a dialog").body()),
        Request::AgentWatch { .. } => Err(Error::internal("handled by a dialog").body()),
        Request::Devices {} => devices::list(node).await,
        Request::DeviceChallenge { contact } => devices::challenge(node, contact).await,
        Request::DeviceApprove {
            contact,
            request,
            nonce,
            key_id,
            sig,
        } => devices::approve(node, contact, request, nonce, key_id, sig).await,
        Request::DeviceDecide {
            contact,
            id,
            decision,
            fingerprint,
            ..
        } => devices::decide(node, contact, id, decision, fingerprint).await,
        Request::DeviceKeysConfirm {
            contact, key_ids, ..
        } => devices::keys_confirm(node, contact, key_ids).await,
        Request::DeviceKeysRemove { contact, key_ids } => {
            devices::keys_remove(node, contact, key_ids).await
        }
        Request::DeviceLendSet { enabled, .. } => devices::lend_set(node, enabled).await,
        Request::DeviceRevoke {
            contact,
            delete_history,
            ..
        } => devices::revoke(node, contact, delete_history).await,
        Request::DeviceLostDismiss { contact } => devices::lost_dismiss(node, contact).await,
        Request::Invite { .. } | Request::Join { .. } | Request::Subscribe {} => {
            Err(Error::internal("handled by a dialog").body())
        }
    }
}

/// `antenna invite`: the invite is created in the daemon (Q-7); the connection may watch and confirm it (it has
/// already passed the password check), but closing the connection does not burn the invite.
async fn invite(req: Request, node: Arc<Node>, mut lines: Lines, mut out: Out) -> Result<()> {
    let Request::Invite {
        trust,
        ttl_secs,
        label,
        auto_confirm,
        follow,
        ..
    } = req
    else {
        return out.err(&Error::internal("not an invite")).await;
    };
    let cfg = node.config().clone();
    // Auto-confirmation removes the protection of SPEC §6 item 9: only for a daemon started for tests
    if auto_confirm && !cfg.allow_auto_confirm {
        return out
            .err(&Error::new(
                code::FORBIDDEN,
                "--confirm is disabled: the owner must confirm after hearing the code matched \
                 (antennad --allow-auto-confirm is for tests only)",
            ))
            .await;
    }
    let session = match node.session().await {
        Ok(s) => s,
        Err(e) => return out.err(&e).await,
    };
    let entry = match invites::create(
        session,
        &cfg.net,
        trust,
        Duration::from_secs(ttl_secs),
        label,
        auto_confirm,
    )
    .await
    {
        Ok(e) => e,
        Err(e) => return out.err(&e).await,
    };
    let mut events = entry.subscribe();
    let mut done = entry.done();
    let info = entry.info();
    out.send(&ServerMsg::Event(Event::InviteCreated {
        id: info.id.clone(),
        link: info.link.clone(),
        link_app: info.link_app.clone(),
        expires_ms: info.expires_ms,
        trust: info.trust,
        net_mode: info.net_mode.clone(),
    }))
    .await?;
    if !follow {
        return out.send(&ServerMsg::Ok(Reply::InviteCreated(info))).await;
    }
    // Owner input on this connection: only "yes/no" to the daemon's question; EOF = the client left (the invite lives).
    // "Yes" carries the code the owner typed (as read out by the other side), or no code when the daemon offered that
    // (`confirm_without_code`, D-95); a code of another invite, or no code when it is required, is refused with an
    // `input_rejected` event (formal model F-4/F-6, PROTOCOL §9, §15).
    let e2 = entry.clone();
    let (rej_tx, mut rej_rx) = mpsc::unbounded_channel::<Event>();
    let mut reader = tokio::spawn(async move {
        while let Ok(Some(m)) = read_msg(&mut lines).await {
            if let ClientMsg::Input(Input::Confirm { yes, code }) = m {
                let r = e2.decide(yes, code.as_deref());
                if let Err(e) = r {
                    tracing::debug!("invite {}: input rejected: {}", e2.id, e.code);
                    let _ = rej_tx.send(Event::InputRejected {
                        what: "confirm".into(),
                        code: e.code.into(),
                        message: e.message,
                    });
                }
            }
        }
    });
    let outcome = loop {
        tokio::select! {
            Some(ev) = rej_rx.recv() => {
                if out.send(&ServerMsg::Event(ev)).await.is_err() {
                    reader.abort();
                    return Ok(());
                }
            }
            ev = events.recv() => match ev {
                Ok(ev) => {
                    if out.send(&ServerMsg::Event(ev)).await.is_err() {
                        reader.abort();
                        return Ok(());
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
            },
            r = async { done.wait_for(|d| d.is_some()).await.map(|v| v.clone()) } => {
                break r.ok().flatten();
            }
            _ = &mut reader => {
                tracing::debug!("invite {}: client detached; the invite stays in the daemon", entry.id);
                return Ok(());
            }
        }
    };
    reader.abort();
    while let Ok(ev) = events.try_recv() {
        let _ = out.send(&ServerMsg::Event(ev)).await;
    }
    match outcome {
        Some(Ok(l)) => out.send(&ServerMsg::Ok(Reply::Linked(l))).await,
        Some(Err(b)) => out.send(&ServerMsg::Err(b)).await,
        None => {
            out.err(&Error::internal("invite finished without result"))
                .await
        }
    }
}

/// Side B's pairing dialog: events go to the client, code input comes from the same connection.
async fn join_dialog(req: Request, node: Arc<Node>, mut lines: Lines, mut out: Out) -> Result<()> {
    let session = match node.session().await {
        Ok(s) => s,
        Err(e) => return out.err(&e).await,
    };
    let Request::Join {
        link,
        trust,
        label,
        sas_code,
        connect_timeout_ms,
        ..
    } = req
    else {
        return out.err(&Error::internal("not a join")).await;
    };
    let (ev_tx, mut ev_rx) = mpsc::unbounded_channel::<Event>();
    let (in_tx, in_rx) = mpsc::unbounded_channel::<Input>();
    // Owner input; EOF (the client closed `antenna join`) closes the channel, which is a refusal
    let reader = tokio::spawn(async move {
        while let Ok(Some(m)) = read_msg(&mut lines).await {
            if let ClientMsg::Input(i) = m
                && in_tx.send(i).is_err()
            {
                break;
            }
        }
    });
    let mut ui = Ui {
        events: ev_tx,
        inputs: in_rx,
    };
    let cfg = node.config().clone();
    let s2 = session.clone();
    let persist: pairing::Persist<'_> = Box::new(move |rec| s2.persist_link(rec));
    let fut = pairing::run_joiner(
        &cfg.net,
        &link,
        trust,
        label,
        sas_code,
        Duration::from_millis(connect_timeout_ms.clamp(1000, 120_000)),
        &mut ui,
        persist,
    );
    tokio::pin!(fut);
    let result = loop {
        tokio::select! {
            r = &mut fut => break r,
            Some(ev) = ev_rx.recv() => {
                let _ = out.send(&ServerMsg::Event(ev)).await;
            }
            // `antenna lock` during pairing: the session is aborted, keys and the DB are not held (Q-4)
            _ = session.closed_wait() => {
                break Err(Error::new(code::LOCKED, "keystore was locked during pairing"));
            }
        }
    };
    while let Ok(ev) = ev_rx.try_recv() {
        let _ = out.send(&ServerMsg::Event(ev)).await;
    }
    reader.abort();
    match result {
        Ok(p) => {
            let reply = LinkedReply {
                contact: p.label.clone(),
                link_id: p.link_id.to_hex(),
                trust: p.trust,
                net_mode: p.net_mode.as_str().into(),
                kx_group: p.kx_group.clone(),
                pairing_ms: p.pairing_ms,
            };
            match session.start_paired_link(p).await {
                Ok(()) => out.send(&ServerMsg::Ok(Reply::Linked(reply))).await,
                Err(e) => out.err(&e).await,
            }
        }
        Err(e) => out.err(&e).await,
    }
}

// Agent

async fn agent_req(ctx: AgentCtx, req: AgentRequest, node: Arc<Node>, mut out: Out) -> Result<()> {
    tracing::debug!("control (agent {}): {req:?}", ctx.name);
    let session = match node.session().await {
        Ok(s) => s,
        Err(e) => return out.err(&e).await,
    };
    let s = &session;
    let ms = |t: Option<u64>| t.map(Duration::from_millis);
    let r: Result<Reply> = async {
        Ok(match req {
            AgentRequest::Status {} => {
                // For an agent: without the total number of links
                let mut st = node.status().await;
                st.links = None;
                Reply::Status(st)
            }
            AgentRequest::Contacts {} => Reply::AgentContacts {
                contacts: s.agent_contacts(&ctx)?,
            },
            AgentRequest::GetTrust { contact } => Reply::Trust(s.agent_trust(&ctx, &contact)?),
            AgentRequest::SendStream { .. } => {
                return Err(Error::bad_request("send_stream is a dialog"));
            }
            AgentRequest::ShareFileContent { .. } => {
                return Err(Error::bad_request("share_file_content is a dialog"));
            }
            AgentRequest::Send {
                contact,
                text,
                wait_ms,
                approval_id,
                to,
                to_agent,
                topic,
                topic_id,
                local,
            } => Reply::Sent(
                s.agent_send(
                    &ctx,
                    &contact,
                    &text,
                    Duration::from_millis(wait_ms.min(60_000)),
                    approval_id.as_deref(),
                    &AddrReq::new(to, to_agent, topic, topic_id).local(local),
                )
                .await?,
            ),
            AgentRequest::Inbox {
                wait,
                timeout_ms,
                contact,
            } => Reply::AgentInbox(
                s.agent_inbox(&ctx, wait, ms(timeout_ms), contact.as_deref())
                    .await?,
            ),
            AgentRequest::Wait {
                timeout_ms,
                contact,
            } => {
                let (pending, approvals) = s
                    .agent_wait(&ctx, ms(timeout_ms), contact.as_deref())
                    .await?;
                Reply::Waited {
                    pending,
                    approvals,
                    tasks: s.take_team_facts(ctx.id),
                    escalations: s.take_escalation_answers(ctx.id),
                    to_answer: s.take_to_answer(ctx.id),
                    files: s.file_facts(ctx.id),
                }
            }
            AgentRequest::Session {} => Reply::Session(s.agent_session(&ctx)?),
            AgentRequest::MarkRead { level, what } => {
                Reply::Session(s.agent_mark_read(&ctx, level, &what)?)
            }
            AgentRequest::Check { action, detail } => {
                Reply::Check(s.agent_check(&ctx, &action, &detail)?)
            }
            AgentRequest::Log { contact, limit } => Reply::Log {
                entries: s.agent_log(&ctx, &contact, limit)?,
                contact,
            },
            AgentRequest::ShareFile {
                contact,
                path,
                name,
                approval_id,
                to,
                to_agent,
            } => Reply::File(
                s.agent_share_file(
                    &ctx,
                    &contact,
                    &path,
                    name.as_deref(),
                    approval_id.as_deref(),
                    &crate::addressing::file_addr(to, to_agent)?,
                )
                .await?,
            ),
            AgentRequest::RequestFile { contact, path } => {
                let (contact, id, status) = s.agent_request_file(&ctx, &contact, &path).await?;
                Reply::FileRequested {
                    contact,
                    id,
                    status,
                }
            }
            AgentRequest::FilesPending { contact, all } => Reply::Files {
                files: s.agent_files_pending(&ctx, contact.as_deref(), all)?,
            },
            AgentRequest::FilePreview { id } => {
                let (file, preview) = s.agent_file_preview(&ctx, &id)?;
                Reply::FilePreview { file, preview }
            }
            AgentRequest::FileAccept {
                id,
                name,
                approval_id,
            } => Reply::File(
                s.agent_file_accept(&ctx, &id, name.as_deref(), approval_id.as_deref())
                    .await?,
            ),
            AgentRequest::FileReject { id } => Reply::File(s.agent_file_reject(&ctx, &id).await?),
            AgentRequest::History {
                contact,
                before,
                limit,
            } => Reply::History(s.agent_history(&ctx, &contact, before, limit)?),
            AgentRequest::Subscribe {} => {
                return Err(Error::internal("handled by the subscription dialog"));
            }
            AgentRequest::HistoryStatus { contact } => {
                let row = s.agent_link(&ctx, &contact)?;
                Reply::HistoryStatus(s.history_status(&row)?)
            }
            AgentRequest::Verify { contact } => {
                let row = s.agent_link(&ctx, &contact)?;
                Reply::HistoryStatus(s.verify(&row, false, false).await?)
            }
            r @ (AgentRequest::TeamInfo(_)
            | AgentRequest::TaskList(_)
            | AgentRequest::TaskGet(_)
            | AgentRequest::TaskCreate(_)
            | AgentRequest::TaskAssign(_)
            | AgentRequest::TaskReview(_)
            | AgentRequest::TaskDiff(_)
            | AgentRequest::TaskNote(_)
            | AgentRequest::TaskReport(_)
            | AgentRequest::RunCheck(_)
            | AgentRequest::ApplyResult(_)
            | AgentRequest::WorkerSpawn(_)
            | AgentRequest::WorkerStop(_)
            | AgentRequest::Capacity(_)) => session.agent_team(&ctx, r).await?,
            AgentRequest::Escalate { question, wait_ms } => Reply::Escalation(
                s.agent_escalate(&ctx, &question, wait_ms.map(Duration::from_millis))
                    .await?,
            ),
            AgentRequest::EscalationGet { id } => {
                Reply::Escalation(s.agent_escalation_get(&ctx, &id)?)
            }
            AgentRequest::ApprovalsToAnswer(_) => Reply::ToAnswer(s.agent_to_answer(&ctx)?),
            AgentRequest::ApprovalAnswer(a) => {
                Reply::Answered(session.agent_approval_answer(&ctx, &a).await?)
            }
        })
    }
    .await;
    out.reply(r).await
}

// Event subscription (v1)

/// One long-lived connection: node events until the client closes the connection (or `antenna lock`).
/// For an agent, only its own links: facts about incoming messages without text (SPEC §11), its own approval requests.
/// What a long-lived subscription checks again every few seconds.
enum Recheck {
    /// An agent's own subscription: the agent still exists.
    Agent,
    /// The owner's: the owner session still holds.
    Owner {
        node: Arc<Node>,
        chain: Option<Vec<ProcStat>>,
        token: Option<String>,
    },
    /// `agent_watch` (D-103): the agent exists, runs, and the client is still an ancestor of its process.
    Watch { agent: String, chain: Vec<ProcStat> },
}

async fn subscribe(
    session: Arc<Session>,
    agent: Option<AgentCtx>,
    proto: String,
    mut lines: Lines,
    mut out: Out,
    recheck: Recheck,
) -> Result<()> {
    let mut rx = session.events.subscribe();
    let scope = match &agent {
        Some(ctx) => match session.agent_scope(ctx) {
            Ok(s) => Some(s),
            Err(e) => return out.err(&e).await,
        },
        None => None,
    };
    let version = proto_version(&proto);
    out.send(&ServerMsg::Event(Event::Subscribed {
        proto,
        role: if agent.is_some() {
            Role::Agent
        } else {
            Role::Owner
        },
    }))
    .await?;
    // `agent_watch`: the messages that already wait come first, as facts (D-108): a session or a restored window that
    // starts watching after they arrived still wakes its agent. The events are subscribed to before this read, so a
    // message that lands in between may come twice; the watcher coalesces facts per contact.
    if let (Recheck::Watch { .. }, Some(ctx)) = (&recheck, &agent) {
        for r in session.agent_unread_rows(ctx, 100).unwrap_or_default() {
            let fact = Event::MessageFact {
                contact: r.label,
                id: r.id.to_hex(),
                trust: r.trust,
                chars: r.body.chars().count() as u64,
                received_ms: r.received_ms,
                // What already waits is never urgent: "now" was when it arrived (PG-58)
                urgent: false,
                local: None,
            };
            if out.send(&ServerMsg::Event(fact)).await.is_err() {
                return Ok(());
            }
        }
        // And those over a local route (D-132)
        for f in session.local_facts(ctx.id) {
            let fact = Event::MessageFact {
                contact: f.from.clone(),
                id: f.id,
                trust: f.trust,
                chars: f.chars,
                received_ms: f.at_ms,
                local: Some(f.from),
                urgent: false,
            };
            if out.send(&ServerMsg::Event(fact)).await.is_err() {
                return Ok(());
            }
        }
    }
    // The client closed the connection: the subscription is over
    let mut reader =
        tokio::spawn(async move { while let Ok(Some(_)) = read_line(&mut lines).await {} });
    let requester = agent.as_ref().map(|c| format!("agent:{}", c.id));
    let mut tick = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            // The agent was revoked: its subscription ends; the owner session held by the window closed: the
            // window's subscription ends (Q-14b); a watched agent stopped or the watcher is no longer its ancestor
            _ = tick.tick() => {
                if let Some(ctx) = &agent
                    && session.agent_scope(ctx).is_err()
                {
                    let _ = out.err(&Error::new(code::TOKEN_INVALID, "agent was removed")).await;
                    break;
                }
                match &recheck {
                    Recheck::Owner { node, chain, token }
                        if node.owner_sessions.lock().unwrap_or_else(PoisonError::into_inner).peek(
                            chain.as_deref(),
                            token.as_deref(),
                            now_ms(),
                        ).is_none() =>
                    {
                        let _ = out.err(&login_required()).await;
                        break;
                    }
                    Recheck::Watch { agent, chain } => {
                        if let Err(e) = session.agent_watch(agent, Some(chain)) {
                            let _ = out.err(&e).await;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            ev = rx.recv() => match ev {
                Ok(ev) => {
                    let mapped = match (&scope, ev) {
                        (None, ev) => owner_event(ev),
                        // Facts only about messages the agent may read (v6, CONTROL §20)
                        (Some(_), NodeEvent::Message { link, item, .. })
                            if item.direction == "in"
                                && agent
                                    .as_ref()
                                    .is_none_or(|ctx| !session.agent_sees_item(ctx, &link, &item)) =>
                        {
                            None
                        }
                        // Offers addressed to another agent or the person are not this agent's business (PG-19)
                        (Some(_), NodeEvent::File { link, info })
                            if info.direction == "in"
                                && agent.as_ref().is_none_or(|ctx| {
                                    !session.agent_sees_offer(ctx, &link, info.message_id.as_deref())
                                }) =>
                        {
                            None
                        }
                        (Some(scope), ev) => agent_event(ev, scope, requester.as_deref().unwrap_or("")),
                    };
                    if let Some(e) = mapped.filter(|e| version >= since_version(e))
                        && out.send(&ServerMsg::Event(e)).await.is_err()
                    {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                    if out.send(&ServerMsg::Event(Event::Lagged { missed })).await.is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            },
            _ = &mut reader => break,
            _ = session.closed_wait() => {
                let _ = out.err(&Error::new(code::LOCKED, "keystore was locked")).await;
                break;
            }
        }
    }
    reader.abort();
    Ok(())
}

fn owner_event(ev: NodeEvent) -> Option<Event> {
    Some(match ev {
        NodeEvent::Message {
            link,
            contact,
            item,
            ..
        } => Event::Message {
            contact,
            link_id: link.to_hex(),
            message: *item,
        },
        NodeEvent::Status {
            link,
            contact,
            id,
            status,
        } => Event::MessageStatus {
            contact,
            link_id: link.to_hex(),
            id,
            status: status.into(),
        },
        NodeEvent::Contact { summary, .. } => Event::Contact { contact: summary },
        NodeEvent::Invite(i) => Event::Invite { invite: *i },
        NodeEvent::Approval { info, .. } => Event::Approval { approval: *info },
        NodeEvent::History {
            link,
            contact,
            status,
        } => Event::History {
            contact,
            link_id: link.to_hex(),
            status: *status,
        },
        NodeEvent::Rekey { contact, state, .. } => Event::Rekey {
            contact,
            state: state.into(),
        },
        NodeEvent::File { link, info } => Event::File {
            contact: info.contact.clone(),
            link_id: link.to_hex(),
            file: *info,
        },
        NodeEvent::Stream { body, .. } => Event::MessageStream(*body),
        NodeEvent::Wake(body) => Event::Wake(*body),
        NodeEvent::Agent { name, change, by } => Event::Agent { name, change, by },
        NodeEvent::ApprovalResolved { resolution, .. } => Event::ApprovalResolved(*resolution),
        NodeEvent::LocalModel(m) => Event::LocalModel(*m),
        NodeEvent::LocalAgent(a) => Event::LocalAgent(*a),
        NodeEvent::UpdateAuto(e) => Event::UpdateAuto(*e),
        NodeEvent::Device {
            link,
            contact,
            change,
        } => Event::Device {
            contact,
            link_id: link.to_hex(),
            change: change.into(),
        },
        NodeEvent::Team(t) => Event::Team(*t),
        NodeEvent::Chat(c) => Event::Chat(*c),
        NodeEvent::Escalation { info, .. } => Event::Escalation(*info),
        NodeEvent::Picture(p) => Event::Picture(*p),
        // For the approver agent only (PG-57): the owner sees the request itself
        NodeEvent::ToAnswer { .. } => return None,
        // For the recipient agent only (D-132): the owner's map reads `agent_traffic`
        NodeEvent::LocalMessage { .. } => return None,
    })
}

/// `wake_say` (v6): the owner's turn in a resident session; the reply streams back on this connection
/// (`resident_delta`) and ends with `resident_turn`. If the client goes away, the turn still runs to its end.
async fn wake_say(
    s: Arc<Session>,
    contact: String,
    text: String,
    to_contact: bool,
    interrupt: bool,
    timeout_ms: Option<u64>,
    mut out: Out,
) -> Result<()> {
    let mut rx = match s.resident_say(&contact, text, to_contact, interrupt) {
        Ok(rx) => rx,
        Err(e) => return out.err(&e).await,
    };
    let limit = Duration::from_millis(timeout_ms.unwrap_or(600_000).clamp(1_000, 3_600_000));
    let deadline = tokio::time::sleep(limit);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            o = rx.recv() => match o {
                Some(crate::resident::OwnerOut::Delta { turn, delta, activity }) => {
                    let ev = Event::ResidentDelta { contact: contact.clone(), turn, delta, activity };
                    if out.send(&ServerMsg::Event(ev)).await.is_err() {
                        return Ok(());
                    }
                }
                Some(crate::resident::OwnerOut::Done(t)) => {
                    return out.send(&ServerMsg::Ok(Reply::ResidentTurn(t))).await;
                }
                None => {
                    return out
                        .err(&Error::internal("the resident session ended before the turn"))
                        .await;
                }
            },
            _ = &mut deadline => {
                return out
                    .err(&Error::new(
                        code::TIMEOUT,
                        "the turn did not end in time; it goes on (see `antenna wake list`)",
                    ))
                    .await;
            }
        }
    }
}

/// `local_say` (v7, CONTROL §24): the owner's turn in a local agent's conversation; the reply streams back on this
/// connection (`local_delta`) and ends with `local_turn`. If the client goes away, the turn still runs to its end.
async fn local_say(
    s: Arc<Session>,
    agent: String,
    text: String,
    interrupt: bool,
    timeout_ms: Option<u64>,
    mut out: Out,
) -> Result<()> {
    let mut rx = match s.local_say(&agent, text, interrupt) {
        Ok(rx) => rx,
        Err(e) => return out.err(&e).await,
    };
    let limit = Duration::from_millis(timeout_ms.unwrap_or(600_000).clamp(1_000, 3_600_000));
    let deadline = tokio::time::sleep(limit);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            o = rx.recv() => match o {
                Some(crate::local::LocalOut::Delta { turn, delta, activity }) => {
                    let ev = Event::LocalDelta { agent: agent.clone(), turn, delta, activity };
                    if out.send(&ServerMsg::Event(ev)).await.is_err() {
                        return Ok(());
                    }
                }
                Some(crate::local::LocalOut::Done(t)) => {
                    return out.send(&ServerMsg::Ok(Reply::LocalTurn(t))).await;
                }
                None => {
                    return out
                        .err(&Error::internal("the local agent's session ended before the turn"))
                        .await;
                }
            },
            _ = &mut deadline => {
                return out
                    .err(&Error::new(
                        code::TIMEOUT,
                        "the turn did not end in time; it goes on (see `antenna local history`)",
                    ))
                    .await;
            }
        }
    }
}

/// The control protocol version of a connection (`x-control/N` → N).
fn proto_version(proto: &str) -> u8 {
    proto
        .strip_prefix("x-control/")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

/// The first control protocol version that has this event: a subscription of an older client does not get it.
fn since_version(e: &Event) -> u8 {
    match e {
        Event::MessageStream(_) | Event::StreamStarted { .. } | Event::Wake(_) => 4,
        Event::Agent { .. } => 5,
        Event::ResidentDelta { .. } | Event::ApprovalResolved(_) => 6,
        Event::LocalDelta { .. }
        | Event::LocalModel(_)
        | Event::LocalAgent(_)
        | Event::UpdateAuto(_)
        | Event::Device { .. }
        | Event::Team(_)
        | Event::WorkerOutput(_)
        | Event::Chat(_)
        | Event::Escalation(_)
        | Event::Picture(_)
        | Event::ApprovalToAnswer(_) => 7,
        _ => 0,
    }
}

/// How long to wait for the next chunk from a `send_stream` client.
const STREAM_INPUT_IDLE: Duration = Duration::from_secs(10 * 60);

/// Streaming message dialog (v4): chunks `{"input":{"chunk":{"text":…}}}` until `{"input":{"end":{}}}`. If the
/// connection closes or the client goes silent, the final message is "interrupted" with the text received so far.
async fn send_stream(
    s: Arc<Session>,
    author: Author,
    contact: String,
    wait_ms: u64,
    req: AddrReq,
    mut lines: Lines,
    mut out: Out,
) -> Result<()> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "snake_case", deny_unknown_fields)]
    enum InMsg {
        Input(Input),
    }
    let mut w = match s.stream_begin(author, &contact, &req).await {
        Ok(w) => w,
        Err(e) => return out.err(&e).await,
    };
    out.send(&ServerMsg::Event(Event::StreamStarted {
        stream_id: w.id_hex(),
        live: w.is_live(),
        reason: w.no_live_reason().map(Into::into),
    }))
    .await?;
    let deadline = tokio::time::Instant::now() + crate::stream::MAX_DURATION;
    let end = loop {
        let idle = tokio::time::Instant::now() + STREAM_INPUT_IDLE;
        let r = tokio::time::timeout_at(deadline.min(idle), read_line(&mut lines)).await;
        match r {
            Ok(Ok(Some(line))) => match parse::<InMsg>(&line) {
                Ok(InMsg::Input(Input::Chunk { text })) => w.push(&text),
                Ok(InMsg::Input(Input::End {})) => break antenna_proto::stream::StreamEnd::Done,
                _ => break antenna_proto::stream::StreamEnd::Interrupted,
            },
            _ => break antenna_proto::stream::StreamEnd::Interrupted,
        }
    };
    let r = w
        .finish(end, Duration::from_millis(wait_ms.min(60_000)))
        .await;
    // The client may already be gone (dropped connection): the final message is sent anyway
    let _ = out.reply(r.map(Reply::Sent)).await;
    Ok(())
}

/// How long to wait for the next data frame of `share_file_content`.
const CONTENT_INPUT_IDLE: Duration = Duration::from_secs(60);

/// Fields of a `share_file_content` request.
struct ContentReq {
    contact: String,
    name: String,
    size: u64,
    approval_id: Option<String>,
    addr: crate::addressing::Addr,
}

/// One `data` frame: standard base64, with or without padding; whitespace (the line breaks of `base64` tools) is
/// ignored. Each frame decodes on its own.
fn decode_frame(b64: &str) -> Result<Vec<u8>> {
    let s: String = b64.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    data_encoding::BASE64_NOPAD
        .decode(s.trim_end_matches('=').as_bytes())
        .map_err(|e| Error::bad_request(format!("data is not valid base64: {e}")))
}

/// The `share_file_content` dialog (v5). The checks that need no data come first (contact, level, size limit, name);
/// when they pass, the daemon asks for the bytes with `need_input {what: "data"}`. Then `data` frames up to exactly
/// `size` bytes and `end`. The bytes go into a staging file of the data directory that has no name by then
/// (`files::stage_outgoing`) and then through the `share_file` pipeline. More bytes than declared, fewer, bad base64,
/// 60 s of silence or a dropped connection: nothing is sent and nothing stays on disk.
async fn share_content(
    s: Arc<Session>,
    ctx: AgentCtx,
    req: ContentReq,
    mut lines: Lines,
    mut out: Out,
) -> Result<()> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "snake_case", deny_unknown_fields)]
    enum InMsg {
        Input(Input),
    }
    let (link, file) = match s.agent_share_content_begin(&ctx, &req.contact, &req.name, req.size) {
        Ok(v) => v,
        Err(e) => return out.err(&e).await,
    };
    out.send(&ServerMsg::Event(Event::NeedInput {
        what: "data".into(),
        confirm_without_code: false,
    }))
    .await?;
    let mut w = match file.try_clone() {
        Ok(f) => tokio::fs::File::from_std(f),
        Err(e) => return out.err(&Error::from(e)).await,
    };
    let mut got: u64 = 0;
    loop {
        let line = match tokio::time::timeout(CONTENT_INPUT_IDLE, read_line(&mut lines)).await {
            Ok(Ok(Some(l))) => l,
            // The client left: the staging file goes away with its descriptor
            Ok(Ok(None)) => return Ok(()),
            Ok(Err(e)) => return out.err(&e).await,
            Err(_) => {
                return out
                    .err(&Error::new(
                        code::TIMEOUT,
                        "no data for 60 s: the upload is dropped",
                    ))
                    .await;
            }
        };
        match parse::<InMsg>(&line) {
            Ok(InMsg::Input(Input::Data { b64 })) => {
                let bytes = match decode_frame(&b64) {
                    Ok(b) => b,
                    Err(e) => return out.err(&e).await,
                };
                got += bytes.len() as u64;
                if got > req.size {
                    return out
                        .err(&Error::bad_request(format!(
                            "more data than the declared size of {} bytes",
                            req.size
                        )))
                        .await;
                }
                if let Err(e) = w.write_all(&bytes).await {
                    return out.err(&Error::from(e)).await;
                }
            }
            Ok(InMsg::Input(Input::End {})) => break,
            _ => {
                return out
                    .err(&Error::bad_request(
                        "expected {\"input\":{\"data\":{\"b64\":…}}} or {\"input\":{\"end\":{}}}",
                    ))
                    .await;
            }
        }
    }
    if got != req.size {
        return out
            .err(&Error::bad_request(format!(
                "the data ended at {got} of the declared {} bytes",
                req.size
            )))
            .await;
    }
    if let Err(e) = w.flush().await {
        return out.err(&Error::from(e)).await;
    }
    drop(w);
    let r = s
        .agent_share_content_finish(
            &ctx,
            &link,
            file,
            &req.name,
            req.approval_id.as_deref(),
            &req.addr,
        )
        .await;
    out.reply(r.map(Reply::File)).await
}

fn agent_event(
    ev: NodeEvent,
    scope: &Option<Vec<antenna_proto::LinkId>>,
    requester: &str,
) -> Option<Event> {
    let visible = |l: &antenna_proto::LinkId| scope.as_ref().is_none_or(|s| s.contains(l));
    match ev {
        NodeEvent::Message {
            link,
            contact,
            trust,
            item,
        } if visible(&link) && item.direction == "in" && item.kind == "text" => {
            Some(Event::MessageFact {
                contact,
                id: item.id,
                trust,
                chars: item.text.chars().count() as u64,
                received_ms: item.local_ms,
                urgent: item.urgent,
                local: None,
            })
        }
        // A message over a local route, for its recipient only (D-132): facts without text, as for a link's
        NodeEvent::LocalMessage {
            agent_id,
            from,
            id,
            trust,
            chars,
            at_ms,
        } if requester == format!("agent:{agent_id}") => Some(Event::MessageFact {
            contact: from.clone(),
            id,
            trust,
            chars,
            received_ms: at_ms,
            local: Some(from),
            // A local route never carries urgency: it is between agents, not from the owner (PG-58)
            urgent: false,
        }),
        NodeEvent::Status {
            link,
            contact,
            id,
            status,
        } if visible(&link) => Some(Event::MessageStatus {
            contact,
            link_id: link.to_hex(),
            id,
            status: status.into(),
        }),
        NodeEvent::Contact { link, summary } if visible(&link) => {
            Some(Event::Contact { contact: summary })
        }
        NodeEvent::Approval { requester_id, info } if requester_id == requester => {
            // Who may answer it in the owner's place, and an approver's answer that did not count, are the owner's
            // to read (PG-57): the asking agent learns only the decision
            let mut approval = *info;
            approval.answerable_by.clear();
            approval.delegate_refused = None;
            Some(Event::Approval { approval })
        }
        // A request this agent may answer as an approver (PG-57): facts only
        NodeEvent::ToAnswer { agent_id, fact } if requester == format!("agent:{agent_id}") => {
            Some(Event::ApprovalToAnswer(*fact))
        }
        NodeEvent::ApprovalResolved {
            requester_id,
            resolution,
        } if requester_id == requester => Some(Event::ApprovalResolved(*resolution)),
        // The agent's own question, once the owner answered or set it aside (D-118)
        NodeEvent::Escalation { agent_id, info }
            if requester == format!("agent:{agent_id}")
                && info.state != ESCALATION_OPEN
                && info.state != ESCALATION_SENT =>
        {
            Some(Event::Escalation(*info))
        }
        NodeEvent::History {
            link,
            contact,
            status,
        } if visible(&link) => Some(Event::History {
            contact,
            link_id: link.to_hex(),
            status: *status,
        }),
        // The event does not set taint: the file name and the details of findings (contact data) reach an agent only
        // through `files_pending` / `file_preview`, which set taint
        NodeEvent::File { link, info } if visible(&link) => {
            // Only fields from closed vocabularies and numbers: the name, the name on receipt, the sender's MIME and
            // the details of findings are contact data
            let mut file = *info;
            file.name = String::new();
            file.saved_as = None;
            file.saved_path = None;
            file.sender_mime = String::new();
            for f in &mut file.findings {
                f.detail = String::new();
            }
            Some(Event::File {
                contact: file.contact.clone(),
                link_id: link.to_hex(),
                file,
            })
        }
        _ => None,
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;

    fn me() -> Sid {
        Sid::parse("S-1-5-21-1-2-3-1001").unwrap()
    }

    fn medium() -> TokenFacts {
        TokenFacts {
            user: me(),
            integrity: 0x2000,
            app_container: false,
            restricted: false,
            elevated: false,
        }
    }

    /// The pipe client rule (D-135): the user at medium, and the same user elevated, pass; each other case alone is
    /// refused and says why.
    #[test]
    fn a_pipe_client_is_admitted_by_its_token() {
        let me = me();
        assert_eq!(admit(Ok(medium()), &me), Ok(()));
        let elevated = TokenFacts {
            integrity: 0x3000,
            elevated: true,
            ..medium()
        };
        assert_eq!(admit(Ok(elevated), &me), Ok(()));
        let refused = [
            (
                TokenFacts {
                    user: Sid::parse("S-1-5-21-1-2-3-1002").unwrap(),
                    ..medium()
                },
                "different user (S-1-5-21-1-2-3-1002)",
            ),
            (
                TokenFacts {
                    user: Sid::parse("S-1-5-7").unwrap(),
                    ..medium()
                },
                "different user (S-1-5-7)",
            ),
            (
                TokenFacts {
                    integrity: 0x1000,
                    ..medium()
                },
                "below medium integrity (0x1000)",
            ),
            (
                TokenFacts {
                    app_container: true,
                    ..medium()
                },
                "AppContainer",
            ),
            (
                TokenFacts {
                    restricted: true,
                    ..medium()
                },
                "restricted token",
            ),
        ];
        for (t, why) in refused {
            let e = admit(Ok(t.clone()), &me).unwrap_err();
            assert!(e.contains(why), "{t:?}: {e}");
        }
        let e = admit(Err(std::io::Error::from_raw_os_error(1347)), &me).unwrap_err();
        assert!(e.contains("cannot read the client's identity"), "{e}");
    }
}
