// SPDX-License-Identifier: AGPL-3.0-only
// Client for the control unix socket of the `antennad` daemon (antenna_proto::control, D-22). Pure Dart (dart:io),
// no Flutter: the same code will go into the mobile build on top of the embedded core (flutter_rust_bridge) or into
// Dart CLI utilities. On Windows the daemon's endpoint is a named pipe, which dart:io cannot open: there each
// connection goes through the window bridge (`bridge_mux.dart`, D-135) instead of a socket, with the same lines.
//
// One dialog per connection: `hello` → `hello_ok` → `req` → `event`* → `ok`/`err`. Owner input during pairing
// (`input`) goes over the same connection. If the client closes the connection during pairing, the daemon treats it
// as a refusal.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_mux.dart';
import 'daemon.dart';
import 'daemon_calls.dart';
import 'errors.dart';
import 'models.dart';
import 'requests.dart';

/// Client of one daemon. Every call is a separate connection (that is how the protocol works).
final class XControlClient with XDaemonCalls implements XDaemon {
  XControlClient(this.socketPath, {this.connectTimeout = const Duration(seconds: 3), this.bridge});

  @override
  final String socketPath;
  final Duration connectTimeout;

  /// Connections go through this window bridge instead of a unix socket (Windows, D-135); [socketPath] is then only
  /// shown in errors, and the bridge finds the daemon itself.
  final BridgeMux? bridge;

  /// Owner session token (`xos_…`, v2): put into `hello.session` of every connection from this process.
  @override
  String? sessionToken;

  /// The `hello.proto` this client sends: [controlProto], or the newest of [controlProtos] the daemon accepted once it
  /// refused a newer one (it stays for this client: a daemon does not get newer without a restart, and a restart
  /// reconnects).
  String proto = controlProto;

  /// Open a connection. A daemon older than [proto] refuses the hello, and the client asks again with the next older
  /// version of [controlProtos] until one is accepted or none is left (CONTROL §2: the daemon echoes the accepted
  /// version in `hello_ok.proto`). Each connection steps down from the version it tried itself, so two connections
  /// refused at the same time never skip a version.
  Future<_Connection> _connect() async {
    var tried = proto;
    while (true) {
      try {
        return await _Connection.open(socketPath, connectTimeout, session: sessionToken, proto: tried, bridge: bridge);
      } on XControlException catch (e) {
        final older = olderControlProto(tried);
        if (older == null || !isUnsupportedProto(e)) rethrow;
        tried = older;
        if (controlProtos.indexOf(older) > controlProtos.indexOf(proto)) proto = older;
      }
    }
  }

  @override
  Future<HelloOk> hello() async {
    final conn = await _connect();
    try {
      return conn.helloOk;
    } finally {
      await conn.close();
    }
  }

  @override
  Future<Reply> call(XRequest request) async {
    if (request.isDialog) {
      return open(request).result;
    }
    final conn = await _connect();
    try {
      conn.send({'req': request.toJson()});
      return await _finalReply(conn);
    } finally {
      await conn.close();
    }
  }

  @override
  Future<Reply> callWithProof(XRequest request, ProofSource prove) async {
    if (request.isDialog) return openWithProof(request, prove).result;
    // Sign first, then connect: a Touch ID prompt may take seconds, and the line must carry the signed text as is.
    final req = requestText(request);
    final proof = await prove(req);
    final conn = await _connect();
    try {
      conn.sendLine(proofLine(req, proof));
      return await _finalReply(conn);
    } finally {
      await conn.close();
    }
  }

  static Future<Reply> _finalReply(_Connection conn) async {
    while (true) {
      final m = await conn.next();
      switch (m) {
        case _Ok(:final reply):
          return reply;
        case _Err(:final error):
          throw error;
        case _Ev():
          continue; // non-dialog requests do not send events; tolerate them anyway
      }
    }
  }

  @override
  XDialog open(XRequest request) => _SocketDialog.start(_connect, request);

