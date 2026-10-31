// SPDX-License-Identifier: AGPL-3.0-only
// The window bridge (experimental; D-135 item 5, docs/CONTROL.md §34). On Windows the daemon's control endpoint is a
// named pipe, and dart:io has no API for one. The window starts one long-lived `antenna window-bridge` and carries all of
// its control connections over that process's stdin and stdout; the CLI opens the pipe and checks its server. Pure Dart
// (dart:io), no Flutter.
//
// Frames, both ways: u32 LE connection id below 2^31, u8 type, u32 LE length, then that many bytes (the format of
// crates/antenna-cli/src/window_bridge.rs). The window sends open, data and close; the bridge sends data, close and
// error ("<code>: <message>", just before the close of a connection it could not make). Each side sends one close per
// connection, first or in answer, and an id is free again once both have. The bounds mirror the bridge's: frames of at
// most one line with its newline, at most 256 connections in use, ids below 2^31. A frame from the bridge outside them
// ends that bridge; its connections fail, and the next open starts a new one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Frame types (`crates/antenna-cli/src/window_bridge.rs`).
abstract final class BridgeFrame {
  /// Window → bridge: connect to the daemon under this id. Carries nothing.
  static const open = 1;

  /// Both ways: bytes of one connection.
  static const data = 2;

  /// Both ways: this side is done with the connection. Carries nothing.
  static const close = 3;

  /// Bridge → window: why the connection could not be made, `<code>: <message>`, just before its close.
  static const error = 4;
}

/// The longest frame: one control line (`MAX_LINE`, 256 KiB) with its newline.
const bridgeMaxFrame = 256 * 1024 + 1;

/// The most connections in use at once: the daemon's own limit. Counted until both closes.
const bridgeMaxConnections = 256;

/// Connection ids are below 2^31.
const bridgeIdLimit = 0x80000000;

/// The CLI's code for a daemon endpoint held by a process it does not trust (D-135 item 4).
const daemonUntrustedCode = 'daemon_untrusted';

/// The subcommand of `antenna` that is the bridge.
const windowBridgeCommand = 'window-bridge';

const _header = 9;

/// Why a connection through the bridge failed. [code] is the CLI's error code when the bridge gave one
/// (`daemon_unavailable`, `daemon_untrusted`, …), otherwise `bridge` (the bridge itself stopped or could not start).
final class BridgeException implements Exception {
  const BridgeException(this.message, {this.code = 'bridge'});

  final String code;
  final String message;

  /// The CLI found the daemon's endpoint held by something it does not trust.
  bool get untrusted => code == daemonUntrustedCode;

  @override
  String toString() => 'BridgeException($code: $message)';
}

/// The bridge process's pipes, as the mux uses them.
abstract interface class BridgeChannel {
  /// The bridge's stdout; it ends when the bridge ends.
  Stream<List<int>> get output;

  /// Writes to the bridge's stdin.
  void add(List<int> bytes);

  /// Ends the bridge: closes its stdin and kills it.
  void kill();

  /// The last line the bridge wrote to stderr (its framing error), or empty.
  String get lastError;
}

/// Starts a bridge.
typedef BridgeStarter = Future<BridgeChannel> Function();

/// `antenna window-bridge` as a child process (and `antenna agent-run`, Code mode's terminal on Windows,
/// host/windows_pty.dart). On Windows it is started detached with its stdio: a window starting a console program in the
/// normal mode makes Windows open a console window for it. There is no exit code in that mode; the end of stdout is the
/// end of the bridge.
final class ProcessBridgeChannel implements BridgeChannel {
  ProcessBridgeChannel._(this._process) {
    // A bridge that died makes writes to its stdin fail later; that is reported by its stdout ending, not here.
    _process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    _process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(
      (l) => _lastError = l.length > 512 ? l.substring(0, 512) : l,
      onError: (Object _) {},
    );
  }

  /// Starts [executable] with [arguments] (which end with `window-bridge`, or are `agent-run`). [mode] defaults to
  /// [ProcessStartMode.detachedWithStdio] on Windows and [ProcessStartMode.normal] elsewhere.
  static Future<ProcessBridgeChannel> start(String executable, List<String> arguments, {ProcessStartMode? mode}) async {
    final p = await Process.start(
      executable,
      arguments,
      mode: mode ?? (Platform.isWindows ? ProcessStartMode.detachedWithStdio : ProcessStartMode.normal),
    );
    return ProcessBridgeChannel._(p);
  }

  final Process _process;
  String _lastError = '';
  bool _ended = false;

  /// The bridge's process id (tests).
  int get pid => _process.pid;

  @override
  Stream<List<int>> get output => _process.stdout;

  @override
  String get lastError => _lastError;

  @override
  void add(List<int> bytes) {
    if (_ended) return;
    try {
      _process.stdin.add(bytes);
    } on Object {
      _ended = true;
    }
  }

