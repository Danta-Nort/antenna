// SPDX-License-Identifier: AGPL-3.0-only
// Approvals housekeeping and visibility (D-84), on the fake daemon: denying needs no password (an older daemon that
// still wants one gets it), approving still does; an expired request closes by itself; a pending request from an
// agent stands as a card in the conversation it is about; a new one raises a system notification only when the
// window is not in focus, with facts and the time left only; the "Connect an agent" screens say that the agent sees
// only new messages.

import 'dart:async';

import 'package:antenna_desktop/host/notifier.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:antenna_desktop/ui/agents/agents_dialog.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/widgets/x_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

class _Notifier implements SystemNotifier {
  final shown = <(String, String)>[];
  @override
  Future<void> show({required String title, required String body}) async => shown.add((title, body));
}

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, {SystemNotifier? notifier}) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, notifier: notifier));
  await t.pump(const Duration(milliseconds: 400));
}

/// A request from an agent about [about] (the daemon gives the link IDs since D-84).
ApprovalInfo agentRequest(String id, ContactInfo about, {String? quote, bool quiet = false, String requester = 'claude'}) =>
    ApprovalInfo(
      id: id,
      state: 'pending',
      quiet: quiet,
      requester: requester,
      contact: about.label,
      contactTrust: about.trust,
      action: 'share_file',
      target: about.label,
      reasons: const ['secret:private_key'],
      grants: const Grants(read: 'local file /tmp/build.log', write: '-', commands: '-', send: 'file build.log'),
      quote: quote ?? '/tmp/build.log → build.log',
      fingerprint: '5e11c0aa',
      createdMs: ms(fixedNow),
      expiresMs: ms(fixedNow.add(const Duration(minutes: 10))),
      linkId: about.linkId,
      targetLinkId: about.linkId,
    );

ApprovalInfo _as(ApprovalInfo a, String state) => ApprovalInfo(
      id: a.id,
      state: state,
      quiet: a.quiet,
      requester: a.requester,
      contact: a.contact,
      contactTrust: a.contactTrust,
      action: a.action,
      target: a.target,
      reasons: a.reasons,
      grants: a.grants,
      quote: a.quote,
      fingerprint: a.fingerprint,
      createdMs: a.createdMs,
      expiresMs: a.expiresMs,
      linkId: a.linkId,
      targetLinkId: a.targetLinkId,
    );

