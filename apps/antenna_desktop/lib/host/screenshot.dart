// SPDX-License-Identifier: AGPL-3.0-only
// Screenshots for an agent in Code mode (D-UI-27): the owner picks an area or a window with the system's own screenshot tool,
// the window keeps the image in a folder of its own, and hands that file to the agent (code_shot.dart). Pure Dart
// (dart:io).
//
// The tool: macOS `screencapture -i` (drag an area, Space for a window, Esc to cancel); on Linux the first of the
// usual desktop tools that is installed (GNOME, KDE, Xfce, wlroots `grim` + `slurp`, `maim`, `scrot`, ImageMagick
// `import`); none: the window offers no screenshot button.
//
// The folder: macOS ~/Library/Caches/Antenna/screenshots, Linux $XDG_CACHE_HOME/antenna/screenshots, 0700, one folder
// per agent (Claude Code is started with `--add-dir` on its folder, so it may read the image it was given without a
// permission question). Files are named by the window (`screenshot-YYYYMMDD-HHMMSS.png`) and deleted after a day.
// A [WindowScreenshot] exists only for a file this library created and checked; it is the only kind of path the
// window ever puts into an agent's terminal (code_lines.dart, `AllowedLine.screenshot`).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cli_install.dart' show CliCommandRunner, runWithTimeout;
import 'program_locator.dart';

/// How long the owner may take to pick the area or window.
const screenshotTimeout = Duration(minutes: 5);

/// The largest screenshot the window hands over (a 6K display at 2x is well below this).
const maxScreenshotBytes = 64 << 20;

/// Characters a screenshot path may contain to be put into a terminal: no spaces, quotes, escapes or control
/// characters, so the text pasted is exactly a path and nothing else (a home folder with other characters keeps its
/// screenshots, which are then shown to the owner instead of pasted).
final _pasteablePath = RegExp(r'^/[A-Za-z0-9/._-]+$');
final _shotName = RegExp(r'^screenshot-\d{8}-\d{6}(-\d{1,3})?\.png$');
final _agentDir = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _slurpGeometry = RegExp(r'^\d{1,6},\d{1,6} \d{1,6}x\d{1,6}$');

/// The system screenshot tool.
abstract interface class ScreenCapture {
  /// The tool's program, for the log and the tooltip (`screencapture`, `gnome-screenshot`…).
  String get name;

  /// Let the owner pick an area or a window and write it to [path] as PNG. `false`: cancelled or failed (no file).
  Future<bool> capture(String path);
}

/// One way to run a tool: its program and the arguments for a target path.
final class _Tool {
  const _Tool(this.name, this.args, {this.needs});
  final String name;
  final List<String> Function(String path) args;

  /// An environment variable the tool needs (an X11 or Wayland display).
  final String? needs;
}

/// The Linux tools, in the order tried: desktop environments' own first (they work under Wayland and X11), then
/// wlroots' pair, then X11-only tools.
final _linuxTools = <_Tool>[
  _Tool('gnome-screenshot', (p) => ['-a', '-f', p]),
  _Tool('spectacle', (p) => ['-r', '-b', '-n', '-o', p]),
  _Tool('xfce4-screenshooter', (p) => ['-r', '-s', p]),
  _Tool('grim', (p) => [p], needs: 'WAYLAND_DISPLAY'),
  _Tool('maim', (p) => ['-s', p], needs: 'DISPLAY'),
  _Tool('scrot', (p) => ['-s', p], needs: 'DISPLAY'),
  _Tool('import', (p) => [p], needs: 'DISPLAY'),
];

final class SystemScreenCapture implements ScreenCapture {
  SystemScreenCapture._(this._exe, this._tool, {this.slurp, CliCommandRunner? run}) : _run = run ?? runWithTimeout;

