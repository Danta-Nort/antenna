// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for addressing, topics and batch approvals (x-control/6, CONTROL §20, D-UI-18): a link with three
// counterparts on the contact's side shown as threads, the filters inside a thread, authorship over the bubbles, the
// composer's address line; several approval requests decided with one password.

part of 'scenarios.dart';

FakeDaemon _team() {
  final d = FakeDaemon(
    contacts: [jordanTeam, emily, buildBot, ryan, rachel],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
  );
  d.topicMap[jordanTeam.linkId] = teamTopics();
  return d;
}

Future<AppModel> _teamModel() async {
  final m = await _model(_team());
  await m.select(jordanTeam.linkId);
  // The owner picked a topic for the next message: the address line shows it next to "To".
  m.setTopicChoice(jordanTeam.linkId, TopicChoice.existing(topicAvatars));
  return m;
}

void _defineThreadScenarios() {
  // Jordan's agent `claude-backend` is the open thread: my two agents and I talk to it about two topics; Jordan
  // himself and his `design-bot` each have an unread message in their own threads.
  _s('40_threads', (t) async {
    const name = '40_threads';
    final m = await _teamModel();
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('40_threads_dark', (t) async {
    const name = '40_threads_dark';
    final m = await _teamModel();
    await _frame(t, _dark(m));
    await _snap(t, name);
  });

  // Four requests; two were approved with one password, one of them had expired and is reported alone; the other two
  // are selected for the next decision.
  _s('41_batch_approvals', (t) async {
    const name = '41_batch_approvals';
    final requests = [
      agentApproval('ap-b1d001', jordanTeam,
          quote: 'Summary for Jordan: build 412 passes after the token fix; the flaky test is quarantined.',
          fingerprint: 'b1d0017e', minutesAgo: 4),
      agentApproval('ap-b1d002', jordanTeam,
          quote: 'Attaching the full log from the CI run.', fingerprint: 'b1d0022a', minutesAgo: 3),
      agentApproval('ap-b1d003', jordanTeam,
          action: 'share_file', quote: '/home/owner/build/auth-refresh.log → auth-refresh.log', fingerprint: 'b1d00391',
          minutesAgo: 2),
      agentApproval('ap-c9a004', jordanTeam,
          requester: 'chatgpt', quote: 'The avatar sizes are fine; sending the first three drafts.', fingerprint: 'c9a004e5'),
    ];
    final d = _team()
      ..approvalList = requests
      ..expiredIds.add('ap-b1d002');
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('select-ap-b1d001')));
    await t.tap(find.byKey(const Key('select-ap-b1d002')));
    await t.pump();
    await t.tap(find.byKey(const Key('approve-selected')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('approvals-select-all')));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });
}
