// SPDX-License-Identifier: AGPL-3.0-only
// Windows (D-135): the window finds `antennad.exe` and `antenna.exe` next to its own executable and nowhere else, keeps
// the daemon's log beside the data folder (never inside it), and starts the daemon as its child: ready when the daemon
// says it listens on its pipe. The lookups run on every system; the live test runs the real `antennad.exe` on Windows
// only, and touches no unix socket.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore_for_file: avoid_print

/// `antennad.exe` for the live test: `ANTENNAD_BIN`, otherwise the repository's debug build.
String? _antennadExe() {
  final env = Platform.environment['ANTENNAD_BIN'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  final repo = Directory.current.parent.parent.path;
  final p = '$repo\\target\\debug\\antennad.exe';
  return File(p).existsSync() ? p : null;
}

void main() {
  test('locateCore on Windows: next to the window only, never PATH; the development variables still win', () {
    const exe = r'C:\Program Files\Antenna\antenna_desktop.exe';
    final files = {
      r'C:\Program Files\Antenna\antennad.exe',
      r'C:\Program Files\Antenna\antenna.exe',
      r'C:\Users\o\.cargo\bin\antennad.exe',
      r'C:\Users\o\.cargo\bin\antenna.exe',
    };
    final env = {'PATH': r'C:\Users\o\.cargo\bin;C:\Windows', 'USERPROFILE': r'C:\Users\o'};
    final bundled = locateCore(env: env, executable: exe, exists: files.contains, os: 'windows');
    expect(bundled.daemon, r'C:\Program Files\Antenna\antennad.exe');
    expect(bundled.cli, r'C:\Program Files\Antenna\antenna.exe');
    expect(bundled.bundled, isTrue);

    // The control: the same PATH holds both, but the window does not take them from there.
    final alone = locateCore(
      env: env,
      executable: exe,
      exists: {r'C:\Users\o\.cargo\bin\antennad.exe', r'C:\Users\o\.cargo\bin\antenna.exe'}.contains,
      os: 'windows',
    );
    expect(alone.daemon, isNull);
    expect(alone.cli, isNull);

    final dev = locateCore(
      env: {
        ...env,
        'ANTENNAD_BIN': r'D:\src\target\debug\antennad.exe',
        'ANTENNA_CLI_BIN': r'D:\src\target\debug\antenna.exe',
      },
      executable: exe,
      exists: {r'D:\src\target\debug\antennad.exe', r'D:\src\target\debug\antenna.exe'}.contains,
      os: 'windows',
    );
    expect(dev.daemon, r'D:\src\target\debug\antennad.exe');
    expect(dev.cli, r'D:\src\target\debug\antenna.exe');
  });

  test('the daemon log on Windows is beside the data folder, never inside it (the window must not make it)', () {
    final log = defaultDaemonLog({'LOCALAPPDATA': r'C:\Users\o\AppData\Local'}, os: 'windows');
    expect(log, r'C:\Users\o\AppData\Local\AntennaLogs\antennad.log');
    expect(log.toLowerCase(), isNot(startsWith(r'c:\users\o\appdata\local\antenna\')));
  });

  test('defaultHost on Windows: a child of the window, none for another daemon', () {
    const sock = r'C:\Users\o\AppData\Local\Antenna\antennad.sock';
    DaemonHost? h(String socket) => defaultHost(
      xdPath: r'C:\Program Files\Antenna\antennad.exe',
      socketPath: socket,
      defaultSocket: sock,
      env: {'LOCALAPPDATA': r'C:\Users\o\AppData\Local'},
      logPath: r'C:\Users\o\AppData\Local\AntennaLogs\antennad.log',
      os: 'windows',
    );
    expect(h(sock), isA<ChildProcessHost>());
    expect(h(r'\\.\pipe\someone-else'), isNull);
  });

  final antennad = _antennadExe();

  test(
    'live: the window starts antennad.exe, which makes its own data folder, says it listens, and stops with the window',
    () async {
      final root = await Directory.systemTemp.createTemp('antenna-host-');
      final data = '${root.path}\\Antenna';
      final log = '${root.path}\\AntennaLogs\\antennad.log';
      final host = ChildProcessHost(
        xdPath: antennad!,
        socketPath: '$data\\antennad.sock',
        logPath: log,
        dataDir: data,
        environment: {'ANTENNA_LINKS_DIR': '${root.path}\\links'},
        os: 'windows',
      );
      try {
        final sw = Stopwatch()..start();
        await host.start();
        print('LIVE: antennad.exe listening after ${sw.elapsedMilliseconds} ms');
        expect(host.running, isTrue);
        expect(Directory(data).existsSync(), isTrue, reason: 'the daemon made its data folder');
        expect(File(log).readAsStringSync(), contains(r'listening on \\.\pipe\antenna-'));
        // The control: a second daemon on the same folder refuses, and the window says why with the log tail.
        final second = ChildProcessHost(
          xdPath: antennad,
          socketPath: '$data\\antennad.sock',
          logPath: '${root.path}\\AntennaLogs\\second.log',
          dataDir: data,
          environment: {'ANTENNA_LINKS_DIR': '${root.path}\\links'},
          os: 'windows',
        );
        final e = await second.start().then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<DaemonStartException>());
        final d = e! as DaemonStartException;
        print('LIVE second daemon: ${d.reason.name}, exit ${d.exitCode}: ${d.logTail}');
        expect(d.reason, DaemonStartFailure.exited);
        expect(d.logTail, contains('another antennad is using the data folder'));
        await host.onWindowExit();
        expect(host.running, isFalse);
      } finally {
        await host.stop();
        // The killed daemon's lock and files go once the process is gone.
        for (var i = 0; i < 20; i++) {
          try {
            await root.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    },
    skip: !Platform.isWindows
        ? 'Windows only'
        : (antennad == null ? 'antennad.exe not found: set ANTENNAD_BIN' : false),
  );
}
