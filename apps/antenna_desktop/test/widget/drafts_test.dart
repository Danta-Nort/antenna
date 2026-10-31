// SPDX-License-Identifier: AGPL-3.0-only
// Drafts per chat (state/drafts.dart; fake daemon). The maintainer attached a screenshot in one chat, opened another,
// and the file was still waiting in that chat's composer, where Enter would have sent it to the wrong recipient. Now
// each chat keeps its own text, files and To choice: another chat's composer is empty and its Send cannot send them;
// coming back finds the draft; the chat list says "Draft"; the hint under the files names the exact recipient.

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

FakeDaemon _team() => FakeDaemon(
      contacts: [jordanTeam, emily, buildBot],
      history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
    );

final link = jordanTeam.linkId;
const backend = ThreadKey.agent('claude-backend');
Key _row(ThreadKey k) => k.isPerson ? Key('contact-$jordanName') : Key('chat-$jordanName-${k.id}');
final _composer = find.byKey(const Key('composer'));
String _field(WidgetTester t) => t.widget<TextField>(_composer).controller!.text;

Future<void> _open(WidgetTester t, Key row) async {
  await t.tap(find.byKey(row));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a file and text attached in one chat stay in it: another chat cannot send them, and they come back',
      (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await m.openThread(link, backend);
    await _app(t, m);

    // In the chat with claude-backend: a screenshot and a caption, not sent yet
    final shot = OutgoingStaging.instance!.stageBytes(previewPagePng(), 'Screenshot 2026-10-06.png')!;
    m.stageAttachment(link, shot);
    await t.enterText(_composer, 'the error is on this screen');
    await t.pump();
    expect(find.byKey(const Key('staged-attachments')), findsOneWidget);
    expect(find.text(en.composerAttachmentsHint(en.chatAgentTitle(jordanName, 'claude-backend'))), findsOneWidget,
        reason: 'the hint names the contact and the agent of this chat');

    // Another chat of the same contact: nothing of that draft is here, and Send sends nothing of it
    await _open(t, _row(ThreadKey.person));
    expect(find.byKey(const Key('staged-attachments')), findsNothing);
    expect(_field(t), isEmpty);
    await t.tap(_composer);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, isNot(contains('share_file')));
    expect(d.calls, isNot(contains('send')));
    expect(find.text(en.listPreviewDraft('the error is on this screen')), findsOneWidget,
        reason: 'the chat list says the other chat has a draft');

    // Another contact: the same
    await _open(t, Key('contact-${emily.label}'));
    expect(find.byKey(const Key('staged-attachments')), findsNothing);
    expect(_field(t), isEmpty);

    // Back to claude-backend: the draft is as it was, and its Send sends it there
    await _open(t, _row(backend));
    expect(_field(t), 'the error is on this screen');
    expect(find.byKey(const Key('staged-attachments')), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('send')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump(const Duration(milliseconds: 300));
    expect(d.shareAddresses.single, ('agent', 'claude-backend'));
    expect(d.calls.where((c) => c == 'send'), hasLength(1));
    expect(m.hasDraft(link, backend), isFalse);
  });

  testWidgets('the person chat names the person; the To choice belongs to its chat', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await m.openThread(link, ThreadKey.person);
    await _app(t, m);
    m.stageAttachment(link, OutgoingStaging.instance!.stageBytes(previewPagePng(), 'a.png')!);
    await t.pump();
    expect(find.text(en.composerAttachmentsHint(en.mapPersonOf(jordanName))), findsOneWidget);

    m.setRecipient(link, Recipient.everyone);
    await t.pump();
    expect(find.text(en.composerAttachmentsHint(en.chatAgentTitle(jordanName, en.authorToEveryone))), findsOneWidget);
    await _open(t, _row(backend));
    expect(m.recipientOf(link), Recipient.of(backend), reason: "the agent's chat writes to its agent");
    await _open(t, _row(ThreadKey.person));
    expect(m.recipientOf(link), Recipient.everyone, reason: 'the choice came back with its draft');
  });
}