  @override
  XDialog openWithProof(XRequest request, ProofSource prove) => _SocketDialog.start(_connect, request, prove: prove);
}

sealed class _ServerMsg {}

final class _Ok extends _ServerMsg {
  _Ok(this.reply);
  final Reply reply;
}

final class _Err extends _ServerMsg {
  _Err(this.error);
  final XControlException error;
}

final class _Ev extends _ServerMsg {
  _Ev(this.event);
  final XEvent event;
}

/// One connection: JSON lines in both directions, over a unix socket or one connection of the window bridge.
final class _Connection {
  _Connection._(Stream<List<int>> input, this._write, this._closeTransport, this.socketPath)
      : _lines = StreamIterator(input.transform(const Utf8Decoder()).transform(const LineSplitter()));

  final void Function(List<int> bytes) _write;
  final Future<void> Function() _closeTransport;
  final StreamIterator<String> _lines;
  final String socketPath;
  late final HelloOk helloOk;
  bool _closed = false;

  static Future<_Connection> open(
    String path,
    Duration timeout, {
    String? session,
    String proto = controlProto,
    BridgeMux? bridge,
  }) async {
    final c = bridge != null ? await _throughBridge(path, bridge) : await _overSocket(path, timeout);
    try {
      c.send({
        'hello': {'proto': proto, 'role': 'owner', 'session': ?session},
      });
      final first = await c._nextJson();
      if (first case {'hello_ok': final Map<String, Object?> h}) {
        c.helloOk = HelloOk.fromJson(h);
      } else if (first case {'err': final Map<String, Object?> e}) {
        throw _error(e);
      } else {
        throw XProtocolException('expected hello_ok, got ${first.keys.join(',')}');
      }
      return c;
    } catch (_) {
      await c.close();
      rethrow;
    }
  }

  static Future<_Connection> _overSocket(String path, Duration timeout) async {
    // Windows: no unix socket is ever opened there, since Windows' afunix.sys bugchecks the machine when a process with
    // one ends (D-135). Its control endpoint is a named pipe, reached only through the window bridge.
    if (Platform.isWindows) {
      throw XDaemonUnreachable(path, 'the Antenna daemon does not run on Windows yet');
    }
    final Socket socket;
    try {
      socket = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0, timeout: timeout);
    } on SocketException catch (e) {
      throw XDaemonUnreachable(path, e.osError?.message ?? e.message);
    } on ArgumentError catch (e) {
      throw XDaemonUnreachable(path, e.message.toString());
    }
    return _Connection._(socket.cast<List<int>>(), socket.add, () async {
      try {
        await socket.flush();
      } catch (_) {}
      socket.destroy();
    }, path);
  }

  /// The bridge connects when it reads the open, so a daemon it cannot reach shows on the first read, as
  /// [_bridgeError].
  static Future<_Connection> _throughBridge(String path, BridgeMux bridge) async {
    final BridgeConnection b;
    try {
      b = await bridge.open();
    } on BridgeException catch (e) {
      throw _bridgeError(path, e);
    }
    return _Connection._(b.input, b.add, b.close, path);
  }

  /// A daemon endpoint held by something the CLI does not trust is not "unreachable": the window must not start a
  /// second daemon against it (D-135 item 4).
  static XClientException _bridgeError(String path, BridgeException e) => e.untrusted
      ? XDaemonUntrusted(
          path,
          'the daemon\'s endpoint is held by a program that is not your daemon, so the window does not connect to it '
          'and does not start a daemon: ${e.message}',
        )
      : XDaemonUnreachable(path, e.message);

  void send(Json msg) => sendLine(jsonEncode(msg));

  /// One line as is (a request with a proof carries the signed text unchanged).
  void sendLine(String line) {
    if (_closed) throw const XProtocolException('connection is closed');
    _write(utf8.encode('$line\n'));
  }

  Future<Json> _nextJson() async {
    final bool has;
    try {
      has = await _lines.moveNext();
    } on SocketException catch (e) {
      throw XDaemonUnreachable(socketPath, 'connection lost: ${e.message}');
    } on BridgeException catch (e) {
      throw _bridgeError(socketPath, e);
    }
    if (!has) throw XDaemonUnreachable(socketPath, 'daemon closed the connection');
    final line = _lines.current;
    if (line.length > maxReplyLine) throw const XProtocolException('line too long');
    final Object? v;
    try {
      v = jsonDecode(line);
    } on FormatException catch (e) {
      throw XProtocolException('not JSON: ${e.message}');
    }
    if (v is! Map<String, Object?>) throw const XProtocolException('expected JSON object');
    return v;
  }

  Future<_ServerMsg> next() async {
    final m = await _nextJson();
    return switch (m) {
      {'ok': final Map<String, Object?> r} => _Ok(Reply.fromJson(r)),
      {'err': final Map<String, Object?> e} => _Err(_error(e)),
      {'event': final Map<String, Object?> e} => _Ev(XEvent.fromJson(e)),
      _ => throw XProtocolException('unexpected message: ${m.keys.join(',')}'),
    };
  }

  static XControlException _error(Json e) => XControlException(
        (e['code'] as String?) ?? XErrorCode.internal,
        (e['message'] as String?) ?? '',
        approval: e['approval'] is Map<String, Object?> ? e['approval'] as Map<String, Object?> : null,
      );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _closeTransport();
    await _lines.cancel();
  }
}

