// SPDX-License-Identifier: AGPL-3.0-only
// After the owner approves, the daemon finishes the agent's action itself (x-control/6, `completes`): the card does
// not vanish at once but says "Approved — Antenna is finishing it…" (no buttons) and leaves when the daemon reports
// the outcome (`approval_resolved`), when the request is used up, or 15 s after the approval at the latest (a daemon
// that sends no outcome); a failure stays with its reason until the owner dismisses it. A request the daemon does not
// finish (`completes: false`, every older daemon) leaves as soon as it is approved, as before. Nothing in the window
// asks the owner to tell the agent anything.

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/messages.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
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
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

ApprovalInfo _as(ApprovalInfo a, String state) => ApprovalInfo(
      id: a.id,
      state: state,
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
      completes: a.completes,
    );

ApprovalResolvedEvent _resolved(ApprovalInfo a, String state, {XControlException? error}) => ApprovalResolvedEvent(
      id: a.id,
      state: state,
      action: a.action,
      requester: a.requester,
      contact: a.contact,
      linkId: a.linkId,
      target: a.target,
      targetLinkId: a.targetLinkId,
      error: error,
      message: 'The owner approved; Antenna sent it for the agent.',
      atMs: ms(fixedNow),
    );

Finder _card(String id) => find.byKey(Key('chat-approval-$id'));

/// Open the conversation with Jordan and approve [a] from its card, with the password.
Future<void> _approveInChat(WidgetTester t, AppModel m, FakeDaemon d, ApprovalInfo a) async {
  await m.select(jordan.linkId);
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.descendant(of: _card(a.id), matching: find.byKey(Key('approve-${a.id}'))));
  await t.pump(const Duration(milliseconds: 300));
  await t.enterText(find.byKey(const Key('owner-password')), d.password);
  await t.tap(find.byKey(const Key('password-ok')));
  await t.pump(const Duration(milliseconds: 300));
}

void _expectFinishing(String id) {
  expect(_card(id), findsOneWidget, reason: 'the card does not vanish at once');
  expect(find.descendant(of: _card(id), matching: find.text(en.approvalFinishing)), findsOneWidget);
  expect(find.byKey(Key('approval-finishing-$id')), findsOneWidget, reason: 'a small progress mark');
  expect(find.descendant(of: _card(id), matching: find.byType(FilledButton)), findsNothing, reason: 'no buttons');
  expect(find.descendant(of: _card(id), matching: find.byType(OutlinedButton)), findsNothing);
}

