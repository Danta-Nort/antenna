// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna window-bridge` (experimental): many control connections over the stdin and stdout of one process. The
//! window starts it once on Windows, where the daemon's control endpoint is a named pipe and dart:io has no API for one
//! (D-135 item 5); the CLI reaches the pipe, so the window's connections go through it (`docs/CONTROL.md` §34).
//!
//! Frames, in both directions: a `u32` LE connection id below 2^31, a `u8` type, a `u32` LE length, then that many
//! bytes. The window sends [`OPEN`], [`DATA`] and [`CLOSE`]; the bridge sends [`DATA`], [`CLOSE`] and [`ERROR`] (a
//! short UTF-8 reason, just before the close of a connection it could not make). An open and a close carry nothing; data
//! and errors carry 1 to [`MAX_FRAME`] bytes.
//!
//! The bridge is a pipe, not a client: it says no hello of its own and holds no role and no token. Each connection's
//! bytes pass through unchanged, and the daemon checks every connection as it checks any client (D-135 items 3 and 4).
//! It logs framing errors only, and never a frame's content: frames carry passwords and messages.
//!
//! The rules that keep both sides in step:
//! - an id is live from the window's open until the window's close, and is free again once both sides have sent their
//!   close for it. The bridge sends exactly one close per open: when the daemon side ends, or in answer to the window's
//!   close, after every data frame of that connection; the window answers a close of the bridge with its own. Data
//!   from the window for a connection whose daemon side has ended is dropped;
//! - anything outside the format ends the bridge at once with a non-zero exit, before any of it is acted on: a frame
//!   over [`MAX_FRAME`], an unknown type, a length its type does not allow, an id of 2^31 or more, an open of a live id
//!   or past [`MAX_CONNECTIONS`], data or a close for an id that is not live, and a frame cut short by the end of
//!   stdin;
//! - the end of stdin between two frames closes every connection, and the bridge exits 0.

use std::{
    cell::RefCell, collections::HashMap, fmt, future::Future, path::PathBuf, process::ExitCode,
    rc::Rc,
};

use antenna_proto::control::MAX_LINE;
use clap::{Parser, Subcommand};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::mpsc,
    task::{JoinHandle, LocalSet, spawn_local},
};
use zeroize::Zeroizing;

use crate::client::{self, EXIT_FAIL};

/// The subcommand's name. It is hidden from the help: the window starts it, a person has no use for it.
pub const COMMAND: &str = "window-bridge";

/// Window → bridge: connect to the daemon under this id. Carries nothing.
pub const OPEN: u8 = 1;
/// Both ways: bytes of one connection, passed through as they are.
pub const DATA: u8 = 2;
/// Both ways: this side is done with the connection. Carries nothing.
pub const CLOSE: u8 = 3;
/// Bridge → window: why the connection could not be made, as short UTF-8 text, just before its close.
pub const ERROR: u8 = 4;

/// The longest frame: one control line with its newline. A longer reply of the daemon goes in several data frames.
pub const MAX_FRAME: usize = MAX_LINE + 1;
/// The most live connections, the daemon's own limit (`MAX_CONNECTIONS` of `antenna-core`'s control server).
pub const MAX_CONNECTIONS: usize = 256;
/// Connection ids are below 2^31, so a reader with signed 32-bit integers sees the same ids.
pub const ID_LIMIT: u32 = 1 << 31;

/// Id, type and length.
const HEADER: usize = 9;
/// The most bytes read from the daemon into one data frame.
const READ_CHUNK: usize = 64 * 1024;
/// Frames waiting for stdout.
const OUT_QUEUE: usize = 64;
/// Data frames from the window waiting for one daemon connection. When the queue is full, reading stdin waits for it:
/// the window sends a request and its inputs, which the daemon reads as they come.
const CONN_QUEUE: usize = 16;
/// The longest reason an error frame carries, in bytes.
const MAX_REASON: usize = 512;

/// `antenna [--data-dir <dir>] [--socket <path>] window-bridge`: the daemon is found as by every other command
/// (`docs/CONTROL.md` §1). No token is read: the bridge has no role of its own.
#[derive(Debug, Parser)]
#[command(name = "antenna")]
struct BridgeCli {
    /// Daemon data directory.
    #[arg(long, global = true, env = "ANTENNA_DATA_DIR")]
    data_dir: Option<PathBuf>,
    /// Path to the control socket (overrides `--data-dir`).
    #[arg(long, global = true, env = "ANTENNA_SOCKET")]
    socket: Option<PathBuf>,
    #[command(subcommand)]
    command: BridgeCommand,
}

