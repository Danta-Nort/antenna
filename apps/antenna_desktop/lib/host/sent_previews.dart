// SPDX-License-Identifier: AGPL-3.0-only
// The window's own preview copies of the images it sent. An image's bubble on the sender's side used to read the
// original file again, and a macOS screenshot dragged from its floating thumbnail is a temporary file that is gone a
// moment later (as are a pasted image's and a file promise's staged copies, which `OutgoingStaging` deletes once the
// daemon has them): the bubble said "Couldn't show the preview image" (TROUBLESHOOTING "The sender's own image").
// Every messenger keeps its own copy of what it sent; this is that copy, made the way the window already makes a
// picture it hands on (the profile photo, `photo_crop.dart`): the bytes that were sent are decoded by the engine,
// scaled down to at most [SentPreviews.maxSide] pixels on the longer side, and encoded again as a PNG. Only pixels
// survive: no EXIF, location, camera, comments or colour profile chunks of the original, and nothing of it is ever
// opened as anything but an image. The original path is never needed after the send.
//
// Where: macOS ~/Library/Application Support/Antenna/sent-previews, Linux $XDG_CACHE_HOME/antenna/sent-previews
// (~/.cache/antenna/sent-previews): the window's folder, next to `outgoing`, 0700, never inside the daemon's data
// directory. One PNG per file, `<link id>/<file id>.png`, so a link's previews go with its history when the contact is
// removed with it. Bounded: an input over [SentPreviews.maxInput] or over [SentPreviews.maxPixels] gets no preview
// (its card shows without a picture), a preview older than [SentPreviews.maxAge] is deleted, and the folder is kept
// under [SentPreviews.maxTotal], oldest first.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The bytes of [image] decoded and encoded again as a PNG of at most [maxSide] pixels on its longer side (the first
/// frame of an animation): pixels only. `null` when the engine cannot decode it, it is empty, or it has more than
/// [maxPixels] pixels (a decompression bomb is refused before anything is decoded: the size comes from the header).
Future<Uint8List?> rebuildImagePreview(Uint8List image,
    {int maxSide = SentPreviews.maxSide, int maxPixels = SentPreviews.maxPixels}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? desc;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(image);
    desc = await ui.ImageDescriptor.encoded(buffer);
    final w = desc.width, h = desc.height;
    if (w <= 0 || h <= 0 || w * h > maxPixels) return null;
    final k = maxSide / math.max(w, h);
    codec = k < 1
        ? await desc.instantiateCodec(
            targetWidth: math.max(1, (w * k).round()), targetHeight: math.max(1, (h * k).round()))
        : await desc.instantiateCodec();
    frame = (await codec.getNextFrame()).image;
    final png = await frame.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } on Object catch (e) {
    debugPrint('sent preview: $e');
    return null;
  } finally {
    frame?.dispose();
    codec?.dispose();
    desc?.dispose();
    buffer?.dispose();
  }
}

/// The first bytes of a file are an image format the engine decodes (PNG, JPEG, GIF, WebP, BMP, HEIF/AVIF, TIFF), or
/// its [name] says so: only such a file is read whole for a preview. The decoder decides in the end; this only keeps
/// the window from reading every document it sends.
bool looksLikeImage(List<int> head, {String? name}) {
  bool at(int offset, List<int> magic) =>
      head.length >= offset + magic.length && [for (var i = 0; i < magic.length; i++) head[offset + i]].join(',') == magic.join(',');
  if (at(0, [0x89, 0x50, 0x4E, 0x47]) || at(0, [0xFF, 0xD8, 0xFF]) || at(0, [0x47, 0x49, 0x46, 0x38])) return true;
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return true;
  if (at(0, [0x42, 0x4D]) || at(4, [0x66, 0x74, 0x79, 0x70])) return true;
  if (at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A])) return true;
  return name != null && RegExp(r'\.(png|jpe?g|gif|webp|bmp|heic|heif|avif|tiff?)$', caseSensitive: false).hasMatch(name);
}

/// The window's folder of preview copies of sent images (see the file's header).
class SentPreviews {
  SentPreviews(String root,
      {this.maxAge = const Duration(days: 30), this.maxTotal = 256 << 20, DateTime Function()? clock})
      : root = root.endsWith('/') && root.length > 1 ? root.substring(0, root.length - 1) : root,
        _clock = clock ?? DateTime.now;

  /// The longer side of a preview: enough for the full-screen viewer on a laptop, a fraction of a Retina screenshot.
  static const maxSide = 1600;

  /// The largest file the window reads to make a preview (the profile photo has the same limit).
  static const maxInput = 32 << 20;

  /// The largest picture decoded (about 8000 × 8000).
  static const maxPixels = 64 << 20;

  /// The window's folder (replaced in tests; `null` without a home directory).
  static SentPreviews? instance = SentPreviews.forEnv(Platform.environment);

