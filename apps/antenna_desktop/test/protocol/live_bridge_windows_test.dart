// SPDX-License-Identifier: AGPL-3.0-only
// The window's flow on Windows (D-135, CONTROL §34), wired as main.dart wires it: the REAL `antennad.exe` started by the
// window's ChildProcessHost, and the REAL `antenna.exe window-bridge` between the window's control client and the
// daemon's named pipe. No unix socket anywhere. The checks only Windows can run: connect → daemon_unavailable → start →
// connect, init to unlocked; the held owner session through the bridge (an owner command needs no second password, and
// the same token from another process is refused); the bridge opens no console; and closing the window leaves no
// `antenna.exe` or `antennad.exe` running.
//
// Run: flutter test test/protocol/live_bridge_windows_test.dart (ANTENNAD_BIN=<antennad.exe, with antenna.exe beside
// it>, otherwise the repository's release build, then its debug build).
@Tags(['live'])
@TestOn('windows')
library;

import 'dart:io';

import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:antenna_desktop/host/window_bridge.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore_for_file: avoid_print

/// `antennad.exe` with `antenna.exe` beside it: `ANTENNAD_BIN`, else the release build, else the debug build.
String? _antennad() {
  final env = Platform.environment['ANTENNAD_BIN'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  final repo = Directory.current.parent.parent.path;
  for (final p in ['$repo\\target\\release\\antennad.exe', '$repo\\target\\debug\\antennad.exe']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// PIDs of the processes named [name] that run from [dir], and, with [parent], only its children.
Future<List<int>> _pids(String name, {String? dir, int? parent}) async {
  final filter = [
    "\$_.Name -eq '$name'",
    if (dir != null) "\$_.ExecutablePath -like '${dir.replaceAll("'", "''")}*'",
    if (parent != null) '\$_.ParentProcessId -eq $parent',
  ].join(' -and ');
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    'Get-CimInstance Win32_Process | Where-Object { $filter } | ForEach-Object { \$_.ProcessId }',
  ]);
  return '${r.stdout}'.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).map(int.parse).toList();
}

void main() {
  final antennad = _antennad();
  final dir = antennad == null ? null : File(antennad).parent.path;
  final cli = dir == null ? null : '$dir\\antenna.exe';
  final missing = antennad == null
      ? 'antennad.exe not found: set ANTENNAD_BIN or build it'
      : !File(cli!).existsSync()
          ? 'antenna.exe not found beside antennad.exe'
          : null;

  test('the window on Windows: the bridge, the daemon it starts, init, the held session, and nothing left behind',
      () async {
    final root = await Directory.systemTemp.createTemp('antenna-bridge-');
    final data = '${root.path}\\Antenna';
    final env = {...Platform.environment, 'ANTENNA_DATA_DIR': data}..remove('ANTENNA_SOCKET');
    final sock = defaultSocketPath(env, os: 'windows');
    final host = ChildProcessHost(
      xdPath: antennad!,
      socketPath: sock,
      logPath: '${root.path}\\AntennaLogs\\antennad.log',
      dataDir: data,
      environment: {'ANTENNA_LINKS_DIR': '${root.path}\\links'},
      os: 'windows',
    );
    final bridges = WindowBridges(cli: cli!, env: env, defaultSocket: sock);
    final m = AppModel(
      connector: (p) => XControlClient(p, bridge: bridges.forSocket(p)),
      socketPath: sock,
      host: host,
      live: false,
    );
    final password = 'test-${DateTime.now().microsecondsSinceEpoch}';
    BridgeMux? other;
    try {
      // 1. Nothing runs yet: the bridge says the daemon is unavailable, the window starts it, and connects.
      final sw = Stopwatch()..start();
      await m.connect();
      print('WINDOWS FLOW: connect → start → connected in ${sw.elapsedMilliseconds} ms, phase ${m.phase.name}');
      expect(m.phase, Phase.uninitialized, reason: '${m.lastError} ${m.hostError}');
      expect(host.running, isTrue);

      // 2. One bridge process, and no console for it.
      final bridgePids = await _pids('antenna.exe', dir: dir);
      expect(bridgePids, hasLength(1), reason: 'one bridge for the window');
      final consoles = await _pids('conhost.exe', parent: bridgePids.single);
      print('WINDOWS FLOW: bridge pid ${bridgePids.single}, its console hosts: $consoles');
      expect(consoles, isEmpty, reason: 'the bridge is started detached, with no console');
      final daemonPids = await _pids('antennad.exe', dir: dir);
      expect(daemonPids, hasLength(1));
      expect(await _pids('conhost.exe', parent: daemonPids.single), isEmpty, reason: 'antennad has no console');

      // Init, then the window holds its owner session through the bridge.
      expect(await m.init(password), isNull);
      expect(m.phase, Phase.unlocked);
      expect(m.daemon.sessionToken, isNotNull);

      // 4. An owner command needs no second password: the held session covers it.
      expect(await m.daemon.contacts(), isEmpty);
      // The control: the same token from another process (a second bridge) is not that session.
      other = BridgeMux.process(cli, arguments: windowBridgeArgs(env));
      final stranger = XControlClient(sock, bridge: other)..sessionToken = m.daemon.sessionToken;
      final refused = await stranger.contacts().then<Object?>((_) => null, onError: (Object e) => e);
      print('WINDOWS FLOW: the held token from another process: $refused');
      expect(refused, isA<XClientException>());
    } finally {
      // 3. The window closes: its daemon is stopped, and its bridges end with their standard input.
      await other?.dispose();
      await m.onWindowExit();
      await bridges.forSocket(sock).dispose();
      m.dispose();
      var left = <int>[];
      for (var i = 0; i < 50; i++) {
        left = [...await _pids('antenna.exe', dir: dir), ...await _pids('antennad.exe', dir: dir)];
        if (left.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      print('WINDOWS FLOW: left running after the window closed: $left');
      for (var i = 0; i < 20; i++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(left, isEmpty);
    }
  }, skip: missing ?? false, timeout: const Timeout(Duration(minutes: 2)));
}
