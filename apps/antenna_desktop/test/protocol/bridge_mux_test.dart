// SPDX-License-Identifier: AGPL-3.0-only
// The window bridge's mux (D-135, CONTROL §34) against a fake bridge, a pair of streams: the frames it sends, the
// frames it takes, each bound of the format (frame size, types and lengths, ids in use and below 2^31, 256 connections
// counted until both closes), the bridge's end and restart, and the client's errors through it (an unreachable daemon
// is XDaemonUnreachable, so the window starts its daemon; an untrusted endpoint is not, so it never does). No process
// and no socket: runs on every system.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A frame as the test compares it: the payload as Latin-1 text, one character per byte.
typedef _Frame = (int id, int kind, String payload);

Uint8List _encode(int id, int kind, [List<int> payload = const []]) {
  final b = Uint8List(9 + payload.length);
  ByteData.sublistView(b)
    ..setUint32(0, id, Endian.little)
    ..setUint8(4, kind)
    ..setUint32(5, payload.length, Endian.little);
  b.setRange(9, b.length, payload);
  return b;
}

/// A bridge process as two streams: [frame] and [raw] write its stdout; [next] reads the frames the mux sent to its
/// stdin. [onFrame], if set, answers frames as they come (a stand-in daemon).
final class _FakeBridge implements BridgeChannel {
  _FakeBridge({this.onFrame});

  final void Function(_FakeBridge bridge, int id, int kind, List<int> payload)? onFrame;
  final _out = StreamController<List<int>>();
  final _sent = StreamController<_Frame>();
  late final _frames = StreamIterator(_sent.stream);
  final _in = BytesBuilder();
  bool killed = false;

  @override
  String lastError = '';

  @override
  Stream<List<int>> get output => _out.stream;

  @override
  void add(List<int> bytes) {
    expect(killed, isFalse, reason: 'a write to a bridge that was ended');
    _in.add(bytes);
    var buf = _in.takeBytes();
    while (buf.length >= 9) {
      final head = ByteData.sublistView(buf, 0, 9);
      final len = head.getUint32(5, Endian.little);
      expect(len, lessThanOrEqualTo(bridgeMaxFrame));
      if (buf.length < 9 + len) break;
      final payload = buf.sublist(9, 9 + len);
      final f = (head.getUint32(0, Endian.little), head.getUint8(4), latin1.decode(payload));
      buf = buf.sublist(9 + len);
      _sent.add(f);
      onFrame?.call(this, f.$1, f.$2, payload);
    }
    _in.add(buf);
  }

  @override
  void kill() {
    killed = true;
    end();
  }

  void frame(int id, int kind, [List<int> payload = const []]) => raw(_encode(id, kind, payload));

  void raw(List<int> bytes) {
    if (!_out.isClosed) _out.add(bytes);
  }

  void end() {
    if (!_out.isClosed) unawaited(_out.close());
  }

  Future<_Frame> next() async {
    expect(await _frames.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    return _frames.current;
  }
}

/// A mux whose bridges are fakes, kept in [bridges].
(BridgeMux, List<_FakeBridge>) _mux({int firstId = 1, _FakeBridge Function()? make}) {
  final bridges = <_FakeBridge>[];
  final mux = BridgeMux(() async {
    final b = (make ?? _FakeBridge.new)();
    bridges.add(b);
    return b;
  }, restartDelay: Duration.zero, firstId: firstId);
  return (mux, bridges);
}

/// What a connection's input gives: its bytes as text, and the error it ended with.
Future<(String, Object?)> _drain(BridgeConnection c) async {
  final got = BytesBuilder();
  Object? error;
  final done = Completer<void>();
  c.input.listen(got.add, onError: (Object e) => error = e, onDone: done.complete);
  await done.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('the input did not end'));
  return (utf8.decode(got.takeBytes()), error);
}

Matcher _bridgeError(Object message) => isA<BridgeException>().having((e) => e.message, 'message', message);

/// Opens a mux connection and expects the bridge to have got its open.
Future<BridgeConnection> _open(BridgeMux mux, _FakeBridge Function() bridge) async {
  final c = await mux.open();
  expect(await bridge().next(), (c.id, BridgeFrame.open, ''));
  return c;
}

