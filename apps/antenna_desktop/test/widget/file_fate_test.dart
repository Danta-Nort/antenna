// SPDX-License-Identifier: AGPL-3.0-only
// A sent file's fate as the contact's node tells it (D-129), on the fake daemon: `reject_file` / `denied` is the
// contact's check or limits (blocked), never "declined"; `check_file` / `held` reads "Waiting for <contact> to
// decide", with the reason in words and the rules; only `reject_file` / `rejected` reads "declined". A hold is not a
// decision: a later accept still moves the card on, also after a block (the contact's owner accepted a held threat
// with the password), and an older receipt that arrives after the accept does not move it back. The field report of
// 2026-10-06 is the first widget test: a PNG the contact's check held as a threat read "The contact declined the file".

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/files.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

FileInfo _sent(int seed, String name, {ContactInfo? to}) => demoFile(seed,
    from: to ?? buildBot,
    name: name,
    size: 4096,
    mime: 'image/png',
    state: 'sent',
    verdict: 'clean',
    at: ago(minutes: 10 - seed),
    direction: 'out');

String _k(FileInfo f) => f.id.substring(0, 8);

/// The contact's signed receipt about our file [f], as a history item.
HistoryItem _receipt(int seq, FileInfo f, String action, String decision,
        {String? why, List<String> rules = const [], int? number}) =>
    HistoryItem(
        seq: seq,
        id: hex(0xFA7E0 + seq, 64),
        direction: 'in',
        kind: 'receipt',
        text: '',
        ts: ms(ago(minutes: 1)),
        localMs: ms(ago(minutes: 1)),
        lamport: seq,
        status: 'received',
        receipt: ReceiptInfo(
            seq: seq,
            ts: ms(ago(minutes: 1)),
            actor: 'owner',
            action: action,
            decision: decision,
            reason: '',
            source: 'dag',
            author: 'contact',
            refs: [f.messageId!],
            nameNumber: number,
            why: why,
            rules: rules));

Future<AppModel> _app(WidgetTester t, List<FileInfo> files) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  for (final f in files) {
    d.fileMap[f.id] = f;
  }
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('nav-files')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
  return m;
}