/// A pairing dialog over a single connection.
final class _SocketDialog implements XDialog {
  _SocketDialog._();

  // Single-subscription: events are buffered until the UI subscribes.
  final _events = StreamController<XEvent>();
  final _result = Completer<Reply>();
  final _pendingInputs = <XInput>[];
  _Connection? _conn;
  bool _cancelled = false;

  /// With [prove], the request goes with a proof over its exact text (`login {password: "", hold: true}`).
  static _SocketDialog start(Future<_Connection> Function() connect, XRequest request, {ProofSource? prove}) {
    final d = _SocketDialog._();
    // A result error must not count as "unhandled" if the UI has not awaited it yet (a later await gets the same
    // error).
    d._result.future.then<void>((_) {}, onError: (Object _) {});
    unawaited(d._run(connect, request, prove));
    return d;
  }

  Future<void> _run(Future<_Connection> Function() connect, XRequest request, ProofSource? prove) async {
    try {
      // The proof first (it may wait for Touch ID), then the connection; the line carries the signed text as is.
      String? line;
      if (prove != null) {
        final req = requestText(request);
        line = proofLine(req, await prove(req));
      }
      if (_cancelled) throw const XControlException(XErrorCode.rejected, 'cancelled by the owner');
      final conn = await connect();
      _conn = conn;
      if (_cancelled) {
        await conn.close();
        throw const XControlException(XErrorCode.rejected, 'cancelled by the owner');
      }
      if (line != null) {
        conn.sendLine(line);
      } else {
        conn.send({'req': request.toJson()});
      }
      for (final i in _pendingInputs) {
        conn.send({'input': i.toJson()});
      }
      _pendingInputs.clear();
      while (true) {
        final m = await conn.next();
        switch (m) {
          case _Ev(:final event):
            _events.add(event);
          case _Ok(:final reply):
            _result.complete(reply);
            return;
          case _Err(:final error):
            throw error;
        }
      }
    } catch (e, st) {
      if (!_result.isCompleted) {
        if (_cancelled && e is XDaemonUnreachable) {
          _result.completeError(const XControlException(XErrorCode.rejected, 'cancelled by the owner'), st);
        } else {
          _result.completeError(e, st);
        }
      }
    } finally {
      await _conn?.close();
      await _events.close();
    }
  }

  @override
  Stream<XEvent> get events => _events.stream;

  @override
  Future<Reply> get result => _result.future;

  @override
  void input(XInput i) {
    final c = _conn;
    if (c == null) {
      _pendingInputs.add(i);
    } else {
      c.send({'input': i.toJson()});
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _conn?.close();
  }
}
