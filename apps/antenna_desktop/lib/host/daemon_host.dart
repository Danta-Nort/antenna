// SPDX-License-Identifier: AGPL-3.0-only
// The window starts `antennad` itself if the daemon does not respond (first launch, after a reboot). Pure Dart
// (dart:io).
//
// Two ways (D-UI-10):
// - macOS: a per-user LaunchAgent (`~/Library/LaunchAgents/io.github.danta-nort.antenna.daemon.plist`,
//   `launchctl bootstrap gui/<uid>`):
//   the daemon keeps running after the window closes, so agents on this Mac and message delivery do not depend on the
//   window; launchd restarts it after a crash and starts it at login (keys stay locked until the password, Q-4);
// - Linux desktop and the fallback: a child process of the window that lives while the window is open and is stopped
//   with SIGTERM.
// - Windows (D-135): the same child process, `antennad.exe` from next to the window, started directly (no bash); it is
//   ready when it says it listens, since its named pipe is no file to wait for. A daemon started elevated refuses to
//   run, and its reason reaches the window through the log tail.
// On a server the daemon is installed by packaging/linux/install.sh (a systemd user unit); no window is needed there.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/src/socket_path.dart' show envWithFallback;

/// Runs an external command (replaced in tests).
typedef CommandRunner = Future<ProcessResult> Function(String exe, List<String> args);

Future<ProcessResult> _run(String exe, List<String> args) => Process.run(exe, args);

/// Why the daemon did not start. The text for the owner is built by the UI, in the window's language
/// (gate_screen.dart).
enum DaemonStartFailure {
  /// The binary failed to launch (`Process.start`): [DaemonStartException.detail] is the path and the OS message.
  spawn,

  /// The process is alive, but the socket did not appear within 15 s.
  socketTimeout,

  /// The process exited during startup.
  exited,

  /// launchctl refused: [DaemonStartException.detail] is its stderr (if empty, see the exit code).
  launchctl,
}

/// The daemon did not start: the reason, exit code and log tail, for a clear error on screen.
final class DaemonStartException implements Exception {
  const DaemonStartException(this.reason, {this.detail = '', this.exitCode, this.logTail = '', this.logPath});
  final DaemonStartFailure reason;

  /// Raw technical details (path and OS message, launchctl stderr), not translated.
  final String detail;
  final int? exitCode;
  final String logTail;
  final String? logPath;

  @override
  String toString() => 'DaemonStartException(${reason.name}${detail.isEmpty ? '' : ': $detail'}, exit $exitCode)';
}

/// What keeps the daemon running.
abstract interface class DaemonHost {
  /// `launch_agent` / `child`.
  String get kind;

  /// The daemon outlives the window.
  bool get outlivesWindow;

  /// Path of the `antennad` binary.
  String get xdPath;

  /// The daemon log.
  String get logPath;

  /// Start and wait for the socket. Throws [DaemonStartException].
  Future<void> start();

  /// Stop the daemon (keys are wiped from memory, the socket is removed).
  Future<void> stop();

  /// The window is closing: a child daemon is stopped, a LaunchAgent stays.
  Future<void> onWindowExit();
}