#[derive(Debug, Subcommand)]
enum BridgeCommand {
    /// Carry the window's control connections over stdin and stdout (`docs/CONTROL.md` §34).
    WindowBridge,
}

/// A frame that ends the bridge. None holds a frame's content: the message names the id, the type and the length.
#[derive(Debug, PartialEq, Eq)]
pub enum Violation {
    /// Longer than [`MAX_FRAME`].
    TooLong {
        /// Connection id.
        id: u32,
        /// The length the frame claimed.
        len: u32,
    },
    /// Not one of the window's types.
    UnknownType {
        /// Connection id.
        id: u32,
        /// The type.
        kind: u8,
    },
    /// A length the type does not allow (an open or close with content, empty data).
    BadLength {
        /// Connection id.
        id: u32,
        /// The type.
        kind: u8,
        /// The length.
        len: u32,
    },
    /// An id of 2^31 or more.
    BadId {
        /// The id.
        id: u32,
    },
    /// An open of an id that is live.
    OpenLive {
        /// The id.
        id: u32,
    },
    /// An open past [`MAX_CONNECTIONS`].
    TooMany {
        /// The id.
        id: u32,
    },
    /// Data or a close for an id that is not live.
    NotLive {
        /// The id.
        id: u32,
        /// The type.
        kind: u8,
    },
    /// Stdin ended inside a frame.
    Short,
    /// Stdin could not be read.
    Input(std::io::ErrorKind),
    /// Stdout could not be written: the window is gone. Not logged.
    Output,
}

impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLong { id, len } => write!(
                f,
                "frame of {len} bytes for connection {id}: over the limit of {MAX_FRAME}"
            ),
            Self::UnknownType { id, kind } => {
                write!(f, "frame of unknown type {kind} for connection {id}")
            }
            Self::BadLength { id, kind, len } => write!(
                f,
                "frame of type {kind} for connection {id} with a length of {len} bytes, which its type does not allow"
            ),
            Self::BadId { id } => write!(f, "connection id {id} is not below 2^31"),
            Self::OpenLive { id } => write!(f, "open of connection {id}, which is live"),
            Self::TooMany { id } => write!(
                f,
                "open of connection {id} past the limit of {MAX_CONNECTIONS} live connections"
            ),
            Self::NotLive { id, kind } => {
                write!(
                    f,
                    "frame of type {kind} for connection {id}, which is not live"
                )
            }
            Self::Short => write!(f, "stdin ended inside a frame"),
            Self::Input(k) => write!(f, "stdin: {k}"),
            Self::Output => write!(f, "stdout closed"),
        }
    }
}

/// One frame.
struct Frame {
    id: u32,
    kind: u8,
    payload: Zeroizing<Vec<u8>>,
}

impl Frame {
    fn data(id: u32, bytes: &[u8]) -> Self {
        Self {
            id,
            kind: DATA,
            payload: Zeroizing::new(bytes.to_vec()),
        }
    }

    fn close(id: u32) -> Self {
        Self {
            id,
            kind: CLOSE,
            payload: Zeroizing::default(),
        }
    }

    /// The reason, cut at a character boundary to at most [`MAX_REASON`] bytes, and never empty.
    fn error(id: u32, reason: &str) -> Self {
        let mut end = reason.len().min(MAX_REASON);
        while !reason.is_char_boundary(end) {
            end -= 1;
        }
        let reason = if end == 0 {
            "cannot connect"
        } else {
            &reason[..end]
        };
        Self {
            id,
            kind: ERROR,
            payload: Zeroizing::new(reason.as_bytes().to_vec()),
        }
    }
}

/// One frame's bytes. The bridge only encodes frames of at most [`MAX_FRAME`] bytes (a read of [`READ_CHUNK`], a
/// reason of [`MAX_REASON`]), so the length always fits its `u32`.
pub fn encode(id: u32, kind: u8, payload: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut b = Zeroizing::new(Vec::with_capacity(HEADER + payload.len()));
    b.extend_from_slice(&id.to_le_bytes());
    b.push(kind);
    b.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    b.extend_from_slice(payload);
    b
}

