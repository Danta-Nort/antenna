// SPDX-License-Identifier: AGPL-3.0-only
// Pictures and files waiting in the composer (D-UI-46): a picture is a square of the picture itself, a file a chip; a
// click or Space opens a picture in the viewer over the composer's pictures; dragging reorders them, and the new order
// is the order they are sent in (so the album's); ✕ removes one. Rules under test are in each test's reason.

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/chat/attachments.dart';
import 'package:antenna_desktop/ui/files/image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';
import '../support/png.dart';

final en = l10nFor('en');

List<String> _order(WidgetTester t) => [
      for (final w in t.widgetList(find.byWidgetPredicate((w) => w is AttachmentChip || w is AttachmentTile)))
        w is AttachmentTile ? w.a.name : (w as AttachmentChip).a.name,
    ];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('antenna-staged-'));
  tearDown(() => dir.deleteSync(recursive: true));

  String file(String name, List<int> bytes) {
    final p = '${dir.path}/$name';
    File(p).writeAsBytesSync(bytes);
    return p;
  }

  Future<(AppModel, FakeDaemon)> app(WidgetTester t, List<String> paths) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    await m.select(jordan.linkId);
    for (final p in paths) {
      m.stageAttachment(jordan.linkId, StagedFile(p));
    }
    // The squares read their files: loaded into the image cache outside FakeAsync before the frame (a load a frame
    // starts inside FakeAsync never completes while `runAsync` waits).
    await t.runAsync(() async {
      for (final p in paths.where((p) => p.endsWith('.png'))) {
        final done = Completer<void>();
        ResizeImage(FileImage(File(p)), width: 144).resolve(ImageConfiguration.empty).addListener(ImageStreamListener(
            (_, _) => done.isCompleted ? null : done.complete(),
            onError: (e, s) => done.isCompleted ? null : done.completeError(e, s)));
        await done.future;
      }
    });
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    return (m, d);
  }

  testWidgets('a picture is a square of the picture; a click opens the viewer over the composer\'s pictures',
      (t) async {
    final one = file('one.png', plainPng(120, 80));
    final notes = file('notes.txt', 'hello'.codeUnits);
    final two = file('two.png', plainPng(80, 120, rgb: 0xFF9800));
    final (m, _) = await app(t, [one, notes, two]);
    final staged = m.stagedOf(jordan.linkId);
    expect(find.byType(AttachmentTile), findsNWidgets(2));
    expect(find.byType(AttachmentChip), findsOneWidget, reason: 'the text file is a chip');
    expect(t.getSize(find.byKey(Key('attachment-${staged[0].id}'))), const Size(72, 72));

    await t.tap(find.byKey(Key('attachment-open-${staged[2].id}')));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.text(en.filesImageOf(2, 2)), findsOneWidget, reason: 'the second of the two pictures, not the text');
    expect(find.text('two.png'), findsOneWidget);
    expect(find.byKey(const Key('image-viewer-saveAs')), findsNothing, reason: 'nothing sent yet: no file actions');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 10 && find.byType(ImageViewer).evaluate().isNotEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    // Space on a focused picture opens it too (the keyboard path).
    Focus.of(t.element(find.byKey(Key('attachment-thumb-${staged[0].id}')))).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.filesImageOf(1, 2)), findsOneWidget);
    expect(find.text('one.png'), findsOneWidget);
  });

  testWidgets('dragging changes the order, and the files go in that order', (t) async {
    final a = file('a.png', plainPng(60, 60));
    final b = file('b.pdf', List.filled(300, 1));
    final c = file('c.png', plainPng(60, 60, rgb: 0x00AA55));
    final (m, d) = await app(t, [a, b, c]);
    expect(_order(t), ['a.png', 'b.pdf', 'c.png']);
    final first = m.stagedOf(jordan.linkId).first;
    // Drag a.png past the other two, slowly, as a mouse does.
    final g = await t.startGesture(t.getCenter(find.byKey(Key('attachment-${first.id}'))));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(20, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(_order(t), ['b.pdf', 'c.png', 'a.png']);
    expect(m.stagedOf(jordan.linkId).map((x) => x.name), ['b.pdf', 'c.png', 'a.png']);

    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.shared.map((p) => p.split('/').last), ['b.pdf', 'c.png', 'a.png'], reason: 'sent in the new order');
  });

  testWidgets('✕ on a picture removes it; one file left needs no order hint', (t) async {
    final a = file('a.png', plainPng(60, 60));
    final b = file('b.png', plainPng(60, 60, rgb: 0x123456));
    final (m, d) = await app(t, [a, b]);
    expect(find.textContaining(en.composerAttachmentsOrder), findsOneWidget);
    await t.tap(find.byKey(Key('attachment-remove-${m.stagedOf(jordan.linkId).first.id}')));
    await t.pump();
    expect(_order(t), ['b.png']);
    expect(find.textContaining(en.composerAttachmentsOrder), findsNothing);
    expect(d.shared, isEmpty);
  });
}