/// Wait for the socket to appear; [alive] reports whether the process is still alive (otherwise there is nothing to
/// wait for).
Future<bool> waitForSocket(String socket, {Duration timeout = const Duration(seconds: 15), bool Function()? alive}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (FileSystemEntity.typeSync(socket) != FileSystemEntityType.notFound) return true;
    if (alive != null && !alive()) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

String tailOf(String path, {int lines = 12}) {
  try {
    final all = const LineSplitter().convert(File(path).readAsStringSync());
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  } on Object {
    return '';
  }
}

/// Launch without inherited descriptors: the window process (the Flutter engine) holds open descriptors without
/// CLOEXEC (for example, the assets directory); `antennad` inherits them and passes them on to the file check worker,
/// and the antenna-files worker does not consider itself isolated with extra descriptors and fails the check
/// (x-control/3: "the file changed while it was being prepared"). We close 3…255 and exec, so the PID stays the same.
/// The proper place for this is the daemon itself (D-P-8). dash (`/bin/sh` on Debian/Ubuntu) cannot handle
/// descriptors above 9, so bash is required (present on both Linux and macOS).
(String, List<String>) withoutInheritedFds(String exe, List<String> args) => (
      File('/bin/bash').existsSync() ? '/bin/bash' : '/usr/bin/bash',
      [
        '-c',
        r'fd=3; while [ "$fd" -le 255 ]; do eval "exec $fd>&-"; fd=$((fd+1)); done; exec "$@"',
        'antennad-launch',
        exe,
        ...args,
      ],
    );

List<String> _xdArgs(String? dataDir, String? socket) => [
      if (dataDir != null) ...['--data-dir', dataDir],
      if (socket != null) ...['--socket', socket],
    ];

/// The child daemon's lifeline (D-UI-10): the window keeps the daemon's stdin open (it never closes `Process.stdin`),
/// and at its end, when the window closes or is killed, the daemon locks and exits as on SIGTERM. Only for a child: a
/// LaunchAgent's daemon outlives the window by design.
const childLifelineArg = '--exit-with-stdin';

/// What `antennad` writes to stderr once its control socket or pipe takes clients: `antennad VERSION listening on PATH
/// (state: …)`.
const daemonListeningMark = ' listening on ';

/// A child process of the window.
final class ChildProcessHost implements DaemonHost {
  ChildProcessHost({
    required this.xdPath,
    required this.socketPath,
    required this.logPath,
    this.dataDir,
    this.socketArg,
    this.environment,
    this.os,
  });

  /// The system (`Platform.operatingSystem` when not given).
  final String? os;

  bool get _windows => (os ?? Platform.operatingSystem) == 'windows';

  /// Extra daemon environment (tests: `ANTENNA_LINKS_DIR` in a temporary directory).
  final Map<String, String>? environment;

  @override
  final String xdPath;
  final String socketPath;
  @override
  final String logPath;

  /// `--data-dir`, if not the default.
  final String? dataDir;

  /// `--socket`, if not the default.
  final String? socketArg;
  Process? _proc;
  int? _exit;

  @override
  String get kind => 'child';
  @override
  bool get outlivesWindow => false;

  @override
  Future<void> start() async {
    File(logPath).parent.createSync(recursive: true);
    final log = File(logPath).openWrite(mode: FileMode.append);
    if (_windows) return _startWindows(log);
    final Process p;
    try {
      final (exe, args) = withoutInheritedFds(xdPath, [..._xdArgs(dataDir, socketArg), childLifelineArg]);
      p = await Process.start(exe, args, environment: environment);
    } on ProcessException catch (e) {
      await log.close();
      throw DaemonStartException(DaemonStartFailure.spawn, detail: '$xdPath: ${e.message}', logPath: logPath);
    }
    _proc = p;
    _exit = null;
    unawaited(p.exitCode.then((c) => _exit = c));
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.pipe(log));
    final ok = await waitForSocket(socketPath, alive: () => _exit == null);
    if (!ok) {
      if (_exit == null) p.kill(ProcessSignal.sigkill);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _proc = null;
      throw DaemonStartException(
        _exit == null ? DaemonStartFailure.socketTimeout : DaemonStartFailure.exited,
        exitCode: _exit,
        logTail: tailOf(logPath),
        logPath: logPath,
      );
    }
  }

  /// Windows: `antennad.exe` started directly; ready when its stderr says it listens. Its stderr goes on into the log.
  Future<void> _startWindows(IOSink log) async {
    final Process p;
    try {
      p = await Process.start(xdPath, [..._xdArgs(dataDir, socketArg), childLifelineArg], environment: environment);
    } on ProcessException catch (e) {
      await log.close();
      throw DaemonStartException(DaemonStartFailure.spawn, detail: '$xdPath: ${e.message}', logPath: logPath);
    }
    _proc = p;
    _exit = null;
    unawaited(p.exitCode.then((c) => _exit = c));
    unawaited(p.stdout.drain<void>());
    final listening = Completer<bool>();
    var closed = false;
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(
      (line) {
        log.writeln(line);
        if (!listening.isCompleted && line.contains(daemonListeningMark)) listening.complete(true);
      },
      onDone: () {
        closed = true;
        unawaited(log.close());
        if (!listening.isCompleted) listening.complete(false);
      },
    );
    final ok = await listening.future.timeout(const Duration(seconds: 15), onTimeout: () => false);
    if (ok) return;
    final exited = await p.exitCode.then<int?>((c) => c).timeout(const Duration(seconds: 1), onTimeout: () => null);
    if (exited == null) p.kill(ProcessSignal.sigkill);
    if (!closed) await log.flush();
    _proc = null;
    throw DaemonStartException(
      exited == null ? DaemonStartFailure.socketTimeout : DaemonStartFailure.exited,
      exitCode: exited,
      logTail: tailOf(logPath),
      logPath: logPath,
    );
  }

  @override
  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p == null) return;
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  @override
  Future<void> onWindowExit() => stop();

  bool get running => _proc != null && _exit == null;
}

/// LaunchAgent label of the daemon: reverse-DNS, matching the window's bundle id `io.github.danta-nort.antenna`.
const launchAgentLabel = 'io.github.danta-nort.antenna.daemon';

/// LaunchAgent of the pre-release `x` build (before the rename): the window removes it on first launch.
const legacyLaunchAgentLabels = ['dev.x.xd'];

/// A per-user LaunchAgent on macOS.
final class LaunchAgentHost implements DaemonHost {
  LaunchAgentHost({
    required this.xdPath,
    required this.socketPath,
    required this.logPath,
    required this.home,
    this.dataDir,
    this.socketArg,
    CommandRunner? runner,
    this.label = launchAgentLabel,
    this.legacyLabels = legacyLaunchAgentLabels,
  }) : _runner = runner ?? _run;

  @override
  final String xdPath;
  final String socketPath;
  @override
  final String logPath;
  final String home;
  final String? dataDir;
  final String? socketArg;
  final String label;

