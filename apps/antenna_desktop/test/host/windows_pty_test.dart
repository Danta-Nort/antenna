// SPDX-License-Identifier: AGPL-3.0-only
// T14 (D-134): Code mode's terminal on Windows, `antenna agent-run` behind frames, against a fake host. The
// spec goes first and carries the run; keys and sizes follow, also when written before the host started; the exit
// code comes only from EXIT; Stop is a frame and the second step a kill; a host whose output ends without EXIT was
// killed, never a clean 0; a frame outside the format ends the host.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/host/windows_pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'xat_TESTTOKEN0123456789abcdefghijklmnopqrstu';

const _launch = AgentLaunch(
  executable: r'C:\Users\o\AppData\Local\Programs\Antenna\antenna.exe',
  arguments: [agentRunCommand],
  environment: {'ANTENNA_AGENT_TOKEN': _token, 'SystemRoot': r'C:\Windows'},
  workingDirectory: r'C:\Users\o\projects\app',
  command: [r'C:\Users\o\.local\bin\claude.exe', '--settings', '{"hooks":{}}'],
);

/// `antenna agent-run` as the window sees it: what it was sent, and what it says.
class _FakeHost implements BridgeChannel {
  final _out = StreamController<List<int>>();
  final sent = <int>[];
  bool killed = false;

  @override
  String lastError = '';

  @override
  Stream<List<int>> get output => _out.stream;

  @override
  void add(List<int> bytes) => sent.addAll(bytes);

  /// A killed process's stdout ends.
  @override
  void kill() {
    killed = true;
    unawaited(_out.close());
  }

  void say(int kind, List<int> payload, {int id = 0}) => _out.add(_frame(kind, payload, id: id));

  void raw(List<int> bytes) => _out.add(bytes);

  void end() => unawaited(_out.close());

  /// The frames the window sent, in order.
  List<(int, Uint8List)> get frames {
    final b = Uint8List.fromList(sent);
    final out = <(int, Uint8List)>[];
    var at = 0;
    while (at < b.length) {
      final h = ByteData.sublistView(b, at, at + 9);
      expect(h.getUint32(0, Endian.little), 0, reason: 'the only id is 0');
      final len = h.getUint32(5, Endian.little);
      out.add((h.getUint8(4), Uint8List.sublistView(b, at + 9, at + 9 + len)));
      at += 9 + len;
    }
    return out;
  }
}

Uint8List _frame(int kind, List<int> payload, {int id = 0}) {
  final f = agentRunFrame(kind, payload);
  ByteData.sublistView(f).setUint32(0, id, Endian.little);
  return f;
}

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

/// A run against a fake host that starts at once; [output] collects what the terminal gets.
Future<(WindowsAgentPty, _FakeHost, List<int>)> _run({int rows = 30, int columns = 100}) async {
  final host = _FakeHost();
  final pty = WindowsAgentPty(_launch, rows: rows, columns: columns, start: (_, _) async => host);
  final output = <int>[];
  pty.output.listen(output.addAll);
  await pumpEventQueue();
  return (pty, host, output);
}

