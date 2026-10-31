// SPDX-License-Identifier: AGPL-3.0-only
// Agents' marks and what a new agent reads (D-UI-18), on the fake daemon:
// - a contact's agent never gets a vendor logo, whatever its name says (the contact chose the name): the author line,
//   the thread chip, the To picker, the contact card, Agents → "Contacts' agents" and the chat list all show the
//   neutral agent mark; my own agent gets its AI's mark only where the window knows the app (here: connected as
//   Claude Code);
// - "Sees messages to everyone" for a new agent in Connect an agent, Connect an AI app and Start agent: off by default
//   (`agent_add` sends `everyone: false`), on sends `true`, and a daemon older than v6 gets no field and no switch.

import 'dart:async';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/agents/agents_dialog.dart';
import 'package:antenna_desktop/ui/agents/connect_app_dialog.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/widgets/ai_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

FakeAgentComputer _mac() => FakeAgentComputer(
      macos: true,
      installed: const {'/Applications/Claude.app', '/Users/owner/.local/bin/claude', '/opt/homebrew/bin/codex'},
      env: const {'HOME': '/Users/owner', 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );

Future<AppModel> _model(FakeDaemon d, {bool computer = false}) async {
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: computer ? _mac().host : null,
    defaultSocket: d.socketPath,
    connectorFs: FakeConnectorFs(const {}),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, {Appearance? look}) async {
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look ?? Appearance(rolePreset: RolePreset.assistant)));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

Finder _within(Finder of, Finder f) => find.descendant(of: of, matching: f);
Finder _key(String k) => find.byKey(Key(k));

