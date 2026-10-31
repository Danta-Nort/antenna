// SPDX-License-Identifier: AGPL-3.0-only
// "Add <folder> to PATH" (the Check panel, D-UI-26): an AI app's command-line program is installed, but a new terminal
// does not find it because its folder is not on the login shell's PATH (Claude Code's own documentation names this
// case after its installer). The fix appends one line to the shell's profile, after a backup, with the owner's consent
// in a dialog that shows the line and the file. Pure Dart (dart:io).
//
// Only folders whose path is plain text are offered (letters, digits and `/ . _ + @ -`): nothing is quoted into a
// shell line, so no folder name can add a command to the profile. Appending (not rewriting) keeps a profile that is
// a link into a dotfiles folder a link, and keeps its permissions. Idempotent: a profile that already has the line is
// not touched.

import 'dart:io';

import 'package:flutter/foundation.dart';

final _plainFolder = RegExp(r'^/[A-Za-z0-9/._+@-]+$');

/// The profile edit that puts a folder on PATH for new terminals.
@immutable
final class PathFix {
  const PathFix({required this.folder, required this.profile, required this.line, required this.shell});

  /// The folder, absolute.
  final String folder;

  /// The profile file, absolute.
  final String profile;

  /// The line appended to it.
  final String line;

  /// The shell's name (`zsh`, `bash`, `fish`, `sh`).
  final String shell;
}

/// The fix for [folder] in the login shell [shell] (`$SHELL`), or `null` when [folder] is not plain text (the
/// owner then gets the guide, not a button).
PathFix? pathFixFor(String folder, {required String shell, required String home, required bool macos}) {
  if (!_plainFolder.hasMatch(folder) || folder.split('/').any((s) => s == '..' || s == '.')) return null;
  if (!home.startsWith('/')) return null;
  final name = shell.split('/').last;
  // Under the home folder, the line names it through $HOME, as installers write it.
  final shown = folder == home
      ? r'$HOME'
      : folder.startsWith('$home/')
          ? '\$HOME${folder.substring(home.length)}'
          : folder;
  return switch (name) {
    'zsh' => PathFix(folder: folder, profile: '$home/.zprofile', line: 'export PATH="$shown:\$PATH"', shell: name),
    'bash' => PathFix(
        folder: folder,
        profile: macos ? '$home/.bash_profile' : '$home/.bashrc',
        line: 'export PATH="$shown:\$PATH"',
        shell: name),
    'fish' => PathFix(
        folder: folder, profile: '$home/.config/fish/config.fish', line: 'fish_add_path $shown', shell: name),
    _ => PathFix(folder: folder, profile: '$home/.profile', line: 'export PATH="$shown:\$PATH"', shell: 'sh'),
  };
}

/// What [applyPathFix] did.
enum PathFixResult {
  /// The line was appended (after a backup when the profile existed).
  added,

  /// The profile already had the line.
  present,
}

/// The profile files [applyPathFix] reads and appends to (replaced in tests).
abstract interface class ProfileFs {
  String? read(String path);

  /// Copy [path] next to itself as `<path>.antenna-backup-<stamp>` and return the copy's path.
  String backup(String path, DateTime now);

  /// Append [text], creating the file (and its folder) when missing.
  void append(String path, String text);
}

final class SystemProfileFs implements ProfileFs {
  const SystemProfileFs();

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
  String backup(String path, DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var target = '$path.antenna-backup-$stamp';
    for (var n = 2; FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound; n++) {
      target = '$path.antenna-backup-$stamp-$n';
    }
    File(path).copySync(target);
    return target;
  }

  @override
  void append(String path, String text) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text, mode: FileMode.append, flush: true);
  }
}

/// Append [fix]'s line to its profile, after a backup; nothing when the line is there already. Returns what happened
/// and the backup's path (`null`: no backup was needed).
(PathFixResult, String?) applyPathFix(PathFix fix, {ProfileFs fs = const SystemProfileFs(), DateTime? now}) {
  final before = fs.read(fix.profile);
  if (before != null && before.split('\n').any((l) => l.trim() == fix.line)) return (PathFixResult.present, null);
  final backup = before == null ? null : fs.backup(fix.profile, now ?? DateTime.now());
  final sep = before == null || before.isEmpty || before.endsWith('\n') ? '' : '\n';
  fs.append(fix.profile, '$sep# Added by Antenna: ${fix.folder} on PATH for new terminals\n${fix.line}\n');
  return (PathFixResult.added, backup);
}
