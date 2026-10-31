// SPDX-License-Identifier: AGPL-3.0-only
// The Check panel's "Install `app`" (D-110, Q-LM2 of D-96): the vendor's own install command for an AI app's
// command-line program, shown to the owner first, run only after the owner presses Run, and run in a terminal in the
// window where the owner sees everything it prints. The window never runs an installer out of sight.
//
// - The command is a constant of the app's definition ([VendorInstall], copied from the vendor's page with the date it
//   was checked), never built from anything a contact, an agent or a file could influence.
// - It runs in the owner's login shell (`$SHELL -l -c <command>`, so the profile's PATH with Node or Homebrew is
//   there), under the same wrapper as Code mode's terminals (agent_launch.dart): descriptors above 2 closed, the
//   window's variables that are not the user's own context removed (no agent token, no socket, no other agent
//   session's markers), its exit code reported through the terminal. No Antenna variable is set for it.
// - Stop sends SIGHUP to the terminal's process group, then SIGKILL, like closing a terminal window.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../host/pty.dart';
import 'agent_launch.dart';
import 'terminal_sgr.dart';

/// A vendor's official install command for its command-line program on macOS and Linux.
@immutable
final class VendorInstall {
  const VendorInstall(this.command, {required this.source, required this.checked});

  /// The shell line, exactly as the vendor's page gives it.
  final String command;

  /// The page it is from.
  final String source;

  /// When it was last compared with that page (ISO date).
  final String checked;
}

/// The owner's login shell for the installer: `$SHELL` when it is an absolute path to a shell this computer has, else
/// the wrapper's shell.
String installShell(Map<String, String> env, String fallback, {bool Function(String path)? exists}) {
  final isFile = exists ?? (String p) => File(p).existsSync();
  final s = env['SHELL'] ?? '';
  const known = {'bash', 'zsh', 'sh', 'fish', 'dash', 'ksh'};
  return s.startsWith('/') && known.contains(s.split('/').last) && isFile(s) ? s : fallback;
}

/// What the window starts in the installer's terminal: the wrapper (in [home]) running `$SHELL -l -c command` (the
/// login shell), with the window's environment cleaned the way Code mode cleans it and nothing of Antenna's added.
AgentLaunch buildInstallLaunch({
  required VendorInstall install,
  required String shell,
  required String loginShell,
  required String home,
  required Map<String, String> env,
  required List<String> searchDirs,
}) {
  final command = [loginShell, '-l', '-c', install.command];
  final set = {
    'PATH': agentPath(searchDirs),
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
    'BASH_ENV': '',
    'ENV': '',
  };
  return AgentLaunch(
    executable: shell,
    arguments: ['-c', agentWrapperScript, agentWrapperName, home, ...command],
    environment: {
      ...set,
      agentEnvUnsetVar: [...agentEnvUnset(env, set), 'BASH_ENV', 'ENV'].join(' '),
    },
    workingDirectory: home,
    command: command,
  );
}

enum InstallState { running, finished, failed }

/// One installer run in its own terminal.
final class CliInstallRun extends ChangeNotifier {
  CliInstallRun(this.install);

  final VendorInstall install;
  final terminal = Terminal(maxLines: 5000);
  InstallState state = InstallState.running;

  /// The command's exit code ([agentExitOsc]), once it ended.
  int? exitCode;

  /// Why it did not start.
  Object? error;

  PtyProcess? _pty;
  StreamSubscription<String>? _out;
  int? _reported;
  bool _disposed = false;

  bool get running => state == InstallState.running && _pty != null;

  /// Start [launch] through [startPty]. Errors become [InstallState.failed].
  void start(PtyStarter startPty, AgentLaunch launch) {
    try {
      final pty = _pty = startPty(launch, rows: terminal.viewHeight, columns: terminal.viewWidth);
      final sgr = SgrFilter();
      _out = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .map(sgr.add)
          .where((s) => s.isNotEmpty)
          .listen(terminal.write);
      // The owner may answer the installer's own questions (a password prompt of sudo, a "y/N").
      terminal.onOutput = (s) => _pty?.write(Uint8List.fromList(utf8.encode(s)));
      terminal.onResize = (w, h, _, _) => _pty?.resize(h, w);
      terminal.onPrivateOSC = (code, args) {
        if (code == agentExitOsc && args.isNotEmpty) _reported = int.tryParse(args.first);
      };
      unawaited(pty.exitCode.then((c) {
        if (!identical(_pty, pty)) return;
        _pty = null;
        exitCode = _reported ?? c;
        state = InstallState.finished;
        _notify();
      }));
    } on Object catch (e) {
      error = e;
      state = InstallState.failed;
    }
    _notify();
  }

  /// Stop it like closing a terminal window: SIGHUP to its process group, SIGKILL after 3 s.
  Future<void> stop() async {
    final p = _pty;
    if (p == null) return;
    p.signalGroup(ProcessSignal.sighup);
    await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      p.signalGroup(ProcessSignal.sigkill);
      return null;
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_out?.cancel());
    final p = _pty;
    if (p != null) p.signalGroup(ProcessSignal.sighup);
    super.dispose();
  }
}