  /// LaunchAgent labels of older builds: removed (bootout + plist deleted) before starting ours.
  final List<String> legacyLabels;
  final CommandRunner _runner;

  @override
  String get kind => 'launch_agent';
  @override
  bool get outlivesWindow => true;

  String get plistPath => '$home/Library/LaunchAgents/$label.plist';

  /// Remove the LaunchAgent of the pre-release `x` build (`dev.x.xd`): it keeps the old daemon running with the
  /// `~/.local/share/x` directory, and while that daemon runs `antennad` does not migrate the data (DECISIONS D-56).
  /// Happens once: the plist is deleted afterwards. Returns the removed labels.
  Future<List<String>> removeLegacyAgents(String uid) async {
    final removed = <String>[];
    for (final l in legacyLabels) {
      final f = File('$home/Library/LaunchAgents/$l.plist');
      if (!f.existsSync()) continue;
      // bootout waits for the process to exit; "not loaded" is fine too.
      await _runner('/bin/launchctl', ['bootout', 'gui/$uid/$l']);
      f.deleteSync();
      removed.add(l);
    }
    if (removed.isNotEmpty) {
      try {
        File(logPath).writeAsStringSync(
          '${DateTime.now().toUtc().toIso8601String()} window: removed the LaunchAgent of the preview build '
          '(${removed.join(', ')}); antennad moves its data once\n',
          mode: FileMode.append,
        );
      } on Object {
        // The log is best-effort.
      }
    }
    return removed;
  }

  /// plist contents: antennad from the app, restart after a crash (not after a normal stop), the log.
  String plist() {
    String esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);
    final args = [xdPath, ..._xdArgs(dataDir, socketArg)];
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${esc(label)}</string>
	<key>ProgramArguments</key>
	<array>
${args.map((a) => '\t\t<string>${esc(a)}</string>').join('\n')}
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>${esc(logPath)}</string>
	<key>StandardOutPath</key>
	<string>/dev/null</string>
</dict>
</plist>
''';
  }

  Future<String> _uid() async {
    final r = await _runner('/usr/bin/id', ['-u']);
    return '${r.stdout}'.trim();
  }

  @override
  Future<void> start() async {
    File(logPath).parent.createSync(recursive: true);
    final f = File(plistPath);
    f.parent.createSync(recursive: true);
    final want = plist();
    final changed = !f.existsSync() || f.readAsStringSync() != want;
    final uid = await _uid();
    await removeLegacyAgents(uid);
    final target = 'gui/$uid/$label';
    if (changed) {
      // The antennad path changed (the app was moved): unload the old agent.
      await _runner('/bin/launchctl', ['bootout', target]);
      f.writeAsStringSync(want);
    }
    var r = await _runner('/bin/launchctl', ['bootstrap', 'gui/$uid', plistPath]);
    if (r.exitCode != 0) {
      // Already loaded: restart it.
      r = await _runner('/bin/launchctl', ['kickstart', '-k', target]);
    }
    if (r.exitCode != 0) {
      throw DaemonStartException(
        DaemonStartFailure.launchctl,
        detail: '${r.stderr}'.trim(),
        exitCode: r.exitCode,
        logTail: tailOf(logPath),
        logPath: logPath,
      );
    }
    if (!await waitForSocket(socketPath)) {
      throw DaemonStartException(
        DaemonStartFailure.socketTimeout,
        logTail: tailOf(logPath),
        logPath: logPath,
      );
    }
  }

  @override
  Future<void> stop() async {
    final uid = await _uid();
    await _runner('/bin/launchctl', ['bootout', 'gui/$uid/$label']);
  }

  /// Remove autostart entirely.
  Future<void> uninstall() async {
    await stop();
    final f = File(plistPath);
    if (f.existsSync()) f.deleteSync();
  }

  @override
  Future<void> onWindowExit() async {}
}

/// The default host for this OS; `null` if `antennad` was not found.
DaemonHost? defaultHost({
  required String? xdPath,
  required String socketPath,
  required String defaultSocket,
  required Map<String, String> env,
  required String logPath,
  String? os,
}) {
  // The window starts its own daemon only for its default socket: a socket forwarded over ssh belongs to another
  // daemon.
  if (xdPath == null || socketPath != defaultSocket) return null;
  final system = os ?? Platform.operatingSystem;
  final dataDir = envWithFallback(env, 'ANTENNA_DATA_DIR', 'X_DATA_DIR');
  final explicit = envWithFallback(env, 'ANTENNA_SOCKET', 'X_SOCKET');
  final socketArg = explicit != null ? socketPath : null;
  if (system == 'macos') {
    return LaunchAgentHost(
      xdPath: xdPath,
      socketPath: socketPath,
      logPath: logPath,
      home: env['HOME'] ?? '',
      dataDir: dataDir,
      socketArg: socketArg,
    );
  }
  return ChildProcessHost(
    xdPath: xdPath,
    socketPath: socketPath,
    logPath: logPath,
    dataDir: dataDir,
    socketArg: socketArg,
    os: system,
  );
}