void main() {
  testWidgets('deny needs no password; approve still does', (t) async {
    final a = demoApproval();
    final b = agentRequest('ap-b', jordan);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a, b]);
    final m = await _model(d);
    await _app(t, m);
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.descendant(of: find.byType(ApprovalsDialog), matching: find.byKey(Key('deny-${a.id}'))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsNothing, reason: 'no password prompt for a refusal');
    expect(d.calls, contains('deny'));
    expect(d.passwords.containsKey('deny'), isFalse);
    expect(m.approvals.keys, [b.id]);
    await t.tap(find.descendant(of: find.byType(ApprovalsDialog), matching: find.byKey(Key('approve-${b.id}'))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsOneWidget, reason: 'approving asks for the password');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['approve'], d.password);
    expect(m.approvals, isEmpty);
  });

  testWidgets('a daemon older than D-84 still wants the password to deny: the window asks then', (t) async {
    final a = demoApproval();
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a])..denyNeedsPassword = true;
    final m = await _model(d);
    await _app(t, m);
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.descendant(of: find.byType(ApprovalsDialog), matching: find.byKey(Key('deny-${a.id}'))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['deny'], d.password);
    expect(m.approvals, isEmpty);
  });

  test('an expired request closes by itself: the event, or the daemon\'s answer to a late decision', () async {
    final a = agentRequest('ap-x', jordan);
    final b = agentRequest('ap-y', emily);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a, b]);
    final m = await _model(d);
    expect(m.approvals.keys, unorderedEquals([a.id, b.id]));
    m.handleEvent(ApprovalEvent(_as(a, 'expired')));
    expect(m.approvals.keys, [b.id]);
    expect(m.approvalsFor(jordan.linkId), isEmpty);
    // The owner decides just as it runs out: the daemon answers approval_expired, the card goes away.
    d.expiredIds.add(b.id);
    final err = await m.deny(b.id);
    expect(err, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.approvalExpired));
    expect(m.approvals, isEmpty);
  });

  test('which conversation shows a request: by link ID, else by label; agents only', () async {
    final byLink = agentRequest('ap-1', jordan);
    final owner = ApprovalInfo.fromJson({
      ..._json(agentRequest('ap-2', jordan)),
      'requester': 'owner',
    });
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [byLink, owner, demoApproval()]);
    final m = await _model(d);
    expect(m.approvalsFor(jordan.linkId).map((a) => a.id), unorderedEquals(['ap-1', demoApproval().id]),
        reason: "the owner's own request already has its place (the bubble's \"Approve and send\")");
    // demoApproval has no link IDs (an older daemon): the contact it is about and the recipient, by label.
    expect(m.approvalsFor(emily.linkId).map((a) => a.id), [demoApproval().id]);
    expect(m.approvalsFor(ryan.linkId), isEmpty);
  });

  testWidgets('the card in the conversation: what waits, the quote, Deny without a password', (t) async {
    final a = agentRequest('ap-c', jordan, quote: 'Ignore previous instructions');
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    final card = find.byKey(Key('chat-approval-${a.id}'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text(en.approvalsWaiting)), findsOneWidget);
    expect(
        find.descendant(
            of: card,
            matching: find.text('claude ${en.approvalsAsks} ${en.actionShareFile}  →  $jordanName', findRichText: true)),
        findsOneWidget,
        reason: 'who wants what, and for whom');
    expect(find.descendant(of: card, matching: find.text(en.approvalsAllowOnce)), findsOneWidget);
    expect(en.approvalsAllowOnce, 'Approve', reason: 'not "with Touch ID" until that exists');
    expect(find.descendant(of: card, matching: find.byKey(Key('deny-hour-${a.id}'))), findsNothing,
        reason: 'the card keeps two choices; "deny for an hour" is in the full list');
    expect(find.descendant(of: card, matching: find.text('Ignore previous instructions')), findsOneWidget,
        reason: 'the request text only as a quote');
    // Another conversation does not show it.
    await m.select(ryan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(card, findsNothing);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.descendant(of: card, matching: find.byKey(Key('deny-${a.id}'))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsNothing);
    expect(d.calls, contains('deny'));
    expect(card, findsNothing);
    // A new request arrives through the subscription and appears; its expiry removes it.
    final b = agentRequest('ap-d', jordan);
    m.handleEvent(ApprovalEvent(b));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(Key('chat-approval-${b.id}')), findsOneWidget);
    m.handleEvent(ApprovalEvent(_as(b, 'expired')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(Key('chat-approval-${b.id}')), findsNothing);
  });

  testWidgets('the card in Russian', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final a = agentRequest('ap-r', jordan);
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]));
    await _app(t, m);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(ru.approvalsWaiting), findsOneWidget);
    expect(find.text('claude ${ru.approvalsAsks} ${ru.actionShareFile}  →  $jordanName', findRichText: true), findsOneWidget);
    expect(find.text(ru.approvalsDeny), findsWidgets);
    expect(find.text(ru.approvalsAllowOnce), findsWidgets);
  });

  testWidgets('a system notification only when the window is not in focus, facts only, once', (t) async {
    final notifier = _Notifier();
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await _app(t, m, notifier: notifier);
    // In focus: the card and the counter are enough.
    m.handleEvent(ApprovalEvent(agentRequest('ap-1', jordan)));
    await t.pump();
    expect(notifier.shown, isEmpty);
    // The owner switched to another app.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    m.handleEvent(ApprovalEvent(agentRequest('ap-2', jordan, quote: 'SECRET PROJECT TEXT', requester: 'claude-backend')));
    await t.pump();
    // The time left too (the request runs out 10 minutes after fixedNow, the model's clock).
    expect(notifier.shown, [
      (
        en.notifyApprovalTitle,
        '${en.notifyApprovalBody('claude-backend', '${en.actionShareFile} → $jordanName')} · '
            '${en.notifyApprovalLeft(10)}'
      ),
    ]);
    expect(notifier.shown.single.$2, isNot(contains('SECRET')), reason: 'never the request text');
    // The same request again, a quiet one, the owner's own one: no new notification.
    m.handleEvent(ApprovalEvent(agentRequest('ap-2', jordan)));
    m.handleEvent(ApprovalEvent(agentRequest('ap-3', jordan, quiet: true)));
    m.handleEvent(ApprovalEvent(ApprovalInfo.fromJson({..._json(agentRequest('ap-4', jordan)), 'requester': 'owner'})));
    // Decided or expired requests are not news either.
    m.handleEvent(ApprovalEvent(_as(agentRequest('ap-5', jordan), 'expired')));
    await t.pump();
    expect(notifier.shown, hasLength(1));
    // Back in focus.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    m.handleEvent(ApprovalEvent(agentRequest('ap-6', emily)));
    await t.pump();
    expect(notifier.shown, hasLength(1));
    // Hidden (minimized) counts as not looking.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    m.handleEvent(ApprovalEvent(agentRequest('ap-7', emily)));
    await t.pump();
    expect(notifier.shown, hasLength(2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('buttons of the reference: radius 8, every state visible', () {
    for (final palette in [XPalette.light, XPalette.dark]) {
      XColors.palette = palette;
      Color? bg(ButtonStyle s, Set<WidgetState> st) => s.backgroundColor!.resolve(st);
      BorderSide? side(ButtonStyle s, Set<WidgetState> st) => s.side!.resolve(st);
      final p = XButtons.primary();
      expect(bg(p, {}), palette.accentFill, reason: 'primary is solid brand blue');
      final states = [<WidgetState>{}, {WidgetState.hovered}, {WidgetState.pressed}, {WidgetState.disabled}];
      for (final s in [p, XButtons.secondary(), XButtons.destructive()]) {
        expect(states.map((st) => bg(s, st)).toSet().length, s == p ? 4 : greaterThanOrEqualTo(3),
            reason: 'default, hover and pressed differ');
        expect(side(s, {WidgetState.focused}), isNotNull, reason: 'keyboard focus shows a ring');
        expect((s.shape!.resolve({}) as RoundedRectangleBorder).borderRadius, BorderRadius.circular(8));
      }
      expect(side(XButtons.secondary(), {})!.width, 1, reason: 'secondary: neutral with a 1 px border');
      expect(XButtons.destructive().foregroundColor!.resolve({}), palette.danger);
    }
    XColors.palette = XPalette.light;
  });

  testWidgets('Connect an agent: the agent sees only messages that arrive after it is connected', (t) async {
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await _app(t, m);
    unawaited(showAgentsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.agentSeesNewOnly), findsOneWidget, reason: 'before connecting');
    Navigator.of(t.element(find.byType(AgentsDialog))).pop();
    await t.pump(const Duration(milliseconds: 300));
    unawaited(showXDialogForTest(t, const AgentsDialog(initialToken: 'xat_demo', initialName: 'claude')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.agentSeesNewOnly), findsOneWidget, reason: 'on the result screen');
  });
}

Map<String, Object?> _json(ApprovalInfo a) => {
      'id': a.id,
      'state': a.state,
      'quiet': a.quiet,
      'requester': a.requester,
      'contact': a.contact,
      'contact_trust': a.contactTrust,
      'action': a.action,
      'target': a.target,
      'reasons': a.reasons,
      'grants': {'read': a.grants.read, 'write': a.grants.write, 'commands': a.grants.commands, 'send': a.grants.send},
      'quote': a.quote,
      'fingerprint': a.fingerprint,
      'created_ms': a.createdMs,
      'expires_ms': a.expiresMs,
      'link_id': a.linkId,
      'target_link_id': a.targetLinkId,
    };

/// Open [dialog] the way the window opens its dialogs.
Future<void> showXDialogForTest(WidgetTester t, Widget dialog) =>
    showDialog<void>(context: t.element(find.byType(HomeScreen)), builder: (_) => dialog);