Future<void> _arrive(WidgetTester t, AppModel m, ContactInfo c, HistoryItem receipt) async {
  m.handleEvent(MessageEvent(contact: c.label, linkId: c.linkId, message: receipt));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  test('the receipt view carries why and rules; an older node\'s has neither', () {
    final j = {
      'seq': 7,
      'id': 'ab' * 32,
      'direction': 'in',
      'kind': 'receipt',
      'text': '',
      'ts': 1,
      'local_ms': 1,
      'lamport': 7,
      'status': 'received',
      'receipt': {
        'actor': 'owner',
        'action': 'check_file',
        'decision': 'held',
        'refs': ['cd' * 32],
        'why': 'executable',
        'rules': ['archive_member_executable', 'active_content'],
      },
    };
    final r = HistoryItem.fromJson(j).receipt!;
    expect(r.why, 'executable');
    expect(r.rules, ['archive_member_executable', 'active_content']);
    final old = HistoryItem.fromJson({
      ...j,
      'receipt': {'actor': 'owner', 'action': 'reject_file', 'decision': 'denied', 'refs': ['cd' * 32]},
    }).receipt!;
    expect(old.why, isNull);
    expect(old.rules, isEmpty);
    final held = FileInfo.fromJson({
      'id': 'ef' * 16,
      'state': 'held',
      'direction': 'out',
      'held': {'code': 'review', 'message': '', 'rules': ['active_content']},
    }).held!;
    expect(held.code, 'review');
    expect(held.rules, ['active_content']);
  });

  test('which receipt is which fate, and fates only move forward', () {
    ReceiptInfo r(String action, String decision) =>
        ReceiptInfo(seq: 0, ts: 0, actor: 'owner', action: action, decision: decision, reason: '');
    expect(sentFileFate(r('accept_file', 'accepted')), 'accepted');
    expect(sentFileFate(r('check_file', 'held')), 'held');
    expect(sentFileFate(r('reject_file', 'denied')), 'blocked');
    expect(sentFileFate(r('reject_file', 'rejected')), 'rejected');
    expect(sentFileFate(r('withdraw_file', 'withdrawn')), isNull);
    expect(sentFileFate(r('send_message', 'allowed')), isNull);
    expect(['sent', 'held', 'blocked', 'rejected', 'accepted'].map(sentFileRank).toList(), [0, 1, 2, 3, 4]);
  });

  testWidgets('the field report: an older node\'s reject_file / denied is blocked by its check, never "declined"',
      (t) async {
    final f = _sent(1, 'screenshot.png');
    final m = await _app(t, [f]);
    await _arrive(t, m, buildBot, _receipt(900, f, 'reject_file', 'denied'));
    expect(m.files[f.id]!.state, 'blocked');
    expect(find.byKey(Key('file-out-blocked-${_k(f)}')), findsOneWidget);
    expect(find.text(en.filesOutBlockedUnknown(buildBot.label)), findsOneWidget);
    expect(find.text(en.filesOutBlockedOldNote), findsOneWidget, reason: 'its limits refuse the same way');
    expect(find.text(en.filesOutRejected), findsNothing, reason: 'a check is not a person declining it');
    expect(find.byKey(Key('file-out-rejected-${_k(f)}')), findsNothing);
  });

  testWidgets('blocked as a threat says so with the rules; the contact\'s owner accepting it later still applies',
      (t) async {
    final f = _sent(2, 'prototypes.zip');
    final m = await _app(t, [f]);
    await _arrive(t, m, buildBot,
        _receipt(901, f, 'reject_file', 'denied', why: 'threat', rules: ['polyglot_html', 'active_content']));
    expect(find.text(en.filesOutBlocked(buildBot.label, en.filesFateThreat)), findsOneWidget);
    expect(find.text(en.filesOutBlockedOldNote), findsNothing, reason: 'this node said why');
    expect(find.text(en.filesRules('polyglot_html, active_content')), findsOneWidget);
    expect(find.text(en.filesOutRejected), findsNothing);
    await _arrive(t, m, buildBot, _receipt(902, f, 'accept_file', 'accepted'));
    expect(m.files[f.id]!.state, 'accepted');
    expect(find.byKey(Key('file-out-accepted-${_k(f)}')), findsOneWidget);
    expect(find.byKey(Key('file-out-blocked-${_k(f)}')), findsNothing);
  });

  testWidgets('a block by the limits or a damaged file says nothing waits there', (t) async {
    final limit = _sent(3, 'video.mov', to: emily);
    final damaged = _sent(4, 'notes.txt', to: emily);
    final later = _sent(9, 'page.html', to: emily);
    final m = await _app(t, [limit, damaged, later]);
    await _arrive(t, m, emily, _receipt(903, limit, 'reject_file', 'denied', why: 'limit'));
    await _arrive(t, m, emily, _receipt(904, damaged, 'reject_file', 'denied', why: 'damaged'));
    expect(find.text(en.filesOutRefused(emily.label, en.filesFateLimit)), findsOneWidget);
    expect(find.text(en.filesOutRefused(emily.label, en.filesFateDamaged)), findsOneWidget);
    expect(find.text(en.filesOutRejected), findsNothing);
    // A block that gives no reason does not keep the reason of the hold before it.
    await _arrive(t, m, emily, _receipt(914, later, 'check_file', 'held', why: 'review', rules: ['active_content']));
    await _arrive(t, m, emily, _receipt(915, later, 'reject_file', 'denied'));
    expect(m.files[later.id]!.held, isNull);
    expect(find.text(en.filesOutBlockedUnknown(emily.label)), findsOneWidget);
    expect(find.text(en.filesRules('active_content')), findsNothing);
  });

  testWidgets('check_file / held waits for the contact\'s owner with the reason; a later accept moves it on',
      (t) async {
    final f = _sent(5, 'tools.zip');
    final bare = _sent(6, 'draft.html');
    final m = await _app(t, [f, bare]);
    await _arrive(t, m, buildBot,
        _receipt(905, f, 'check_file', 'held', why: 'executable', rules: ['archive_member_executable']));
    await _arrive(t, m, buildBot, _receipt(906, bare, 'check_file', 'held'));
    expect(m.files[f.id]!.state, 'held');
    expect(m.files[f.id]!.decided, isFalse, reason: 'a hold is not a decision');
    expect(find.byKey(Key('file-out-held-${_k(f)}')), findsOneWidget);
    expect(find.text(en.filesOutHeldWhy(buildBot.label, en.filesFateExecutable)), findsOneWidget);
    expect(find.text(en.filesRules('archive_member_executable')), findsOneWidget);
    expect(find.text(en.filesOutHeld(buildBot.label)), findsOneWidget, reason: 'no reason given: none shown');
    expect(find.text(en.filesOutRejected), findsNothing);
    await _arrive(t, m, buildBot, _receipt(907, f, 'accept_file', 'accepted', number: 2));
    expect(m.files[f.id]!.state, 'accepted');
    expect(find.text(en.filesOutAcceptedAs('tools (2).zip')), findsOneWidget);
    expect(find.byKey(Key('file-out-held-${_k(f)}')), findsNothing);
  });

  testWidgets('only reject_file / rejected reads "declined"', (t) async {
    final f = _sent(7, 'invoice.pdf', to: emily);
    final m = await _app(t, [f]);
    await _arrive(t, m, emily, _receipt(908, f, 'check_file', 'held', why: 'review', rules: ['pdf_javascript']));
    await _arrive(t, m, emily, _receipt(909, f, 'reject_file', 'rejected'));
    expect(m.files[f.id]!.state, 'rejected');
    expect(find.byKey(Key('file-out-rejected-${_k(f)}')), findsOneWidget);
    expect(find.text(en.filesOutRejected), findsOneWidget);
  });

  testWidgets('an older hold or block arriving after the accept does not move the card back', (t) async {
    final f = _sent(8, 'report.html');
    final m = await _app(t, [f]);
    // A page of history: the newest receipt first, the older ones after it.
    m.applyFileReceipts([
      _receipt(912, f, 'accept_file', 'accepted'),
      _receipt(911, f, 'reject_file', 'denied', why: 'threat'),
      _receipt(910, f, 'check_file', 'held', why: 'review'),
    ]);
    await _arrive(t, m, buildBot, _receipt(913, f, 'check_file', 'held', why: 'review'));
    expect(m.files[f.id]!.state, 'accepted');
    expect(find.byKey(Key('file-out-accepted-${_k(f)}')), findsOneWidget);
  });
}
