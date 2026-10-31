// SPDX-License-Identifier: AGPL-3.0-only
// Inline image thumbnails on a file card, and the full-screen viewer they open. The security rule under test: an
// incoming image's thumbnail is only ever the daemon's safe preview (CONTROL §14's rebuilt pixels), only once the
// file has actually been checked — never a byte of the original, never before `file_preview` would even have an
// answer. An outgoing image shows the window's own preview copy of the bytes it sent, never the original path.

import 'dart:io';

import 'package:antenna_desktop/host/image_actions.dart';
import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/host/sent_previews.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app_scope.dart';
import 'package:antenna_desktop/ui/files/file_card.dart';
import 'package:antenna_desktop/ui/files/image_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';
import '../support/png.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

/// A minimal host for the widget under test: just `AppScope` and localizations, no window chrome.
Future<void> _host(WidgetTester t, AppModel m, Widget child) async {
  await t.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AppScope(model: m, child: Material(child: Center(child: SizedBox(width: 300, child: child)))),
  ));
}

/// `Image.memory`/`Image.file` decode outside FakeAsync (CONTRIBUTING.md: a frame inside FakeAsync never sees them finish).
Future<void> _decode(WidgetTester t) async {
  await t.pump();
  final images = t.widgetList<Image>(find.byType(Image)).toList();
  await t.runAsync(() async {
    for (final i in images) {
      await precacheImage(i.image, t.element(find.byWidget(i)));
    }
  });
  await t.pump();
}

Finder _thumb(String id) => find.byKey(Key('image-thumb-${id.substring(0, 8)}'));

