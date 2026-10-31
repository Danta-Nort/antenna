// SPDX-License-Identifier: AGPL-3.0-only
// Code mode: the pseudo-terminal an agent's CLI runs in. The window state talks to [PtyProcess]; the real one is
// flutter_pty (forkpty through FFI, MIT, docs/STACK.md), tests use a fake.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import '../state/agent_launch.dart';

/// A process in a pseudo-terminal.
abstract interface class PtyProcess {
  /// What the process writes (stdout and stderr are one stream in a terminal).
  Stream<Uint8List> get output;

  /// The exit code: 0…255, or a negative signal number if it was killed; `null` when the process has ended but its
  /// status was taken by someone else (see [SystemPty]).
  Future<int?> get exitCode;

  /// The terminal's session leader (the wrapper shell); its process group holds the agent.
  int get pid;

  /// Keystrokes and pasted text.
  void write(Uint8List data);

  void resize(int rows, int columns);

  /// Send [signal] to the terminal's process group (the wrapper and the agent it runs), like closing a terminal
  /// window does with SIGHUP.
  bool signalGroup(ProcessSignal signal);
}

/// Starts [launch] in a new pseudo-terminal of the given size.
typedef PtyStarter = PtyProcess Function(AgentLaunch launch, {required int rows, required int columns});

/// The variables flutter_pty adds for an agent launch. Its child inherits [processEnv], this process's real
/// environment (flutter_pty only adds to it), which can hold more than the environment the launch was built from: the
/// wrapper removes those variables too, by the same allowlist ([agentEnvKeep]).
Map<String, String> agentPtyEnvironment(Map<String, String> launchEnv, Map<String, String> processEnv) {
  final names = launchEnv[agentEnvUnsetVar];
  if (names == null) return launchEnv;
  final all = {...names.split(' ').where((n) => n.isNotEmpty), ...agentEnvUnset(processEnv, launchEnv)}
    ..remove(agentEnvUnsetVar);
  return {...launchEnv, agentEnvUnsetVar: (all.toList()..sort()).join(' ')};
}

/// The real pseudo-terminal (flutter_pty). The plugin's child sets the environment and execs [AgentLaunch.executable];
/// the wrapper does the rest (agent_launch.dart).
///
/// The end of the process is watched twice. flutter_pty waits for the child with `waitpid`, but the Dart VM reaps
/// every child with `wait()` while the window has child processes of its own (the daemon on Linux, a running CLI), and
/// whoever reaps first gets the status: flutter_pty may then never report, or report garbage. So the session leader is
/// also probed every 250 ms (a signal it ignores while it lives; ESRCH once it is gone), and the exit code itself comes
/// from the wrapper's OSC in the terminal output.
final class SystemPty implements PtyProcess {
  SystemPty._(this._pty) {
    unawaited(_pty.exitCode.then(_finish));
    _probe = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_alive()) return;
      _probe?.cancel();
      // Gone: give flutter_pty a moment to report the status it may still have.
      Timer(const Duration(milliseconds: 300), () => _finish(null));
    });
  }

  static PtyProcess start(AgentLaunch launch, {required int rows, required int columns}) => SystemPty._(Pty.start(
        launch.executable,
        arguments: launch.arguments,
        workingDirectory: launch.workingDirectory,
        environment: agentPtyEnvironment(launch.environment, Platform.environment),
        rows: rows,
        columns: columns,
      ));

  final Pty _pty;
  final _exit = Completer<int?>();
  Timer? _probe;

  void _finish(int? code) {
    _probe?.cancel();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// SIGCONT: harmless to a running process; `kill` fails with ESRCH once the process has been reaped.
  bool _alive() {
    try {
      return Process.killPid(_pty.pid, ProcessSignal.sigcont);
    } on Object {
      return false;
    }
  }

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  int get pid => _pty.pid;

  @override
  void write(Uint8List data) => _pty.write(data);

  @override
  void resize(int rows, int columns) {
    if (rows > 0 && columns > 0) _pty.resize(rows, columns);
  }

  @override
  bool signalGroup(ProcessSignal signal) {
    // A negative PID addresses the process group (kill(2)); the wrapper is the session leader and, without job
    // control, the group leader of the agent too. If the group is gone, signal the leader itself.
    try {
      if (Process.killPid(-_pty.pid, signal)) return true;
    } on Object {
      // fall through
    }
    return Process.killPid(_pty.pid, signal);
  }
}
