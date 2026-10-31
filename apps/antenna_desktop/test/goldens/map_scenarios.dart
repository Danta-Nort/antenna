// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for the agent map (x-control/7, CONTROL §30, D-UI-47; experimental): Agents → Map, the editor, with this
// computer in the middle (volna in Claude Code connected both ways with the Mac mini's session-2, docs-bot in Codex
// connected to Bob's builder and leading the team "site", reviewer waiting for the build server's approval, a
// local-model agent and the team's worker), the Mac mini and the build server on the left (∞), Bob and Emily Carter on
// the right; the connect dialog for an agent of an own computer; a selected line with its popover, with the recent
// messages layer on and two agents of this computer connected inside its group; the dialog that connects two agents
// of this computer. Demo data: `mapDemo` (international names).

part of 'scenarios.dart';

/// The Code mode runs the window remembers, so volna and reviewer show Claude Code's mark and docs-bot Codex's.
const _mapRuns = <String, Object?>{
  'volna': {'cli': 'claude', 'dir': '/Users/maya/code/volna'},
  'docs-bot': {'cli': 'codex', 'dir': '/Users/maya/code/docs'},
  'reviewer': {'cli': 'claude', 'dir': '/Users/maya/code/site'},
};

/// [local]: the daemon knows connections between two agents of this computer; [tester]: and a tester agent is
/// connected to docs-bot there (its messages without an address go to docs-bot, it takes docs-bot's as tasks).
Future<AppModel> _mapModel({bool local = false, bool tester = false}) async {
  final demo = mapDemo();
  final d = FakeDaemon(contacts: demo.contacts)
    ..devicesEnabled = true
    ..teamsEnabled = true
    ..agentList = [
      for (final a in demo.agents)
        if (tester && a.name == 'docs-bot')
          mapAgent('docs-bot',
              counterpart: const Counterpart(contact: 'Bob', agent: 'builder'),
              tasksFrom: const [],
              localRoutes: const [LocalRoute(agent: 'tester')])
        else
          a,
      if (tester)
        mapAgent('tester',
            counterpart: const Counterpart(contact: '', agent: 'docs-bot', local: true),
            localRoutes: const [LocalRoute(agent: 'docs-bot', tasks: true)]),
    ]
    ..devicesState = demo.devices
    ..trafficPairs = demo.traffic;
  d.localRoutesEnabled = local || tester;
  PictureEntry theirs(String label, {String? agent, required String drawn}) {
    final c = demo.contacts.firstWhere((c) => c.label == label);
    return PictureEntry(contact: c.label, linkId: c.linkId, agent: agent, drawn: drawn);
  }

  d.pictureList = [
    theirs('Mac mini', agent: 'session-2', drawn: 'set3/axolotl'),
    theirs('Bob', drawn: 'set1/rabbit'),
    theirs('Bob', agent: 'builder', drawn: 'set2/wolf'),
  ];
  d.addTeam(TeamInfo(
    name: 'site',
    project: '/Users/maya/code/site',
    target: 'main',
    integration: 'antenna/site',
    lead: 'docs-bot',
    state: 'active',
    workers: [
      demoWorker('site.docs-1', team: 'site', role: 'docs', kind: WorkerKind.local, model: 'qwen3.5-4b',
          state: WorkerState.busy),
    ],
  ));
  final m = await _model(d);
  await m.refreshAgentMap();
  // reviewer was connected to the build server's lead from this window: the request waits there
  await m.connectAgent(const AgentConnectRequest(
      name: 'reviewer', contact: 'Build server', agent: 'lead', peerTasks: true, password: 'correct horse battery'));
  return m;
}

Future<void> _mapFrame(WidgetTester t, AppModel m, {bool dark = false}) async {
  await _frame(
      t,
      XApp(
          model: m,
          appearance: Appearance(initial: dark ? ThemeChoice.dark : ThemeChoice.light, agentRuns: _mapRuns)));
  await t.tap(find.byKey(const Key('agents-button')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('agents-view-map')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _decodeImages(t);
}

void _defineMapScenarios() {
  Future<void> map(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _mapModel();
    await _mapFrame(t, m, dark: dark);
    await _snap(t, name);
  }

  _s('86_agent_map', (t) => map(t, '86_agent_map'));
  _s('86_agent_map_dark', (t) => map(t, '86_agent_map_dark', dark: true));

  /// A line drawn with the mouse from [from]'s handle to [to], and the dialog it opens with the password typed.
  Future<void> drawTo(WidgetTester t, String from, String to, {required String side}) async {
    final a = t.getCenter(find.byKey(Key('agent-map-handle-$from-$side')));
    final b = t.getCenter(find.byKey(Key('agent-map-node-$to')));
    final g = await t.startGesture(a, kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(24, 0));
    await t.pump();
    await g.moveTo(b);
    await t.pump();
    await g.up();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 400));
    await _decodeImages(t);
  }

  _s('87_agent_connect', (t) async {
    final m = await _mapModel();
    await _mapFrame(t, m);
    // Drawn with the mouse: from docs-bot's handle to the Mac mini's codex
    await drawTo(t, 'here/docs-bot', 'c/Mac mini/a/codex', side: 'l');
    await _snap(t, '87_agent_connect');
  });

  _s('93_map_line_selected', (t) async {
    final m = await _mapModel(tester: true);
    await _mapFrame(t, m);
    // The recent messages layer on, then a click on the line between volna and the Mac mini's session-2
    await t.tap(find.byKey(const Key('agent-map-recent')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('agent-map-line-configured:here/volna>c/Mac mini/a/session-2')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _decodeImages(t);
    await _snap(t, '93_map_line_selected');
  });

  _s('94_local_connect', (t) async {
    final m = await _mapModel(local: true);
    await _mapFrame(t, m);
    // Two agents of this computer: from docs-bot's handle to reviewer
    await drawTo(t, 'here/docs-bot', 'here/reviewer', side: 'l');
    await _snap(t, '94_local_connect');
  });
}