  /// The screenshot tool for this computer, or `null` when there is none (the window then shows no button).
  static SystemScreenCapture? detect(ProgramLocator programs,
      {required Map<String, String> env, bool? macos, bool Function(String)? exists, CliCommandRunner? run}) {
    if (macos ?? Platform.isMacOS) {
      const exe = '/usr/sbin/screencapture';
      final ok = exists ?? isExecutableFile;
      // -i: the owner drags an area or presses Space for a window (Esc cancels); -o: no window shadow; -x: no sound.
      return ok(exe) ? SystemScreenCapture._(exe, _Tool('screencapture', (p) => ['-i', '-o', '-x', '-t', 'png', p]), run: run) : null;
    }
    for (final t in _linuxTools) {
      if (t.needs != null && (env[t.needs] ?? '').isEmpty) continue;
      final exe = programs.locate(t.name);
      if (exe == null) continue;
      if (t.name == 'grim') {
        final slurp = programs.locate('slurp');
        if (slurp == null) continue;
        return SystemScreenCapture._(exe, t, slurp: slurp, run: run);
      }
      return SystemScreenCapture._(exe, t, run: run);
    }
    return null;
  }

  final String _exe;
  final _Tool _tool;

  /// wlroots: `slurp` picks the area, `grim` takes it.
  final String? slurp;
  final CliCommandRunner _run;

  @override
  String get name => _tool.name;

  @override
  Future<bool> capture(String path) async {
    try {
      final args = _tool.args(path);
      if (slurp != null) {
        final s = await _run(slurp!, const [], timeout: screenshotTimeout);
        final geometry = '${s.stdout}'.trim();
        // Only a geometry goes on grim's command line; anything else (cancelled, an error) ends the capture.
        if (s.exitCode != 0 || !_slurpGeometry.hasMatch(geometry)) return false;
        args.insertAll(0, ['-g', geometry]);
      }
      final r = await _run(_exe, args, timeout: screenshotTimeout);
      if (r.exitCode != 0) debugPrint('screenshot: $name exited with ${r.exitCode}');
      // Cancelling leaves no file; some tools exit 0 either way, so the file decides.
      return File(path).existsSync();
    } on ProcessException catch (e) {
      debugPrint('screenshot: $name: $e');
      return false;
    }
  }
}

/// A screenshot the window took and checked: a PNG in its own folder, under a name it chose. The only constructor is
/// private to this library, so nothing else (a message, a file a contact sent, a path typed somewhere) can become one.
@immutable
final class WindowScreenshot {
  const WindowScreenshot._(this.path, this.agent);

  final String path;

  /// The agent it was taken for.
  final String agent;

  /// The path may be put into a terminal as it is ([_pasteablePath]).
  bool get pasteable => _pasteablePath.hasMatch(path) && !path.contains('/../') && !path.contains('/./');

  @override
  String toString() => path;
}

/// Why a capture produced no screenshot.
enum ScreenshotFailure {
  /// The owner pressed Esc, or the tool left no file.
  cancelled,

  /// The folder could not be made private, or the file is not a plain PNG the window wrote.
  rejected,
}

final class ScreenshotException implements Exception {
  const ScreenshotException(this.reason, [this.detail = '']);
  final ScreenshotFailure reason;
  final String detail;

  @override
  String toString() => 'ScreenshotException(${reason.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// The window's screenshot folder.
class ScreenshotStore {
  ScreenshotStore(String root, {this.maxAge = const Duration(days: 1)})
      : root = root.endsWith('/') && root.length > 1 ? root.substring(0, root.length - 1) : root;

  /// The folder for this user (`null` without a home directory).
  static ScreenshotStore? forEnv(Map<String, String> env, {bool? macos}) {
    final home = env['HOME'] ?? '';
    if (!home.startsWith('/')) return null;
    if (macos ?? Platform.isMacOS) return ScreenshotStore('$home/Library/Caches/Antenna/screenshots');
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.startsWith('/')) ? xdg : '$home/.cache';
    return ScreenshotStore('$base/antenna/screenshots');
  }

  final String root;
  final Duration maxAge;

