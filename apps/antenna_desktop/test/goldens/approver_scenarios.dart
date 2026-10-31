// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for approver agents (x-control/7, CONTROL §31; experimental): the red warning before volna is named to answer
// builder's requests (messages and files it sends) in the owner's place; the conversation with the build server, where
// volna approved builder's summary with its reason and builder's next request waits because volna's answer did not
// count; and the approvers with their latest answers. Demo data: `approversDemo` (international names).

part of 'scenarios.dart';

Future<(AppModel, FakeDaemon)> _approverModel({
  List<ApproverInfo> approvers = const [],
  List<DelegatedAnswer> answers = const [],
  List<ApprovalInfo> approvals = const [],
}) async {
  final demo = approversDemo();
  final server = demo.contacts.firstWhere((c) => c.label == 'Build server');
  final d = FakeDaemon(contacts: demo.contacts, approvals: [...approvals], history: {
    server.linkId: [
      msg(301, false, 'build #418 · main · ok · 3m02s · 2 warnings', ago(minutes: 14)),
      msg(302, true, 'Thanks. builder will send the summary.', ago(minutes: 12)),
    ],
  })
    ..agentList = demo.agents
    ..approversEnabled = true
    ..approverList = [...approvers]
    ..answerList = [...answers];
  final m = await _model(d);
  await m.refreshApprovers();
  if (approvals.isNotEmpty) await m.refreshApprovals();
  return (m, d);
}

const _volnaReason = 'The build summary for my own server, as the task asked; no secrets in it.';

DelegatedAnswer _demoAnswer(String id, String decision, String action, int minutes,
        {String approver = 'volna', String? device, String reason = _volnaReason, String? target = 'Build server'}) =>
    DelegatedAnswer(
      approvalId: id,
      action: action,
      requester: 'builder',
      contact: 'Mac mini',
      target: target,
      approver: approver,
      device: device,
      decision: decision,
      reason: reason,
      atMs: ms(ago(minutes: minutes)),
    );

void _defineApproverScenarios() {
  // Agents → volna → Can approve for… → Yes, builder's messages and files → Save: the warning, red.
  _s('88_approver_warning', (t) async {
    final (m, _) = await _approverModel();
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await t.scrollUntilVisible(find.byKey(const Key('agent-approver-edit-volna')), 300,
        scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('agent-approver-edit-volna')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('approver-on')));
    await t.pump();
    await t.tap(find.byKey(const Key('approver-agents-chosen')));
    await t.pump();
    await t.tap(find.byKey(const Key('approver-agent-builder')));
    await t.pump();
    for (final k in ['request_file', 'accept_file']) {
      await t.tap(find.byKey(Key('approver-kind-$k')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('approver-save')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, '88_approver_warning');
  });

  // The conversation with the build server: decided by volna, and a request whose answer did not count.
  Future<void> card(WidgetTester t, String name, {bool dark = false}) async {
    final (m, _) = await _approverModel(
      approvers: [ApproverInfo(agent: 'volna', createdMs: ms(ago(days: 1)), agents: const ['builder'])],
      approvals: [
        approverRequest('ap-71c2', action: 'share_file', quote: '/srv/build/report-418.txt → report-418.txt', minutesAgo: 1,
            refused: DelegateNote(
                agent: 'volna',
                why: DelegateWhy.tainted,
                message: 'its session read a contact below level 5',
                atMs: ms(ago(minutes: 0)))),
      ],
    );
    m.handleEvent(ApprovalEvent(approverRequest('ap-5e90',
        state: 'approved',
        minutesAgo: 6,
        quote: 'Build 418 is green: 2 warnings, 0 failures. Report attached next.',
        decidedBy: DecidedBy(agent: 'volna', reason: _volnaReason, atMs: ms(ago(minutes: 5))))));
    m.handleEvent(const ApprovalResolvedEvent(id: 'ap-5e90', state: 'completed'));
    await m.select(approversDemo().contacts.firstWhere((c) => c.label == 'Build server').linkId);
    await _frame(t, dark ? _dark(m) : XApp(model: m));
    await _snap(t, name);
  }

  _s('89_approver_card', (t) => card(t, '89_approver_card'));
  _s('89_approver_card_dark', (t) => card(t, '89_approver_card_dark', dark: true));

  // Agents → Approvers: who answers for whom, a stale one, the latest answers.
  _s('90_approvers_list', (t) async {
    final (m, _) = await _approverModel(
      approvers: [
        ApproverInfo(
            agent: 'volna', createdMs: ms(ago(days: 1)), agents: const ['builder'], kinds: const ['send_message', 'share_file']),
        ApproverInfo(
            agent: 'session-2',
            contact: 'Mac mini',
            linkId: approversDemo().contacts.first.linkId,
            kinds: const ['send_message'],
            keyId: '9c41e07a3b5d0f12',
            createdMs: ms(ago(days: 2))),
        ApproverInfo(
            agent: 'lead',
            contact: 'Build server',
            linkId: approversDemo().contacts[1].linkId,
            stale: true,
            createdMs: ms(ago(days: 6))),
      ],
      answers: [
        _demoAnswer('ap-71c2', AnswerDecision.refused, 'share_file', 0,
            reason: 'its session read a contact below level 5'),
        _demoAnswer('ap-5e90', AnswerDecision.approved, 'send_message', 5),
        _demoAnswer('ap-4a11', AnswerDecision.denied, 'request_file', 47,
            approver: 'session-2', device: 'Mac mini', reason: 'Not this file: the task asked for the log only.'),
        _demoAnswer('ap-39d0', AnswerDecision.approved, 'send_message', 95),
      ],
    );
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await t.ensureVisible(find.byKey(const Key('approvers-all-answers')));
    await t.pump();
    await t.tap(find.byKey(const Key('approvers-all-answers')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, '90_approvers_list');
  });
}
