// SPDX-License-Identifier: AGPL-3.0-only
// Files in the conversation as a messenger shows them (D-UI-46): a picture is the picture at its own aspect ratio,
// with its name only on hover and a badge only when there is something to say; pictures sent together form an album;
// any other file is a compact row whose click opens it and whose menu has Open, Show in Finder, Save as… and Copy path;
// Copy puts the picture shown on the clipboard, never the file. The rules under test are in each test's reason.

import 'dart:io';

import 'package:antenna_desktop/host/image_actions.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/media.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/app_scope.dart';
import 'package:antenna_desktop/ui/chat/chat_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';
import '../support/png.dart';

final en = l10nFor('en');

/// Records what the viewer and the menus ask of this computer.
class FakeImageActions implements ImageActions {
  final copied = <Uint8List>[];
  final revealed = <String>[];
  String? saveTo;
  final saveAsked = <String>[];

  @override
  Future<bool> copyPng(Uint8List png) async {
    copied.add(png);
    return true;
  }

  @override
  Future<String?> saveLocation(String suggestedName) async {
    saveAsked.add(suggestedName);
    return saveTo;
  }

  @override
  Future<bool> reveal(String path) async {
    revealed.add(path);
    return true;
  }
}

String _k(FileInfo f) => f.id.substring(0, 8);

/// A received picture from an own computer (∞): accepted by the daemon at once, its safe preview [png].
FileInfo _picture(FakeDaemon d, int seed, Uint8List png, {DateTime? at, String? name}) {
  final f = demoFile(seed,
      from: buildBot,
      name: name ?? 'logo-$seed.png',
      size: png.length,
      mime: 'image/png',
      state: 'accepted',
      verdict: 'clean',
      dest: 'shared',
      at: at ?? ago(minutes: 3));
  d.fileMap[f.id] = f;
  d.previewMap[f.id] = FilePreview(kind: 'image', imagesPng: [png]);
  return f;
}

Future<(AppModel, FakeImageActions, FakeAppLauncher)> _model(FakeDaemon d) async {
  final launcher = FakeAppLauncher();
  final m = AppModel(
      connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, appLauncher: launcher);
  await m.connect();
  final actions = FakeImageActions();
  final before = ImageActions.instance;
  ImageActions.instance = actions;
  addTearDown(() => ImageActions.instance = before);
  return (m, actions, launcher);
}

Future<void> _host(WidgetTester t, AppModel m, Widget child) async {
  t.view.physicalSize = const Size(1000, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AppScope(model: m, child: Scaffold(body: Center(child: SizedBox(width: 600, child: child)))),
  ));
}

/// Pictures decode outside FakeAsync (CONTRIBUTING.md, Dart and Flutter).
Future<void> _decode(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.pump();
    final images = t.widgetList<Image>(find.byType(Image)).toList();
    await t.runAsync(() async {
      for (final img in images) {
        await precacheImage(img.image, t.element(find.byWidget(img)));
      }
    });
  }
  await t.pump();
}