void main() {
  testWidgets('a sent screenshot keeps its own preview after the original file is gone', (t) async {
    // The maintainer's case: a macOS screenshot dragged from its floating thumbnail is a temporary file that macOS
    // deletes right after the drop; the window's staged copy is deleted once the daemon has the file. The bubble must
    // show the window's own preview copy, rebuilt from the bytes that were sent, with none of the original's metadata.
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final dir = Directory.systemTemp.createTempSync('antenna-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final original = '${dir.path}/Screenshot 2026-10-06 at 21.53.00.png';
    final shot = (await t.runAsync(() => pngWithText(3200, 2000, 'Location', 'Fifth Avenue 203')))!;
    File(original).writeAsBytesSync(shot);

    final staged = (await t.runAsync(() => OutgoingStaging.instance!.stageFile(original)))!;
    expect(staged.owned, isTrue);
    File(original).deleteSync();
    m.stageAttachment(jordan.linkId, staged);
    expect(await t.runAsync(() => m.sendStaged(jordan.linkId)), isTrue);
    final sent = m.files.values.firstWhere((f) => f.direction == 'out' && f.linkId == jordan.linkId);
    expect(d.sharedContent[staged.path], shot, reason: 'the daemon read the staged copy');
    expect(File(staged.path).existsSync(), isFalse, reason: 'the staged copy is gone after the send');
    expect(File(original).existsSync(), isFalse, reason: 'and so is the original');

    expect(m.hasSentPreview(sent), isTrue);
    final kept = (await t.runAsync(() => m.sentPreviewBytes(sent)))!;
    expect(String.fromCharCodes(kept).contains('Fifth Avenue'), isFalse, reason: 'pixels only, no text chunk');
    final size = (await t.runAsync(() => pngSize(kept)))!;
    expect(size, (SentPreviews.maxSide, 1000), reason: 'bounded: the longer side scaled to the limit');

    // The thumbnail shows exactly the kept copy (seeded into the cache: a read started in initState does not
    // complete inside a pumped frame, see primeImageBytesForTest).
    primeImageBytesForTest(sent.id, kept);
    await _host(t, m, FileCard(sent));
    await _decode(t);
    expect(_thumb(sent.id), findsOneWidget);
    expect(find.text(en.filesPreviewImageError), findsNothing);
    expect(d.calls, isNot(contains('file_preview')), reason: 'an outgoing image never asks for a safe preview');
  });

  testWidgets('a sent image without a preview copy (an agent sent it) reads like any other file', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final f = demoFile(97,
        from: jordan, direction: 'out', name: 'chart.png', size: 4096, mime: 'image/png', state: 'sent', at: ago(minutes: 1));
    expect(m.hasSentPreview(f), isFalse);
    await _host(t, m, FileCard(f));
    await t.pump();
    expect(_thumb(f.id), findsNothing);
    expect(find.text(en.filesPreviewImageError), findsNothing, reason: 'no broken picture: the card has no thumbnail');
    expect(find.text('chart.png'), findsOneWidget);
  });

  testWidgets('removing a contact with its history removes the previews of what was sent there', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final f = demoFile(98,
        from: jordan, direction: 'out', name: 'a.png', size: 4096, mime: 'image/png', state: 'sent', at: ago(minutes: 1));
    expect(SentPreviews.instance!.store(f.linkId, f.id, previewPagePng()), isTrue);
    expect(m.hasSentPreview(f), isTrue);
    expect(await t.runAsync(() => m.revoke(jordan.linkId, PasswordAuth(d.password), deleteHistory: true)), isNull);
    expect(SentPreviews.instance!.has(f.linkId, f.id), isFalse);
    expect(m.hasSentPreview(f), isFalse);
  });

  // Whatever the reason a received picture cannot be shown (a file accepted by preview.8 or earlier has no preview
  // left; a threat has none), the card must not shout about it in a large box, and the file must stay usable: its
  // type icon, name and size, Open and Show in Finder.
  testWidgets('no picture to show: no box, the card keeps its icon, Open and Show in Finder work', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final launcher = FakeAppLauncher();
    final revealed = _RevealOnly();
    final before = ImageActions.instance;
    ImageActions.instance = revealed;
    addTearDown(() => ImageActions.instance = before);
    final m = AppModel(
        connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, appLauncher: launcher);
    await m.connect();
    final dir = Directory.systemTemp.createTempSync('antenna-img-none-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final saved = '${dir.path}/volna-logo-1024.png';
    File(saved).writeAsBytesSync([1, 2, 3]);
    final f = demoFile(95,
        from: emily,
        name: 'volna-logo-1024.png',
        size: 3,
        mime: 'image/png',
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        savedPath: saved,
        at: ago(minutes: 1));
    d.fileMap[f.id] = f; // and no preview: accepted by an older daemon, which deleted it
    final id = f.id.substring(0, 8);

    await _host(t, m, SingleChildScrollView(child: FileCard(f)));
    await t.pump();
    await t.pump();
    expect(d.calls, contains('file_preview'));
    expect(find.byKey(Key('image-none-$id')), findsOneWidget);
    expect(find.text(en.filesPreviewImageError), findsNothing, reason: 'no box saying the preview failed');
    expect(find.byIcon(Icons.image_outlined), findsOneWidget, reason: 'the type icon of the card');
    await t.tap(find.byKey(Key('file-open-$id')));
    await t.pump();
    expect(launcher.opened, [(saved, null)]);
    await t.tap(find.byKey(Key('file-reveal-$id')));
    await t.pump();
    expect(revealed.paths, [saved]);

    // The saved file is gone: no Open for a path that is not there.
    File(saved).deleteSync();
    await _host(t, m, SingleChildScrollView(child: FileCard(f, key: const Key('again'))));
    await t.pump();
    expect(find.byKey(Key('file-open-$id')), findsNothing);
  });

  testWidgets('an incoming image before the check: no thumbnail, "Preview after the check", no file_preview call',
      (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    for (final state in ['offered', 'downloaded']) {
      final f = demoFile(90 + state.length,
          from: emily, name: 'photo.png', size: 2048, mime: 'image/png', state: state, at: ago(minutes: 1));
      // Deliberately no `previewMap` entry: if the widget asked for one anyway before the check, the daemon would
      // happily answer and this test would not catch the mistake — the real guard is `d.calls`, below.
      await _host(t, m, ImageThumbnail(f));
      await t.pump();
      expect(d.calls, isNot(contains('file_preview')), reason: '$state: not checked yet, no safe preview exists');
      expect(find.text(en.filesImagePendingCheck), findsOneWidget, reason: state);
      expect(_thumb(f.id), findsNothing, reason: state);
    }
  });

  testWidgets('an incoming image once checked: the thumbnail is exactly the safe preview, nothing else', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final f = demoFile(91,
        from: emily, name: 'photo.png', size: 2048, mime: 'image/png', state: 'checked', verdict: 'clean', at: ago(minutes: 1));
    d.fileMap[f.id] = f;
    d.previewMap[f.id] = FilePreview(kind: 'image', imagesPng: [previewPagePng()]);

    await _host(t, m, ImageThumbnail(f));
    await _decode(t);
    expect(d.calls, contains('file_preview'));
    expect(find.text(en.filesImagePendingCheck), findsNothing);
    expect(_thumb(f.id), findsOneWidget);
  });

  testWidgets('an incoming image already decided (accepted) still shows the safe preview', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final f = demoFile(92,
        from: emily,
        name: 'photo.png',
        size: 2048,
        mime: 'image/png',
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        at: ago(minutes: 1));
    d.fileMap[f.id] = f;
    d.previewMap[f.id] = FilePreview(kind: 'image', imagesPng: [previewPagePng()]);

    await _host(t, m, ImageThumbnail(f));
    await _decode(t);
    expect(_thumb(f.id), findsOneWidget);
  });

  testWidgets('the viewer opens on tap, shows the count, closes on Escape and on a tap', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final f1 = demoFile(93,
        from: emily, name: 'one.png', size: 2048, mime: 'image/png', state: 'checked', verdict: 'clean', at: ago(minutes: 2));
    final f2 = demoFile(94,
        from: emily, name: 'two.png', size: 2048, mime: 'image/png', state: 'checked', verdict: 'clean', at: ago(minutes: 1));
    d.fileMap[f1.id] = f1;
    d.fileMap[f2.id] = f2;
    d.previewMap[f1.id] = FilePreview(kind: 'image', imagesPng: [previewPagePng()]);
    d.previewMap[f2.id] = FilePreview(kind: 'image', imagesPng: [previewPagePng()]);

    await _host(t, m, ImageThumbnail(f1, gallery: [f1, f2]));
    await _decode(t);
    await t.tap(_thumb(f1.id));
    await _decode(t);
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.byKey(const Key('image-viewer-close')), findsOneWidget);
    expect(find.text(en.filesImageOf(1, 2)), findsOneWidget);
    expect(find.byKey(const Key('image-viewer-next')), findsOneWidget);
    expect(find.byKey(const Key('image-viewer-prev')), findsNothing, reason: 'already at the first image');

    await t.tap(find.byKey(const Key('image-viewer-next')));
    await _decode(t);
    expect(find.text(en.filesImageOf(2, 2)), findsOneWidget);
    expect(find.byKey(const Key('image-viewer-next')), findsNothing, reason: 'already at the last image');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byType(ImageViewer), findsNothing, reason: 'Escape closes it');

    await t.tap(_thumb(f1.id));
    await _decode(t);
    expect(find.byType(ImageViewer), findsOneWidget);
    // A tap on the picture itself keeps it open (zooming and panning should not close it by accident); a tap beside
    // it closes, as a click outside a picture does in a messenger.
    await t.tap(find.byType(InteractiveViewer));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byType(ImageViewer), findsOneWidget, reason: 'a tap on the picture does not close it');
    await t.tapAt(t.getBottomLeft(find.byKey(const Key('image-viewer-background'))) + const Offset(8, -8));
    for (var i = 0; i < 10 && find.byType(ImageViewer).evaluate().isNotEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ImageViewer), findsNothing, reason: 'a tap beside the picture closes it');
  });
}

/// Records Show in Finder; nothing else is used here.
class _RevealOnly implements ImageActions {
  final paths = <String>[];

  @override
  Future<bool> reveal(String path) async {
    paths.add(path);
    return true;
  }

  @override
  Future<bool> copyPng(Uint8List png) async => false;

  @override
  Future<String?> saveLocation(String suggestedName) async => null;
}