/// A live connection.
struct Live {
    /// Data from the window for the daemon; `None` once the daemon side has ended (the data is then dropped).
    to_daemon: Option<mpsc::Sender<Zeroizing<Vec<u8>>>>,
    /// The bridge has sent its close; the id waits for the window's.
    bridge_closed: bool,
    /// The connection's task.
    task: JoinHandle<()>,
}

type LiveMap = Rc<RefCell<HashMap<u32, Live>>>;

/// `antenna window-bridge`.
pub fn main() -> ExitCode {
    let cli = match BridgeCli::try_parse() {
        Ok(c) => c,
        Err(e) => e.exit(),
    };
    let BridgeCommand::WindowBridge = cli.command;
    let path = client::socket_path(&cli.socket, &cli.data_dir);
    let rt = match crate::runtime() {
        Ok(rt) => rt,
        Err(c) => return c,
    };
    let connect = move || {
        let path = path.clone();
        async move {
            client::connect_raw(&path)
                .await
                .map_err(|f| format!("{}: {}", f.code, f.message))
        }
    };
    let r = rt.block_on(LocalSet::new().run_until(serve(
        tokio::io::stdin(),
        tokio::io::stdout(),
        connect,
    )));
    // A read of stdin may still wait in tokio's blocking pool (stdout failed first): exit without waiting for it.
    rt.shutdown_background();
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(Violation::Output) => ExitCode::from(EXIT_FAIL),
        Err(v) => {
            eprintln!("antenna {COMMAND}: {v}");
            ExitCode::from(EXIT_FAIL)
        }
    }
}

/// Serves the window on `input` and `output` until `input` ends between two frames (`Ok`) or breaks the format (the
/// violation). `connect` opens one connection to the daemon, or says why it cannot. Runs on a [`LocalSet`]; when it
/// returns, every daemon connection is closed.
pub async fn serve<R, W, C, F, DR, DW>(mut input: R, output: W, connect: C) -> Result<(), Violation>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + 'static,
    C: Fn() -> F + 'static,
    F: Future<Output = Result<(DR, DW), String>> + 'static,
    DR: AsyncRead + Unpin + 'static,
    DW: AsyncWrite + Unpin + 'static,
{
    // One writer: frames of different connections never interleave on stdout.
    let (out, out_rx) = mpsc::channel(OUT_QUEUE);
    let mut writer = spawn_local(write_frames(output, out_rx));
    let connect = Rc::new(connect);
    let live: LiveMap = Rc::default();
    let result = loop {
        let frame = tokio::select! {
            f = read_frame(&mut input) => f,
            _ = &mut writer => break Err(Violation::Output),
        };
        let handled = match frame {
            Ok(None) => break Ok(()),
            Ok(Some(f)) => handle(f, &live, &out, &connect).await,
            Err(v) => Err(v),
        };
        if let Err(v) = handled {
            break Err(v);
        }
    };
    let all: Vec<Live> = live.borrow_mut().drain().map(|(_, c)| c).collect();
    for c in all {
        c.task.abort();
    }
    writer.abort();
    result
}

/// Reads one whole frame: `None` at the end of stdin between frames. The header is checked before the content is
/// read, so an oversized length never allocates.
async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Option<Frame>, Violation> {
    let mut head = [0u8; HEADER];
    let mut got = 0;
    while got < HEADER {
        let n = r
            .read(&mut head[got..])
            .await
            .map_err(|e| Violation::Input(e.kind()))?;
        if n == 0 {
            return if got == 0 {
                Ok(None)
            } else {
                Err(Violation::Short)
            };
        }
        got += n;
    }
    let [i0, i1, i2, i3, kind, l0, l1, l2, l3] = head;
    let id = u32::from_le_bytes([i0, i1, i2, i3]);
    let len = u32::from_le_bytes([l0, l1, l2, l3]);
    if id >= ID_LIMIT {
        return Err(Violation::BadId { id });
    }
    let size = usize::try_from(len).map_err(|_| Violation::TooLong { id, len })?;
    if size > MAX_FRAME {
        return Err(Violation::TooLong { id, len });
    }
    let allowed = match kind {
        OPEN | CLOSE => size == 0,
        DATA => size > 0,
        _ => return Err(Violation::UnknownType { id, kind }),
    };
    if !allowed {
        return Err(Violation::BadLength { id, kind, len });
    }
    let mut payload = Zeroizing::new(vec![0u8; size]);
    r.read_exact(&mut payload).await.map_err(|e| {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            Violation::Short
        } else {
            Violation::Input(e.kind())
        }
    })?;
    Ok(Some(Frame { id, kind, payload }))
}

