// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for the first-run tour (D-151) on a new node (no contacts, no agents) on a Mac with Claude Code, Codex,
// Claude Desktop and Cursor installed: the chat list, Agents → AI apps pointing at Claude Code's own button (light,
// dark, Russian), the agent answering in Code mode's terminal once started there, and Invite. The tour starts by
// itself because the window has a settings file and the node has nothing yet.

part of 'scenarios.dart';

/// A new node on the Mac of the Code mode frames.
Future<(AppModel, FakeDaemon, FakeAgentComputer)> _tourModel() async {
  final pc = _mac();
  final d = FakeDaemon(contacts: [], history: demoHistory())..tokenDir = '/Users/owner/.local/share/antenna';
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: pc.host,
    connectorFs: FakeConnectorFs(),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  return (m, d, pc);
}

/// The window's settings file, new: the tour is still due.
Appearance _tourLook({ThemeChoice theme = ThemeChoice.system}) {
  final dir = Directory.systemTemp.createTempSync('antenna-shot-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return Appearance.load(AppearanceStore('${dir.path}/window.json'))..choice = theme;
}

Future<void> _tourStep(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump();
}

Future<void> _tourNext(WidgetTester t) async {
  await t.tap(find.byKey(const Key('tour-next')));
  await _tourStep(t);
}

/// Claude Code just started from the tour, and the owner's first words to it.
String get _claudeHello => [
      '$_d cwd: ~/Antenna/agents/claude-code$_r',
      '',
      '$_c>$_r Hi! Are you connected to Antenna?',
      '',
      '$_g*$_r ${_b}antenna.read_inbox$_r',
      '  ${_d}No new messages.$_r',
      '',
      'Yes: I am connected as claude-code.',
      'When your contacts write to me, I answer them',
      'here, within the trust level of each contact.',
      '',
      '$_c>$_r ',
    ].join('\r\n');

void _defineTourScenarios() {
  _s('97_tour_chats', (t) async {
    const name = '97_tour_chats';
    final (m, _, _) = await _tourModel();
    await _frame(t, XApp(model: m, appearance: _tourLook()));
    await _tourStep(t);
    expect(find.byKey(const Key('tour-chats')), findsOneWidget);
    await _snap(t, name);
  });

  Future<void> aiApps(WidgetTester t, String name, ThemeChoice theme) async {
    final (m, _, _) = await _tourModel();
    await _frame(t, XApp(model: m, appearance: _tourLook(theme: theme)));
    await _tourStep(t);
    await _tourNext(t);
    expect(find.byKey(const Key('tour-aiApps')), findsOneWidget);
    await _snap(t, name);
  }

  _s('98_tour_ai_apps', (t) => aiApps(t, '98_tour_ai_apps', ThemeChoice.system));
  _s('98_tour_ai_apps_dark', (t) => aiApps(t, '98_tour_ai_apps_dark', ThemeChoice.dark));

  // Start in Code mode from the tour: once the agent runs, the tour points at its terminal.
  _s('99_tour_answers', (t) async {
    const name = '99_tour_answers';
    final (m, d, pc) = await _tourModel();
    final look = _tourLook();
    await _frame(t, XApp(model: m, appearance: look));
    await _tourStep(t);
    await _tourNext(t);
    d.agentList = [const AgentInfo(name: 'claude-code', createdMs: 0, localLevel: 5)];
    look.ui = InterfaceMode.code;
    await m.startAgent(
      const AgentRunSpec(agent: 'claude-code', cli: AgentCli.claude, workDir: '/Users/owner/Antenna/agents/claude-code'),
      auth: PasswordAuth(d.password),
    );
    await m.refreshAgents();
    await _tourStep(t);
    pc.last.emit(_claudeHello);
    await _tourStep(t);
    expect(find.byKey(const Key('tour-answers')), findsOneWidget);
    await _snap(t, name);
    for (final r in m.runs) {
      r.kill();
    }
  });

  _s('100_tour_invite', (t) async {
    const name = '100_tour_invite';
    final (m, _, _) = await _tourModel();
    await _frame(t, XApp(model: m, appearance: _tourLook()));
    await _tourStep(t);
    await _tourNext(t);
    await _tourNext(t);
    expect(find.byKey(const Key('tour-invite')), findsOneWidget);
    await _snap(t, name);
  });
}