void main() {
  testWidgets('a received picture is the picture itself, at its aspect ratio; the name only on hover; no card',
      (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final (m, _, _) = await _model(d);
    final f = _picture(d, 1, plainPng(200, 100));
    await _host(t, m, FileRow(f, outgoing: false));
    await _decode(t);

    final box = t.getSize(find.byKey(Key('chat-picture-${_k(f)}')));
    expect(box, const Size(200, 100), reason: 'its own size and aspect ratio, nothing around it');
    expect(find.byKey(Key('file-${_k(f)}')), findsNothing, reason: 'not the old card with the name under the picture');
    expect(find.text(f.name), findsNothing, reason: 'the name is not printed under the picture');
    expect(find.byKey(Key('chat-picture-badge-${_k(f)}')), findsNothing, reason: 'saved and clean: nothing to say');

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.byKey(Key('chat-picture-${_k(f)}'))));
    await t.pump();
    expect(find.byKey(Key('chat-picture-caption-${_k(f)}')), findsOneWidget);
    expect(find.textContaining(f.name), findsOneWidget, reason: 'the name and size on hover');
  });

  testWidgets('a large picture is bounded and keeps its shape; a labelled one has a small badge', (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final (m, _, _) = await _model(d);
    final wide = _picture(d, 2, plainPng(1600, 400));
    final tall = _picture(d, 3, plainPng(300, 1200));
    final labelled = demoFile(4,
        from: buildBot,
        name: 'chart.png',
        size: 100,
        mime: 'image/png',
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        labels: ['polyglot_html'],
        at: ago(minutes: 1));
    d.fileMap[labelled.id] = labelled;
    d.previewMap[labelled.id] = FilePreview(kind: 'image', imagesPng: [plainPng(64, 64)]);
    await _host(
        t,
        m,
        Column(children: [
          FileRow(wide, outgoing: false),
          FileRow(tall, outgoing: false),
          FileRow(labelled, outgoing: false),
        ]));
    await _decode(t);
    expect(t.getSize(find.byKey(Key('chat-picture-${_k(wide)}'))), const Size(320, 80));
    expect(t.getSize(find.byKey(Key('chat-picture-${_k(tall)}'))), const Size(80, 320));
    expect(find.byKey(Key('chat-picture-badge-${_k(labelled)}')), findsOneWidget);
  });

  testWidgets('pictures sent one after another form one album; a tile opens the viewer at it', (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final pics = [
      for (var i = 0; i < 3; i++)
        _picture(d, 10 + i, plainPng(120 + i * 10, 90), at: ago(minutes: 5).add(Duration(seconds: i * 5))),
    ];
    final later = _picture(d, 20, plainPng(80, 80), at: ago(minutes: 1));
    d.historyMap[buildBot.linkId] = [
      for (var i = 0; i < pics.length; i++) fileMsg(50 + i, pics[i], ago(minutes: 5).add(Duration(seconds: i * 5))),
      fileMsg(60, later, ago(minutes: 1)),
    ];
    final (m, _, _) = await _model(d);
    await m.select(buildBot.linkId);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await _decode(t);

    expect(find.byKey(Key('chat-album-${_k(pics.first)}')), findsOneWidget, reason: 'one album for the three');
    for (final p in pics) {
      expect(find.byKey(Key('chat-picture-${_k(p)}')), findsOneWidget);
    }
    expect(find.byKey(Key('chat-album-${_k(later)}')), findsNothing,
        reason: 'four minutes later: a picture of its own');
    expect(find.byKey(Key('chat-picture-box-${_k(later)}')), findsOneWidget);
    // The album's tiles share its width: three pictures are one wide over two.
    final top = t.getSize(find.byKey(Key('chat-picture-${_k(pics[0])}')));
    final second = t.getSize(find.byKey(Key('chat-picture-${_k(pics[1])}')));
    expect(top.width, 320);
    expect(second.width, 159);

    await t.tap(find.byKey(Key('chat-picture-${_k(pics[1])}')));
    await _decode(t);
    expect(find.text(en.filesImageOf(2, 4)), findsOneWidget, reason: 'at that picture, among all the chat\'s pictures');
  });

  testWidgets('a file is one compact row; a click opens it; the menu opens, reveals, saves and copies its path',
      (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final (m, actions, launcher) = await _model(d);
    final dir = Directory.systemTemp.createTempSync('antenna-row-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final saved = '${dir.path}/Q3 report.pdf';
    File(saved).writeAsBytesSync(List.generate(5000, (i) => i & 0xff));
    final f = demoFile(30,
        from: buildBot,
        name: 'Q3 report.pdf',
        size: 5000,
        mime: 'application/pdf',
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        savedPath: saved,
        at: ago(minutes: 2));
    d.fileMap[f.id] = f;
    await _host(t, m, FileRow(f, outgoing: false));
    await t.pump();

    final row = find.byKey(Key('file-row-${_k(f)}'));
    expect(row, findsOneWidget);
    expect(t.getSize(row).height, lessThan(80), reason: 'compact: a row, not a card');
    expect(find.byKey(Key('file-${_k(f)}')), findsNothing);
    expect(find.text(en.filesRowSaved), findsOneWidget);
    expect(find.byKey(Key('file-saved-to-${_k(f)}')), findsOneWidget);

    await t.tap(row);
    await t.pump();
    expect(launcher.opened.single.$1, saved, reason: 'a click opens it with its app');

    await t.tap(find.byKey(Key('file-saved-reveal-${_k(f)}')));
    await t.pump();
    expect(actions.revealed, [saved]);

    // The right-click menu: the actions of a file on this computer; no Copy image for a file that is not a picture.
    await t.tap(row, buttons: kSecondaryMouseButton);
    await t.pumpAndSettle();
    for (final a in ['open', 'reveal', 'saveAs', 'copyPath', 'preview']) {
      expect(find.byKey(Key('file-menu-$a')), findsOneWidget, reason: a);
    }
    expect(find.byKey(Key('file-menu-copyImage')), findsNothing);
    final copy = '${dir.path}/copy.pdf';
    actions.saveTo = copy;
    await t.tap(find.byKey(const Key('file-menu-saveAs')));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      for (var i = 0; i < 50 && !File(copy).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(actions.saveAsked, ['Q3 report.pdf']);
    expect(File(copy).readAsBytesSync(), File(saved).readAsBytesSync(), reason: 'Save as… copies the saved file');

    String? clip;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.tap(find.byKey(Key('file-more-${_k(f)}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('file-menu-copyPath')));
    await t.pumpAndSettle();
    expect(clip, saved);
  });

  testWidgets('Copy image puts the picture shown on the clipboard: the safe preview, never the file', (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final (m, actions, _) = await _model(d);
    final preview = plainPng(40, 30);
    final f = _picture(d, 40, preview);
    await _host(t, m, FileRow(f, outgoing: false));
    await _decode(t);
    await t.tap(find.byKey(Key('chat-picture-${_k(f)}')), buttons: kSecondaryMouseButton);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('file-menu-copyImage')), findsOneWidget);
    expect(find.byKey(const Key('file-menu-open')), findsNothing, reason: 'the saved file is not on this computer');
    await t.tap(find.byKey(const Key('file-menu-copyImage')));
    await t.pumpAndSettle();
    expect(actions.copied.single, preview);
  });

  testWidgets('a picture with no preview to show is a row with its actions, not an empty box', (t) async {
    final d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final (m, _, _) = await _model(d);
    final f = demoFile(50,
        from: buildBot, name: 'old.png', size: 10, mime: 'image/png', state: 'accepted', verdict: 'clean',
        dest: 'shared', at: ago(minutes: 1));
    d.fileMap[f.id] = f; // accepted by an older daemon: no preview kept
    await _host(t, m, FileRow(f, outgoing: false));
    await t.pump();
    await t.pump();
    expect(find.byKey(Key('chat-picture-none-${_k(f)}')), findsOneWidget);
    expect(find.text('old.png'), findsOneWidget);
    expect(find.text(en.filesPreviewImageError), findsNothing);
  });

  test('albums: rows of a grid, the time gap, the direction', () {
    expect([for (var n = 1; n <= 10; n++) albumRows(n)], [
      [1], [2], [1, 2], [2, 2], [2, 3], [3, 3], [2, 2, 3], [2, 3, 3], [3, 3, 3], [2, 2, 3, 3], //
    ]);
    for (var n = 1; n <= 10; n++) {
      expect(albumRows(n).fold<int>(0, (a, b) => a + b), n);
    }
    FileInfo pic(int seed, String name, int minutes, {String direction = 'in'}) => demoFile(seed,
        from: emily,
        direction: direction,
        name: name,
        size: 1,
        mime: 'image/png',
        state: 'accepted',
        at: ago(minutes: minutes));
    final a = pic(1, 'a.png', 5);
    final b = pic(2, 'b.png', 4);
    final c = pic(3, 'c.png', 1);
    final out = pic(4, 'd.png', 4, direction: 'out');
    final pdf = demoFile(5,
        from: emily, name: 'e.pdf', size: 1, mime: 'application/pdf', state: 'accepted', at: ago(minutes: 4));
    expect(joinsAlbum(a, b), isTrue);
    expect(joinsAlbum(b, c), isFalse, reason: 'three minutes apart');
    expect(joinsAlbum(a, out), isFalse, reason: 'sent and received never mix');
    expect(joinsAlbum(a, pdf), isFalse);
    expect(imageSizeOf(plainPng(7, 3)), (7, 3));
    expect(imageSizeOf(Uint8List.fromList([1, 2, 3])), isNull);
    expect(shortPath('/Users/alex/Desktop/a.pdf', home: '/Users/alex'), '~/Desktop/a.pdf');
    expect(shortPath('/Users/alexander/a.pdf', home: '/Users/alex'), '/Users/alexander/a.pdf');
    expect(snippetOf('\n\n  # Title  \nbody'), '# Title');
  });
}
