// SPDX-License-Identifier: AGPL-3.0-only
// The window's preview copies of sent images (host/sent_previews.dart): rebuilt from the bytes as pixels only and
// bounded, kept under the link and file IDs only, removed with the link, after their age and over the folder's size.

import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/host/sent_previews.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/png.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('antenna-previews-'));
  tearDown(() => dir.deleteSync(recursive: true));

  const link = 'a1b2c3d4';
  const file = '00ff00ff00ff00ff';

  test('a preview is the picture again as a bounded PNG without the original metadata', () async {
    final s = SentPreviews('${dir.path}/p');
    final src = await pngWithText(2400, 1200, 'Comment', 'GPS 40.7128 N');
    expect(String.fromCharCodes(src).contains('GPS 40.7128'), isTrue, reason: 'the fixture carries the chunk');
    expect(await s.keep(link, file, src), isTrue);
    final kept = (await s.read(link, file))!;
    expect(String.fromCharCodes(kept).contains('GPS 40.7128'), isFalse);
    expect(await pngSize(kept), (SentPreviews.maxSide, 800));
    expect(Directory('${dir.path}/p').statSync().mode & 0x1FF, 0x1C0, reason: 'the folder is 0700');
  });

  test('a small picture keeps its size; something that is not a picture gets no preview', () async {
    final s = SentPreviews('${dir.path}/p');
    expect(await s.keep(link, file, await pngWithText(64, 48, 'k', 'v')), isTrue);
    expect(await pngSize((await s.read(link, file))!), (64, 48));
    expect(await s.keep(link, 'abcdef01', Uint8List.fromList('%PDF-1.7 not a picture'.codeUnits)), isFalse);
    expect(s.has(link, 'abcdef01'), isFalse);
  });

  test('a picture over the pixel limit is refused from its header, before decoding', () async {
    final png = await pngWithText(300, 300, 'k', 'v');
    expect(await rebuildImagePreview(png, maxPixels: 300 * 300 - 1), isNull);
    expect(await rebuildImagePreview(png, maxPixels: 300 * 300), isNotNull);
  });

  test('only hex IDs become paths', () async {
    final s = SentPreviews('${dir.path}/p');
    final png = await pngWithText(8, 8, 'k', 'v');
    for (final (l, f) in [('../x', file), (link, '../../etc'), (link, 'A1'), ('', file)]) {
      expect(s.store(l, f, png), isFalse, reason: '$l/$f');
      expect(s.has(l, f), isFalse);
    }
    expect(Directory('${dir.path}/p').existsSync(), isFalse, reason: 'nothing was written');
  });

  test('a link removed with its history takes its previews along', () async {
    final s = SentPreviews('${dir.path}/p');
    final png = await pngWithText(8, 8, 'k', 'v');
    expect(s.store(link, file, png) && s.store('beef', file, png), isTrue);
    s.forgetLink(link);
    expect(s.has(link, file), isFalse);
    expect(s.has('beef', file), isTrue, reason: 'another link keeps its own');
  });

  test('the sweep removes old previews, strays and symlinks, then the oldest above the size limit', () async {
    var now = DateTime(2026, 10, 6, 12);
    final target = Directory('${dir.path}/elsewhere')..createSync();
    File('${target.path}/keep.txt').writeAsStringSync('not ours');
    final s = SentPreviews('${dir.path}/p', maxAge: const Duration(days: 30), maxTotal: 3000, clock: () => now);
    final png = Uint8List(1000);
    for (final (i, id) in ['01', '02', '03'].indexed) {
      expect(s.store(link, id, png), isTrue);
      File('${dir.path}/p/$link/$id.png').setLastModifiedSync(now.subtract(Duration(days: 40 - i * 15)));
    }
    File('${dir.path}/p/stray.txt').writeAsStringSync('x');
    Link('${dir.path}/p/cafe').createSync(target.path);
    expect(s.sweep(now: now), 3, reason: 'the 40-day-old preview, the stray file and the symlink');
    expect([for (final id in ['01', '02', '03']) s.has(link, id)], [false, true, true]);
    expect(File('${target.path}/keep.txt').existsSync(), isTrue, reason: 'the symlink was removed, not followed');

    expect(s.store(link, '04', png) && s.store(link, '05', png), isTrue);
    now = now.add(const Duration(minutes: 1));
    expect(s.sweep(now: now), 1, reason: '4000 bytes over a 3000-byte limit: the oldest goes');
    expect([for (final id in ['02', '03', '04', '05']) s.has(link, id)], [false, true, true, true]);
  });
}
