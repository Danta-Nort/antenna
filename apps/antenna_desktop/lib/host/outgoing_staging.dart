// SPDX-License-Identifier: AGPL-3.0-only
// Copies of files the window is about to send. `share_file` (CONTROL §14) takes a path that the daemon opens when the
// request arrives, so a file that another app deletes right after a drop (the macOS screenshot thumbnail, an archive
// manager's temporary extraction) is gone by then, and image data dropped or pasted from another app has no path at
// all. The window copies such a file into a folder of its own at once, sends the copy, and deletes the copy when the
// daemon has read and encrypted it (its `share_file` reply), when the person dismisses the send, or after a day.
//
// The folder belongs to the window, not to the daemon: `share_file` refuses files inside the daemon's data directory.
// macOS: ~/Library/Application Support/Antenna/outgoing (the Runner's drop view stages there too, ComposerInput.swift);
// Linux: $XDG_CACHE_HOME/antenna/outgoing (~/.cache/antenna/outgoing). The daemon runs as the same user and reads it.
// The folder is 0700; every copy sits in a folder of its own (random name) and keeps its file name, which the contact
// sees.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// A file ready for `share_file`.
@immutable
class StagedFile {
  const StagedFile(this.path, {this.owned = false, this.origin});

  /// The path the daemon reads.
  final String path;

  /// A copy in the staging folder: the window deletes it after the send.
  final bool owned;

  /// Where the person's file was, for the card; `null` for image data and file promises.
  final String? origin;
}

class OutgoingStaging {
  OutgoingStaging(String root, {this.maxAge = const Duration(days: 1), this.copyLimit = defaultCopyLimit})
      : root = root.endsWith('/') && root.length > 1 ? root.substring(0, root.length - 1) : root;

  /// Larger files are sent from where they are: copying gigabytes before a send costs more than it protects, and the
  /// files that vanish after a drop (screenshots, extracted attachments) are small. On macOS the drop view clones a
  /// file of any size on the same volume before the drop ends (APFS, no extra space), so this limit only matters for
  /// files from other volumes and on Linux.
  static const defaultCopyLimit = 64 << 20;

  /// The window's staging folder (replaced in tests; `null` without a home directory).
  static OutgoingStaging? instance = OutgoingStaging.forEnv(Platform.environment);