void main() {
  testWidgets('finishing, then gone when approval_resolved says completed', (t) async {
    final a = agentApproval('ap-f1', jordan, action: 'share_file', quote: '/tmp/build.log → build.log', completes: true);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    // Pending: the note says that nobody has to tell the agent.
    expect(find.descendant(of: _card(a.id), matching: find.text(en.approvalContinuesNote)), findsOneWidget);
    await _approveInChat(t, m, d, a);
    expect(d.passwords['approve'], d.password);
    expect(m.approvals, isEmpty, reason: 'nothing waits for the owner any more');
    _expectFinishing(a.id);
    expect(find.text(en.approvalContinuesNote), findsNothing);
    // The subscription reports the approval itself; the card stays.
    m.handleEvent(ApprovalEvent(_as(a, 'approved')));
    await t.pump(const Duration(milliseconds: 100));
    _expectFinishing(a.id);
    m.handleEvent(_resolved(a, 'completed'));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
  });

  testWidgets('finishing, then gone when the approval event says used', (t) async {
    final a = agentApproval('ap-f2', jordan, quote: 'Deploy notes for Jordan', completes: true);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await _approveInChat(t, m, d, a);
    _expectFinishing(a.id);
    m.handleEvent(ApprovalEvent(_as(a, 'used')));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    // A late `approval_resolved{completed}` changes nothing.
    m.handleEvent(_resolved(a, 'completed'));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
  });

  testWidgets('a daemon that reports no outcome: the card leaves 15 s after the approval', (t) async {
    final a = agentApproval('ap-f3', jordan, quote: 'Status for Jordan', completes: true);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await _approveInChat(t, m, d, a);
    _expectFinishing(a.id);
    await t.pump(const Duration(seconds: 14));
    _expectFinishing(a.id);
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
    // The outcome arriving afterwards does not bring it back.
    m.onApproved(_as(a, 'approved'));
    expect(m.finishing, isEmpty);
  });

  testWidgets('failed: the reason, and Dismiss', (t) async {
    final a = agentApproval('ap-f4', jordan, action: 'share_file', quote: '/tmp/build.log → build.log', completes: true);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await _approveInChat(t, m, d, a);
    // The daemon used the approval, then could not carry the action out.
    m.handleEvent(ApprovalEvent(_as(a, 'used')));
    const why = XControlException(XErrorCode.network, 'the contact is unreachable');
    m.handleEvent(_resolved(a, 'failed', error: why));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsOneWidget, reason: 'a failure stays');
    expect(find.descendant(of: _card(a.id), matching: find.text(en.approvalFinishFailed(describeError(en, why)))),
        findsOneWidget);
    expect(find.byKey(Key('approval-finishing-${a.id}')), findsNothing);
    expect(find.descendant(of: _card(a.id), matching: find.text(a.quote)), findsOneWidget,
        reason: 'what was approved is still shown');
    // It is also in the list.
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: find.byType(ApprovalsDialog), matching: find.byKey(Key('approval-dismiss-${a.id}'))),
        findsOneWidget);
    Navigator.of(t.element(find.byType(ApprovalsDialog))).pop();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(Key('approval-dismiss-${a.id}')));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
    // 15 s later nothing comes back.
    await t.pump(const Duration(seconds: 16));
    expect(_card(a.id), findsNothing);
  });

  testWidgets('a failure for a request the window never showed: who, what and why, from the event', (t) async {
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await _app(t, m);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    final a = agentApproval('ap-f5', jordan, requester: 'claude-code', completes: true);
    m.handleEvent(_resolved(a, 'failed', error: const XControlException(XErrorCode.denied, 'over the daily limit')));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsOneWidget);
    expect(find.text('claude-code ${en.approvalsAsks} ${en.actionSendMessage}  →  $jordanName', findRichText: true),
        findsOneWidget);
    await t.tap(find.byKey(Key('approval-dismiss-${a.id}')));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
  });

  testWidgets('completes: false (and every older daemon): the card leaves as soon as it is approved', (t) async {
    final a = agentApproval('ap-f6', jordan, quote: 'Status for Jordan');
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    await _app(t, m);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.approvalContinuesNote), findsNothing, reason: 'the agent acts on the approval itself');
    await _approveInChat(t, m, d, a);
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
    m.handleEvent(ApprovalEvent(_as(a, 'approved')));
    m.handleEvent(_resolved(a, 'approved'));
    await t.pump(const Duration(milliseconds: 100));
    expect(_card(a.id), findsNothing);
    expect(m.finishing, isEmpty);
  });

  testWidgets('batch approve: each request the daemon finishes shows as finishing, the others leave', (t) async {
    final b1 = agentApproval('ap-b1', jordan, quote: 'one', fingerprint: 'b1b1b1b1', completes: true);
    final b2 = agentApproval('ap-b2', jordan, quote: 'two', fingerprint: 'b2b2b2b2', completes: true);
    final b3 = agentApproval('ap-b3', jordan, quote: 'three', fingerprint: 'b3b3b3b3');
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [b1, b2, b3]);
    final m = await _model(d);
    await _app(t, m);
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('approvals-select-all')));
    await t.pump();
    await t.tap(find.byKey(const Key('approve-selected')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.approveManyCalls, hasLength(1));
    expect(m.approvals, isEmpty);
    expect(m.finishing.keys, unorderedEquals([b1.id, b2.id]));
    final dialog = find.byType(ApprovalsDialog);
    expect(find.descendant(of: dialog, matching: find.text(en.approvalFinishing)), findsNWidgets(2));
    expect(find.descendant(of: dialog, matching: find.byKey(const Key('approve-selected'))), findsNothing,
        reason: 'nothing left to select');
    m.handleEvent(_resolved(b1, 'completed'));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: dialog, matching: find.text(en.approvalFinishing)), findsOneWidget);
    m.handleEvent(ApprovalEvent(_as(b2, 'used')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: dialog, matching: find.text(en.approvalFinishing)), findsNothing);
    expect(find.descendant(of: dialog, matching: find.text(en.approvalsNone)), findsOneWidget);
  });

  test('order: an outcome that arrives before the approve reply is not replaced by "finishing"', () async {
    final a = agentApproval('ap-o1', jordan, completes: true);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = await _model(d);
    // The subscription is faster than the reply: approved, used, completed, then the reply.
    m.handleEvent(ApprovalEvent(_as(a, 'approved')));
    expect(m.finishing.keys, [a.id]);
    m.handleEvent(ApprovalEvent(_as(a, 'used')));
    m.handleEvent(_resolved(a, 'completed'));
    expect(m.finishing, isEmpty);
    expect(await m.approve(a.id, d.password), isNull);
    expect(m.finishing, isEmpty, reason: 'the outcome is known already');
    // A pending request elsewhere is not affected; an approval the window did not see as pending still counts.
    final b = agentApproval('ap-o2', emily, completes: true);
    m.handleEvent(ApprovalEvent(_as(b, 'approved')));
    expect(m.finishingFor(emily.linkId).map((f) => f.approval.id), [b.id]);
    expect(m.finishingFor(jordan.linkId), isEmpty);
    m.handleEvent(_resolved(b, 'expired'));
    expect(m.finishing, isEmpty);
    m.dispose();
  });
}
