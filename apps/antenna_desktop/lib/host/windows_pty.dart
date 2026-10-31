// SPDX-License-Identifier: AGPL-3.0-only
// Code mode on Windows (D-134): an agent's terminal is `antenna agent-run`, which hosts the
// agent CLI in a pseudoconsole and a kill-on-close job (crates/antenna-cli/src/agent_run.rs). The window speaks frames
// to it over the process's stdin and stdout, with the window bridge's header: a u32 LE id, always 0; a u8 type; a u32
// LE length; then that many bytes. There is no process group to signal and no wrapper to print an exit code: Stop is a
// frame, a kill ends the host and the job with it, and the host's EXIT frame is the only source of the agent's exit
// code. The process is started the way the window bridge is (detached with its stdio: no console window opens), and
// its stdin is the lifeline: when the window goes away, the run ends. Pure Dart (dart:io).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/x_control.dart' show BridgeChannel, ProcessBridgeChannel;
import '../state/agent_launch.dart';
import 'pty.dart';

/// Frame types of `antenna agent-run` (crates/antenna-cli/src/agent_run.rs).
abstract final class AgentRunFrame {
  /// Window → host, first and once: the run as JSON ([agentRunSpec]).
  static const spec = 1;

  /// Both ways: keys to the console, or its output.
  static const data = 2;

  /// Window → host: end the run and everything it started. Carries nothing.
  static const stop = 3;

  /// Host → window: why the run could not start (short UTF-8 text); the last frame.
  static const error = 4;

  /// Window → host: the console's new size, u16 LE rows and then u16 LE cols.
  static const resize = 5;

  /// Host → window: the agent's exit code, u32 LE; the last frame.
  static const exit = 6;
}

/// The longest frame either side sends (agent_run.rs `MAX_FRAME`).
const agentRunMaxFrame = 1 << 20;

const _header = 9;

/// The most keys in one frame: a long paste goes in several.
const _keysChunk = 64 * 1024;

/// Starts the host: `<executable> <arguments…>` with its stdin and stdout as pipes.
typedef AgentRunStarter = Future<BridgeChannel> Function(String executable, List<String> arguments);

/// The spec `antenna agent-run` takes first: the agent's argv as its program and arguments, its folder, its whole
/// environment (the token or its file is in it) and the console's size. It travels only through the host's stdin.
Map<String, Object?> agentRunSpec(AgentLaunch launch, {required int rows, required int columns}) => {
      'program': launch.command.first,
      'args': launch.command.skip(1).toList(),
      'folder': launch.workingDirectory,
      'env': launch.environment,
      'cols': columns.clamp(1, 0xffff),
      'rows': rows.clamp(1, 0xffff),
    };

/// One frame: the header (id 0) and [payload].
Uint8List agentRunFrame(int kind, List<int> payload) {
  final b = Uint8List(_header + payload.length);
  ByteData.sublistView(b)
    ..setUint32(0, 0, Endian.little)
    ..setUint8(4, kind)
    ..setUint32(5, payload.length, Endian.little);
  b.setRange(_header, b.length, payload);
  return b;
}

/// An agent's terminal on Windows: `antenna agent-run` ([AgentLaunch.executable], [AgentLaunch.arguments]) with the
/// launch as its spec. What the window writes before the process has started waits for it, after the spec.
///
/// The end: EXIT gives the agent's exit code; ERROR (the run could not start) is said in the terminal and ends it with
/// no code; so does a host that could not be started. A host whose output ends without either was killed (by Stop's
/// second step, or by anything else): -9, never 0. A frame outside the format ends the host the same way.
final class WindowsAgentPty implements PtyProcess {
  WindowsAgentPty(AgentLaunch launch, {required int rows, required int columns, AgentRunStarter? start}) {
    final spec = agentRunFrame(
        AgentRunFrame.spec, utf8.encode(jsonEncode(agentRunSpec(launch, rows: rows, columns: columns))));
    if (spec.length - _header > agentRunMaxFrame) {
      _say('the agent\'s environment is too large to start it');
      _finish(null);
      return;
    }
    _queue.add(spec);
    (start ?? ProcessBridgeChannel.start)(launch.executable, launch.arguments).then(_started, onError: (Object e) {
      _say('cannot start ${launch.executable}: ${e is ProcessException ? e.message : e}');
      _finish(null);
    });
  }

  /// The real one, for [AgentHost.system].
  static PtyProcess start(AgentLaunch launch, {required int rows, required int columns}) =>
      WindowsAgentPty(launch, rows: rows, columns: columns);