  @override
  void kill() {
    if (_ended) return;
    _ended = true;
    try {
      unawaited(_process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    } on Object {
      // already closed
    }
    _process.kill();
  }
}

/// Many control connections over one bridge process, started on the first [open] and again after it ends.
final class BridgeMux {
  /// [restartDelay]: the least time between two starts, so a bridge that cannot run is not restarted in a loop.
  BridgeMux(this._start, {this.restartDelay = const Duration(milliseconds: 500), int firstId = 1})
      : assert(firstId > 0 && firstId < bridgeIdLimit),
        _firstId = firstId;

  /// `<executable> <arguments…> window-bridge`. [executable] comes from the host layer (the `antenna` next to the
  /// window), never from PATH.
  factory BridgeMux.process(String executable, {List<String> arguments = const []}) =>
      BridgeMux(() => ProcessBridgeChannel.start(executable, [...arguments, windowBridgeCommand]));

  final BridgeStarter _start;
  final Duration restartDelay;
  final int _firstId;
  _Bridge? _bridge;
  Future<_Bridge>? _starting;
  DateTime? _lastStart;
  bool _disposed = false;

  /// How many bridges were started (tests).
  int starts = 0;

  /// The running bridge's channel, if any (tests).
  BridgeChannel? get channel => _bridge?.dead == false ? _bridge!.channel : null;

  /// Opens a connection to the daemon. The open is sent at once; whether the daemon was reached shows on
  /// [BridgeConnection.input] (its first bytes, or a [BridgeException]).
  Future<BridgeConnection> open() async {
    final b = await _running();
    return b.open();
  }

  Future<_Bridge> _running() {
    if (_disposed) return Future.error(const BridgeException('the window bridge is closed'));
    final b = _bridge;
    if (b != null && !b.dead) return Future.value(b);
    return _starting ??= _startBridge().whenComplete(() => _starting = null);
  }

  Future<_Bridge> _startBridge() async {
    final last = _lastStart;
    if (last != null) {
      final wait = restartDelay - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastStart = DateTime.now();
    starts++;
    final BridgeChannel ch;
    try {
      ch = await _start();
    } on ProcessException catch (e) {
      throw BridgeException('cannot start the window bridge ${e.executable}: ${e.message}');
    } on Object catch (e) {
      throw BridgeException('cannot start the window bridge: $e');
    }
    if (_disposed) {
      ch.kill();
      throw const BridgeException('the window bridge is closed');
    }
    return _bridge = _Bridge(ch, _firstId);
  }

  /// Ends the bridge; its connections fail. The mux opens nothing afterwards.
  Future<void> dispose() async {
    _disposed = true;
    _bridge?.die(const BridgeException('the window bridge is closed'));
  }
}

/// One connection through the bridge.
final class BridgeConnection {
  BridgeConnection._(this._bridge, this.id);

  final _Bridge _bridge;

  /// The connection id.
  final int id;

  // Single-subscription: bytes are kept until the client listens.
  final _input = StreamController<List<int>>();
  bool _closeSent = false;
  bool _closeReceived = false;
  BridgeException? _error;

  /// The daemon's bytes. Ends when the connection ends; a connection the bridge could not make, or a bridge that
  /// stopped, ends with a [BridgeException] first.
  Stream<List<int>> get input => _input.stream;

  /// Sends bytes to the daemon, in frames of at most [bridgeMaxFrame] bytes. Dropped once the connection has ended.
  void add(List<int> bytes) {
    if (_closeSent || _closeReceived || _bridge.dead) return;
    for (var at = 0; at < bytes.length; at += bridgeMaxFrame) {
      final end = at + bridgeMaxFrame < bytes.length ? at + bridgeMaxFrame : bytes.length;
      _bridge.send(id, BridgeFrame.data, bytes.sublist(at, end));
    }
  }

  /// Closes the connection; the id stays in use until the bridge answers with its close.
  Future<void> close() async {
    if (!_closeSent && !_closeReceived && !_bridge.dead) {
      _closeSent = true;
      _bridge.send(id, BridgeFrame.close, const []);
    }
    _closeSent = true;
    _end();
  }

  void _data(Uint8List bytes) {
    if (!_closeSent && !_input.isClosed) _input.add(bytes);
  }

  void _end([BridgeException? e]) {
    if (_input.isClosed) return;
    final err = e ?? _error;
    if (err != null) _input.addError(err);
    unawaited(_input.close());
  }
}

/// One bridge process: its connections and the reader of its frames.
final class _Bridge {
  _Bridge(this.channel, this._nextId) {
    _sub = channel.output.listen(
      _onBytes,
      onError: (Object e) => die(BridgeException('the window bridge failed: $e')),
      onDone: () {
        final why = channel.lastError.isEmpty ? '' : ': ${channel.lastError}';
        die(BridgeException(_len > 0 ? 'the window bridge stopped inside a frame$why' : 'the window bridge stopped$why'));
      },
    );
  }