  static OutgoingStaging? forEnv(Map<String, String> env, {bool? macos}) {
    final home = env['HOME'] ?? '';
    if (home.isEmpty) return null;
    if (macos ?? Platform.isMacOS) return OutgoingStaging('$home/Library/Application Support/Antenna/outgoing');
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.startsWith('/')) ? xdg : '$home/.cache';
    return OutgoingStaging('$base/antenna/outgoing');
  }

  final String root;
  final Duration maxAge;
  final int copyLimit;
  DateTime? _sweptAt;

  /// [path] is a copy in this folder: `<root>/<folder>/<name>`.
  bool owns(String path) {
    if (!path.startsWith('$root/')) return false;
    final rest = path.substring(root.length + 1).split('/');
    return rest.length == 2 && rest.every((s) => s.isNotEmpty && s != '.' && s != '..');
  }

  /// Copy the dropped file [source] and return the copy. The source is opened before this returns its future (the
  /// caller starts it for every dropped file before it awaits anything else): once open, it stays readable even if
  /// the other app deletes it a moment later. A file that is already a copy here (the macOS drop view made it), a
  /// folder, a missing file and a file over [copyLimit] are returned as they are: the daemon then reads the original
  /// path and reports its own error if there is one.
  Future<StagedFile> stageFile(String source) async {
    if (owns(source)) return StagedFile(source, owned: true);
    Directory? dir;
    RandomAccessFile? src;
    RandomAccessFile? dst;
    try {
      final st = File(source).statSync();
      if (st.type != FileSystemEntityType.file || st.size > copyLimit) return StagedFile(source);
      src = File(source).openSync();
      dir = _newItemDir();
      final dest = '${dir.path}/${_baseName(source, 'file')}';
      dst = File(dest).openSync(mode: FileMode.writeOnly);
      var copied = 0;
      while (true) {
        final chunk = await src.read(1 << 20);
        if (chunk.isEmpty) break;
        copied += chunk.length;
        // The file grew past the limit after the check (a log being written): send the original instead.
        if (copied > copyLimit) throw FileSystemException('grew over the copy limit', source);
        await dst.writeFrom(chunk);
      }
      await dst.flush();
      return StagedFile(dest, owned: true, origin: source);
    } on Object catch (e) {
      debugPrint('staging $source: $e');
      await dst?.close();
      dst = null;
      _delete(dir);
      return StagedFile(source);
    } finally {
      await src?.close();
      await dst?.close();
    }
  }

  /// Write image data (a paste, an image dragged as data) as file [name]. `null` if the folder cannot be written.
  StagedFile? stageBytes(List<int> bytes, String name) {
    Directory? dir;
    try {
      dir = _newItemDir();
      final f = File('${dir.path}/${_baseName(name, 'image.png')}')..writeAsBytesSync(bytes, flush: true);
      return StagedFile(f.path, owned: true);
    } on Object catch (e) {
      debugPrint('staging $name: $e');
      _delete(dir);
      return null;
    }
  }

  /// Delete a copy made here, then its folder once empty (one file promise can deliver several files into one folder).
  /// Any other path is left alone.
  void release(String path) {
    if (!owns(path)) return;
    try {
      switch (FileSystemEntity.typeSync(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          // A promised folder (the daemon sends files only, but the copy is ours to remove).
          Directory(path).deleteSync(recursive: true);
        case FileSystemEntityType.notFound:
          break;
        default:
          File(path).deleteSync();
      }
      final dir = Directory(File(path).parent.path);
      if (dir.listSync().isEmpty) dir.deleteSync();
    } on FileSystemException catch (e) {
      debugPrint('staging cleanup: $e');
    }
  }

  /// Delete copies older than [maxAge]: sends that were never finished (the window was closed, the daemon was gone).
  /// Returns how many were deleted.
  int sweep({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var n = 0;
    try {
      final dir = Directory(root);
      if (!dir.existsSync()) return 0;
      for (final e in dir.listSync(followLinks: false)) {
        try {
          // A symlink has no business here: removed (the link, not what it points to).
          if (e is Link || e.statSync().modified.isBefore(cutoff)) {
            e.deleteSync(recursive: e is Directory);
            n++;
          }
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('staging sweep: $e');
    }
    return n;
  }

  /// A new folder with a random name for one copy, inside the 0700 staging folder.
  Directory _newItemDir() {
    final now = DateTime.now();
    if (_sweptAt == null || now.difference(_sweptAt!) > const Duration(hours: 1)) {
      _sweptAt = now;
      sweep(now: now);
    }
    return _ensureRoot().createTempSync('');
  }

  /// The staging folder itself, 0700 (only this user can look inside). A symlink or a file in its place is refused:
  /// the copies would land somewhere else.
  Directory _ensureRoot() {
    final dir = Directory(root);
    var type = FileSystemEntity.typeSync(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      dir.createSync(recursive: true);
      type = FileSystemEntity.typeSync(root, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) throw FileSystemException('not a folder', root);
    // dart:io creates folders with the umask's mode and has no chmod: set it once, when it is not 0700 yet.
    if (dir.statSync().mode & 0x3F != 0) {
      final r = Process.runSync('/bin/chmod', ['700', root]);
      if (r.exitCode != 0) throw FileSystemException('chmod 700: ${r.stderr}', root);
    }
    return dir;
  }

  static void _delete(Directory? dir) {
    try {
      if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('staging cleanup: $e');
    }
  }

  static String _baseName(String path, String fallback) {
    final name = path.split('/').last.replaceAll('\u0000', '');
    return name.isEmpty || name == '.' || name == '..' ? fallback : name;
  }
}

/// The name of a pasted or dropped image: `image-2026-10-05-140322.png` (local time, ISO date). A random suffix is
/// not needed: every copy has its own folder.
String stagedImageName(DateTime t, {String ext = 'png'}) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'image-${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
}
