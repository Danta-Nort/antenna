// SPDX-License-Identifier: AGPL-3.0-only
// Text longer than one message holds (state/long_text.dart, the composer, the bubble; fake daemon): the composer
// counts bytes near the 64 KiB limit and over it says the text goes as a file and turns Send into "Send as a file";
// the file is the text itself, named after its first line, sent in the same chat with the chat's address (the agent of
// an agent's chat); a bubble the daemon refused as too long (`text_too_long`, or `bad_request` from an older daemon)
// offers the same and is replaced by the file; any other refusal shows the daemon's words, not only the code.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/long_text.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/files/file_card.dart' show fileSizeLabel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
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

/// A crash report: a first line, then lines until it is [bytes] long.
String _crashLog(int bytes) {
  final b = StringBuffer('Process:  Antenna [4127]\n');
  var i = 0;
  while (b.length < bytes) {
    b.write('Thread ${i++} Crashed:: Dispatch queue: com.apple.main-thread 0x0000000100${i.toRadixString(16)}\n');
  }
  return b.toString().substring(0, bytes);
}

final link = jordanTeam.linkId;
const backend = ThreadKey.agent('claude-backend');
final limit = fileSizeLabel(maxMessageBytes);

void main() {
  test('bytes are counted as UTF-8, and a file name comes from the first line', () {
    for (final s in ['', 'plain', 'Καλημέρα', '€ and ✓', '👋🏽 hi', 'a\uD800b']) {
      expect(utf8Length(s), utf8.encode(s).length, reason: s);
    }
    expect(textTooLong('a' * maxMessageBytes), isFalse);
    expect(textTooLong('a' * (maxMessageBytes + 1)), isTrue);
    expect(textTooLong('€' * (maxMessageBytes ~/ 3 + 1)), isTrue, reason: 'bytes, not characters');
    final at = DateTime(2026, 10, 6, 21, 53, 7);
    expect(textFileName('Process:  Antenna [4127]\nmore', at), 'Process-Antenna-4127.txt');
    expect(textFileName('\n\n  ../../etc/passwd  \nx', at), 'etc-passwd.txt', reason: 'no path in a name');
    expect(textFileName('////\n', at), 'message-2026-10-06-215307.txt');
    expect(textFileName('Crash report — café', at), 'Crash-report-café.txt');
    expect(textFileName('x' * 100, at).length, 48 + 4);
  });

  testWidgets('near the limit a quiet counter; over it the composer sends the text as a file in the agent\'s chat',
      (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await m.openThread(link, backend);
    await _app(t, m);

    // 60 KB: still a message, with the counter
    await t.enterText(find.byKey(const Key('composer')), _crashLog(60 * 1024));
    await t.pump();
    expect(find.byKey(const Key('composer-counter')), findsOneWidget);
    expect(find.text(en.composerTextCounter('60.0 KB', limit)), findsOneWidget);
    expect(find.byKey(const Key('composer-too-long')), findsNothing);
    expect(find.byKey(const Key('send')), findsOneWidget);

    // Pasted over the limit: the line and "Send as a file" at once, before anything is sent
    final log = _crashLog(70 * 1024);
    await t.enterText(find.byKey(const Key('composer')), log);
    await t.pump();
    expect(find.text(en.composerTooLongHint(limit)), findsOneWidget);
    expect(find.byKey(const Key('send')), findsNothing);
    expect(find.byKey(const Key('send-as-file')), findsOneWidget);
    expect(d.calls, isNot(contains('send')));

    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('send-as-file')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('share_file'));
    expect(d.calls, isNot(contains('send')), reason: 'never sent as a message the daemon would refuse');
    final path = d.shared.last;
    expect(path.split('/').last, 'Process-Antenna-4127.txt');
    expect(utf8.decode(d.sharedContent[path]!), log, reason: 'the file is exactly the text');
    expect(d.shareAddresses.last, ('agent', 'claude-backend'), reason: "the agent's chat: the file is for that agent");
    expect(File(path).existsSync(), isFalse, reason: 'the staged copy is deleted once the daemon has it');
    expect(find.byKey(const Key('composer-too-long')), findsNothing, reason: 'the field is empty again');
  });

  testWidgets('a bubble an older daemon refused as a bad request for its length offers "Send as a file"', (t) async {
    final d = _team()..tooLongAsBadRequest = true;
    final m = await _model(d);
    await m.select(link);
    await _app(t, m);
    final log = _crashLog(80 * 1024);
    await m.send(log);
    await t.pump(const Duration(milliseconds: 300));
    final failed = m.visibleChat(link).last;
    expect((failed.delivery, failed.error), (Delivery.failed, XErrorCode.badRequest));
    expect(refusedAsTooLong(failed), isTrue);
    expect(find.text(en.bubbleTooLong(limit)), findsOneWidget);
    expect(find.text(en.bubbleNotSent('bad_request')), findsNothing, reason: 'never only the code');
    expect(find.text(en.bubbleRetry), findsNothing, reason: 'a retry would fail the same way');

    await t.runAsync(() async {
      await t.tap(find.byKey(Key('send-as-file-${failed.id}')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump(const Duration(milliseconds: 300));
    expect(utf8.decode(d.sharedContent[d.shared.last]!), log);
    expect(m.visibleChat(link).where((e) => identical(e, failed)), isEmpty, reason: 'the file replaces the bubble');
  });

  testWidgets('the current daemon says text_too_long; another refusal is shown in words with the daemon\'s text',
      (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await _app(t, m);
    await m.send(_crashLog(66 * 1024));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.visibleChat(link).last.error, XErrorCode.textTooLong);
    expect(find.text(en.bubbleTooLong(limit)), findsOneWidget);

    // A refusal with no bubble text of its own: the explanation and the daemon's message
    final e = m.visibleChat(link).last
      ..error = XErrorCode.badRequest
      ..errorMessage = 'unknown field `colour`'
      ..text = 'short';
    m.safeNotify();
    await t.pump();
    expect(find.text(en.bubbleNotSentBecause(en.errBadRequest('unknown field `colour`'))), findsOneWidget);
    expect(find.text(en.bubbleNotSent(e.error!)), findsNothing);
    expect(find.text(en.bubbleRetry), findsOneWidget, reason: 'not a length problem: Retry as before');
  });
}