  final BridgeChannel channel;
  late final StreamSubscription<List<int>> _sub;

  /// Connections in use: from the window's open until both closes.
  final _conns = <int, BridgeConnection>{};
  int _nextId;
  bool dead = false;

  // Bytes of the frames not yet whole.
  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;

  BridgeConnection open() {
    if (dead) throw const BridgeException('the window bridge stopped');
    if (_conns.length >= bridgeMaxConnections) {
      throw const BridgeException('too many connections through the window bridge ($bridgeMaxConnections)');
    }
    var id = _nextId;
    while (_conns.containsKey(id)) {
      id = id + 1 >= bridgeIdLimit ? 1 : id + 1;
    }
    _nextId = id + 1 >= bridgeIdLimit ? 1 : id + 1;
    final c = BridgeConnection._(this, id);
    _conns[id] = c;
    send(id, BridgeFrame.open, const []);
    return c;
  }

  void send(int id, int kind, List<int> payload) {
    final b = Uint8List(_header + payload.length);
    ByteData.sublistView(b)
      ..setUint32(0, id, Endian.little)
      ..setUint8(4, kind)
      ..setUint32(5, payload.length, Endian.little);
    b.setRange(_header, b.length, payload);
    channel.add(b);
  }

  void _onBytes(List<int> chunk) {
    if (dead) return;
    if (_len + chunk.length > _buf.length) {
      var size = _buf.length;
      while (size < _len + chunk.length) {
        size *= 2;
      }
      _buf = Uint8List(size)..setRange(0, _len, _buf);
    }
    _buf.setRange(_len, _len + chunk.length, chunk);
    _len += chunk.length;
    var at = 0;
    while (_len - at >= _header) {
      final head = ByteData.sublistView(_buf, at, at + _header);
      final id = head.getUint32(0, Endian.little);
      final kind = head.getUint8(4);
      final len = head.getUint32(5, Endian.little);
      // The header is checked before the content is waited for: an oversized length never grows the buffer.
      final wrong = _check(id, kind, len);
      if (wrong != null) {
        die(BridgeException('the window bridge broke its framing: $wrong'));
        return;
      }
      if (_len - at - _header < len) break;
      final payload = Uint8List.fromList(Uint8List.sublistView(_buf, at + _header, at + _header + len));
      at += _header + len;
      _dispatch(id, kind, payload);
      if (dead) return;
    }
    if (at > 0) {
      _buf.setRange(0, _len - at, _buf, at);
      _len -= at;
    }
    // A buffer grown for one long frame shrinks back once it is empty.
    if (_len == 0 && _buf.length > 64 * 1024) _buf = Uint8List(64 * 1024);
  }

  /// What is wrong with a frame's header, or `null`.
  String? _check(int id, int kind, int len) {
    if (len > bridgeMaxFrame) return 'a frame of $len bytes for connection $id';
    if (id >= bridgeIdLimit) return 'connection $id, which is not below 2^31';
    final allowed = switch (kind) {
      BridgeFrame.data || BridgeFrame.error => len > 0,
      BridgeFrame.close => len == 0,
      _ => null,
    };
    if (allowed == null) return 'a frame of type $kind for connection $id';
    if (!allowed) return 'a frame of type $kind with $len bytes for connection $id';
    if (!_conns.containsKey(id)) return 'a frame of type $kind for connection $id, which is not in use';
    return null;
  }

  void _dispatch(int id, int kind, Uint8List payload) {
    final c = _conns[id]!;
    switch (kind) {
      case BridgeFrame.data:
        c._data(payload);
      case BridgeFrame.error:
        c._error = _errorOf(payload);
      case BridgeFrame.close:
        // The id is free once both sides have closed: answer the bridge's close unless the window closed first.
        c._closeReceived = true;
        if (!c._closeSent) {
          c._closeSent = true;
          send(id, BridgeFrame.close, const []);
        }
        _conns.remove(id);
        c._end();
    }
  }

  /// `<code>: <message>` from the CLI's error; any other text is the message, with the code `bridge`.
  static BridgeException _errorOf(Uint8List payload) {
    final text = utf8.decode(payload, allowMalformed: true);
    final i = text.indexOf(': ');
    if (i > 0 && RegExp(r'^[a-z_]+$').hasMatch(text.substring(0, i))) {
      return BridgeException(text.substring(i + 2), code: text.substring(0, i));
    }
    return BridgeException(text);
  }

  /// Ends this bridge: every connection fails with [e], and the next open starts another bridge.
  void die(BridgeException e) {
    if (dead) return;
    dead = true;
    unawaited(_sub.cancel());
    channel.kill();
    final all = _conns.values.toList();
    _conns.clear();
    for (final c in all) {
      c._end(e);
    }
  }
}