/// Acts on one frame of the window.
async fn handle<C, F, DR, DW>(
    f: Frame,
    live: &LiveMap,
    out: &mpsc::Sender<Frame>,
    connect: &Rc<C>,
) -> Result<(), Violation>
where
    C: Fn() -> F + 'static,
    F: Future<Output = Result<(DR, DW), String>> + 'static,
    DR: AsyncRead + Unpin + 'static,
    DW: AsyncWrite + Unpin + 'static,
{
    let id = f.id;
    match f.kind {
        OPEN => {
            let mut l = live.borrow_mut();
            if l.contains_key(&id) {
                return Err(Violation::OpenLive { id });
            }
            if l.len() >= MAX_CONNECTIONS {
                return Err(Violation::TooMany { id });
            }
            let (tx, rx) = mpsc::channel(CONN_QUEUE);
            let task = spawn_local(connection(
                id,
                rx,
                out.clone(),
                live.clone(),
                connect.clone(),
            ));
            l.insert(
                id,
                Live {
                    to_daemon: Some(tx),
                    bridge_closed: false,
                    task,
                },
            );
            Ok(())
        }
        DATA => {
            let found = live.borrow().get(&id).map(|c| c.to_daemon.clone());
            let Some(tx) = found else {
                return Err(Violation::NotLive { id, kind: DATA });
            };
            if let Some(tx) = tx {
                // A connection that ended meanwhile drops the data, as one whose daemon side had ended.
                let _ = tx.send(f.payload).await;
            }
            Ok(())
        }
        CLOSE => {
            let removed = live.borrow_mut().remove(&id);
            let Some(c) = removed else {
                return Err(Violation::NotLive { id, kind: CLOSE });
            };
            if !c.bridge_closed {
                // Stopped before it can queue another frame (one thread: it is not running now), so the answering
                // close comes after all of its data and is the only close of this id.
                c.task.abort();
                let _ = out.send(Frame::close(id)).await;
            }
            Ok(())
        }
        kind => Err(Violation::UnknownType { id, kind }),
    }
}

/// One connection: connect, carry bytes both ways until either side ends, then send the bridge's close.
async fn connection<C, F, DR, DW>(
    id: u32,
    mut from_window: mpsc::Receiver<Zeroizing<Vec<u8>>>,
    out: mpsc::Sender<Frame>,
    live: LiveMap,
    connect: Rc<C>,
) where
    C: Fn() -> F,
    F: Future<Output = Result<(DR, DW), String>>,
    DR: AsyncRead + Unpin,
    DW: AsyncWrite + Unpin,
{
    match connect().await {
        Ok((r, w)) => pump(id, r, w, &mut from_window, &out).await,
        Err(reason) => {
            let _ = out.send(Frame::error(id, &reason)).await;
        }
    }
    // The close is queued and the id marked in one step: when the window has read this close, the bridge already
    // waits for the window's, and an id the window reuses after both is never live twice.
    let Ok(permit) = out.reserve().await else {
        return;
    };
    let mut l = live.borrow_mut();
    if let Some(c) = l.get_mut(&id) {
        c.bridge_closed = true;
        c.to_daemon = None;
        permit.send(Frame::close(id));
    }
}

/// Bytes both ways at once, so a daemon that writes while its input is full never waits on the bridge: returns when the
/// daemon side ends (end of file or an error either way) or stdout is gone.
async fn pump<DR, DW>(
    id: u32,
    mut r: DR,
    mut w: DW,
    from_window: &mut mpsc::Receiver<Zeroizing<Vec<u8>>>,
    out: &mpsc::Sender<Frame>,
) where
    DR: AsyncRead + Unpin,
    DW: AsyncWrite + Unpin,
{
    let reading = async {
        let mut buf = Zeroizing::new(vec![0u8; READ_CHUNK]);
        loop {
            match r.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    if out.send(Frame::data(id, &buf[..n])).await.is_err() {
                        return;
                    }
                }
            }
        }
    };
    let writing = async {
        while let Some(bytes) = from_window.recv().await {
            if w.write_all(&bytes).await.is_err() || w.flush().await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        () = reading => {}
        () = writing => {}
    }
}

