// SPDX-License-Identifier: AGPL-3.0-only
// Widget tests of user flows on the fake daemon: unlock, send, slash commands, trust change with the password,
// pairing (A confirms only by itself, B types the code), approvals, subscription events, an agent's streaming reply.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/trust.dart' show trustGlyph;
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/chat/slash_commands.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

FakeDaemon _demo() => FakeDaemon(contacts: demoContacts(), history: demoHistory());

/// App strings: the test system is English, so the window ("as in the system") is English.
final en = l10nFor('en');

/// Russian app strings, for checks of the Russian UI.
final ru = l10nFor('ru');

/// A Russian ARB message with its placeholders filled in: what the generated code must return.
String ruMessage(String key, Map<String, Object> args) {
  final arb = json.decode(File('lib/l10n/app_ru.arb').readAsStringSync()) as Map<String, dynamic>;
  var message = arb[key] as String;
  args.forEach((name, value) => message = message.replaceAll('{$name}', '$value'));
  return message;
}

void main() {
  testWidgets('unlock: wrong password shows an error, right one opens the home screen', (t) async {
    final d = FakeDaemon(state: DaemonState.locked, contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    expect(find.text('Keys are locked'), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'wrong');
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Wrong password.'), findsOneWidget);
    expect(m.phase, Phase.locked);
    await t.enterText(find.byKey(const Key('password')), d.password);
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 600));
    expect(m.phase, Phase.unlocked);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(d.calls, containsAllInOrder(['unlock', 'unlock', 'contacts', 'history']));
  });

  testWidgets('Russian system: the window speaks Russian (unlock screen, daemon error, home)', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU'), Locale('en', 'US')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final d = FakeDaemon(state: DaemonState.locked, contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    expect(find.text(ru.gateUnlockTitle), findsOneWidget);
    expect(find.text(ru.gateUnlockButton), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'wrong');
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text(ru.errWrongPassword), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), d.password);
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text(ru.navChats), findsWidgets);
    expect(find.text(ru.commonLockKeys), findsOneWidget);
    expect(find.text(ru.composerHint), findsOneWidget);
  });

  test('ICU plurals and placeholders: English counts, Russian keeps its wording', () {
    expect(en.navContactsCount(1), '1 contact');
    expect(en.navContactsCount(5), '5 contacts');
    expect(ru.navContactsCount(5), ruMessage('navContactsCount', {'count': 5}));
    expect(en.listPreviewQueued(1), '1 message queued');
    expect(en.listPreviewFailed(3), '3 messages not delivered');
    expect(ru.listPreviewFailed(3), ruMessage('listPreviewFailed', {'count': 3}));
    expect(en.composerNoteContacts(2), 'antenna contacts → 2 contacts; E2E facts and queues refreshed');
    expect(en.trustChangeAction('Bob', '2', '4'), 'Trust level for “Bob”: 2 → 4');
    expect(ru.trustChangeAction('Bob', '2', '4'),
        ruMessage('trustChangeAction', {'name': 'Bob', 'before': '2', 'after': '4'}));
    // Level 5 reads as ∞ "My computer" everywhere, including this dialog (D-UI-30); the protocol keeps the number.
    expect(en.trustChangeAction('Bob', trustGlyph(4), trustGlyph(5)), 'Trust level for “Bob”: 4 → ∞');
  });

  testWidgets('init asks for the password twice and checks length', (t) async {
    final m = await _model(FakeDaemon(state: DaemonState.uninitialized));
    await _app(t, m);
    await t.enterText(find.byKey(const Key('password')), 'short');
    await t.enterText(find.byKey(const Key('password2')), 'short');
    await t.tap(find.byKey(const Key('submit')));
    await t.pump();
    expect(find.text(en.gatePasswordTooShort), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'long enough pw');
    await t.enterText(find.byKey(const Key('password2')), 'different pw!!');
    await t.tap(find.byKey(const Key('submit')));
    await t.pump();
    expect(find.text("The passwords don't match."), findsOneWidget);
    expect(m.phase, Phase.uninitialized);
  });

  testWidgets('send: Enter sends via antenna send, bubble gets the delivered mark', (t) async {
    final d = _demo();
    final m = await _model(d);
    await _app(t, m);
    await t.enterText(find.byKey(const Key('composer')), 'Sent the draft');
    await t.testTextInput.receiveAction(TextInputAction.newline);
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls.where((c) => c == 'send').length, 1);
    final last = m.chatOf(emily.linkId).last;
    expect(last.text, 'Sent the draft');
    expect(last.delivery, Delivery.delivered);
    expect(find.text('Sent the draft'), findsOneWidget);
  });

  test('slash parser: only real commands, arguments validated', () {
    final inv = parseSlash('/invite --trust 3 --ttl 1h --label Bob')!;
    expect(inv.command.kind, SlashKind.invite);
    expect(inv.trust, 3);
    expect(inv.ttl, const Duration(hours: 1));
    expect(inv.label, 'Bob');
    expect(parseSlash('/invite --trust 9')!.error, isNotNull);
    expect(parseSlash('/invite --ttl 48h')!.error, isNotNull);
    expect(parseSlash('/trust 4')!.trust, 4);
    expect(parseSlash('/trust')!.error, isNotNull);
    expect(parseSlash('/join x://pair#abc')!.link, 'x://pair#abc');
    expect(parseSlash('//not a command'), isNull, reason: '// escapes a leading slash');
    expect(parseSlash('/approve 1'), isNull, reason: 'approve is not a slash command');
    expect(parseSlash('/inbox'), isNull, reason: 'the window never consumes the inbox');
    expect(SlashCommand.matching('/in').map((c) => c.name), ['/invite']);
  });

  testWidgets('trust change: password goes to the daemon, card updates', (t) async {
    final d = _demo();
    final m = await _model(d);
    await _app(t, m);
    // The link card opens from a button in the conversation header.
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('trust-edit')));
    await t.pump();
    await t.tap(find.byKey(const Key('trust-2')));
    await t.pump();
    await t.tap(find.byKey(const Key('trust-apply')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Confirm with password'), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 400));
    expect(d.passwords['trust'], d.password);
    expect(m.selected!.trust, 2);
    expect(m.selected!.netMode, 'relay_only');
  });

  testWidgets('invite: link → code → the owner TYPES the confirmed code; the window never fills it in', (t) async {
    final d = _demo();
    final m = await _model(d);
    await _app(t, m);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-invite');
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    final dlg = d.dialogs.last;
    final req = dlg.request as InviteRequest;
    expect(req.password, 'pw-for-invite');
    expect(req.trust, 2, reason: 'default level 2 (D-25)');
    expect(req.follow, isTrue);
    dlg
      ..emit(InviteCreated(id: 'i1', link: demoLink, expiresMs: ms(fixedNow) + 600000, trust: 2, netMode: 'relay_only'))
      ..emit(const SasEvent(code: '482913', emoji: '\u{1F984}\u{1F43C}\u{1F981}\u{1F413}\u{1F431}\u{1F40E}'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('sas-digits')), findsOneWidget);
    expect(find.text('482 913'), findsOneWidget);
    await t.tap(find.text('Emoji'));
    await t.pump();
    expect(find.byKey(const Key('sas-emoji')), findsOneWidget);
    dlg
      ..emit(const PeerEnteredCode())
      ..emit(const NeedInput('confirm'));
    await t.pump(const Duration(milliseconds: 200));
    // At the confirmation step the code is not on screen: the owner types it.
    expect(find.text('482 913'), findsNothing);
    expect(find.byKey(const Key('sas-emoji')), findsNothing);
    expect(dlg.inputs, isEmpty);

    // An empty code: a clear error, and nothing went to the daemon.
    await t.tap(find.byKey(const Key('invite-confirm')));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('Enter the code: 6 digits or 6 animals.'), findsOneWidget);
    expect(d.calls, isNot(contains('pairing_confirm')));

    // A wrong code: the daemon answers with an input_rejected event (v2); the invite is still alive, so no second password.
    expect(find.byKey(const Key('owner-password')), findsNothing);
    await t.enterText(find.byKey(const Key('sas-input')), '111111');
    await t.tap(find.byKey(const Key('invite-confirm')));
    await t.pump();
    expect(dlg.inputs.last, isA<ConfirmInput>().having((i) => i.code, 'code', '111111'));
    dlg.emit(const InputRejected(what: 'confirm', code: 'sas_mismatch', message: 'not the code of this invite'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.textContaining("That's not this invite's code"), findsOneWidget);

    // The right code typed by the owner (as read out by the other side) → "yes" on the monitoring connection → a link.
    await t.enterText(find.byKey(const Key('sas-input')), '482913');
    await t.tap(find.byKey(const Key('invite-confirm')));
    await t.pump();
    expect(
      dlg.inputs.last,
      isA<ConfirmInput>().having((i) => i.yes, 'yes', isTrue).having((i) => i.code, 'code', '482913'),
      reason: 'the typed code, never the shown one filled in by the window',
    );
    expect(d.calls, isNot(contains('pairing_confirm')));
    dlg.finish(const LinkedReply(
      contact: 'Alex',
      linkId: 'ab12',
      trust: 2,
      netMode: 'relay_only',
      kxGroup: 'X25519MLKEM768',
      pairingMs: 2600,
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Linked with “Alex”'), findsOneWidget);
  });

  testWidgets('invite: "did not match" rejects without a code', (t) async {
    final d = _demo();
    final m = await _model(d);
    await _app(t, m);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    d.dialogs.last
      ..emit(InviteCreated(id: 'i2', link: demoLink, expiresMs: ms(fixedNow) + 600000, trust: 2, netMode: 'relay_only'))
      ..emit(const SasEvent(code: '000111'))
      ..emit(const NeedInput('confirm'));
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byKey(const Key('invite-reject')));
    await t.pump();
    expect(d.dialogs.last.inputs.single, isA<ConfirmInput>().having((i) => i.yes, 'yes', isFalse));
  });

  testWidgets('join: B types the code (digits) — it is sent as input', (t) async {
    final d = _demo();
    final m = await _model(d);
    await _app(t, m);
    unawaited(showJoinDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('join-link')), 'not a link');
    await t.tap(find.byKey(const Key('join-start')));
    await t.pump();
    expect(find.text(en.pairJoinBadLink), findsOneWidget);
    await t.enterText(find.byKey(const Key('join-link')), demoLink);
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-join');
    await t.tap(find.byKey(const Key('join-start')));
    await t.pump();
    final dlg = d.dialogs.last;
    expect((dlg.request as JoinRequest).password, 'pw-for-join');
    dlg.emit(const NeedInput('sas_code'));
    await t.pump(const Duration(milliseconds: 200));
    await t.enterText(find.byKey(const Key('sas-input')), '482913');
    await t.pump();
    await t.tap(find.byKey(const Key('sas-submit')));
    await t.pump();
    expect(dlg.inputs.single, isA<SasCodeInput>().having((i) => i.code, 'code', '482913'));
    dlg.fail(const XControlException(XErrorCode.sasMismatch, 'the code does not match'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text(en.errSasMismatch), findsOneWidget);
  });

  testWidgets('approve: rights shown structurally, decision needs the password', (t) async {
    final d = _demo()..approvalList = [demoApproval()];
    final m = await _model(d);
    await _app(t, m);
    expect(find.byKey(const Key('approvals-banner')), findsOneWidget);
    // The selected conversation (the request is about it) shows the same card (D-84); the dialog lists them all.
    expect(find.byKey(const Key('chat-approval-ap-7f3c19')), findsOneWidget);
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    final dialog = find.byType(ApprovalsDialog);
    expect(find.descendant(of: dialog, matching: find.text(en.approvalsQuoteLabel)), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text(en.approvalsPermissions)), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text(en.approvalsGrantSend)), findsOneWidget);
    await t.tap(find.descendant(of: dialog, matching: find.byKey(const Key('approve-ap-7f3c19'))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['approve'], d.password);
    expect(m.approvals, isEmpty);
  });

  test('subscription events: delivery only moves forward, unread counts, presence by level', () async {
    // The rule before threads (a v5 daemon): selecting a link marks it read up to its last incoming message. With
    // x-control/6 the window marks the open thread's messages by ID (test/widget/threads_test.dart).
    final d = _demo()..protoVersion = 5;
    final m = await _model(d);
    // Outgoing: a message(queued) event after the send(delivered) response does not roll the status back.
    final t0 = m.chatOf(emily.linkId).length;
    m.handleEvent(MessageEvent(contact: emilyName, linkId: emily.linkId, message: msg(99, true, 'x', fixedNow)));
    m.handleEvent(MessageStatusEvent(contact: emilyName, linkId: emily.linkId, id: hex(99 * 7 + 3), status: 'delivered'));
    m.handleEvent(MessageEvent(
      contact: emilyName,
      linkId: emily.linkId,
      message: msg(99, true, 'x', fixedNow, status: 'queued'),
    ));
    expect(m.chatOf(emily.linkId).length, t0 + 1);
    expect(m.chatOf(emily.linkId).last.delivery, Delivery.delivered);
    // Incoming to an unselected link → unread (Jordan had 2 from the daemon).
    m.handleEvent(MessageEvent(contact: jordanName, linkId: jordan.linkId, message: msg(98, false, 'y', fixedNow)));
    expect(m.unreadOf(m.contactById(jordan.linkId)!), 3);
    // A receipt is not a message: it adds no unread count and does not show in the preview.
    m.handleEvent(MessageEvent(
      contact: jordanName,
      linkId: jordan.linkId,
      message: receiptMsg(97, false, 'claude', 'read_messages', 'allowed', fixedNow),
    ));
    expect(m.unreadOf(m.contactById(jordan.linkId)!), 3);
    expect(m.lastEntry(jordan.linkId)!.text, 'y');
    // Selecting the link → mark_read up to the last incoming message.
    await m.select(jordan.linkId);
    expect(d.markedRead[jordan.linkId], 98);
    expect(m.unreadOf(m.contactById(jordan.linkId)!), 0);
    // A history event: "History verified" → the contact's state.
    m.handleEvent(HistoryEvent(contact: jordanName, linkId: jordan.linkId, status: verifiedHistory(23)));
    expect(m.contactById(jordan.linkId)!.history!.verified, isTrue);
    // A contact event: level and presence.
    m.handleEvent(ContactEvent(ContactSummary(
      contact: jordanName,
      linkId: jordan.linkId,
      trust: 2,
      netMode: 'relay_only',
      presence: 'not_tracked',
    )));
    final c = m.contactById(jordan.linkId)!;
    expect(c.trust, 2);
    expect(m.presenceOf(c), isNull, reason: 'levels 1–2: presence is not tracked (SPEC §4)');
    expect(m.presenceOf(emily), isTrue);
  });
}