void main() {
  testWidgets('a contact\'s agent named claude-backend gets no Claude logo anywhere; my Claude Code agent gets its mark',
      (t) async {
    // My agent `claude-code` is the agent the window creates when it connects Claude Code (Agents → AI apps).
    final mine = msg(59, true, 'The patch is ready for review.', ago(minutes: 2),
        viaAgent: 'claude-code', to: 'agent', toAgent: 'claude-backend');
    // A contact whose whole side is an agent, labelled like a vendor.
    final bot = contact('Claude helper', 61, peerKind: 'agent');
    final d = FakeDaemon(
      contacts: [jordanTeam, emily, bot],
      history: {jordanTeam.linkId: [...teamHistory(), mine]},
    )..agentList = [AgentInfo(name: 'claude-code', createdMs: 0, localLevel: 5, everyone: false)];
    final m = await _model(d);
    await m.select(jordanTeam.linkId);
    await _app(t, m);
    // The whole thread, not the default "With me" filter (D-UI-44): every message here is agent-to-agent.
    await t.tap(_key('thread-filter-all'));
    await _settle(t);

    final theirs = teamHistory().firstWhere((x) => x.seq == 53).id;
    // The picture of the contact's agent beside its message: the neutral monogram with the agent badge, no vendor logo.
    expect(_within(_key('avatar-$theirs'), _key('agent-mark-generic')), findsOneWidget);
    expect(_within(_key('avatar-$theirs'), find.byType(AiLogo)), findsNothing);
    expect(_within(_key('author-$theirs'), find.byType(AiLogo)), findsNothing);
    // Its row in the chat list and the To picker: the same.
    expect(_within(_key('chat-Jordan Lee-agent-claude-backend'), _key('agent-mark-generic')), findsOneWidget);
    expect(_within(_key('chat-Jordan Lee-agent-claude-backend'), find.byType(AiLogo)), findsNothing);
    expect(_within(_key('composer-to'), find.byType(AiLogo)), findsNothing);
    // My agent connected as Claude Code: its mark, from the app the window knows.
    expect(_within(_key('avatar-${mine.id}'), _key('ai-logo-claudecode')), findsOneWidget);
    // Per-my-agent filter chips are gone from an agent's chat (D-UI-44: "With me" / "Between agents" / "All" instead).
    expect(_key('thread-filter-mine-claude-code'), findsNothing);
    // The chat list: a contact that is an agent keeps the neutral Antenna avatar, whatever its label says.
    expect(_within(_key('contact-Claude helper'), find.byType(AiLogo)), findsNothing);

    // The contact card lists the contact's agents with the neutral mark.
    await t.tap(_key('card-toggle'));
    await _settle(t);
    await t.scrollUntilVisible(_key('peer-agent-claude-backend'), 300, scrollable: find.byType(Scrollable).last);
    expect(_within(_key('peer-agent-claude-backend'), find.byType(AiLogo)), findsNothing);

    // Agents: my Claude Code agent with its mark; Contacts' agents without any.
    await t.tap(_key('agents-button'));
    await _settle(t);
    await _settle(t);
    expect(_within(_key('agent-row-claude-code'), _key('ai-logo-claudecode')), findsOneWidget);
    await t.scrollUntilVisible(_key('contact-agent-$jordanName-claude-backend'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(_within(_key('contact-agent-$jordanName-claude-backend'), find.byType(AiLogo)), findsNothing);
  });

  group('"Sees messages to everyone" for a new agent', () {
    Future<void> issue(WidgetTester t, FakeDaemon d, String name, {bool on = false}) async {
      unawaited(showAgentsDialog(t.element(find.byType(HomeScreen))));
      await _settle(t);
      await t.enterText(_key('agent-name'), name);
      await t.tap(_key('label-3'));
      await _settle(t);
      expect(_key('new-agent-everyone'), findsOneWidget);
      expect(find.text(en.agentEveryoneNewOff), findsOneWidget, reason: 'off by default, said plainly');
      if (on) {
        await _tapVisible(t, _key('new-agent-everyone'));
        expect(find.text(en.agentEveryoneNewOn), findsOneWidget);
      }
      await t.enterText(_key('owner-password'), d.password);
      await _tapVisible(t, _key('agent-issue'));
      Navigator.of(t.element(find.byType(AgentsDialog))).pop();
      await _settle(t);
    }

    testWidgets('Connect an agent: off sends false, on sends true', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
      final m = await _model(d);
      await _app(t, m);
      await issue(t, d, 'helper');
      await issue(t, d, 'reader', on: true);
      expect(d.agentAddEveryone, [false, true]);
      expect({for (final a in d.agentList) a.name: a.everyone}, {'helper': false, 'reader': true});
    });

    testWidgets('a daemon older than v6: no switch, no field', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..protoVersion = 5;
      final m = await _model(d);
      await _app(t, m);
      unawaited(showAgentsDialog(t.element(find.byType(HomeScreen))));
      await _settle(t);
      expect(_key('new-agent-everyone'), findsNothing);
      await t.enterText(_key('agent-name'), 'helper');
      await t.tap(_key('label-3'));
      await t.enterText(_key('owner-password'), d.password);
      await _tapVisible(t, _key('agent-issue'));
      expect(d.agentAddEveryone, [null], reason: 'a v5 daemon rejects unknown fields');
    });

    testWidgets('Connect an AI app: the switch is on the set-up step, and on sends true', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
      final m = await _model(d, computer: true);
      await _app(t, m);
      await t.tap(_key('agents-button'));
      await _settle(t);
      await _tapVisible(t, _key('app-connect-claudeDesktop'));
      expect(find.byType(ConnectAppDialog), findsOneWidget);
      expect(_within(find.byType(ConnectAppDialog), find.text(en.agentEveryoneNewOff)), findsOneWidget);
      await _tapVisible(t, _within(find.byType(ConnectAppDialog), _key('new-agent-everyone')));
      await t.enterText(_within(find.byType(ConnectAppDialog), _key('owner-password')), d.password);
      await _tapVisible(t, _key('connect-continue'));
      expect(d.agentAddEveryone, [true]);
      expect(d.agentList.single.everyone, isTrue);
    });

    testWidgets('Start agent: a new agent with the switch off sends false', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
      final m = await _model(d, computer: true);
      addTearDown(() {
        for (final r in m.runs) {
          r.kill();
        }
      });
      await _app(t, m, look: Appearance(ui: InterfaceMode.code, rolePreset: RolePreset.assistant));
      await t.tap(_key('code-start-empty'));
      await _settle(t);
      expect(find.byType(StartAgentDialog), findsOneWidget);
      await t.enterText(_key('agent-name'), 'builder');
      await t.tap(_key('code-cli-codex'));
      await _settle(t);
      expect(_within(find.byType(StartAgentDialog), _key('new-agent-everyone')), findsOneWidget);
      expect(find.text(en.agentEveryoneNewOff), findsOneWidget);
      await t.enterText(_key('owner-password'), d.password);
      await _tapVisible(t, _key('code-start-go'));
      expect(d.agentAddEveryone, [false]);
    });

    testWidgets('Start agent: switched on sends true', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
      final m = await _model(d, computer: true);
      addTearDown(() {
        for (final r in m.runs) {
          r.kill();
        }
      });
      await _app(t, m, look: Appearance(ui: InterfaceMode.code, rolePreset: RolePreset.assistant));
      await t.tap(_key('code-start-empty'));
      await _settle(t);
      await t.enterText(_key('agent-name'), 'reader');
      await t.tap(_key('code-cli-codex'));
      await _settle(t);
      await _tapVisible(t, _key('new-agent-everyone'));
      expect(find.text(en.agentEveryoneNewOn), findsOneWidget);
      await t.enterText(_key('owner-password'), d.password);
      await _tapVisible(t, _key('code-start-go'));
      expect(d.agentAddEveryone, [true]);
    });
  });
}

