// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for chats per agent (x-control/7, CONTROL §26, D-UI-32): a server of the owner's own with three agent
// sessions, each its own chat under the server's row, two of them named by the owner ("Payments API", "Docs site"),
// one with its notifications off; Jordan's agents under Jordan; an archived chat in the folded section. The open chat
// is the one with the payments session; the second frame has its menu open. The third has "Urgent: interrupt now" on
// (CONTROL §33), after an earlier urgent message that carries its mark.

part of 'scenarios.dart';

/// The owner's own server (∞): two Claude Code sessions, one per project, and the lead agent.
ContactInfo get devServer => contact('Dev server', 61,
    trust: 5, presence: 'online', role: 'inviter', unread: 3, peerKind: 'mixed', lamport: 30, peerUrgent: true,
    agents: [
      PeerAgent(name: 'payments-dev', state: 'active', sinceMs: ms(ago(days: 3))),
      PeerAgent(name: 'docs-dev', state: 'active', sinceMs: ms(ago(days: 3))),
      PeerAgent(name: 'lead', state: 'active', sinceMs: ms(ago(days: 5))),
    ]);

List<HistoryItem> devServerHistory() => [
      msg(90, false, 'Nightly backups finished: 3 of 3.', ago(hours: 6), viaAgent: 'lead', to: 'person'),
      msg(91, true, 'Thanks. Leave the old ones for a week.', ago(hours: 5), to: 'agent', toAgent: 'lead'),
      msg(92, false, 'payments-dev is connected: write to it in this chat.', ago(hours: 2), viaAgent: 'payments-dev',
          to: 'person'),
      msg(93, true, 'Please add retries to the refund webhook, with a test.', ago(minutes: 40), to: 'agent',
          toAgent: 'payments-dev'),
      msg(94, false, 'On it. The webhook retries 3 times with backoff; the test covers a 502 from the bank.',
          ago(minutes: 31), viaAgent: 'payments-dev', to: 'person'),
      msg(95, false, 'Done: 14 tests pass. The change is on the branch refund-retries.', ago(minutes: 6),
          viaAgent: 'payments-dev', to: 'person', unread: true),
      msg(96, false, 'docs-dev is connected: write to it in this chat.', ago(hours: 2), viaAgent: 'docs-dev',
          to: 'person'),
      msg(97, false, 'The API page now lists the refund endpoints. Want a review?', ago(minutes: 14),
          viaAgent: 'docs-dev', to: 'person', unread: true),
      msg(98, false, 'Disk on /var is at 81 %.', ago(minutes: 2), viaAgent: 'lead', to: 'person', unread: true),
    ];

FakeDaemon _devServer() {
  final d = FakeDaemon(
    contacts: [devServer, jordanTeam, emily, buildBot],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory(), devServer.linkId: devServerHistory()},
  );
  d.topicMap[jordanTeam.linkId] = teamTopics();
  ChatInfo set(ContactInfo c, String agent, {String? name, String? notify, int? archivedMs}) => ChatInfo(
        contact: c.label,
        linkId: c.linkId,
        agent: agent,
        name: name,
        notify: notify ?? ChatNotify.asks,
        notifySet: notify != null,
        archivedMs: archivedMs,
        saved: true,
      );
  d.chatSettings[devServer.linkId] = {
    'payments-dev': set(devServer, 'payments-dev', name: 'Payments API'),
    'docs-dev': set(devServer, 'docs-dev', name: 'Docs site'),
    'lead': set(devServer, 'lead', notify: ChatNotify.off),
  };
  d.chatSettings[jordanTeam.linkId] = {
    'design-bot': set(jordanTeam, 'design-bot', archivedMs: ms(fixedNow)),
  };
  return d;
}

/// The payments session's chat after an urgent message: the owner stopped a deploy, the agent stopped it.
List<HistoryItem> devServerUrgentHistory() => [
      ...devServerHistory(),
      HistoryItem(
          seq: 99,
          id: hex(99 * 7 + 3),
          direction: 'out',
          kind: 'text',
          text: 'Stop the deploy now: the staging bank key is wrong.',
          ts: ms(ago(minutes: 4)),
          localMs: ms(ago(minutes: 4)),
          lamport: 99,
          status: 'delivered',
          to: 'agent',
          toAgent: 'payments-dev',
          urgent: true),
      msg(100, false, 'Stopped the deploy before it reached the bank. Waiting for the new key.', ago(minutes: 3),
          viaAgent: 'payments-dev', to: 'person'),
    ];

Future<AppModel> _devServerModel({List<HistoryItem>? history}) async {
  final d = _devServer();
  if (history != null) d.historyMap[devServer.linkId] = history;
  final m = await _model(d);
  m.archivedShown = true;
  await m.select(devServer.linkId, chat: const ThreadKey.agent('payments-dev'));
  return m;
}

void _defineChatScenarios() {
  _s('67_agent_chats', (t) async {
    const name = '67_agent_chats';
    final m = await _devServerModel();
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('67_agent_chats_dark', (t) async {
    const name = '67_agent_chats_dark';
    final m = await _devServerModel();
    await _frame(t, _dark(m));
    await _snap(t, name);
  });

  // Urgent: interrupt now, on for the next message to the payments session (CONTROL §33).
  _s('95_urgent_composer', (t) async {
    const name = '95_urgent_composer';
    final m = await _devServerModel(history: devServerUrgentHistory());
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('composer-urgent')));
    await t.pump();
    await t.enterText(find.byKey(const Key('composer')), 'Use the new key from the vault, then deploy again.');
    await t.pump();
    await _snap(t, name);
  });

  // The open chat's menu: rename, notifications, archive (kept on this computer, never sent).
  _s('68_chat_menu', (t) async {
    const name = '68_chat_menu';
    final m = await _devServerModel();
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('chat-menu-Dev server-agent-payments-dev')).last);
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });
}
