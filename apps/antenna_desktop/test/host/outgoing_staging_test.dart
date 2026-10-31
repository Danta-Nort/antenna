// SPDX-License-Identifier: AGPL-3.0-only
// The window's staging folder for outgoing copies: where it is (never inside the daemon's data directory), 0700
// folders, a copy that survives the source being deleted right after the drop, what is not copied, cleanup.

import 'dart:io';

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/host/window_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

int _mode(String path) => FileStat.statSync(path).mode & 0x1FF;

void main() {
  late Directory tmp;
  late OutgoingStaging staging;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('staging-test-');
    staging = OutgoingStaging('${tmp.path}/outgoing');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File source(String name, String text) => File('${tmp.path}/$name')..writeAsStringSync(text);

  group('where', () {
    test('macOS: Application Support of the window; Linux: the cache folder', () {
      expect(OutgoingStaging.forEnv({'HOME': '/Users/ana'}, macos: true)!.root,
          '/Users/ana/Library/Application Support/Antenna/outgoing');
      expect(OutgoingStaging.forEnv({'HOME': '/home/ana'}, macos: false)!.root, '/home/ana/.cache/antenna/outgoing');
      expect(OutgoingStaging.forEnv({'HOME': '/home/ana', 'XDG_CACHE_HOME': '/var/cache/ana'}, macos: false)!.root,
          '/var/cache/ana/antenna/outgoing');
      expect(OutgoingStaging.forEnv({}, macos: false), isNull);
    });

    test('never inside the daemon data directory, whose files share_file refuses', () {
      for (final macos in [true, false]) {
        final root = OutgoingStaging.forEnv({'HOME': '/home/ana'}, macos: macos)!.root;
        expect(root.startsWith('/home/ana/.local/share/antenna'), isFalse, reason: root);
      }
    });

    test('owns only <root>/<folder>/<name>', () {
      final r = staging.root;
      expect(staging.owns('$r/ab12/shot.png'), isTrue);
      expect(staging.owns('$r/shot.png'), isFalse);
      expect(staging.owns('$r/ab12/x/shot.png'), isFalse);
      expect(staging.owns('$r/../ab12/shot.png'), isFalse);
      expect(staging.owns('$r/ab12/..'), isFalse);
      expect(staging.owns('${r}x/ab12/shot.png'), isFalse);
      expect(staging.owns('/home/ana/shot.png'), isFalse);
    });
  });

  group('stageFile', () {
    test('a file deleted right after the drop is still copied (opened before the first await)', () async {
      final shot = source('Screenshot 2026-10-05 at 14.03.22.png', 'png bytes');
      final pending = staging.stageFile(shot.path);
      // macOS removes the screenshot thumbnail's temporary file as soon as the drop ends.
      shot.deleteSync();
      final s = await pending;
      expect(s.owned, isTrue);
      expect(s.origin, shot.path);
      expect(s.path, endsWith('/Screenshot 2026-10-05 at 14.03.22.png'), reason: 'the contact sees the same name');
      expect(staging.owns(s.path), isTrue);
      expect(File(s.path).readAsStringSync(), 'png bytes');
      expect(_mode(staging.root), 0x1C0, reason: 'the staging folder is 0700');
      expect(File(s.path).parent.parent.path, staging.root, reason: 'each copy has a folder of its own');
    });

    test('a file deleted 100 ms after the drop: the copy has its content', () async {
      final f = source('notes.txt', 'n' * 300000);
      final pending = staging.stageFile(f.path);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      f.deleteSync();
      final s = await pending;
      expect(File(s.path).lengthSync(), 300000);
    });

    test('not copied: a missing file, a folder, a file over the limit, a copy made here', () async {
      final missing = await staging.stageFile('${tmp.path}/gone.png');
      expect(missing.owned, isFalse);
      expect(missing.path, '${tmp.path}/gone.png');
      final folder = await staging.stageFile(tmp.path);
      expect(folder.owned, isFalse);
      final small = OutgoingStaging('${tmp.path}/small', copyLimit: 4);
      final big = await small.stageFile(source('big.bin', '12345').path);
      expect(big.owned, isFalse, reason: 'large files are sent from where they are');
      final copy = await staging.stageFile(source('a.txt', 'a').path);
      final again = await staging.stageFile(copy.path);
      expect(again.owned, isTrue);
      expect(again.path, copy.path, reason: 'the macOS drop view already staged it');
      expect(Directory(staging.root).listSync(), hasLength(1));
    });

    test('a staging folder made with a looser mode is set back to 0700', () async {
      Directory(staging.root).createSync(recursive: true);
      Process.runSync('/bin/chmod', ['755', staging.root]);
      await staging.stageFile(source('a.txt', 'a').path);
      expect(_mode(staging.root), 0x1C0);
    });

    test('a symlink in place of the staging folder is refused: the original is sent', () async {
      final elsewhere = Directory('${tmp.path}/elsewhere')..createSync();
      Link(staging.root).createSync(elsewhere.path);
      final s = await staging.stageFile(source('a.txt', 'a').path);
      expect(s.owned, isFalse);
      expect(elsewhere.listSync(), isEmpty);
    });
  });

  group('stageBytes and cleanup', () {
    test('image data becomes a file; release removes it and its folder, nothing else', () {
      final s = staging.stageBytes([1, 2, 3], 'image-2026-10-05-140322.png')!;
      expect(s.owned, isTrue);
      expect(File(s.path).readAsBytesSync(), [1, 2, 3]);
      final folder = File(s.path).parent;
      staging.release(s.path);
      expect(File(s.path).existsSync(), isFalse);
      expect(folder.existsSync(), isFalse);
      final mine = source('mine.txt', 'keep');
      staging.release(mine.path);
      expect(mine.existsSync(), isTrue, reason: 'only copies in the staging folder are deleted');
    });

    test('a folder with two promised files: release of one keeps the other', () {
      final dir = Directory('${staging.root}/promise')..createSync(recursive: true);
      final a = File('${dir.path}/a.jpg')..writeAsStringSync('a');
      final b = File('${dir.path}/b.jpg')..writeAsStringSync('b');
      staging.release(a.path);
      expect(b.existsSync(), isTrue);
      staging.release(b.path);
      expect(dir.existsSync(), isFalse);
    });

    test('sweep removes copies older than a day', () {
      final s = staging.stageBytes([1], 'image.png')!;
      expect(staging.sweep(), 0, reason: 'a fresh copy stays');
      expect(staging.sweep(now: DateTime.now().add(const Duration(days: 2))), 1);
      expect(File(s.path).existsSync(), isFalse);
    });

    test('a name never leaves its folder', () {
      final s = staging.stageBytes([1], '../../escape.png')!;
      expect(staging.owns(s.path), isTrue);
      expect(s.path, endsWith('/escape.png'));
      expect(staging.stageBytes([1], '')!.path, endsWith('/image.png'));
    });

    test('stagedImageName: ISO date and time', () {
      expect(stagedImageName(DateTime(2026, 10, 5, 14, 3, 22)), 'image-2026-10-05-140322.png');
    });
  });

  group('the macOS drop view messages', () {
    setUp(() => OutgoingStaging.instance = staging);

    test('parsed into events; only paths inside the staging folder are the window\'s to delete', () {
      expect(WindowDrop.parse(const MethodCall('entered', [10.0, 20.0])),
          isA<WindowDragOver>().having((e) => e.position, 'position', const Offset(10, 20)));
      expect(WindowDrop.parse(const MethodCall('exited')), isA<WindowDragExit>());
      final e = WindowDrop.parse(MethodCall('dropped', {
        'x': 5.0,
        'y': 6.0,
        'items': [
          {'path': '${staging.root}/f1/shot.png', 'staged': true},
          {'path': '/Users/ana/Desktop/report.pdf', 'staged': true},
          {'path': '/Users/ana/big.mov', 'staged': false},
          {'path': ''},
          'junk',
        ],
        'failed': 1,
      }))! as WindowDropped;
      expect(e.items.map((i) => (i.path, i.owned)), [
        ('${staging.root}/f1/shot.png', true),
        ('/Users/ana/Desktop/report.pdf', false),
        ('/Users/ana/big.mov', false),
      ]);
      expect(e.failed, 1);
      expect(WindowDrop.parse(const MethodCall('dropped', 'junk')), isNull);
      expect(WindowDrop.parse(const MethodCall('unknown')), isNull);
    });

    test('a drop nobody takes (outside the conversation): the copies are deleted', () async {
      final s = staging.stageBytes([1], 'image.png')!;
      await WindowDrop.instance.handle(MethodCall('dropped', {
        'x': 1.0,
        'y': 1.0,
        'items': [
          {'path': s.path, 'staged': true},
        ],
      }));
      expect(File(s.path).existsSync(), isFalse);
    });
  });
}
