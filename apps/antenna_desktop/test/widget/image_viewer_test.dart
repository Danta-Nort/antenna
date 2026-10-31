// SPDX-License-Identifier: AGPL-3.0-only
// The full-screen viewer (D-UI-46): the bar names the picture; zoom by keys and buttons; Previous and Next by keys;
// Save as…, Copy and Show in Finder act on the picture shown (the safe preview) or on the saved file, and only offer
// what this computer has. Rules under test are in each test's reason.

import 'dart:io';

import 'package:antenna_desktop/host/image_actions.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app_scope.dart';
import 'package:antenna_desktop/ui/files/image_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';
import '../support/png.dart';
import 'chat_media_test.dart' show FakeImageActions;

final en = l10nFor('en');

/// Real file I/O and the fake daemon's replies both move: pump the test's own zone and let real time pass.
Future<void> _until(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await t.pump();
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.pump();
    final images = t.widgetList<Image>(find.byType(Image)).toList();
    await t.runAsync(() async {
      for (final img in images) {
        await precacheImage(img.image, t.element(find.byWidget(img)));
      }
    });
  }
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  late FakeDaemon d;
  late AppModel m;
  late FakeImageActions actions;
  late FileInfo saved;
  late FileInfo preview;
  late Directory dir;

  Future<void> open(WidgetTester t, FileInfo f) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // As in the app: the model above the root navigator the viewer is pushed on.
    await t.pumpWidget(AppScope(
      model: m,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () => showImageViewer(context, [viewerImageOf(saved), viewerImageOf(preview)],
                  initialIndex: f == saved ? 0 : 1),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('open')));
    await _settle(t);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('antenna-viewer-');
    d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    final path = '${dir.path}/harbor.png';
    File(path).writeAsBytesSync(plainPng(300, 200, rgb: 0x112233));
    saved = demoFile(1,
        from: buildBot,
        name: 'harbor.png',
        size: 4096,
        mime: 'image/png',
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        savedPath: path,
        at: ago(minutes: 2));
    preview = demoFile(2,
        from: emily, name: 'whiteboard.jpg', size: 8192, mime: 'image/jpeg', state: 'checked', verdict: 'clean',
        at: ago(minutes: 1));
    for (final f in [saved, preview]) {
      d.fileMap[f.id] = f;
      d.previewMap[f.id] = FilePreview(kind: 'image', imagesPng: [plainPng(200, 100)]);
    }
    actions = FakeImageActions();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> model() async {
    m = AppModel(
        connector: (_) => d,
        socketPath: d.socketPath,
        live: false,
        clock: () => fixedNow,
        appLauncher: FakeAppLauncher());
    await m.connect();
    final before = ImageActions.instance;
    ImageActions.instance = actions;
    addTearDown(() => ImageActions.instance = before);
  }

  testWidgets('the bar names the picture; a saved file offers Open, Show in Finder, Save as… and Copy', (t) async {
    await model();
    await open(t, saved);
    expect(find.byKey(const Key('image-viewer-name')), findsOneWidget);
    expect(find.text('harbor.png'), findsOneWidget);
    expect(find.text(en.filesImageOf(1, 2)), findsOneWidget);
    for (final a in ['open', 'reveal', 'saveAs', 'copyImage']) {
      expect(find.byKey(Key('image-viewer-$a')), findsOneWidget, reason: a);
    }
    await t.tap(find.byKey(const Key('image-viewer-reveal')));
    await t.pump();
    expect(actions.revealed, [saved.savedPath]);
    final copy = '${dir.path}/copy.png';
    actions.saveTo = copy;
    await t.tap(find.byKey(const Key('image-viewer-saveAs')));
    await _until(t, () => File(copy).existsSync() && File(copy).lengthSync() > 0);
    expect(File(copy).readAsBytesSync(), File(saved.savedPath!).readAsBytesSync(),
        reason: 'the saved file itself, not the preview');
    await t.tap(find.byKey(const Key('image-viewer-copyImage')));
    await t.pump();
    expect(actions.copied.single, plainPng(200, 100), reason: 'the picture shown: the safe preview');
  });

  testWidgets('a picture not saved here: no Open or Show in Finder; Save as… saves the picture as a PNG', (t) async {
    await model();
    await open(t, preview);
    expect(find.byKey(const Key('image-viewer-open')), findsNothing, reason: 'nothing on this computer to open');
    expect(find.byKey(const Key('image-viewer-reveal')), findsNothing);
    final to = '${dir.path}/whiteboard.png';
    actions.saveTo = to;
    await t.tap(find.byKey(const Key('image-viewer-saveAs')));
    await _until(t, () => File(to).existsSync() && File(to).lengthSync() > 0);
    expect(actions.saveAsked, ['whiteboard.png'], reason: 'the picture is a PNG: its name says so');
    expect(File(to).readAsBytesSync(), plainPng(200, 100));
  });

  testWidgets('keys: arrows move, + and − zoom, 0 fits, Escape closes', (t) async {
    await model();
    await open(t, saved);
    final zoom = find.byKey(const Key('image-viewer-zoom'));
    double scale() => t.widget<InteractiveViewer>(zoom).transformationController!.value.getMaxScaleOnAxis();
    expect(scale(), 1);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.pump();
    expect(scale(), closeTo(1.5, 0.01));
    expect(find.text('150 %'), findsOneWidget);
    await t.tap(find.byKey(const Key('image-viewer-zoom-in')));
    await t.pump();
    expect(scale(), closeTo(2.25, 0.01));
    await t.sendKeyEvent(LogicalKeyboardKey.minus);
    await t.pump();
    expect(scale(), closeTo(1.5, 0.01));
    await t.sendKeyEvent(LogicalKeyboardKey.digit0);
    await t.pump();
    expect(scale(), 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(t);
    expect(find.text(en.filesImageOf(2, 2)), findsOneWidget);
    expect(find.text('whiteboard.jpg'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _settle(t);
    expect(find.text(en.filesImageOf(1, 2)), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 10 && find.byKey(const Key('image-viewer-name')).evaluate().isNotEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('image-viewer-name')), findsNothing);
  });
}