/// The only writer of stdout. Returns when stdout fails.
async fn write_frames<W: AsyncWrite + Unpin>(mut w: W, mut frames: mpsc::Receiver<Frame>) {
    while let Some(f) = frames.recv().await {
        let bytes = encode(f.id, f.kind, &f.payload);
        if w.write_all(&bytes).await.is_err() {
            return;
        }
        if frames.is_empty() && w.flush().await.is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{cell::Cell, time::Duration};

    use tokio::io::{AsyncBufReadExt, BufReader, DuplexStream, ReadHalf, WriteHalf, duplex, split};

    use super::*;

    type Halves = (ReadHalf<DuplexStream>, WriteHalf<DuplexStream>);
    type Connecting = std::pin::Pin<Box<dyn Future<Output = Result<Halves, String>>>>;
    type Connect = Box<dyn Fn() -> Connecting>;

    fn boxed(f: impl Future<Output = Result<Halves, String>> + 'static) -> Connecting {
        Box::pin(f)
    }

    /// A daemon behind every connect: it answers each line `x` with `re:x`, and `bye` with `bye` and the end of the
    /// connection. When a connection ends from the bridge's side, `ended` goes up by one.
    fn daemon(ended: Rc<Cell<usize>>) -> Connect {
        Box::new(move || {
            let ended = ended.clone();
            boxed(async move {
                let (ours, theirs) = duplex(1 << 20);
                spawn_local(async move {
                    let (r, mut w) = split(theirs);
                    let mut lines = BufReader::new(r).lines();
                    loop {
                        match lines.next_line().await {
                            Ok(Some(l)) if l == "bye" => {
                                let _ = w.write_all(b"bye\n").await;
                                return;
                            }
                            Ok(Some(l)) => {
                                if w.write_all(format!("re:{l}\n").as_bytes()).await.is_err() {
                                    return;
                                }
                            }
                            _ => {
                                ended.set(ended.get() + 1);
                                return;
                            }
                        }
                    }
                });
                Ok(split(ours))
            })
        })
    }

    /// No daemon: every connect fails with this reason.
    fn nobody() -> Connect {
        Box::new(|| boxed(async { Err("daemon_unavailable: nobody listens".to_string()) }))
    }

    /// A connect that never completes.
    fn hanging() -> Connect {
        Box::new(|| boxed(std::future::pending()))
    }

    /// The window's side of a bridge under test.
    struct Window {
        stdin: DuplexStream,
        stdout: DuplexStream,
        bridge: JoinHandle<Result<(), Violation>>,
    }

    fn start(connect: Connect) -> Window {
        let (stdin, bridge_in) = duplex(4 << 20);
        let (bridge_out, stdout) = duplex(4 << 20);
        let bridge = spawn_local(serve(bridge_in, bridge_out, connect));
        Window {
            stdin,
            stdout,
            bridge,
        }
    }

    impl Window {
        async fn send(&mut self, id: u32, kind: u8, payload: &[u8]) {
            self.raw(&encode(id, kind, payload)).await;
        }

        /// Bytes as they are; a bridge that has already ended may not take them.
        async fn raw(&mut self, bytes: &[u8]) {
            let _ = self.stdin.write_all(bytes).await;
        }

        async fn frame(&mut self) -> (u32, u8, Vec<u8>) {
            tokio::time::timeout(Duration::from_secs(5), async {
                let mut head = [0u8; HEADER];
                self.stdout.read_exact(&mut head).await.expect("header");
                let id = u32::from_le_bytes(head[..4].try_into().expect("4 bytes"));
                let len = u32::from_le_bytes(head[5..].try_into().expect("4 bytes")) as usize;
                assert!(len <= MAX_FRAME, "the bridge sent a frame of {len} bytes");
                let mut payload = vec![0u8; len];
                self.stdout.read_exact(&mut payload).await.expect("payload");
                (id, head[4], payload)
            })
            .await
            .expect("a frame from the bridge")
        }

        /// The data of `id` up to and including the next newline, from frames of that id only.
        async fn line(&mut self, id: u32) -> String {
            let mut got = Vec::new();
            while !got.ends_with(b"\n") {
                let (i, kind, payload) = self.frame().await;
                assert_eq!(
                    (i, kind),
                    (id, DATA),
                    "{}",
                    String::from_utf8_lossy(&payload)
                );
                got.extend_from_slice(&payload);
            }
            String::from_utf8(got).expect("UTF-8")
        }

        async fn end(self) -> Result<(), Violation> {
            drop(self.stdin);
            tokio::time::timeout(Duration::from_secs(5), self.bridge)
                .await
                .expect("the bridge ends")
                .expect("not cancelled")
        }

        /// The bridge ended by itself with this result (stdin still open).
        async fn ended(self) -> Result<(), Violation> {
            let stdin = self.stdin;
            let r = tokio::time::timeout(Duration::from_secs(5), self.bridge)
                .await
                .expect("the bridge ends by itself")
                .expect("not cancelled");
            drop(stdin);
            r
        }
    }

    async fn local<T>(f: impl Future<Output = T>) -> T {
        LocalSet::new().run_until(f).await
    }

    #[test]
    fn a_frame_is_id_type_length_and_content() {
        assert_eq!(
            encode(7, DATA, b"xyz").as_slice(),
            [7, 0, 0, 0, 2, 3, 0, 0, 0, b'x', b'y', b'z']
        );
        assert_eq!(
            encode(0x0102_0304, CLOSE, b"").as_slice(),
            [4, 3, 2, 1, 3, 0, 0, 0, 0]
        );
        let long = "é".repeat(MAX_REASON);
        let e = Frame::error(1, &long);
        assert!(e.payload.len() <= MAX_REASON);
        assert!(std::str::from_utf8(&e.payload).is_ok());
        assert!(!Frame::error(1, "").payload.is_empty());
    }

    /// Two connections at once, each answered on its own id; the window's close is answered with the bridge's, the
    /// daemon's end comes as data then a close, and the end of stdin is a clean exit.
    #[tokio::test]
    async fn frames_go_both_ways_and_both_sides_close() {
        local(async {
            let ended = Rc::new(Cell::new(0));
            let mut w = start(daemon(ended.clone()));
            w.send(1, OPEN, b"").await;
            w.send(2, OPEN, b"").await;
            w.send(1, DATA, b"hello\n").await;
            assert_eq!(w.line(1).await, "re:hello\n");
            w.send(2, DATA, b"x\n").await;
            assert_eq!(w.line(2).await, "re:x\n");
            // A line split over two frames reaches the daemon whole.
            w.send(1, DATA, b"ag").await;
            w.send(1, DATA, b"ain\n").await;
            assert_eq!(w.line(1).await, "re:again\n");
            w.send(1, CLOSE, b"").await;
            assert_eq!(w.frame().await, (1, CLOSE, vec![]));
            w.send(2, DATA, b"bye\n").await;
            assert_eq!(w.line(2).await, "bye\n");
            assert_eq!(w.frame().await, (2, CLOSE, vec![]));
            // Data the window sent before it read the bridge's close is dropped, then the window's own close.
            w.send(2, DATA, b"late\n").await;
            w.send(2, CLOSE, b"").await;
            assert_eq!(w.end().await, Ok(()));
            tokio::time::timeout(Duration::from_secs(5), async {
                while ended.get() < 1 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("the window's close ends the daemon connection");
        })
        .await;
    }

    /// The longest frame passes both ways: the daemon's longer reply comes in frames of at most the limit.
    #[tokio::test]
    async fn a_frame_of_the_limit_passes() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.send(1, OPEN, b"").await;
            let mut line = vec![b'a'; MAX_FRAME - 1];
            line.push(b'\n');
            w.send(1, DATA, &line).await;
            let reply = w.line(1).await;
            assert_eq!(reply.len(), MAX_FRAME + 3);
            assert_eq!(w.end().await, Ok(()));
        })
        .await;
    }

    #[tokio::test]
    async fn an_oversized_frame_ends_the_bridge() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.send(1, OPEN, b"").await;
            let len = (MAX_FRAME + 1) as u32;
            let mut head = 1u32.to_le_bytes().to_vec();
            head.push(DATA);
            head.extend_from_slice(&len.to_le_bytes());
            w.raw(&head).await;
            assert_eq!(w.ended().await, Err(Violation::TooLong { id: 1, len }));
            let mut w = start(daemon(Rc::default()));
            let mut head = 1u32.to_le_bytes().to_vec();
            head.push(DATA);
            head.extend_from_slice(&u32::MAX.to_le_bytes());
            w.raw(&head).await;
            assert_eq!(
                w.ended().await,
                Err(Violation::TooLong {
                    id: 1,
                    len: u32::MAX
                })
            );
        })
        .await;
    }

    #[tokio::test]
    async fn an_unknown_type_ends_the_bridge() {
        local(async {
            for kind in [0, ERROR, 5, 255] {
                let mut w = start(daemon(Rc::default()));
                w.send(1, OPEN, b"").await;
                w.send(1, kind, b"x").await;
                assert_eq!(
                    w.ended().await,
                    Err(Violation::UnknownType { id: 1, kind }),
                    "type {kind}"
                );
            }
            // A length the type does not allow.
            for (kind, payload) in [(OPEN, &b"x"[..]), (CLOSE, &b"x"[..]), (DATA, &b""[..])] {
                let mut w = start(daemon(Rc::default()));
                if kind != OPEN {
                    w.send(1, OPEN, b"").await;
                }
                w.send(1, kind, payload).await;
                assert_eq!(
                    w.ended().await,
                    Err(Violation::BadLength {
                        id: 1,
                        kind,
                        len: payload.len() as u32
                    }),
                    "type {kind}"
                );
            }
        })
        .await;
    }

    #[tokio::test]
    async fn data_or_close_for_an_id_that_is_not_live_ends_the_bridge() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.send(3, DATA, b"x\n").await;
            assert_eq!(
                w.ended().await,
                Err(Violation::NotLive { id: 3, kind: DATA })
            );
            let mut w = start(daemon(Rc::default()));
            w.send(3, CLOSE, b"").await;
            assert_eq!(
                w.ended().await,
                Err(Violation::NotLive { id: 3, kind: CLOSE })
            );
            // After the window's close, the id is not live: data or a second close for it is refused.
            for kind in [DATA, CLOSE] {
                let mut w = start(daemon(Rc::default()));
                w.send(1, OPEN, b"").await;
                w.send(1, CLOSE, b"").await;
                assert_eq!(w.frame().await, (1, CLOSE, vec![]));
                let payload: &[u8] = if kind == DATA { b"x\n" } else { b"" };
                w.send(1, kind, payload).await;
                assert_eq!(w.ended().await, Err(Violation::NotLive { id: 1, kind }));
            }
        })
        .await;
    }

    /// An id is open once at a time; after both closes, in either order, it opens again.
    #[tokio::test]
    async fn an_id_is_reused_only_after_both_closes() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.send(1, OPEN, b"").await;
            w.send(1, OPEN, b"").await;
            assert_eq!(w.ended().await, Err(Violation::OpenLive { id: 1 }));

            let mut w = start(daemon(Rc::default()));
            // The window closes first.
            w.send(1, OPEN, b"").await;
            w.send(1, CLOSE, b"").await;
            assert_eq!(w.frame().await, (1, CLOSE, vec![]));
            w.send(1, OPEN, b"").await;
            w.send(1, DATA, b"one\n").await;
            assert_eq!(w.line(1).await, "re:one\n");
            // The daemon ends first: the id is live until the window answers.
            w.send(1, DATA, b"bye\n").await;
            assert_eq!(w.line(1).await, "bye\n");
            assert_eq!(w.frame().await, (1, CLOSE, vec![]));
            w.send(1, CLOSE, b"").await;
            w.send(1, OPEN, b"").await;
            w.send(1, DATA, b"two\n").await;
            assert_eq!(w.line(1).await, "re:two\n");
            assert_eq!(w.end().await, Ok(()));

            // The daemon has ended but the window has not answered: still live.
            let mut w = start(nobody());
            w.send(1, OPEN, b"").await;
            assert_eq!(w.frame().await.1, ERROR);
            assert_eq!(w.frame().await, (1, CLOSE, vec![]));
            w.send(1, OPEN, b"").await;
            assert_eq!(w.ended().await, Err(Violation::OpenLive { id: 1 }));
        })
        .await;
    }

    /// At most 256 live connections, counting those whose daemon side has ended until the window answers.
    #[tokio::test]
    async fn the_connection_cap() {
        local(async {
            let mut w = start(nobody());
            for id in 0..MAX_CONNECTIONS as u32 {
                w.send(id, OPEN, b"").await;
                assert_eq!(w.frame().await.1, ERROR);
                assert_eq!(w.frame().await, (id, CLOSE, vec![]));
            }
            // One answered close frees one place.
            w.send(0, CLOSE, b"").await;
            w.send(1000, OPEN, b"").await;
            assert_eq!(w.frame().await.1, ERROR);
            assert_eq!(w.frame().await, (1000, CLOSE, vec![]));
            w.send(1001, OPEN, b"").await;
            assert_eq!(w.ended().await, Err(Violation::TooMany { id: 1001 }));

            let mut w = start(hanging());
            for id in 0..MAX_CONNECTIONS as u32 {
                w.send(id, OPEN, b"").await;
            }
            w.send(MAX_CONNECTIONS as u32, OPEN, b"").await;
            assert_eq!(
                w.ended().await,
                Err(Violation::TooMany {
                    id: MAX_CONNECTIONS as u32
                })
            );
        })
        .await;
    }

    #[tokio::test]
    async fn ids_of_2_31_and_above_end_the_bridge() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.send(ID_LIMIT - 1, OPEN, b"").await;
            w.send(ID_LIMIT - 1, DATA, b"top\n").await;
            assert_eq!(w.line(ID_LIMIT - 1).await, "re:top\n");
            w.send(ID_LIMIT, OPEN, b"").await;
            assert_eq!(w.ended().await, Err(Violation::BadId { id: ID_LIMIT }));
            let mut w = start(daemon(Rc::default()));
            w.send(u32::MAX, OPEN, b"").await;
            assert_eq!(w.ended().await, Err(Violation::BadId { id: u32::MAX }));
        })
        .await;
    }

    /// The end of stdin between frames closes every connection (connected or still connecting), and the bridge
    /// exits 0.
    #[tokio::test]
    async fn the_end_of_stdin_closes_every_connection_and_is_a_clean_exit() {
        local(async {
            let ended = Rc::new(Cell::new(0));
            let mut w = start(daemon(ended.clone()));
            for id in 1..=3 {
                w.send(id, OPEN, b"").await;
                w.send(id, DATA, b"hi\n").await;
                assert_eq!(w.line(id).await, "re:hi\n");
            }
            assert_eq!(w.end().await, Ok(()));
            tokio::time::timeout(Duration::from_secs(5), async {
                while ended.get() < 3 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("every daemon connection sees its end");

            let mut w = start(hanging());
            w.send(1, OPEN, b"").await;
            assert_eq!(w.end().await, Ok(()));
        })
        .await;
    }

    #[tokio::test]
    async fn a_frame_cut_short_ends_the_bridge() {
        local(async {
            let mut w = start(daemon(Rc::default()));
            w.raw(&encode(1, OPEN, b"")[..5]).await;
            assert_eq!(w.end().await, Err(Violation::Short));
            let mut w = start(daemon(Rc::default()));
            w.send(1, OPEN, b"").await;
            let frame = encode(1, DATA, b"hello\n");
            w.raw(&frame[..frame.len() - 2]).await;
            assert_eq!(w.end().await, Err(Violation::Short));
        })
        .await;
    }

    /// A connect that fails gives an error frame with its reason, then the close; the bridge goes on.
    #[tokio::test]
    async fn a_failed_connect_is_an_error_then_a_close() {
        local(async {
            let mut w = start(nobody());
            w.send(5, OPEN, b"").await;
            w.send(5, DATA, b"lost\n").await;
            assert_eq!(
                w.frame().await,
                (5, ERROR, b"daemon_unavailable: nobody listens".to_vec())
            );
            assert_eq!(w.frame().await, (5, CLOSE, vec![]));
            w.send(5, DATA, b"dropped\n").await;
            w.send(5, CLOSE, b"").await;
            w.send(6, OPEN, b"").await;
            assert_eq!(w.frame().await.0, 6);
            assert_eq!(w.frame().await, (6, CLOSE, vec![]));
            w.send(6, CLOSE, b"").await;
            assert_eq!(w.end().await, Ok(()));
        })
        .await;
    }

    /// A close while the connect is still under way is answered at once.
    #[tokio::test]
    async fn a_close_during_the_connect_is_answered_at_once() {
        local(async {
            let mut w = start(hanging());
            w.send(1, OPEN, b"").await;
            w.send(1, DATA, b"queued\n").await;
            w.send(1, CLOSE, b"").await;
            assert_eq!(w.frame().await, (1, CLOSE, vec![]));
            assert_eq!(w.end().await, Ok(()));
        })
        .await;
    }

    /// A violation's message names the id, the type and the length, never the content.
    #[test]
    fn a_violation_never_shows_content() {
        let shown = Violation::BadLength {
            id: 1,
            kind: OPEN,
            len: 6,
        }
        .to_string();
        assert!(shown.contains("connection 1"), "{shown}");
        assert!(!Violation::Short.to_string().is_empty());
    }
}
