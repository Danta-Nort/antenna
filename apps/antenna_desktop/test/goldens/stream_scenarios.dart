// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for streaming replies and wake (x-control/4): the live bubble of an agent's reply, the Agents section with
// a wake rule, and setting up "an agent that replies on its own".

part of 'scenarios.dart';

/// Link with a node on a server (level 5, so "what it is doing" is visible) where an agent replies on wake.
ContactInfo get _server => buildBot;

Map<String, List<HistoryItem>> _serverHistory() => {
      ...demoHistory(),
      _server.linkId: [
        msg(40, false, 'build #413 · main · ok · 3m12s · 0 warnings', ago(minutes: 30)),
        msg(41, true, 'Why does auth::refresh fail in build 412? Suggest a fix.', ago(minutes: 1)),
      ],
    };

WakeRuleInfo _serverRule({bool running = false}) => WakeRuleInfo(
      contact: _server.label,
      linkId: _server.linkId,
      agent: 'wake-buildbot',
      argv: const ['/usr/local/bin/claude', '-p', '--output-format', 'stream-json'],
      mode: 'claude_stream',
      timeoutSecs: 600,
      maxRunsPerHour: 20,
      homeFiles: const [],
      secretEnv: const ['CLAUDE_CODE_OAUTH_TOKEN'],
      createdMs: ms(ago(days: 1)),
      running: running,
      last: WakeRunInfo(
        runId: 'r-0007',
        startedMs: ms(ago(minutes: 31)),
        endedMs: ms(ago(minutes: 30)),
        outcome: 'ok',
        exitCode: 0,
        sandbox: 'bwrap',
        detail: 'reply 7c1e…; proxy: allowed api.anthropic.com ×3, blocked 0',
      ),
    );

/// The same rule, resident (D-93): a session that has worked for a while and sleeps in the encrypted database.
WakeRuleInfo _residentRule({String state = ResidentState.sleeping}) => WakeRuleInfo(
      contact: _server.label,
      linkId: _server.linkId,
      agent: 'wake-buildbot',
      argv: const ['/usr/local/bin/claude', '-p', '--output-format', 'stream-json'],
      mode: 'claude_stream',
      timeoutSecs: 600,
      maxRunsPerHour: 60,
      homeFiles: const [],
      secretEnv: const ['CLAUDE_CODE_OAUTH_TOKEN'],
      createdMs: ms(ago(days: 3)),
      resident: ResidentInfo(
        state: state,
        sessionId: 'c0ffee00-1111-4222-8333-444455556666',
        sessionStartedMs: ms(ago(days: 3)),
        turns: 14,
        ownerTurns: 3,
        starts: 4,
        inputTokens: 1200,
        outputTokens: 5400,
        cacheReadTokens: 410000,
        contextTokens: 38200,
        costMicroUsd: 1840000,
        lastTurnMs: ms(ago(minutes: 40)),
        compactions: 1,
        idleStopSecs: 3600,
        parked: state == ResidentState.sleeping,
      ),
    );

void _defineStreamScenarios() {
  _s('27_live_stream', (t) async {
    const name = '27_live_stream';
    final d = FakeDaemon(contacts: demoContacts(), history: _serverHistory());
    final m = await _model(d);
    await m.select(_server.linkId);
    final f = StreamFeed(_server);
    m
      ..handleEvent(f.open(activity: 'tool:Bash'))
      ..handleEvent(f.chunk(
          'Found it: the token is refreshed by two tasks at once, and the second one reads the old value before the '
              "first one writes. It's a race, not a timeout. I suggest:\n\n1. Keep the refresh under one mutex;\n2. ",
          activity: 'tool:Bash'));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('28_wake_agents', (t) async {
    const name = '28_wake_agents';
    final d = FakeDaemon(contacts: demoContacts(), history: _serverHistory());
    d.agentList = [
      AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 4, links: [jordanName, buildBotName]),
      AgentInfo(name: 'wake-buildbot', createdMs: 0, localLevel: 0, links: [buildBotName]),
    ];
    d.wakeRuleList = [_serverRule()];
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('29_wake_setup', (t) async {
    const name = '29_wake_setup';
    final d = FakeDaemon(contacts: demoContacts(), history: _serverHistory());
    final m = await _model(d);
    await m.refreshWake();
    await _frame(t, XApp(model: m));
    unawaited(showWakeDialog(t.element(find.byType(HomeScreen)), linkId: _server.linkId));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('wake-secret-value')), 'sk-ant-oat01-0000000000000000');
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // PG-23: a resident agent's session on its rule's card, and the owner's own words to it.
  _s('84_resident_session', (t) async {
    const name = '84_resident_session';
    final d = FakeDaemon(contacts: demoContacts(), history: _serverHistory());
    d.agentList = [
      AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 4, links: [jordanName, buildBotName]),
      AgentInfo(name: 'wake-buildbot', createdMs: 0, localLevel: 0, links: [buildBotName]),
    ];
    d.wakeRuleList = [_residentRule()];
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await t.ensureVisible(find.byKey(Key('resident-${_server.label}')));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('85_resident_talk', (t) async {
    const name = '85_resident_talk';
    final d = FakeDaemon(contacts: demoContacts(), history: _serverHistory());
    d.wakeRuleList = [_residentRule(state: ResidentState.busy)];
    final m = await _model(d);
    await m.refreshWake();
    await _frame(t, XApp(model: m));
    unawaited(showResidentTalk(t.element(find.byType(HomeScreen)), _server.linkId));
    await t.pump(const Duration(milliseconds: 400));
    unawaited(m.sayResident(_server.linkId, 'What did you find in build 412? Keep it short.'));
    await t.pump();
    d.wakeSays.last.$4.emit(ResidentDeltaEvent(
        contact: _server.label,
        turn: 15,
        delta: 'The refresh races itself: two tasks renew the token at once and the second reads the old value. '
            'One mutex around the refresh fixes it; '));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // x-control/5: contact agents by name, and LAN.

  _s('30_contact_agents', (t) async {
    const name = '30_contact_agents';
    final m = await _model(_demo());
    await m.select(jordan.linkId);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.scrollUntilVisible(find.text(l10nFor(demoLang).cardAgentsTitle.toUpperCase()), 300,
        scrollable: find.byType(Scrollable).last);
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('31_lan', (t) async {
    const name = '31_lan';
    final d = _demo()
      ..lanEnabled = true
      ..lanLinks = [
        LanLink(contact: emily.label, beacon: false, found: const ['192.168.1.23:51820'], foundMs: ms(ago(minutes: 1))),
        LanLink(contact: jordan.label, beacon: true),
        LanLink(contact: buildBot.label, beacon: false),
      ];
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('settings-network')));
    await t.pump(const Duration(milliseconds: 400));
    // The LAN state arrives after the section's first frame: let the switch finish its animation.
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });
}