void main() {
  test('the spec goes first and once, with the run; what is written before the start waits behind it', () async {
    final host = _FakeHost();
    final started = Completer<BridgeChannel>();
    final asked = <String>[];
    final pty = WindowsAgentPty(_launch, rows: 30, columns: 100, start: (exe, args) {
      asked.addAll([exe, ...args]);
      return started.future;
    });
    pty.write(Uint8List.fromList(utf8.encode('hello')));
    pty.resize(40, 120);
    await pumpEventQueue();
    expect(host.sent, isEmpty, reason: 'nothing before the host runs');
    started.complete(host);
    await pumpEventQueue();
    expect(asked, [_launch.executable, 'agent-run'], reason: 'no token on the command line');
    final frames = host.frames;
    expect(frames.map((f) => f.$1), [AgentRunFrame.spec, AgentRunFrame.data, AgentRunFrame.resize]);
    expect(jsonDecode(utf8.decode(frames[0].$2)), {
      'program': r'C:\Users\o\.local\bin\claude.exe',
      'args': ['--settings', '{"hooks":{}}'],
      'folder': r'C:\Users\o\projects\app',
      'env': {'ANTENNA_AGENT_TOKEN': _token, 'SystemRoot': r'C:\Windows'},
      'cols': 100,
      'rows': 30,
    });
    expect(utf8.decode(frames[1].$2), 'hello');
    final size = ByteData.sublistView(frames[2].$2);
    expect((size.getUint16(0, Endian.little), size.getUint16(2, Endian.little)), (40, 120), reason: 'rows, then cols');
    expect(pty.pid, 0, reason: 'no process group to address on Windows');
  });

  test('output frames reach the terminal, split anywhere; EXIT alone gives the exit code', () async {
    final (pty, host, output) = await _run();
    final bytes = [
      ..._frame(AgentRunFrame.data, utf8.encode('Claude Code ')),
      ..._frame(AgentRunFrame.data, utf8.encode('ready\r\n')),
      ..._frame(AgentRunFrame.exit, _u32(3)),
    ];
    // One byte at a time: a header and a body may be cut anywhere.
    for (final b in bytes) {
      host.raw([b]);
    }
    expect(await pty.exitCode, 3);
    expect(utf8.decode(output), 'Claude Code ready\r\n');
    // After the end, nothing more is sent.
    pty.write(Uint8List.fromList(const [0x61]));
    expect(pty.signalGroup(ProcessSignal.sighup), isFalse);
    expect(host.frames.map((f) => f.$1), [AgentRunFrame.spec]);
  });

  test('an exit code is the agent\'s whole u32 (a Windows status such as Ctrl+C\'s 0xC000013A)', () async {
    final (pty, host, _) = await _run();
    host.say(AgentRunFrame.exit, _u32(0xC000013A));
    expect(await pty.exitCode, 0xC000013A);
  });

  test('Stop is a frame; the second step kills the host; a run that ends without EXIT was killed', () async {
    final (pty, host, _) = await _run();
    expect(pty.signalGroup(ProcessSignal.sighup), isTrue);
    await pumpEventQueue();
    expect(host.frames.last.$1, AgentRunFrame.stop);
    expect(host.frames.last.$2, isEmpty, reason: 'Stop carries nothing');
    expect(host.killed, isFalse, reason: 'Stop lets the host end the job and report');
    expect(pty.signalGroup(ProcessSignal.sigint), isFalse, reason: 'nothing else is sent');
    expect(pty.signalGroup(ProcessSignal.sigkill), isTrue);
    expect(host.killed, isTrue);
    expect(await pty.exitCode, -9);
  });

  test('a stopped run reports what the host says: STOPPED is its EXIT', () async {
    final (pty, host, _) = await _run();
    pty.signalGroup(ProcessSignal.sighup);
    host.say(AgentRunFrame.exit, _u32(1));
    expect(await pty.exitCode, 1);
  });

  // Control: the end of the host's output is never taken for a clean end.
  test('a host whose output ends without EXIT was killed: -9, never 0, and its last word is shown', () async {
    final (pty, host, output) = await _run();
    host.say(AgentRunFrame.data, utf8.encode('working'));
    host.lastError = 'antenna agent-run: stdin ended inside a frame';
    host.end();
    expect(await pty.exitCode, -9);
    expect(utf8.decode(output), contains('stdin ended inside a frame'));
  });

  test('ERROR: the reason in the terminal, and no exit code (the agent never ran)', () async {
    final (pty, host, output) = await _run();
    host.say(AgentRunFrame.error, utf8.encode('cannot start the run: The system cannot find the file specified.'));
    expect(await pty.exitCode, isNull);
    expect(utf8.decode(output), contains('antenna: cannot start the run: The system cannot find the file specified.'));
  });

  test('a frame outside the format ends the host', () async {
    for (final bad in [
      _frame(AgentRunFrame.data, utf8.encode('x'), id: 1),
      _frame(AgentRunFrame.exit, const [0, 0, 0]),
      _frame(AgentRunFrame.spec, const []),
      _frame(AgentRunFrame.resize, const [0, 0, 0, 0]),
      _frame(9, const []),
      Uint8List.fromList([0, 0, 0, 0, AgentRunFrame.data, ..._u32(agentRunMaxFrame + 1)]),
    ]) {
      final (pty, host, output) = await _run();
      host.raw(bad);
      expect(await pty.exitCode, -9, reason: '$bad');
      expect(host.killed, isTrue, reason: '$bad');
      expect(utf8.decode(output), contains('outside its format'));
    }
  });

  test('a host that cannot start: the reason in the terminal, no exit code', () async {
    final pty = WindowsAgentPty(_launch,
        rows: 30, columns: 100, start: (exe, _) async => throw ProcessException(exe, const [], 'not found', 2));
    final output = <int>[];
    pty.output.listen(output.addAll);
    expect(await pty.exitCode, isNull);
    expect(utf8.decode(output), contains('cannot start ${_launch.executable}: not found'));
  });

  test('a kill before the host started ends the run at once, and the host when it comes', () async {
    final host = _FakeHost();
    final started = Completer<BridgeChannel>();
    final pty = WindowsAgentPty(_launch, rows: 30, columns: 100, start: (_, _) => started.future);
    expect(pty.signalGroup(ProcessSignal.sigkill), isTrue);
    expect(await pty.exitCode, -9);
    started.complete(host);
    await pumpEventQueue();
    expect(host.killed, isTrue);
    expect(host.sent, isEmpty, reason: 'not even the spec');
  });

  test('a long paste goes in frames of at most 64 KiB; sizes are clamped, an empty one is not sent', () async {
    final (pty, host, _) = await _run(rows: 0, columns: 70000);
    final paste = Uint8List.fromList(List.generate(150 * 1024, (i) => 0x61 + i % 26));
    pty.write(paste);
    pty.resize(0, 80);
    pty.resize(24, 0);
    final frames = host.frames;
    final spec = jsonDecode(utf8.decode(frames.first.$2)) as Map;
    expect((spec['rows'], spec['cols']), (1, 0xffff));
    final keys = frames.skip(1).toList();
    expect(keys.map((f) => f.$1).toSet(), {AgentRunFrame.data});
    expect(keys.map((f) => f.$2.length), [65536, 65536, 150 * 1024 - 2 * 65536]);
    expect([for (final f in keys) ...f.$2], paste);
  });
}
