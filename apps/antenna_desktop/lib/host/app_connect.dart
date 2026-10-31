// SPDX-License-Identifier: AGPL-3.0-only
// What "Connect" touches on this computer: an AI app's configuration file (read, back up, write atomically), the
// system's "open" (an app's install link or an extension bundle), and restarting an app that reads its settings only
// when it starts (macOS: its own Quit through an Apple Event, then `open -a`, only on the owner's click). Behind
// interfaces so the flows run in tests against a fake file system and a fake launcher (docs/CONNECT-APPS.md).

import 'dart:async';
import 'dart:io';

import 'cli_install.dart' show CliCommandRunner, runWithTimeout;

/// The files Connect reads and writes. Paths are absolute.
abstract interface class ConnectorFs {
  /// The file's text, or `null` when there is no such file.
  String? read(String path);

  bool fileExists(String path);
  bool dirExists(String path);

  /// Copy [path] next to itself as `<path>.antenna-backup-<stamp>` (same permissions) and return the copy's path.
  String backup(String path, DateTime now);

  /// Replace [path] with [content] atomically (a temporary file in the same folder, then a rename), creating the
  /// folder if needed. A new file is created 0600; an existing file keeps its permissions.
  void write(String path, String content);

  /// Write bytes to a new private file (0600) and return its path (an extension bundle to open).
  String writeTemp(String name, List<int> bytes);
}

/// The system's "open": a URL in the app registered for it, or a file in a given app; and, for an app that reads its
/// MCP settings only when it starts, quitting it and opening it again after Connect (macOS app bundles).
abstract interface class AppLauncher {
  /// `true` when the system accepted the request (the app itself shows its dialog after that).
  Future<bool> openUrl(String url);

  /// Open [path] with the app at [appPath] (macOS `open -a`), or with the default app.
  Future<bool> openFile(String path, {String? appPath});

  /// Whether the app bundle at [appPath] runs now; `null` where the window cannot tell (not macOS, no bundle ID).
  Future<bool?> appRunning(String appPath);

  /// Ask the app at [appPath] to quit, as its own Quit command does (the app may save or ask first), and wait up to
  /// [timeout] for it to exit. Called only after the owner's click; nothing is ever force-quit.
  Future<AppQuitResult> quitApp(String appPath, {Duration timeout});

  /// Open the app at [appPath] (macOS `open -a`).
  Future<bool> openApp(String appPath);
}

/// How [AppLauncher.quitApp] ended.
enum AppQuitResult {
  /// The app exited.
  quit,

  /// macOS did not let Antenna control the app (Privacy & Security → Automation, error -1743).
  notAllowed,

  /// The app is still running: it asked something, or cancelled its quit.
  stillRunning,

  /// The request failed for another reason (no bundle ID, osascript missing).
  failed,
}

/// How long [AppLauncher.quitApp] waits for an app to exit by default.
const appQuitTimeout = Duration(seconds: 20);

/// A bundle identifier as reverse DNS (`com.anthropic.claudefordesktop`): the only text put into an AppleScript.
final _bundleIdShape = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$');

/// `yyyyMMdd-HHmmss`.
String backupStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

final class SystemConnectorFs implements ConnectorFs {
  SystemConnectorFs({this.tempDir});

  /// Where bundles are written (the system temporary folder by default).
  final String? tempDir;