  final _output = StreamController<Uint8List>();
  final _exit = Completer<int?>();

  /// Frames written before the host started, the spec first.
  final List<Uint8List> _queue = [];
  BridgeChannel? _channel;
  StreamSubscription<List<int>>? _sub;
  Uint8List _rest = Uint8List(0);
  bool _killed = false;

  bool get _done => _exit.isCompleted;

  void _started(BridgeChannel channel) {
    if (_killed || _done) {
      channel.kill();
      return;
    }
    _channel = channel;
    for (final f in _queue) {
      channel.add(f);
    }
    _queue.clear();
    _sub = channel.output.listen(_read, onDone: _outputEnded, onError: (Object _) => _outputEnded());
  }

  void _read(List<int> chunk) {
    if (_done) return;
    final buf =
        _rest.isEmpty ? Uint8List.fromList(chunk) : (BytesBuilder(copy: false)..add(_rest)..add(chunk)).takeBytes();
    var at = 0;
    while (buf.length - at >= _header) {
      final h = ByteData.sublistView(buf, at, at + _header);
      final id = h.getUint32(0, Endian.little);
      final kind = h.getUint8(4);
      final len = h.getUint32(5, Endian.little);
      final fits = switch (kind) {
        AgentRunFrame.data || AgentRunFrame.error => len <= agentRunMaxFrame,
        AgentRunFrame.exit => len == 4,
        _ => false,
      };
      if (id != 0 || !fits) {
        _violation('a frame of type $kind, id $id and $len bytes');
        return;
      }
      if (buf.length - at - _header < len) break;
      final body = Uint8List.sublistView(buf, at + _header, at + _header + len);
      at += _header + len;
      switch (kind) {
        case AgentRunFrame.data:
          _output.add(Uint8List.fromList(body));
        case AgentRunFrame.exit:
          _finish(ByteData.sublistView(body).getUint32(0, Endian.little));
          return;
        case AgentRunFrame.error:
          _say(utf8.decode(body, allowMalformed: true));
          _finish(null);
          return;
      }
    }
    _rest = at == buf.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(buf, at));
  }

  void _violation(String what) {
    _say('the terminal host sent $what, outside its format');
    _kill();
    _finish(-9);
  }

  void _outputEnded() {
    if (_done) return;
    final why = _channel?.lastError ?? '';
    if (!_killed && why.isNotEmpty) _say(why);
    _finish(-9);
  }

  /// A line in the terminal from the window itself (the agent never ran, or its host went wrong).
  void _say(String text) {
    if (!_done) _output.add(Uint8List.fromList(utf8.encode('\r\nantenna: $text\r\n')));
  }

  void _finish(int? code) {
    if (_done) return;
    _exit.complete(code);
    _queue.clear();
    unawaited(_sub?.cancel());
    unawaited(_output.close());
  }

  void _send(int kind, List<int> payload) {
    if (_done) return;
    final f = agentRunFrame(kind, payload);
    final c = _channel;
    if (c == null) {
      _queue.add(f);
    } else {
      c.add(f);
    }
  }

  void _kill() {
    _killed = true;
    _channel?.kill();
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  /// There is no process group on Windows: the run is addressed by its frames, never by a PID (0).
  @override
  int get pid => 0;

  @override
  void write(Uint8List data) {
    for (var i = 0; i < data.length; i += _keysChunk) {
      _send(AgentRunFrame.data, Uint8List.sublistView(data, i, (i + _keysChunk).clamp(0, data.length)));
    }
  }

  @override
  void resize(int rows, int columns) {
    if (rows <= 0 || columns <= 0) return;
    final size = ByteData(4)
      ..setUint16(0, rows.clamp(1, 0xffff), Endian.little)
      ..setUint16(2, columns.clamp(1, 0xffff), Endian.little);
    _send(AgentRunFrame.resize, size.buffer.asUint8List());
  }

  /// SIGHUP is Stop (the host ends the job: the agent and everything it started); SIGKILL ends the host itself, and the
  /// job with it. Nothing else is sent.
  @override
  bool signalGroup(ProcessSignal signal) {
    if (_done) return false;
    if (signal == ProcessSignal.sighup) {
      _send(AgentRunFrame.stop, const []);
      return true;
    }
    if (signal == ProcessSignal.sigkill) {
      _kill();
      if (_channel == null) _finish(-9);
      return true;
    }
    return false;
  }
}
