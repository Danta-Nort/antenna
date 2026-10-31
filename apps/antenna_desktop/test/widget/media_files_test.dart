// SPDX-License-Identifier: AGPL-3.0-only
// A chat's Media and files (D-UI-46): opened from the conversation's header, its menu and the contact card; Images as a
// grid, Files and Text as rows, newest first; a search by name; in a chat with an agent, that chat's files first and
// everything with the contact one click away. Rules under test are in each test's reason.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';
import '../support/png.dart';

final en = l10nFor('en');

String _k(FileInfo f) => f.id.substring(0, 8);

/// Within the dialog only: the conversation behind it shows the same files.
Finder _in(String key) => find.descendant(of: find.byKey(const Key('media-dialog')), matching: find.byKey(Key(key)));

FileInfo _f(int seed, String name, String mime, int minutes) => demoFile(seed,
    from: jordan,
    name: name,
    size: 1000 + seed,
    mime: mime,
    state: 'accepted',
    verdict: 'clean',
    dest: 'shared',
    at: ago(minutes: minutes));

void main() {
  late FakeDaemon d;
  late FileInfo chart, photo, report, notes, agentLog;

  setUp(() {
    d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    chart = _f(1, 'chart-q3.png', 'image/png', 50);
    photo = _f(2, 'team-photo.jpg', 'image/jpeg', 40);
    report = _f(3, 'Q3 report.pdf', 'application/pdf', 30);
    notes = _f(4, 'notes.md', 'text/markdown', 20);
    agentLog = _f(5, 'build.log', 'text/plain', 10);
    for (final f in [chart, photo, report, notes, agentLog]) {
      d.fileMap[f.id] = f;
    }
    d.previewMap[chart.id] = FilePreview(kind: 'image', imagesPng: [plainPng(80, 60)]);
    d.previewMap[photo.id] = FilePreview(kind: 'image', imagesPng: [plainPng(60, 80, rgb: 0xAA5500)]);
    d.historyMap[jordan.linkId] = [
      ...?d.historyMap[jordan.linkId],
      fileMsg(80, chart, ago(minutes: 50)),
      fileMsg(81, photo, ago(minutes: 40)),
      fileMsg(82, report, ago(minutes: 30)),
      fileMsg(83, notes, ago(minutes: 20)),
      // The contact's agent sent this one in its own chat.
      fileMsg(84, agentLog, ago(minutes: 10), viaAgent: 'claude-backend'),
    ]..sort((a, b) => a.seq.compareTo(b.seq));
  });

  Future<AppModel> app(WidgetTester t) async {
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    await m.select(jordan.linkId);
    // The person chat (the demo opens the agent's, whose message is the latest).
    m.showThread(jordan.linkId, ThreadKey.person);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    return m;
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('from the header: images as a grid, files and text as rows, newest first; the search narrows by name',
      (t) async {
    await app(t);
    await t.tap(find.byKey(const Key('chat-media')));
    await settle(t);
    expect(find.byKey(const Key('media-dialog')), findsOneWidget);
    expect(find.text(en.mediaTabImages(2)), findsOneWidget);
    expect(find.text(en.mediaTabFiles(1)), findsOneWidget);
    expect(find.text(en.mediaTabText(2)), findsOneWidget,
        reason: 'notes.md and the agent\'s log: everything with Jordan');
    expect(_in('picture-square-${_k(chart)}'), findsOneWidget);
    expect(_in('picture-square-${_k(photo)}'), findsOneWidget);
    // Newest first: the photo before the chart.
    expect(t.getTopLeft(_in('picture-square-${_k(photo)}')).dx,
        lessThan(t.getTopLeft(_in('picture-square-${_k(chart)}')).dx));

    await t.tap(find.byKey(const Key('media-tab-text')));
    await settle(t);
    expect(_in('file-row-${_k(notes)}'), findsOneWidget);
    expect(_in('file-row-${_k(agentLog)}'), findsOneWidget);
    expect(t.getTopLeft(_in('file-row-${_k(agentLog)}')).dy,
        lessThan(t.getTopLeft(_in('file-row-${_k(notes)}')).dy));

    await t.enterText(find.byKey(const Key('media-search')), 'NOTES');
    await settle(t);
    expect(find.text(en.mediaTabImages(0)), findsOneWidget);
    expect(find.text(en.mediaTabText(1)), findsOneWidget, reason: 'by name, ignoring case');
    expect(_in('file-row-${_k(agentLog)}'), findsNothing);
    await t.tap(find.byKey(const Key('media-tab-images')));
    await settle(t);
    expect(find.text(en.mediaNoMatch('NOTES')), findsOneWidget);
  });

  testWidgets('in a chat with an agent: that chat\'s files, and all with the contact one click away', (t) async {
    final m = await app(t);
    m.showThread(jordan.linkId, ThreadKey.agent('claude-backend'));
    await settle(t);
    await t.tap(find.byKey(const Key('chat-media')));
    await settle(t);
    expect(find.text(en.mediaTabText(1)), findsOneWidget, reason: 'only the agent chat\'s log');
    expect(find.text(en.mediaTabImages(0)), findsOneWidget);
    await t.tap(find.byKey(const Key('media-scope-all')));
    await settle(t);
    expect(find.text(en.mediaTabImages(2)), findsOneWidget);
    expect(find.text(en.mediaTabText(2)), findsOneWidget);
  });

  testWidgets('from the chat menu and from the contact card', (t) async {
    await app(t);
    await t.tap(find.byKey(Key('chat-menu-${jordan.label}-person')).first);
    await settle(t);
    await t.tap(find.byKey(const Key('chat-menu-media')));
    await settle(t);
    expect(find.byKey(const Key('media-dialog')), findsOneWidget);
    await t.tap(find.text(en.commonClose).last);
    await settle(t);
    await t.tap(find.byKey(const Key('card-toggle')));
    await settle(t);
    expect(find.text(en.cardMediaFiles(5)), findsOneWidget);
    await t.tap(find.byKey(const Key('card-media')));
    await settle(t);
    expect(find.byKey(const Key('media-dialog')), findsOneWidget);
    expect(find.text(en.mediaTabFiles(1)), findsOneWidget);
  });
}
