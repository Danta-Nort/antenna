// SPDX-License-Identifier: AGPL-3.0-only
// Code mode's terminal on Windows with the REAL `antenna.exe agent-run` (D-134): the window's WindowsAgentPty
// starts it as the window does (detached with its stdio), sends the launch Code mode builds, and reads the agent's
// output and exit code from its frames. A program that ends reports its own code; Stop ends a program that waits, with
// everything it started (agent-run's STOPPED); a kill of the host ends them too (the job), and the run says -9. A hook
// written as Code mode writes it, `antenna hook-signal <word>`, runs from cmd.exe through the agent's Path; an
// `antenna.cmd` in the agent's folder is not run in its place. No daemon and no socket: nothing here needs one.
//
// Run: flutter test test/protocol/live_agent_run_windows_test.dart (ANTENNA_BIN=<antenna.exe>, otherwise the
// repository's release build, then its debug build).
@Tags(['live'])
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/windows_pty.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:flutter_test/flutter_test.dart';

/// `antenna.exe`: `ANTENNA_BIN`, else the release build, else the debug build.
String? _antenna() {
  final env = Platform.environment['ANTENNA_BIN'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  final repo = Directory.current.parent.parent.path;
  for (final p in ['$repo\\target\\release\\antenna.exe', '$repo\\target\\debug\\antenna.exe']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Processes whose command line holds [marker].
Future<int> _running(String marker) async {
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "@(Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$marker*' -and "
        "\$_.Name -ne 'powershell.exe' }).Count",
  ]);
  return int.parse('${r.stdout}'.trim());
}

void main() {
  final cli = _antenna();
  final cmd = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\cmd.exe';
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('artest-agent-run-'));
  tearDown(() async {
    for (var i = 0; i < 20; i++) {
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  });

  /// The launch Code mode builds for an own command, with [extra] variables on top.
  AgentLaunch launch(List<String> program, {Map<String, String> extra = const {}}) {
    final l = buildWindowsAgentLaunch(
      cli: AgentCli.custom,
      program: program,
      token: 'xat_live_agent_run_test',
      antennaPath: cli!,
      socket: r'\\.\pipe\artest-no-daemon',
      workDir: root.path,
      env: Platform.environment,
      searchDirs: ProgramLocator(env: Platform.environment, windows: true).searchDirs,
    );
    return AgentLaunch(
      executable: l.executable,
      arguments: l.arguments,
      environment: {...l.environment, ...extra},
      workingDirectory: l.workingDirectory,
      command: l.command,
    );
  }

  /// Starts [l]; returns the run and its output so far (decoded as it comes).
  (WindowsAgentPty, StringBuffer) start(AgentLaunch l) {
    final pty = WindowsAgentPty(l, rows: 24, columns: 80);
    final out = StringBuffer();
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(out.write);
    return (pty, out);
  }

  Future<void> until(bool Function() ok, String what) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ok(), isTrue, reason: what);
  }

  test('a program that ends: its output and its own exit code, through the frames', () async {
    final (pty, out) = start(launch([cmd, '/d', '/c', 'echo hello from agent-run& exit /b 7']));
    expect(await pty.exitCode.timeout(const Duration(seconds: 20)), 7);
    expect(out.toString(), contains('hello from agent-run'));
  }, skip: cli == null ? 'antenna.exe not found: set ANTENNA_BIN or build it' : false);

  test('Stop ends a program that waits, and what it started; a kill of the host does too', () async {
    for (final kill in [false, true]) {
      final marker = 'artest-wait-${DateTime.now().microsecondsSinceEpoch}';
      final (pty, out) = start(launch([cmd, '/d', '/c', 'echo ready& ping -n 120 127.0.0.1 > nul& rem $marker']));
      await until(() => out.toString().contains('ready'), 'the program started');
      expect(await _running(marker), 1, reason: 'cmd.exe with the marker runs');
      pty.signalGroup(kill ? ProcessSignal.sigkill : ProcessSignal.sighup);
      expect(await pty.exitCode.timeout(const Duration(seconds: 10)), kill ? -9 : 1,
          reason: kill ? 'no EXIT from a killed host' : 'agent-run reports STOPPED');
      var left = 1;
      for (var i = 0; i < 25 && left > 0; i++) {
        left = await _running(marker);
        if (left > 0) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(left, 0, reason: 'the job took the program with it (${kill ? 'kill' : 'Stop'})');
    }
  }, skip: cli == null ? 'antenna.exe not found: set ANTENNA_BIN or build it' : false);

  test('a hook as Code mode writes it runs antenna from the Path, never an antenna.cmd in the folder', () async {
    final hooks = Directory('${root.path}\\hooks')..createSync();
    File('${hooks.path}\\events').writeAsStringSync('');
    // The planted script would record its own word if cmd.exe ran it from the agent's folder.
    File('${root.path}\\antenna.cmd').writeAsStringSync('@echo planted>> "${hooks.path}\\events"\r\n');
    final (pty, _) = start(launch(
      [cmd, '/d', '/c', '$hookSignalCommand start < nul'],
      extra: {codeHooksVar: hooks.path},
    ));
    expect(await pty.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(File('${hooks.path}\\events').readAsStringSync(), 'start\n');
  }, skip: cli == null ? 'antenna.exe not found: set ANTENNA_BIN or build it' : false);
}