  static SentPreviews? forEnv(Map<String, String> env, {bool? macos}) {
    final home = env['HOME'] ?? '';
    if (home.isEmpty) return null;
    if (macos ?? Platform.isMacOS) return SentPreviews('$home/Library/Application Support/Antenna/sent-previews');
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.startsWith('/')) ? xdg : '$home/.cache';
    return SentPreviews('$base/antenna/sent-previews');
  }

  final String root;
  final Duration maxAge;
  final int maxTotal;
  final DateTime Function() _clock;
  DateTime? _sweptAt;

  /// Link and file IDs are the daemon's hex IDs; anything else never becomes a path.
  static final _id = RegExp(r'^[0-9a-f]{1,128}$');

  String? _path(String linkId, String fileId) =>
      _id.hasMatch(linkId) && _id.hasMatch(fileId) ? '$root/$linkId/$fileId.png' : null;

  /// A preview of [fileId] sent on [linkId] is kept here.
  bool has(String linkId, String fileId) {
    final p = _path(linkId, fileId);
    return p != null && FileSystemEntity.typeSync(p, followLinks: false) == FileSystemEntityType.file;
  }

  /// The kept preview, or `null` (none, or it cannot be read).
  Future<Uint8List?> read(String linkId, String fileId) async {
    final p = _path(linkId, fileId);
    if (p == null || FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.file) return null;
    try {
      return await File(p).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Make and keep the preview of [image], the bytes the window sent as [fileId] on [linkId]. `false` when it cannot
  /// be decoded or written (the card then shows without a picture).
  Future<bool> keep(String linkId, String fileId, Uint8List image) async {
    if (_path(linkId, fileId) == null || image.length > maxInput) return false;
    final png = await rebuildImagePreview(image);
    return png != null && store(linkId, fileId, png);
  }

  /// Write [png] (already rebuilt) as the preview of [fileId]: a temporary file, then a rename, so a reader never sees
  /// half of it.
  bool store(String linkId, String fileId, Uint8List png) {
    final p = _path(linkId, fileId);
    if (p == null) return false;
    try {
      _sweepSometimes();
      final dir = _ensureDir('$root/$linkId');
      final tmp = File('${dir.path}/.$fileId.${_clock().microsecondsSinceEpoch}.tmp');
      tmp.writeAsBytesSync(png, flush: true);
      tmp.renameSync(p);
      return true;
    } on Object catch (e) {
      debugPrint('sent preview: $e');
      return false;
    }
  }

  /// The previews of a link whose history was deleted with it.
  void forgetLink(String linkId) {
    if (!_id.hasMatch(linkId)) return;
    final dir = Directory('$root/$linkId');
    try {
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) == FileSystemEntityType.directory) {
        dir.deleteSync(recursive: true);
      }
    } on FileSystemException catch (e) {
      debugPrint('sent preview cleanup: $e');
    }
  }

  void _sweepSometimes() {
    final now = _clock();
    if (_sweptAt != null && now.difference(_sweptAt!) < const Duration(hours: 1)) return;
    _sweptAt = now;
    sweep(now: now);
  }

  /// Delete previews older than [maxAge], then the oldest until the folder is under [maxTotal]; anything that is not
  /// a link folder of previews (a symlink, a stray file) goes too. Returns how many files were deleted.
  int sweep({DateTime? now}) {
    final cutoff = (now ?? _clock()).subtract(maxAge);
    var n = 0;
    final kept = <(File, DateTime, int)>[];
    try {
      final top = Directory(root);
      if (FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.directory) return 0;
      for (final link in top.listSync(followLinks: false)) {
        if (link is! Directory || !_id.hasMatch(link.path.split('/').last)) {
          _delete(link);
          n++;
          continue;
        }
        for (final e in link.listSync(followLinks: false)) {
          final st = e.statSync();
          if (e is! File || st.modified.isBefore(cutoff)) {
            _delete(e);
            n++;
          } else {
            kept.add((e, st.modified, st.size));
          }
        }
        if (link.listSync().isEmpty) link.deleteSync();
      }
    } on FileSystemException catch (e) {
      debugPrint('sent preview sweep: $e');
    }
    var total = kept.fold<int>(0, (a, k) => a + k.$3);
    kept.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _, size) in kept) {
      if (total <= maxTotal) break;
      _delete(f);
      total -= size;
      n++;
    }
    return n;
  }

  static void _delete(FileSystemEntity e) {
    try {
      e.deleteSync(recursive: e is Directory);
    } on FileSystemException catch (err) {
      debugPrint('sent preview cleanup: $err');
    }
  }

  /// A folder of [path]'s, created 0700 with the root; a symlink or a file in the way is refused (the copies would land
  /// somewhere else).
  Directory _ensureDir(String path) {
    for (final p in [root, path]) {
      var type = FileSystemEntity.typeSync(p, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(p).createSync(recursive: true);
        type = FileSystemEntity.typeSync(p, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) throw FileSystemException('not a folder', p);
    }
    // dart:io creates folders with the umask's mode and has no chmod: set it once, when it is not 0700 yet.
    if (Directory(root).statSync().mode & 0x3F != 0) {
      final r = Process.runSync('/bin/chmod', ['700', root]);
      if (r.exitCode != 0) throw FileSystemException('chmod 700: ${r.stderr}', root);
    }
    return Directory(path);
  }
}
