// SPDX-License-Identifier: AGPL-3.0-only
// The window starts the daemon itself: the child process is tested against a REAL antennad; the LaunchAgent (macOS)
// plist and launchctl commands run on a stand-in executor (there is no macOS here); finding binaries in the app.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

void main() {
  final antennad = findXd();

  test('locateCore: bundled Helpers on macOS, bin/ on Linux, the window binary `Antenna` is not the CLI', () {
    final files = {
      '/Applications/Antenna.app/Contents/Helpers/antennad',
      '/Applications/Antenna.app/Contents/Helpers/antenna',
      '/Applications/Antenna.app/Contents/MacOS/Antenna',
    };
    final mac = locateCore(
      env: {'HOME': '/Users/o', 'PATH': '/usr/bin'},
      executable: '/Applications/Antenna.app/Contents/MacOS/Antenna',
      exists: files.contains,
      os: 'macos',
    );
    expect(mac.daemon, '/Applications/Antenna.app/Contents/Helpers/antennad');
    expect(mac.cli, '/Applications/Antenna.app/Contents/Helpers/antenna');
    expect(mac.bundled, isTrue);

    // APFS is case-insensitive: without Helpers, the window binary `MacOS/Antenna` would be "found" as `MacOS/antenna`, so
    // the CLI is not taken from there.
    bool caseInsensitive(String p) => {
          '/Applications/Antenna.app/Contents/MacOS/antenna',
          '/Applications/Antenna.app/Contents/MacOS/Antenna',
        }.contains(p);
    final dev = locateCore(
      env: {'HOME': '/Users/o', 'PATH': '/usr/bin'},
      executable: '/Applications/Antenna.app/Contents/MacOS/Antenna',
      exists: caseInsensitive,
      os: 'macos',
    );
    expect(dev.cli, isNull);
    expect(dev.daemon, isNull);

    final linux = locateCore(
      env: {'HOME': '/home/o', 'PATH': '/usr/bin:/home/o/.cargo/bin'},
      executable: '/opt/antenna/antenna-desktop',
      exists: {'/opt/antenna/bin/antennad', '/opt/antenna/bin/antenna'}.contains,
      os: 'linux',
    );
    expect(linux.daemon, '/opt/antenna/bin/antennad');
    expect(linux.cli, '/opt/antenna/bin/antenna');

    final system = locateCore(
      env: {'HOME': '/home/o', 'PATH': '/usr/bin'},
      executable: '/opt/antenna/antenna-desktop',
      exists: {'/home/o/.local/bin/antennad', '/home/o/.local/bin/antenna'}.contains,
      os: 'linux',
    );
    expect(system.daemon, '/home/o/.local/bin/antennad');
    expect(system.bundled, isFalse);

    // Custom paths (development): the new variable name, with the old one as a fallback.
    final own = locateCore(
      env: {'HOME': '/home/o', 'X_XD_BIN': '/dev/antennad', 'ANTENNA_CLI_BIN': '/dev/antenna'},
      executable: '/opt/antenna/antenna-desktop',
      exists: {'/dev/antennad', '/dev/antenna'}.contains,
      os: 'linux',
    );
    expect(own.daemon, '/dev/antennad');
    expect(own.cli, '/dev/antenna');

    expect(defaultDaemonLog({'HOME': '/Users/o'}, os: 'macos'), '/Users/o/Library/Logs/Antenna/antennad.log');
    expect(defaultDaemonLog({'HOME': '/home/o'}, os: 'linux'), '/home/o/.local/state/antenna/antennad.log');
  });

  test('socket path: ANTENNA_* first, the preview X_* variables as a fallback', () {
    expect(defaultSocketPath({'HOME': '/h'}, os: 'linux'), '/h/.local/share/antenna/antennad.sock');
    expect(defaultSocketPath({'HOME': '/h', 'XDG_DATA_HOME': '/d'}, os: 'linux'), '/d/antenna/antennad.sock');
    expect(defaultSocketPath({'HOME': '/h', 'X_DATA_DIR': '/old'}, os: 'linux'), '/old/antennad.sock');
    expect(defaultSocketPath({'HOME': '/h', 'X_SOCKET': '/old.sock'}, os: 'linux'), '/old.sock');
    expect(
      defaultSocketPath({'HOME': '/h', 'X_SOCKET': '/old.sock', 'ANTENNA_SOCKET': '/new.sock'}, os: 'linux'),
      '/new.sock',
    );
    expect(
      defaultSocketPath({'HOME': '/h', 'ANTENNA_SOCKET': '', 'ANTENNA_DATA_DIR': '/new'}, os: 'linux'),
      '/new/antennad.sock',
    );
  });

  test('socket path on Windows: %LOCALAPPDATA%\\Antenna, never the roaming folder or XDG (WP-3)', () {
    final env = {
      'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
      'APPDATA': r'C:\Users\u\AppData\Roaming',
      'XDG_DATA_HOME': '/d',
      'HOME': '/h',
    };
    expect(defaultSocketPath(env, os: 'windows'), r'C:\Users\u\AppData\Local\Antenna\antennad.sock');
    expect(defaultSocketPath({...env, 'ANTENNA_DATA_DIR': r'D:\a'}, os: 'windows'), r'D:\a\antennad.sock');
    expect(defaultSocketPath({...env, 'ANTENNA_SOCKET': r'D:\s.sock'}, os: 'windows'), r'D:\s.sock');
    expect(defaultSocketPath({'APPDATA': r'C:\Users\u\AppData\Roaming'}, os: 'windows'), r'.\Antenna\antennad.sock');
    // The same lookup on Linux and macOS ignores LOCALAPPDATA.
    expect(defaultSocketPath(env, os: 'macos'), '/d/antenna/antennad.sock');
  });

  test('defaultHost: LaunchAgent on macOS, child on Linux, none for a foreign (forwarded) socket', () {
    DaemonHost? h(String os, String socket) => defaultHost(
          xdPath: '/a/antennad',
          socketPath: socket,
          defaultSocket: '/h/.local/share/antenna/antennad.sock',
          env: {'HOME': '/h'},
          logPath: '/h/log',
          os: os,
        );
    expect(h('macos', '/h/.local/share/antenna/antennad.sock'), isA<LaunchAgentHost>());
    expect(h('linux', '/h/.local/share/antenna/antennad.sock'), isA<ChildProcessHost>());
    expect(h('macos', '/tmp/antenna-server.sock'), isNull);
  });

  test('LaunchAgent: plist and launchctl bootstrap → kickstart fallback, bootout on stop', () async {
    final dir = await Directory('/tmp').createTemp('xla-');
    final sock = '${dir.path}/antennad.sock';
    final calls = <String>[];
    Future<ProcessResult> runner(String exe, List<String> args) async {
      calls.add('$exe ${args.join(' ')}');
      if (exe.endsWith('id')) return ProcessResult(0, 0, '501\n', '');
      if (args.first == 'bootstrap') return ProcessResult(0, 37, '', 'Bootstrap failed: 5: Input/output error');
      if (args.first == 'kickstart') File(sock).writeAsStringSync(''); // launchd started antennad: the socket appears
      return ProcessResult(0, 0, '', '');
    }

    final h = LaunchAgentHost(
      xdPath: '/Applications/Antenna.app/Contents/Helpers/antennad',
      socketPath: sock,
      logPath: '${dir.path}/logs/antennad.log',
      home: dir.path,
      runner: runner,
    );
    await h.start();
    final plist = File(h.plistPath).readAsStringSync();
    expect(h.plistPath, '${dir.path}/Library/LaunchAgents/io.github.danta-nort.antenna.daemon.plist');
    expect(plist, contains('<string>io.github.danta-nort.antenna.daemon</string>'));
    expect(plist, contains('<string>/Applications/Antenna.app/Contents/Helpers/antennad</string>'));
    expect(plist, contains('<key>SuccessfulExit</key>'));
    expect(plist, contains('<string>${dir.path}/logs/antennad.log</string>'));
    expect(calls, [
      '/usr/bin/id -u',
      '/bin/launchctl bootout gui/501/io.github.danta-nort.antenna.daemon',
      '/bin/launchctl bootstrap gui/501 ${h.plistPath}',
      '/bin/launchctl kickstart -k gui/501/io.github.danta-nort.antenna.daemon',
    ]);
    calls.clear();
    await h.onWindowExit();
    expect(calls, isEmpty, reason: 'LaunchAgent outlives the window');
    await h.stop();
    expect(calls.last, '/bin/launchctl bootout gui/501/io.github.danta-nort.antenna.daemon');
    await dir.delete(recursive: true);
  });

  test('LaunchAgent of the preview build (dev.x.xd) is removed once before the new one starts', () async {
    final dir = await Directory('/tmp').createTemp('xla-');
    final sock = '${dir.path}/antennad.sock';
    final legacy = File('${dir.path}/Library/LaunchAgents/dev.x.xd.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync('<plist>old x</plist>');
    final calls = <String>[];
    Future<ProcessResult> runner(String exe, List<String> args) async {
      calls.add('$exe ${args.join(' ')}');
      if (exe.endsWith('id')) return ProcessResult(0, 0, '501\n', '');
      if (args.first == 'bootstrap') File(sock).writeAsStringSync('');
      return ProcessResult(0, 0, '', '');
    }

    LaunchAgentHost host() => LaunchAgentHost(
          xdPath: '/Applications/Antenna.app/Contents/Helpers/antennad',
          socketPath: sock,
          logPath: '${dir.path}/logs/antennad.log',
          home: dir.path,
          runner: runner,
        );
    await host().start();
    expect(calls.take(3), [
      '/usr/bin/id -u',
      '/bin/launchctl bootout gui/501/dev.x.xd',
      '/bin/launchctl bootout gui/501/io.github.danta-nort.antenna.daemon',
    ]);
    expect(legacy.existsSync(), isFalse, reason: 'the old plist is deleted: it does not come back at login');
    expect(File('${dir.path}/logs/antennad.log').readAsStringSync(), contains('removed the LaunchAgent of the preview build'));
    // Second launch: no old agent, so no call for it.
    calls.clear();
    File(sock).deleteSync();
    await host().start();
    expect(calls.where((c) => c.contains('dev.x.xd')), isEmpty);
    await dir.delete(recursive: true);
  });

  test('child host: a daemon that exits at start gives a clear error with the log tail', () async {
    final dir = await Directory('/tmp').createTemp('xch-');
    final fake = File('${dir.path}/antennad')
      ..writeAsStringSync('#!/bin/sh\necho "antennad: data dir permissions: Permission denied (os error 13)" >&2\nexit 1\n');
    await Process.run('chmod', ['+x', fake.path]);
    final h = ChildProcessHost(xdPath: fake.path, socketPath: '${dir.path}/antennad.sock', logPath: '${dir.path}/antennad.log');
    final e = await h.start().then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<DaemonStartException>());
    final d = e! as DaemonStartException;
    print('START ERROR: $d, log: ${d.logTail}');
    expect(d.reason, DaemonStartFailure.exited);
    expect(d.exitCode, 1);
    expect(d.logTail, contains('Permission denied'));
    await dir.delete(recursive: true);
  });

  test('first run: the window starts the real antennad itself, then init → unlocked; child stops on exit', () async {
    final root = await tempRoot();
    final sock = '${root.path}/d/antennad.sock';
    final host = ChildProcessHost(
      xdPath: antennad!,
      socketPath: sock,
      logPath: '${root.path}/antennad.log',
      dataDir: '${root.path}/d',
      environment: {'ANTENNA_LINKS_DIR': '${root.path}/links'},
    );
    final m = AppModel(connector: XControlClient.new, socketPath: sock, host: host, live: false);
    try {
      final sw = Stopwatch()..start();
      await m.connect(); // the daemon does not answer → the window starts it
      print('FIRST RUN: daemon started by the window and answered in ${sw.elapsedMilliseconds} ms, '
          'phase ${m.phase.name}');
      expect(m.phase, Phase.uninitialized);
      expect(host.running, isTrue);
      expect(await m.init('first-run-password'), isNull);
      expect(m.phase, Phase.unlocked);
      // The window closes: the child daemon stops and removes its socket.
      await m.onWindowExit();
      expect(host.running, isFalse);
      expect(FileSystemEntity.typeSync(sock), FileSystemEntityType.notFound);
      // Second window launch: the daemon starts again with locked keys, so the password is needed.
      final m2 = AppModel(connector: XControlClient.new, socketPath: sock, host: host, live: false);
      await m2.connect();
      expect(m2.phase, Phase.locked);
      expect(await m2.unlock('first-run-password'), isNull);
      expect(m2.phase, Phase.unlocked);
      // Stopped from the window: autostart does not kick in on its own.
      await m2.stopDaemon();
      expect(m2.phase, Phase.unreachable);
      await m2.connect();
      expect(m2.phase, Phase.unreachable);
      m2.dispose();
    } finally {
      await host.stop();
      m.dispose();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false);
}
