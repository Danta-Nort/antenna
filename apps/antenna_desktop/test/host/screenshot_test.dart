// SPDX-License-Identifier: AGPL-3.0-only
// Screenshots for Code mode agents on the real file system (host/screenshot.dart, D-UI-27): which system tool is used
// and with which arguments; the window's private folder per agent; only a PNG the window wrote under its own name in
// that folder becomes a [WindowScreenshot]; a path a terminal paste could misread is not pasteable; old files go.

import 'dart:io';

import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/screenshot.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_pty.dart' show FakeCapture, fakePng;

ProgramLocator _programs(Set<String> installed, {Map<String, String> env = const {'HOME': '/home/owner'}}) =>
    ProgramLocator(
      windows: false,
      env: {...env, 'PATH': '/usr/bin'},
      isExecutable: installed.contains,
      readFile: (_) => null,
    );

void main() {
  group('the system tool', () {
    final calls = <(String, List<String>)>[];
    Future<ProcessResult> run(String exe, List<String> args, {required Duration timeout}) async {
      calls.add((exe, args));
      if (exe.endsWith('slurp')) return ProcessResult(1, 0, '10,20 300x200\n', '');
      File(args.last).writeAsBytesSync(fakePng);
      return ProcessResult(1, 0, '', '');
    }

    setUp(calls.clear);

    test('macOS: screencapture -i (an area, Space for a window)', () async {
      final t = SystemScreenCapture.detect(_programs({}),
          env: const {}, macos: true, exists: (p) => p == '/usr/sbin/screencapture', run: run)!;
      expect(t.name, 'screencapture');
      final dir = Directory.systemTemp.createTempSync('antenna-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await t.capture('${dir.path}/a.png'), isTrue);
      expect(calls.single.$1, '/usr/sbin/screencapture');
      expect(calls.single.$2, ['-i', '-o', '-x', '-t', 'png', '${dir.path}/a.png']);
      expect(SystemScreenCapture.detect(_programs({}), env: const {}, macos: true, exists: (_) => false), isNull);
    });

    test('Linux: the first desktop tool found; X11 and Wayland tools only with their display; none: no button', () {
      expect(SystemScreenCapture.detect(_programs({'/usr/bin/gnome-screenshot', '/usr/bin/scrot'}), env: const {}, macos: false)!.name,
          'gnome-screenshot');
      expect(SystemScreenCapture.detect(_programs({'/usr/bin/scrot'}), env: const {}, macos: false), isNull,
          reason: 'scrot needs an X display');
      expect(SystemScreenCapture.detect(_programs({'/usr/bin/scrot'}), env: const {'DISPLAY': ':0'}, macos: false)!.name,
          'scrot');
      expect(SystemScreenCapture.detect(_programs({'/usr/bin/grim'}), env: const {'WAYLAND_DISPLAY': 'wayland-0'}, macos: false),
          isNull, reason: 'grim needs slurp to pick the area');
      expect(SystemScreenCapture.detect(_programs({}), env: const {'DISPLAY': ':0'}, macos: false), isNull);
    });

    test('Linux grim + slurp: only a geometry goes on grim\'s command line', () async {
      final dir = Directory.systemTemp.createTempSync('antenna-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = SystemScreenCapture.detect(_programs({'/usr/bin/grim', '/usr/bin/slurp'}),
          env: const {'WAYLAND_DISPLAY': 'wayland-0'}, macos: false, run: run)!;
      expect(await t.capture('${dir.path}/b.png'), isTrue);
      expect(calls.last.$1, '/usr/bin/grim');
      expect(calls.last.$2, ['-g', '10,20 300x200', '${dir.path}/b.png']);
      // Anything else from slurp (an error, a cancel, something injected) ends the capture.
      Future<ProcessResult> evil(String exe, List<String> args, {required Duration timeout}) async =>
          ProcessResult(1, 0, exe.endsWith('slurp') ? '0,0 1x1; rm -rf ~\n' : '', '');
      final t2 = SystemScreenCapture.detect(_programs({'/usr/bin/grim', '/usr/bin/slurp'}),
          env: const {'WAYLAND_DISPLAY': 'wayland-0'}, macos: false, run: evil)!;
      expect(await t2.capture('${dir.path}/c.png'), isFalse);
    });
  });

  group('the store', () {
    late Directory home;
    late ScreenshotStore store;
    setUp(() {
      home = Directory.systemTemp.createTempSync('antenna-shots-');
      store = ScreenshotStore.forEnv({'HOME': home.path, 'XDG_CACHE_HOME': '${home.path}/.cache'}, macos: false)!;
    });
    tearDown(() => home.deleteSync(recursive: true));

    test('where: Caches on macOS (no space in the path), XDG cache on Linux', () {
      expect(ScreenshotStore.forEnv({'HOME': '/Users/sam'}, macos: true)!.root, '/Users/sam/Library/Caches/Antenna/screenshots');
      expect(ScreenshotStore.forEnv({'HOME': '/home/sam'}, macos: false)!.root, '/home/sam/.cache/antenna/screenshots');
      expect(ScreenshotStore.forEnv({}, macos: false), isNull);
    });

    test('a capture: a PNG under the window\'s name in the agent\'s private folder, pasteable', () async {
      final shot = await store.capture('claude-dev', FakeCapture(), now: DateTime(2026, 10, 5, 14, 3, 22));
      expect(shot.path, '${store.root}/claude-dev/screenshot-20261005-140322.png');
      expect(shot.pasteable, isTrue);
      expect((FileStat.statSync(store.root).mode & 0x1ff).toRadixString(8), '700');
      expect((FileStat.statSync('${store.root}/claude-dev').mode & 0x1ff).toRadixString(8), '700');
      final again = await store.capture('claude-dev', FakeCapture(), now: DateTime(2026, 10, 5, 14, 3, 22));
      expect(again.path, endsWith('screenshot-20261005-140322-2.png'), reason: 'never over an earlier one');
      expect(AllowedLine.screenshot(shot)!.text, shot.path);
      expect(AllowedLine.screenshot(shot)!.paste, isTrue);
    });

    test('cancelled: nothing left; not a PNG: refused and removed', () async {
      await expectLater(store.capture('a', FakeCapture(cancel: true)),
          throwsA(isA<ScreenshotException>().having((e) => e.reason, 'reason', ScreenshotFailure.cancelled)));
      final cap = FakeCapture(bytes: '#!/bin/sh\nrm -rf ~\n'.codeUnits);
      await expectLater(store.capture('a', cap),
          throwsA(isA<ScreenshotException>().having((e) => e.reason, 'reason', ScreenshotFailure.rejected)));
      expect(File(cap.paths.single).existsSync(), isFalse);
    });

    test('only the window\'s own files pass the check: other names, other folders, links', () async {
      final dir = store.ensureFolder('a')!;
      File('$dir/notes.png').writeAsBytesSync(fakePng);
      File('${home.path}/screenshot-20261005-140322.png').writeAsBytesSync(fakePng);
      Link('$dir/screenshot-20261005-140323.png').createSync('${home.path}/screenshot-20261005-140322.png');
      File('${store.ensureFolder('b')}/screenshot-20261005-140324.png').writeAsBytesSync(fakePng);
      for (final p in [
        '$dir/notes.png',
        '${home.path}/screenshot-20261005-140322.png',
        '$dir/screenshot-20261005-140323.png',
        '${store.root}/b/screenshot-20261005-140324.png',
        '$dir/../a/screenshot-20261005-140322.png',
      ]) {
        expect(() => store.check(p, 'a'), throwsA(isA<ScreenshotException>()), reason: p);
      }
      File('$dir/screenshot-20261005-140325.png').writeAsBytesSync(fakePng);
      expect(store.check('$dir/screenshot-20261005-140325.png', 'a').path, '$dir/screenshot-20261005-140325.png');
    });

    test('a home folder with a space: kept, but not pasteable', () async {
      final spaced = ScreenshotStore('${home.path}/My Files/screenshots');
      final shot = await spaced.capture('a', FakeCapture());
      expect(shot.pasteable, isFalse);
      expect(AllowedLine.screenshot(shot), isNull);
    });

    test('agent names that cannot be folders get a fixed one', () {
      expect(store.folderFor('..'), '${store.root}/_agent');
      expect(store.folderFor('a/b'), '${store.root}/_agent');
      expect(store.folderFor('claude.dev_1-x'), '${store.root}/claude.dev_1-x');
    });

    test('screenshots older than a day are deleted', () async {
      final old = await store.capture('a', FakeCapture(), now: DateTime(2026, 10, 1));
      // Age the file against the same fixed clock the sweep uses below (DateTime(2026, 10, 5)), not the wall clock:
      // `now` and the file mtime must come from one clock, or the test flips at local midnight.
      File(old.path).setLastModifiedSync(DateTime(2026, 10, 5).subtract(const Duration(days: 2)));
      final fresh = await store.capture('a', FakeCapture(), now: DateTime(2026, 10, 5));
      expect(File(old.path).existsSync(), isFalse, reason: 'swept before the next capture');
      expect(File(fresh.path).existsSync(), isTrue);
    });
  });
}