void main() {
  test('data both ways; the bridge\'s close ends the input and is answered with the window\'s', () async {
    final (mux, bridges) = _mux();
    final c = await _open(mux, () => bridges.single);
    expect(c.id, 1);
    c.add(utf8.encode('hello\n'));
    expect(await bridges.single.next(), (1, BridgeFrame.data, 'hello\n'));
    bridges.single
      ..frame(1, BridgeFrame.data, utf8.encode('re:'))
      ..frame(1, BridgeFrame.data, utf8.encode('hello\n'))
      ..frame(1, BridgeFrame.close);
    expect(await _drain(c), ('re:hello\n', null));
    expect(await bridges.single.next(), (1, BridgeFrame.close, ''));
    // After both closes the id is not in use: a frame for it breaks the format.
    bridges.single.frame(1, BridgeFrame.data, utf8.encode('stale'));
    await pumpEventQueue();
    expect(bridges.single.killed, isTrue);
  });

  test('the window\'s close is sent once; the bridge\'s data until its close is dropped; then the id is free', () async {
    final (mux, bridges) = _mux();
    final c = await _open(mux, () => bridges.single);
    final drained = _drain(c);
    await c.close();
    await c.close();
    c.add(utf8.encode('after close\n'));
    expect(await bridges.single.next(), (1, BridgeFrame.close, ''));
    bridges.single
      ..frame(1, BridgeFrame.data, utf8.encode('late\n'))
      ..frame(1, BridgeFrame.close);
    expect(await drained, ('', null));
    final d = await mux.open();
    expect(await bridges.single.next(), (d.id, BridgeFrame.open, ''), reason: 'nothing else was sent for 1');
    expect(bridges.single.killed, isFalse);
  });

  test('an error frame, then the close: the input ends with the code and the message', () async {
    final (mux, bridges) = _mux();
    for (final (text, code, message) in [
      ('daemon_unavailable: cannot connect to antennad', 'daemon_unavailable', 'cannot connect to antennad'),
      ('daemon_untrusted: the pipe belongs to another user', daemonUntrustedCode, 'the pipe belongs to another user'),
      ('no code here', 'bridge', 'no code here'),
    ]) {
      final c = await mux.open();
      bridges.single
        ..frame(c.id, BridgeFrame.error, utf8.encode(text))
        ..frame(c.id, BridgeFrame.close);
      final (_, error) = await _drain(c);
      expect(error, isA<BridgeException>().having((e) => e.code, 'code', code).having((e) => e.message, 'message', message));
      expect((error! as BridgeException).untrusted, code == daemonUntrustedCode);
    }
  });

  test('a frame of the limit passes; one byte more ends the bridge, every connection fails, the next open restarts it',
      () async {
    final (mux, bridges) = _mux();
    final a = await _open(mux, () => bridges.single);
    final b = await _open(mux, () => bridges.single);
    final big = List<int>.filled(bridgeMaxFrame, 0x61);
    final da = _drain(a);
    final db = _drain(b);
    bridges.single
      ..frame(a.id, BridgeFrame.data, big)
      ..raw(_head(b.id, BridgeFrame.data, bridgeMaxFrame + 1));
    final (gotA, errA) = await da;
    expect(gotA.length, bridgeMaxFrame);
    expect(errA, _bridgeError(contains('broke its framing')));
    expect((await db).$2, _bridgeError(contains('a frame of ${bridgeMaxFrame + 1} bytes')));
    expect(bridges.single.killed, isTrue);
    final c = await mux.open();
    expect(mux.starts, 2);
    expect(c.id, 1, reason: 'a new bridge has no connection in use');
  });

  test('an unknown type, an open from the bridge, or a length its type does not allow ends the bridge', () async {
    for (final (kind, payload) in <(int, List<int>)>[
      (0, []),
      (BridgeFrame.open, []),
      (5, [1]),
      (255, [1]),
      (BridgeFrame.close, [1]),
      (BridgeFrame.data, []),
      (BridgeFrame.error, []),
    ]) {
      final (mux, bridges) = _mux();
      final c = await _open(mux, () => bridges.single);
      bridges.single.frame(c.id, kind, payload);
      expect((await _drain(c)).$2, _bridgeError(contains('broke its framing')), reason: 'type $kind, ${payload.length} bytes');
      expect(bridges.single.killed, isTrue);
    }
  });

  test('a frame for an id not in use, or of 2^31 and above, ends the bridge', () async {
    for (final id in [2, 7, bridgeIdLimit, 0xffffffff]) {
      final (mux, bridges) = _mux();
      final c = await _open(mux, () => bridges.single);
      bridges.single.frame(id, BridgeFrame.data, [1]);
      expect((await _drain(c)).$2, _bridgeError(contains('connection $id')), reason: 'id $id');
      expect(bridges.single.killed, isTrue);
    }
  });

  test('at most 256 connections in use, counting a closed one until the bridge answers', () async {
    final (mux, bridges) = _mux();
    final open = <BridgeConnection>[];
    for (var i = 0; i < bridgeMaxConnections; i++) {
      open.add(await mux.open());
    }
    await expectLater(mux.open(), throwsA(_bridgeError(contains('too many connections'))));
    await open.first.close();
    await expectLater(mux.open(), throwsA(isA<BridgeException>()), reason: 'still in use until the bridge closes it');
    bridges.single.frame(open.first.id, BridgeFrame.close);
    await pumpEventQueue();
    final again = await mux.open();
    expect(again.id, bridgeMaxConnections + 1);
    expect(bridges.single.killed, isFalse);
  });

  test('ids stay below 2^31: they wrap to 1 and skip ids in use', () async {
    final (mux, bridges) = _mux(firstId: bridgeIdLimit - 2);
    final ids = [for (var i = 0; i < 3; i++) (await mux.open()).id];
    expect(ids, [bridgeIdLimit - 2, bridgeIdLimit - 1, 1]);
    final (wrapped, _) = _mux(firstId: bridgeIdLimit - 1);
    final first = await wrapped.open();
    expect(first.id, bridgeIdLimit - 1);
    expect((await wrapped.open()).id, 1);
    expect((await wrapped.open()).id, 2);
    expect(bridges.single.killed, isFalse);
  });

  test('a long write goes in frames of at most one line', () async {
    final (mux, bridges) = _mux();
    final c = await _open(mux, () => bridges.single);
    c.add(List<int>.filled(2 * bridgeMaxFrame + 5, 0x62));
    final sizes = [for (var i = 0; i < 3; i++) (await bridges.single.next()).$3.length];
    expect(sizes, [bridgeMaxFrame, bridgeMaxFrame, 5]);
  });

  test('the bridge\'s end fails every connection with its last stderr line, and says when a frame was cut short',
      () async {
    final (mux, bridges) = _mux();
    final c = await _open(mux, () => bridges.single);
    bridges.single
      ..lastError = 'antenna window-bridge: stdin ended inside a frame'
      ..raw(_encode(c.id, BridgeFrame.data, [1, 2, 3]).sublist(0, 10))
      ..end();
    expect(
      (await _drain(c)).$2,
      _bridgeError('the window bridge stopped inside a frame: antenna window-bridge: stdin ended inside a frame'),
    );
    final (mux2, bridges2) = _mux();
    final d = await _open(mux2, () => bridges2.single);
    bridges2.single.end();
    expect((await _drain(d)).$2, _bridgeError('the window bridge stopped'));
    await mux2.open();
    expect(mux2.starts, 2);
  });

  test('a bridge that cannot start fails the open; the next open tries again, not before the delay', () async {
    var tries = 0;
    final mux = BridgeMux(() async {
      tries++;
      throw const ProcessException('antenna.exe', ['window-bridge'], 'The system cannot find the file specified', 2);
    }, restartDelay: const Duration(milliseconds: 200));
    await expectLater(mux.open(), throwsA(_bridgeError(contains('cannot start the window bridge antenna.exe'))));
    final t = Stopwatch()..start();
    await expectLater(mux.open(), throwsA(isA<BridgeException>()));
    expect(tries, 2);
    expect(t.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
  });

  test('dispose ends the bridge and refuses later opens', () async {
    final (mux, bridges) = _mux();
    final c = await _open(mux, () => bridges.single);
    await mux.dispose();
    expect((await _drain(c)).$2, _bridgeError('the window bridge is closed'));
    expect(bridges.single.killed, isTrue);
    await expectLater(mux.open(), throwsA(isA<BridgeException>()));
  });

  group('the control client through the bridge', () {
    /// A stand-in daemon behind the fake bridge: hello → hello_ok, then the connection ends. [refuse] answers every
    /// open with an error frame instead.
    _FakeBridge daemon({String? refuse}) => _FakeBridge(onFrame: (b, id, kind, payload) {
          if (kind == BridgeFrame.open && refuse != null) {
            b
              ..frame(id, BridgeFrame.error, utf8.encode(refuse))
              ..frame(id, BridgeFrame.close);
          } else if (kind == BridgeFrame.data && utf8.decode(payload).contains('"hello"')) {
            final hello = jsonDecode(utf8.decode(payload).trim()) as Map<String, Object?>;
            final proto = (hello['hello']! as Map<String, Object?>)['proto'];
            b
              ..frame(
                id,
                BridgeFrame.data,
                utf8.encode('${jsonEncode({
                  'hello_ok': {
                    'daemon': 'antennad 0.1.0 (test)',
                    'protocol': 'x/1',
                    'state': 'unlocked',
                    'role': 'owner',
                    'proto': proto,
                    'session': 'none',
                  },
                })}\n'),
              )
              ..frame(id, BridgeFrame.close);
          }
        });

    test('two hellos at once, over one bridge', () async {
      final (mux, bridges) = _mux(make: daemon);
      final client = XControlClient('/nowhere/antennad.sock', bridge: mux);
      final hellos = await Future.wait([client.hello(), client.hello()]);
      expect(hellos.map((h) => h.role), ['owner', 'owner']);
      expect(mux.starts, 1);
      expect(bridges.single.killed, isFalse);
    });

    test('an unreachable daemon is XDaemonUnreachable, so the window starts its daemon', () async {
      final (mux, _) = _mux(make: () => daemon(refuse: 'daemon_unavailable: cannot connect to antennad (is it running?)'));
      final client = XControlClient(r'C:\Users\u\AppData\Local\Antenna\antennad.sock', bridge: mux);
      await expectLater(
        client.hello(),
        throwsA(isA<XDaemonUnreachable>()
            .having((e) => e.message, 'message', 'cannot connect to antennad (is it running?)')
            .having((e) => e.socketPath, 'socketPath', r'C:\Users\u\AppData\Local\Antenna\antennad.sock')),
      );
    });

    test('an untrusted endpoint is XDaemonUntrusted, not XDaemonUnreachable, and the text says why', () async {
      final (mux, _) = _mux(make: () => daemon(refuse: 'daemon_untrusted: it belongs to another user'));
      final client = XControlClient('antennad.sock', bridge: mux);
      Object? error;
      try {
        await client.hello();
      } catch (e) {
        error = e;
      }
      expect(error, isA<XDaemonUntrusted>());
      expect(error, isNot(isA<XDaemonUnreachable>()));
      expect((error! as XDaemonUntrusted).message, allOf(contains('does not start a daemon'), contains('another user')));
    });

    test('a bridge that cannot start is XDaemonUnreachable', () async {
      final mux = BridgeMux(() async => throw const ProcessException('antenna.exe', [], 'not found', 2));
      final client = XControlClient('antennad.sock', bridge: mux);
      await expectLater(client.hello(), throwsA(isA<XDaemonUnreachable>()));
    });
  });
}

/// A frame's header alone, with any length.
Uint8List _head(int id, int kind, int len) {
  final b = Uint8List(9);
  ByteData.sublistView(b)
    ..setUint32(0, id, Endian.little)
    ..setUint8(4, kind)
    ..setUint32(5, len, Endian.little);
  return b;
}