  @override
  String? read(String path) {
    final f = File(path);
    try {
      return f.existsSync() ? f.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool dirExists(String path) => Directory(path).existsSync();

  @override
  String backup(String path, DateTime now) {
    var target = '$path.antenna-backup-${backupStamp(now)}';
    for (var n = 2; File(target).existsSync(); n++) {
      target = '$path.antenna-backup-${backupStamp(now)}-$n';
    }
    final src = File(path);
    final mode = src.statSync().mode & 0x1ff;
    final copy = src.copySync(target);
    // A backup may hold other servers' secrets: never wider than the original, and never wider than 0600.
    _chmod(copy.path, mode & 0x180);
    return target;
  }

  @override
  void write(String path, String content) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    final existed = f.existsSync();
    final mode = existed ? f.statSync().mode & 0x1ff : 0x180;
    final tmp = File('${f.parent.path}/.${f.uri.pathSegments.last}.antenna-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      tmp.writeAsStringSync(content, flush: true);
      _chmod(tmp.path, mode);
      tmp.renameSync(path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  @override
  String writeTemp(String name, List<int> bytes) {
    final dir = Directory(tempDir ?? Directory.systemTemp.path).createTempSync('antenna-connect-');
    _chmod(dir.path, 0x1c0);
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes, flush: true);
    _chmod(f.path, 0x180);
    return f.path;
  }

  static void _chmod(String path, int mode) {
    try {
      Process.runSync('chmod', [mode.toRadixString(8), path]);
    } on ProcessException {
      // Best effort: the file is still written; its folder is the user's own.
    }
  }
}

final class SystemAppLauncher implements AppLauncher {
  SystemAppLauncher({CliCommandRunner? run, bool? macos, this.poll = const Duration(milliseconds: 250)})
      : _run = run ?? runWithTimeout,
        _macos = macos ?? Platform.isMacOS;

  final CliCommandRunner _run;
  final bool _macos;

  /// How often [quitApp] looks whether the app has exited.
  final Duration poll;

  /// Bundle IDs read from the apps' Info.plist, by bundle path.
  final _ids = <String, String?>{};

  Future<bool> _go(String exe, List<String> args) async {
    try {
      final r = await _run(exe, args, timeout: const Duration(seconds: 10));
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<bool> openUrl(String url) => _macos ? _go('open', [url]) : _go('xdg-open', [url]);

  @override
  Future<bool> openFile(String path, {String? appPath}) => _macos
      ? _go('open', [if (appPath != null) ...['-a', appPath], path])
      : _go('xdg-open', [path]);

  /// The bundle ID of the app at [appPath], from its Info.plist (`defaults` reads both the XML and the binary form).
  /// Read from the app itself rather than kept in a list: an app renamed by its vendor keeps working.
  Future<String?> _bundleId(String appPath) async {
    if (_ids.containsKey(appPath)) return _ids[appPath];
    String? id;
    try {
      final r = await _run('/usr/bin/defaults', ['read', '$appPath/Contents/Info', 'CFBundleIdentifier'],
          timeout: const Duration(seconds: 5));
      final out = '${r.stdout}'.trim();
      if (r.exitCode == 0 && _bundleIdShape.hasMatch(out)) id = out;
    } on ProcessException {
      id = null;
    }
    return _ids[appPath] = id;
  }

  Future<ProcessResult?> _osascript(String script, {Duration timeout = const Duration(seconds: 10)}) async {
    try {
      return await _run('/usr/bin/osascript', ['-e', script], timeout: timeout);
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<bool?> appRunning(String appPath) async {
    if (!_macos) return null;
    final id = await _bundleId(appPath);
    if (id == null) return null;
    // `is running` is answered without launching the app and without the Automation permission.
    final r = await _osascript('application id "$id" is running');
    if (r == null || r.exitCode != 0) return null;
    return '${r.stdout}'.trim() == 'true';
  }

  @override
  Future<AppQuitResult> quitApp(String appPath, {Duration timeout = appQuitTimeout}) async {
    if (!_macos) return AppQuitResult.failed;
    final id = await _bundleId(appPath);
    if (id == null) return AppQuitResult.failed;
    // The app's own Quit (an Apple Event): it may save, ask, or refuse. The first time, macOS asks the owner whether
    // Antenna may control the app (NSAppleEventsUsageDescription in Info.plist) and holds the event until they answer,
    // hence the longer limit for this step.
    final r = await _osascript('tell application id "$id" to quit', timeout: const Duration(minutes: 1));
    if (r == null) return AppQuitResult.failed;
    if (r.exitCode != 0) {
      final err = '${r.stderr}';
      if (err.contains('-1743')) return AppQuitResult.notAllowed;
      // -128: the app cancelled its quit; -1712: it did not answer in time; -1: our limit. Is it still there?
      if (r.exitCode != -1 && !err.contains('-128') && !err.contains('-1712')) return AppQuitResult.failed;
    }
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (await appRunning(appPath) == false) return AppQuitResult.quit;
      await Future<void>.delayed(poll);
    }
    return AppQuitResult.stillRunning;
  }

  @override
  Future<bool> openApp(String appPath) => _macos ? _go('open', ['-a', appPath]) : Future.value(false);
}
