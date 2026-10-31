// SPDX-License-Identifier: AGPL-3.0-only
// What the full-screen viewer does with a picture besides showing it: copy it to the clipboard, save it elsewhere, and
// show a received file in Finder or the file manager. The window only ever holds pixels it rebuilt or the daemon
// rebuilt (the sent image's preview copy, an incoming image's safe preview), so that is what is copied and saved; a
// received file the owner accepted is saved from where the daemon put it, as the owner already has it.
//
// Copy: Flutter's clipboard takes text only. macOS: `osascript` sets the clipboard from a PNG file
// (`«class PNGf»`), as Preview's Copy does; Linux: `wl-copy` (Wayland) or `xclip` (X11), when installed; otherwise
// the viewer says it could not copy. Reveal: macOS `open -R`, Linux the file manager's `ShowItems` over D-Bus, or the
// folder opened with `xdg-open`.

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';

import 'cli_install.dart' show CliCommandRunner, runWithTimeout;
import 'outgoing_staging.dart';

abstract interface class ImageActions {
  /// Put [png] on the clipboard as a picture. `false` when this computer offers no way to.
  Future<bool> copyPng(Uint8List png);

  /// Where the owner wants [suggestedName] saved, or `null` when they cancelled.
  Future<String?> saveLocation(String suggestedName);

  /// Show [path] selected in Finder (or the folder in the file manager).
  Future<bool> reveal(String path);

  /// The window's actions on this computer (replaced in tests).
  static ImageActions instance = SystemImageActions();
}

final class SystemImageActions implements ImageActions {
  SystemImageActions({CliCommandRunner? run, bool? macos})
      : _run = run ?? runWithTimeout,
        _macos = macos ?? Platform.isMacOS;

  final CliCommandRunner _run;
  final bool _macos;

  Future<bool> _go(String exe, List<String> args) async {
    try {
      return (await _run(exe, args, timeout: const Duration(seconds: 10))).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<bool> copyPng(Uint8List png) async {
    // A private copy for the tool to read, in the window's own 0700 staging folder; gone right after.
    final staged = OutgoingStaging.instance?.stageBytes(png, 'clipboard.png');
    if (staged == null) return false;
    try {
      if (_macos) {
        final path = staged.path.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
        return await _go('/usr/bin/osascript', ['-e', 'set the clipboard to (read (POSIX file "$path") as «class PNGf»)']);
      }
      for (final (exe, args) in [
        ('wl-copy', ['--type', 'image/png']),
        ('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-i']),
      ]) {
        try {
          final p = await Process.start(exe, args);
          p.stdin.add(png);
          await p.stdin.close();
          if (await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1) == 0) return true;
        } on ProcessException {
          continue;
        }
      }
      return false;
    } finally {
      OutgoingStaging.instance?.release(staged.path);
    }
  }

  @override
  Future<String?> saveLocation(String suggestedName) async =>
      (await fs.getSaveLocation(suggestedName: suggestedName))?.path;

  @override
  Future<bool> reveal(String path) async {
    if (_macos) return _go('/usr/bin/open', ['-R', path]);
    final uri = Uri.file(path).toString();
    return await _go('dbus-send', [
          '--session',
          '--dest=org.freedesktop.FileManager1',
          '--type=method_call',
          '/org/freedesktop/FileManager1',
          'org.freedesktop.FileManager1.ShowItems',
          'array:string:$uri',
          'string:',
        ]) ||
        await _go('xdg-open', [File(path).parent.path]);
  }
}