  /// The folder of [agent]'s screenshots (an agent name is 1–64 of `[A-Za-z0-9._-]`; `.` and `..` get a fixed name).
  String folderFor(String agent) =>
      '$root/${_agentDir.hasMatch(agent) && agent != '.' && agent != '..' ? agent : '_agent'}';

  /// Create [agent]'s folder (0700, like the root) and return it; `null` when it cannot be made private.
  String? ensureFolder(String agent) {
    try {
      _private(root, create: true);
      final dir = folderFor(agent);
      _private(dir, create: true);
      return dir;
    } on FileSystemException catch (e) {
      debugPrint('screenshots: $e');
      return null;
    }
  }

  /// Let the owner take a screenshot with [tool] for [agent]. Throws [ScreenshotException].
  Future<WindowScreenshot> capture(String agent, ScreenCapture tool, {DateTime? now}) async {
    sweep(now: now);
    final dir = ensureFolder(agent);
    if (dir == null) throw const ScreenshotException(ScreenshotFailure.rejected, 'folder');
    final path = _freeName(dir, now ?? DateTime.now());
    if (!await tool.capture(path)) {
      _remove(path);
      throw const ScreenshotException(ScreenshotFailure.cancelled);
    }
    return check(path, agent);
  }

  /// [path] is a screenshot this store wrote: in [agent]'s folder, under a screenshot name, a regular file (not a
  /// link), not empty, not too large, and a PNG. Anything else is refused and removed when it sits in the folder.
  WindowScreenshot check(String path, String agent) {
    final dir = folderFor(agent);
    final name = path.startsWith('$dir/') ? path.substring(dir.length + 1) : '';
    if (!_shotName.hasMatch(name)) throw ScreenshotException(ScreenshotFailure.rejected, path);
    final st = FileStat.statSync(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.file || st.size <= 8 || st.size > maxScreenshotBytes || !_isPng(path)) {
      _remove(path);
      throw ScreenshotException(ScreenshotFailure.rejected, path);
    }
    return WindowScreenshot._(path, agent);
  }

  /// Delete screenshots older than [maxAge] (the agent has read them by then, or never will). Returns how many.
  int sweep({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var n = 0;
    final top = Directory(root);
    if (!top.existsSync()) return 0;
    try {
      for (final d in top.listSync(followLinks: false)) {
        if (d is! Directory) {
          d.deleteSync();
          n++;
          continue;
        }
        for (final f in d.listSync(followLinks: false)) {
          try {
            if (f is! File || f.statSync().modified.isBefore(cutoff)) {
              f.deleteSync(recursive: f is Directory);
              n++;
            }
          } on FileSystemException {
            continue;
          }
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('screenshots sweep: $e');
    }
    return n;
  }

  static String _freeName(String dir, DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var path = '$dir/screenshot-$stamp.png';
    for (var n = 2; FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound; n++) {
      path = '$dir/screenshot-$stamp-$n.png';
    }
    return path;
  }

  static bool _isPng(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final head = f.readSync(8);
      const magic = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
      if (head.length != 8) return false;
      for (var i = 0; i < 8; i++) {
        if (head[i] != magic[i]) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    } finally {
      f?.closeSync();
    }
  }

  static void _remove(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) File(path).deleteSync();
    } on FileSystemException catch (e) {
      debugPrint('screenshots: $e');
    }
  }

  /// [path] is a folder (not a link) that only this user can open; created when missing.
  static void _private(String path, {required bool create}) {
    var type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      Directory(path).createSync(recursive: true);
      type = FileSystemEntity.typeSync(path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) throw FileSystemException('not a folder', path);
    // dart:io creates folders with the umask's mode and has no chmod.
    if (Directory(path).statSync().mode & 0x3F != 0) {
      final r = Process.runSync('/bin/chmod', ['700', path]);
      if (r.exitCode != 0) throw FileSystemException('chmod 700: ${r.stderr}', path);
    }
  }
}
