// SPDX-License-Identifier: AGPL-3.0-only
// How a chat's files are sorted and grouped for showing them (D-UI-46): pictures, text and other files; a picture's
// size from its header; albums of pictures sent together; name search; a short path for "Saved to …". Pure functions
// over the daemon's `FileInfo`: no I/O, no Flutter.

import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/x_control.dart';

/// What a file is for the Media and files views and the Files screen's filters.
enum MediaKind {
  /// A picture the window shows from its safe preview (received) or its preview copy (sent).
  image,

  /// Text, code, markup, data: shown as a one-line snippet.
  text,

  /// Anything else: a row with its type icon.
  file,
}

/// Text by type, apart from `text/*`: data and markup formats the check reads as text.
const _textMimes = {
  'application/json',
  'application/xml',
  'application/x-yaml',
  'application/yaml',
  'application/toml',
  'application/javascript',
  'application/x-sh',
  'application/sql',
  'image/svg+xml',
};

/// Text by name, when no type is known yet (before the check).
final _textName = RegExp(
    r'\.(txt|md|markdown|csv|tsv|json|jsonl|ya?ml|toml|xml|html?|css|js|ts|tsx|jsx|dart|rs|py|go|java|kt|swift'
    r'|c|h|cc|cpp|hpp|rb|php|sh|zsh|sql|log|ini|cfg|conf|env|svg)$',
    caseSensitive: false);

/// The kind of [f]: by the check's type once known, the sender's claim and the name before that. An SVG is text (the
/// check shows its source, never renders it).
MediaKind mediaKindOf(FileInfo f) {
  final m = f.mime ?? f.senderMime;
  if (_textMimes.contains(m) || m.startsWith('text/') || f.fileClass == 'code' || f.fileClass == 'text') {
    return MediaKind.text;
  }
  if (m.startsWith('image/')) return MediaKind.image;
  if (m.isEmpty && _textName.hasMatch(f.name)) return MediaKind.text;
  return MediaKind.file;
}

/// The files among [files] whose name holds [query] (ignoring case; empty: all) and of [kind] (`null`: any), newest
/// first.
List<FileInfo> searchFiles(Iterable<FileInfo> files, {String query = '', MediaKind? kind}) {
  final q = query.trim().toLowerCase();
  return [
    for (final f in files)
      if ((kind == null || mediaKindOf(f) == kind) && (q.isEmpty || f.name.toLowerCase().contains(q))) f,
  ]..sort((a, b) => b.createdMs.compareTo(a.createdMs));
}

/// Pictures sent one after another within this time join one album (the window sends an album as one file each).
const albumGap = Duration(minutes: 2);

/// The most pictures in one album (as Telegram's).
const albumMax = 10;

/// [next] continues the album [prev] ends with: both pictures, both sent or both received, close in time.
bool joinsAlbum(FileInfo prev, FileInfo next) =>
    mediaKindOf(prev) == MediaKind.image &&
    mediaKindOf(next) == MediaKind.image &&
    prev.direction == next.direction &&
    (next.createdMs - prev.createdMs).abs() <= albumGap.inMilliseconds;

/// How an album of [n] pictures is laid out: the number of pictures in each row, top to bottom. One row for two, a
/// wide picture over two for three, then rows of two and three with the fuller rows at the bottom.
List<int> albumRows(int n) {
  if (n <= 0) return const [];
  if (n <= 2) return [n];
  if (n == 3) return const [1, 2];
  if (n == 4) return const [2, 2];
  final threes = n ~/ 3;
  return switch (n % 3) {
    0 => List.filled(threes, 3),
    1 => [2, 2, ...List.filled(threes - 1, 3)],
    _ => [2, ...List.filled(threes, 3)],
  };
}

/// The pixel size from the header of a PNG or a JPEG (the daemon's previews are PNG, the window's preview copies PNG;
/// a JPEG for completeness), without decoding; `null` for anything else.
(int, int)? imageSizeOf(Uint8List b) {
  // PNG: the signature, then IHDR's width and height.
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    final d = ByteData.sublistView(b);
    final w = d.getUint32(16);
    final h = d.getUint32(20);
    return w > 0 && h > 0 ? (w, h) : null;
  }
  // JPEG: walk the markers to the first start of frame.
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      final sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (sof) {
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return w > 0 && h > 0 ? (w, h) : null;
      }
      if (len < 2) return null;
      i += 2 + len;
    }
  }
  return null;
}

/// A picture of [size] drawn inline at most [maxW] × [maxH] logical pixels, not enlarged past its own size and not
/// smaller than [minSide] on its shorter side (a thin strip stays tappable): its aspect ratio kept where it fits.
(double, double) inlineSize((int, int)? size, {double maxW = 320, double maxH = 320, double minSide = 96}) {
  if (size == null) return (maxW * 0.75, maxW * 0.56);
  final (w, h) = size;
  final k = math.min(1.0, math.min(maxW / w, maxH / h));
  var dw = w * k;
  var dh = h * k;
  if (dw < minSide && dh < minSide) {
    final up = minSide / math.max(dw, dh);
    dw *= up;
    dh *= up;
  }
  return (dw.clamp(minSide / 2, maxW), dh.clamp(minSide / 2, maxH));
}

/// [path] for a line such as "Saved to ~/Desktop/report.pdf": the home folder as `~`.
String shortPath(String path, {String? home}) {
  if (home != null && home.length > 1 && (path == home || path.startsWith('$home/'))) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

/// The first line of [text] with something in it, trimmed, at most [max] characters: a text file's one-line snippet.
String? snippetOf(String? text, {int max = 140}) {
  if (text == null) return null;
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return t.length <= max ? t : '${t.substring(0, max - 1)}…';
  }
  return null;
}
