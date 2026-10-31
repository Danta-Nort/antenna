// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for teams of agents (x-control/7, CONTROL §25, D-111; DESIGN "Teams"): the Teams page (two teams, one
// waiting for the owner), a team's board with a worker writing live, a task in full (its conversation, and its
// changes), New team, applying the team's work to the project's branch with the password, and a worker's read-only
// tab in the Code mode dock. Demo data: the fake daemon's `demoTeam`, international names.

part of 'scenarios.dart';

/// The web team (claude leads it from Code mode) and a stopped docs team the owner leads.
FakeDaemon _teamDemo() {
  final d = _demo()
    ..teamsEnabled = true
    ..agentList = [
      AgentInfo(name: 'claude', createdMs: 0, localLevel: 5, links: [jordanName]),
      const AgentInfo(name: 'helper', createdMs: 0, links: [], localModel: 'qwen3.5-9b'),
    ]
    ..teamDiffs[demoTask(4, title: '').id] = demoDiff;
  d.addTeam(demoTeam());
  d.addTeam(TeamInfo(
    name: 'docs-site',
    project: '/Users/jordan/code/docs-site',
    target: 'main',
    integration: 'antenna/docs-site',
    state: 'stopped',
    slots: const [TeamSlot(role: 'docs', kind: WorkerKind.local, model: 'qwen3.5-9b', max: 2)],
    maxWorkers: 2,
    template: const TeamTemplate(commands: false, localOnly: true),
    workers: [demoWorker('docs-site.docs-1', team: 'docs-site', role: 'docs', kind: WorkerKind.local, model: 'qwen3.5-9b',
        state: WorkerState.stopped, spawnedBy: 'owner')],
    tasks: [
      demoTask(8, team: 'docs-site', title: 'Summarize the changelog for 0.2', check: const [], createdBy: 'owner',
          state: TaskState.done, assignee: 'docs-site.docs-1', round: 1, minutes: 300),
    ],
    createdMs: demoTeamNow - 86400000,
  ));
  return d;
}

/// The live output of web.coder-1, as `team_watch` streams it.
void _teamLive(AppModel m) {
  final task = demoTask(3, title: '').id;
  m
    ..onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: task, turn: 7, part: 'start'))
    ..onWorkerOutput(WorkerOutputEvent(
        team: 'web',
        worker: 'web.coder-1',
        task: task,
        turn: 7,
        part: 'text',
        text: 'The year rolls over before the week check, so 2026-W53 lands in 2027.\n\n'
            'Moving the check into parse_week and adding a test for 2026-W53.\n'))
    ..onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: task, turn: 7, part: 'activity', text: 'tool:Bash'));
}

Future<void> _teamsFrame(WidgetTester t, Widget app, {String? board}) async {
  await _frame(t, app);
  await t.tap(find.byKey(const Key('nav-teams')));
  await t.pump(const Duration(milliseconds: 400));
  if (board != null) {
    await t.tap(find.byKey(Key('team-open-$board')));
    await t.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _taskFrame(WidgetTester t, Widget app, {int task = 4, String? tab}) async {
  await _teamsFrame(t, app, board: 'web');
  await t.tap(find.byKey(Key('task-open-${demoTask(task, title: '').shortId}')));
  await t.pump(const Duration(milliseconds: 400));
  if (tab != null) {
    await t.tap(find.byKey(Key(tab)));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _newTeamFrame(WidgetTester t, Widget app) async {
  await _teamsFrame(t, app);
  await t.tap(find.byKey(const Key('team-new')));
  await t.pump(const Duration(milliseconds: 400));
  await t.enterText(find.byKey(const Key('team-new-name')), 'shop');
  await t.enterText(find.byKey(const Key('team-new-project')), '/Users/jordan/code/shop');
  // The check command is added below the fold; the frame shows the top of the form.
  await t.enterText(find.byKey(const Key('team-new-check')), 'cargo test');
  await t.ensureVisible(find.byKey(const Key('team-new-check-add')));
  await t.pump();
  await t.tap(find.byKey(const Key('team-new-check-add')));
  await t.pump(const Duration(milliseconds: 400));
  await t.ensureVisible(find.byKey(const Key('team-new-about')));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _applyFrame(WidgetTester t, Widget app) async {
  await _teamsFrame(t, app, board: 'web');
  await t.tap(find.byKey(const Key('team-apply-review')));
  await t.pump(const Duration(milliseconds: 400));
  await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
  await t.pump(const Duration(milliseconds: 400));
}

void _defineTeamScenarios() {
  for (final dark in [false, true]) {
    final s = dark ? '_dark' : '';
    Widget app(AppModel m) => dark ? _dark(m) : XApp(model: m);

    _s('71_teams$s', (t) async {
      final m = await _model(_teamDemo());
      await _teamsFrame(t, app(m));
      await _snap(t, '71_teams$s');
    });

    _s('72_team_board$s', (t) async {
      final m = await _model(_teamDemo());
      _teamLive(m);
      await _teamsFrame(t, app(m), board: 'web');
      await _snap(t, '72_team_board$s');
    });

    _s('73_task_detail$s', (t) async {
      final m = await _model(_teamDemo());
      await _taskFrame(t, app(m), task: 5);
      await _snap(t, '73_task_detail$s');
    });

    _s('75_new_team$s', (t) async {
      final m = await _model(_teamDemo());
      await _newTeamFrame(t, app(m));
      await _snap(t, '75_new_team$s');
    });
  }

  _s('74_task_changes', (t) async {
    final m = await _model(_teamDemo());
    await _taskFrame(t, XApp(model: m), task: 4, tab: 'task-tab-changes');
    await _snap(t, '74_task_changes');
  });

  _s('76_team_apply', (t) async {
    final m = await _model(_teamDemo());
    await _applyFrame(t, XApp(model: m));
    await _snap(t, '76_team_apply');
  });

  _s('77_code_team_worker', (t) async {
    final pc = _mac();
    final d = _teamDemo();
    final m = await _codeModel(d, pc);
    await m.startAgent(
      const AgentRunSpec(agent: 'claude', cli: AgentCli.claude, workDir: '/Users/jordan/code/web'),
      auth: PasswordAuth(d.password),
    );
    _teamLive(m);
    m.showWorkerInDock('web.coder-1');
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.tap(find.byKey(const Key('nav-teams')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('team-open-web')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, '77_code_team_worker');
    for (final r in m.runs) {
      r.kill();
    }
  });
}
