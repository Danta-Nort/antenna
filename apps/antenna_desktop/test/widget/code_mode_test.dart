// SPDX-License-Identifier: AGPL-3.0-only
// Code mode on the fake daemon and a fake pseudo-terminal: the interface switch (Chat by default, saved), the layout
// (chats, conversation, the agents' terminals on the right; tabs, folding, resizing), "Start agent" (the token comes
// from the owner flow with the password and goes only into the program's environment), status, Restart and Stop, the
// question when the window closes, the one-time offer.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/code_offer.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart';
import 'package:antenna_desktop/ui/code/terminal_text.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

Future<(AppModel, FakeDaemon, FakeAgentComputer)> _setup({
  List<AgentInfo> agents = const [],
  FakeAgentComputer? computer,
  CoreBinaries bins = _bins,
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..agentList = [...agents];
  final c = computer ?? FakeAgentComputer();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  addTearDown(() {
    for (final r in m.runs) {
      r.kill();
    }
  });
  return (m, d, c);
}

Future<void> _app(WidgetTester t, AppModel m, Appearance look, {Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

/// Settings → Interface.
Future<void> _openInterfaceSettings(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await _settle(t);
  final section = find.byKey(const Key('settings-interface'));
  if (section.evaluate().isNotEmpty) {
    await t.tap(section);
    await _settle(t);
  }
}

Future<void> _start(WidgetTester t, {String? password = 'correct horse battery'}) async {
  if (password != null) await t.enterText(find.byKey(const Key('owner-password')), password);
  await t.tap(find.byKey(const Key('code-start-go')));
  await _settle(t);
}

String _status(WidgetTester t) => t.widget<Text>(find.byKey(const Key('code-status'))).data!;

void main() {
  testWidgets('Chat by default; Settings → Interface: Code shows the agents\' terminals and is saved', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-code-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    final look = settledLook(store);
    expect(look.ui, InterfaceMode.chat, reason: 'new users get Chat');
    final (m, _, _) = await _setup();
    await _app(t, m, look);
    expect(find.byKey(const Key('agent-dock')), findsNothing);

    await _openInterfaceSettings(t);
    await t.tap(find.byKey(const Key('ui-code')));
    await _settle(t);
    expect(find.byKey(const Key('agent-dock')), findsOneWidget);
    expect(find.byKey(const Key('code-start-empty')), findsOneWidget);
    expect(json.decode(File(store.path).readAsStringSync())['ui'], 'code');
    expect(AppearanceStore(store.path).load().ui, InterfaceMode.code);

    // In Code mode the chats keep their place: list on the left, conversation in the middle, terminals on the right.
    await t.tap(find.byKey(const Key('nav-chats')));
    await _settle(t);
    final dock = t.getRect(find.byKey(const Key('agent-dock')));
    final list = t.getRect(find.text('Chats').first);
    expect(dock.left, greaterThan(list.right));
    expect(dock.right, 1440);

    await _openInterfaceSettings(t);
    await t.tap(find.byKey(const Key('ui-chat')));
    await _settle(t);
    expect(find.byKey(const Key('agent-dock')), findsNothing);
  });

  testWidgets('Start an existing agent: the password issues a token that only reaches the program\'s environment',
      (t) async {
    final (m, d, pc) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(find.byKey(const Key('code-program-found')), findsOneWidget, reason: 'Claude Code is installed');
    expect(find.text('Found: /usr/local/bin/claude'), findsOneWidget);
    await _start(t);

    expect(find.byType(StartAgentDialog), findsNothing);
    expect(d.calls.where((c) => c == 'agent_token'), hasLength(1));
    expect(d.passwords['agent_token'], 'correct horse battery');
    final pty = pc.last;
    final token = pty.launch.environment['ANTENNA_AGENT_TOKEN']!;
    expect(token, startsWith('xat_'));
    expect(pty.launch.arguments.join(' '), isNot(contains(token)));
    // No folder chosen: jarvis's own folder, never the owner's whole home folder (TROUBLESHOOTING "macOS asks
    // Antenna for Documents, Photos, Music…").
    expect(pty.launch.workingDirectory, '/home/owner/Antenna/agents/jarvis');
    expect(pc.createdFolders, contains('/home/owner/Antenna/agents/jarvis'));
    expect(pty.launch.command.first, '/usr/local/bin/claude');
    expect(find.text(token), findsNothing, reason: 'the token is never shown');

    // The agent's output reaches the terminal; keystrokes reach the agent.
    pty.emit('Claude Code ready\r\n> ');
    await _settle(t);
    final run = m.runOf('jarvis')!;
    expect(terminalText(run.terminal.buffer), contains('Claude Code ready'));
    expect(_status(t), 'running');
    run.terminal.textInput('hello');
    expect(pty.written.join(), 'hello');

    // It ends on its own: the exit code comes from the wrapper's report.
    pty.emit('\x1b]6973;3\x07');
    pty.end(3);
    await _settle(t);
    expect(_status(t), 'exited with code 3');

    // Restart: the same token from memory, no password, the same tab.
    await t.tap(find.byKey(const Key('code-restart')));
    await _settle(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.ptys, hasLength(2));
    expect(pc.last.launch.environment['ANTENNA_AGENT_TOKEN'], token);
    expect(d.calls.where((c) => c == 'agent_token'), hasLength(1));
    expect(_status(t), 'running');

    // Stop: SIGHUP to the terminal's process group, like closing a terminal window.
    await t.tap(find.byKey(const Key('code-stop')));
    await _settle(t);
    expect(pc.last.signals, [ProcessSignal.sighup]);
    expect(_status(t), 'stopped');
    await t.tap(find.byKey(const Key('code-close-jarvis')));
    await _settle(t);
    expect(m.runs, isEmpty);
    expect(find.byKey(const Key('code-start-empty')), findsOneWidget);
  });

  testWidgets('a new agent from "Start agent": agent_add with the label; next time no password', (t) async {
    final (m, d, pc) = await _setup();
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    // No agents yet: the dialog creates one; a role is required (Q-15), nothing is preselected.
    await t.enterText(find.byKey(const Key('agent-name')), 'builder');
    await t.tap(find.byKey(const Key('code-cli-codex')));
    await _settle(t);
    await _start(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(d.calls, isNot(contains('agent_add')));
    // The two roles, or any of the six data labels behind "Other data label…".
    await t.ensureVisible(find.byKey(const Key('code-other-label')));
    await t.tap(find.byKey(const Key('code-other-label')));
    await _settle(t);
    await t.ensureVisible(find.byKey(const Key('label-3')));
    await t.tap(find.byKey(const Key('label-3')));
    await _settle(t);
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(d.calls, contains('agent_add'));
    expect(d.agentList.single.localLevel, 3);
    expect(pc.last.launch.command.first, '/opt/homebrew/bin/codex');
    expect(pc.last.launch.command, contains('mcp_servers.antenna.env_vars=["ANTENNA_AGENT_TOKEN", "ANTENNA_SOCKET"]'));

    await t.tap(find.byKey(const Key('code-stop')));
    await _settle(t);
    await t.tap(find.byKey(const Key('code-close-builder')));
    await _settle(t);
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    expect(find.byKey(const Key('code-no-password')), findsOneWidget);
    expect(find.byKey(const Key('owner-password')), findsNothing);
    await _start(t, password: null);
    expect(m.runOf('builder')!.alive, isTrue);
    expect(d.calls.where((c) => c == 'agent_token'), isEmpty, reason: 'the window held the token');
  });

  testWidgets('Start agent: a new agent defaults to its own folder, never the home folder', (t) async {
    final (m, _, pc) = await _setup();
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    // No name yet: the hint has nothing to build "its own folder" from, so it falls back to the home folder — but
    // the field itself stays blank (never silently filled in).
    expect(find.byKey(const Key('code-folder')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('code-folder'))).controller!.text, isEmpty);
    expect(t.widget<TextField>(find.byKey(const Key('code-folder'))).decoration!.hintText, '/home/owner');

    await t.enterText(find.byKey(const Key('agent-name')), 'scout');
    await _settle(t);
    expect(t.widget<TextField>(find.byKey(const Key('code-folder'))).decoration!.hintText,
        '/home/owner/Antenna/agents/scout');
    expect(find.byKey(const Key('code-folder-home-warning')), findsNothing);

    await t.tap(find.byKey(const Key('code-other-label')));
    await _settle(t);
    await t.ensureVisible(find.byKey(const Key('label-3')));
    await t.tap(find.byKey(const Key('label-3')));
    await _settle(t);
    await _start(t);

    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.last.launch.workingDirectory, '/home/owner/Antenna/agents/scout');
    expect(pc.createdFolders, contains('/home/owner/Antenna/agents/scout'));
  });

  testWidgets('a folder remembered as the home folder from before this fix migrates to its own folder', (t) async {
    final look = Appearance(ui: InterfaceMode.code);
    // As the window used to save it: the home folder, because that was the only default there ever was.
    look.rememberAgentRun(
        'jarvis', const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: '/home/owner').toJson());
    final (m, _, pc) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, look);
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    // Reads as "nothing chosen", exactly like a brand new agent: blank field, the own-folder hint, no warning.
    expect(t.widget<TextField>(find.byKey(const Key('code-folder'))).controller!.text, isEmpty);
    expect(t.widget<TextField>(find.byKey(const Key('code-folder'))).decoration!.hintText,
        '/home/owner/Antenna/agents/jarvis');
    expect(find.byKey(const Key('code-folder-home-warning')), findsNothing);
    await _start(t);
    expect(pc.last.launch.workingDirectory, '/home/owner/Antenna/agents/jarvis');
  });

  testWidgets('picking the home folder on purpose warns, once it is actually chosen', (t) async {
    final (m, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    expect(find.byKey(const Key('code-folder-home-warning')), findsNothing);

    await t.enterText(find.byKey(const Key('code-folder')), '/home/owner');
    await _settle(t);
    expect(find.byKey(const Key('code-folder-home-warning')), findsOneWidget);
    expect(find.text(l10nFor('en').codeFolderHomeWarning), findsOneWidget);

    // A subfolder of home is not the whole home folder: no warning.
    await t.enterText(find.byKey(const Key('code-folder')), '/home/owner/projects/antenna');
    await _settle(t);
    expect(find.byKey(const Key('code-folder-home-warning')), findsNothing);
  });

  testWidgets('no token is issued when the start cannot work: busy elsewhere, CLI missing, folder missing', (t) async {
    final (m, d, _) = await _setup(
      agents: [
        const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5, boundTo: '7777 claude'),
        const AgentInfo(name: 'helper', createdMs: 0, localLevel: 3),
      ],
      computer: FakeAgentComputer(installed: const {}),
    );
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    expect(find.byKey(const Key('code-agent-busy')), findsOneWidget);
    expect(find.textContaining('7777 claude'), findsWidgets);
    await _start(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(find.textContaining('already running elsewhere'), findsWidgets);

    await t.tap(find.byKey(const Key('code-agent')));
    await _settle(t);
    await t.tap(find.text('helper').last);
    await _settle(t);
    expect(find.byKey(const Key('code-program-missing')), findsOneWidget);
    await _start(t);
    expect(find.text('claude was not found. Install it or choose your own command.'), findsOneWidget);

    await t.tap(find.byKey(const Key('code-cli-custom')));
    await _settle(t);
    await t.enterText(find.byKey(const Key('code-command')), 'my-agent --serve');
    await t.enterText(find.byKey(const Key('code-folder')), '/missing/project');
    await _start(t);
    expect(find.text('The folder /missing/project does not exist.'), findsOneWidget);
    expect(d.calls, isNot(contains('agent_token')));
  });

  testWidgets('the labelled navigation in both modes; icons only when Code mode leaves it no room', (t) async {
    final (m, _, _) = await _setup();
    final look = Appearance(ui: InterfaceMode.code);
    await _app(t, m, look, size: const Size(1440, 900));
    expect(find.byKey(const Key('nav-compact')), findsNothing, reason: 'wide enough: names next to the icons');
    expect(find.text(l10nFor('en').navSettings), findsOneWidget);
    await _app(t, m, look, size: const Size(1300, 900));
    expect(find.byKey(const Key('nav-compact')), findsOneWidget, reason: 'the terminals need the room');
    look.ui = InterfaceMode.chat;
    await _settle(t);
    expect(find.byKey(const Key('nav-compact')), findsNothing, reason: 'Chat mode keeps the names');
  });

  testWidgets('the contact card stays reachable at a narrow width with the Code panel open', (t) async {
    final (m, _, _) = await _setup();
    // Narrow enough that Code mode's docked strip leaves the conversation less than the 980 px the inline card
    // needs, but still above 640 (the header keeps showing): the info button and the header's name and avatar must
    // still open the card, as a dialog instead of the inline panel.
    await _app(t, m, Appearance(ui: InterfaceMode.code), size: const Size(900, 900));
    expect(find.byKey(const Key('agent-dock-strip')), findsOneWidget, reason: 'no room for the full dock either');
    expect(find.byKey(const Key('card-toggle')), findsOneWidget, reason: 'the info button stays reachable');
    expect(find.byKey(const Key('contact-card-dialog')), findsNothing);

    await t.tap(find.byKey(const Key('chat-header-avatar')));
    await _settle(t);
    expect(find.byKey(const Key('contact-card-dialog')), findsOneWidget, reason: 'the avatar opens the card');
    expect(find.descendant(of: find.byKey(const Key('contact-card-dialog')), matching: find.text(emilyName)),
        findsWidgets);
    await t.tap(find.text(l10nFor('en').commonClose));
    await _settle(t);
    expect(find.byKey(const Key('contact-card-dialog')), findsNothing);

    await t.tap(find.byKey(const Key('chat-header-name')));
    await _settle(t);
    expect(find.byKey(const Key('contact-card-dialog')), findsOneWidget, reason: 'the name opens the card too');
    await t.tap(find.text(l10nFor('en').commonClose));
    await _settle(t);

    await t.tap(find.byKey(const Key('card-toggle')));
    await _settle(t);
    expect(find.byKey(const Key('contact-card-dialog')), findsOneWidget, reason: 'and so does the info button');
  });

  testWidgets('several agents: one tab each; fold to a strip and back; drag to resize', (t) async {
    final (m, _, pc) = await _setup(agents: [
      const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5),
      const AgentInfo(name: 'helper', createdMs: 0, localLevel: 3),
    ]);
    // Wide enough for the labelled navigation and a dock with room to resize.
    await _app(t, m, Appearance(ui: InterfaceMode.code), size: const Size(1700, 900));
    expect(await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: '/home/owner/app'),
        auth: const PasswordAuth('correct horse battery')), isNull);
    expect(await m.startAgent(const AgentRunSpec(agent: 'helper', cli: AgentCli.codex, workDir: '/home/owner/infra'),
        auth: const PasswordAuth('correct horse battery')), isNull);
    await _settle(t);
    expect(find.byKey(const Key('code-tab-jarvis')), findsOneWidget);
    expect(find.byKey(const Key('code-tab-helper')), findsOneWidget);
    expect(m.activeRun!.spec.agent, 'helper');
    expect(find.text('~/infra'), findsOneWidget);
    await t.tap(find.byKey(const Key('code-tab-jarvis')));
    await _settle(t);
    expect(m.activeRun!.spec.agent, 'jarvis');
    expect(find.text('~/app'), findsOneWidget);
    // Starting a running agent again only brings its tab to the front.
    expect(await m.startAgent(const AgentRunSpec(agent: 'helper', cli: AgentCli.codex, workDir: '/home/owner/infra')),
        isNull);
    expect(pc.ptys, hasLength(2));
    expect(m.activeRun!.spec.agent, 'helper');

    final w0 = t.getSize(find.byKey(const Key('agent-dock'))).width;
    await t.drag(find.byKey(const Key('dock-handle')), const Offset(100, 0), touchSlopX: 0);
    await _settle(t);
    expect(t.getSize(find.byKey(const Key('agent-dock'))).width, closeTo(w0 - 100, 1));
    // Never wider than the chats allow: the conversation keeps at least 500 px next to the list.
    await t.drag(find.byKey(const Key('dock-handle')), const Offset(-900, 0));
    await _settle(t);
    final dock = t.getRect(find.byKey(const Key('agent-dock')));
    expect(dock.left, greaterThanOrEqualTo(navWidth + 300 + 500));

    await t.tap(find.byKey(const Key('code-collapse')));
    await _settle(t);
    expect(find.byKey(const Key('agent-dock')), findsNothing);
    expect(find.byKey(const Key('agent-dock-strip')), findsOneWidget);
    expect(find.byKey(const Key('code-strip-jarvis')), findsOneWidget);
    await t.tap(find.byKey(const Key('code-strip-jarvis')));
    await _settle(t);
    expect(find.byKey(const Key('agent-dock')), findsOneWidget);
    expect(m.activeRun!.spec.agent, 'jarvis');
  });

  testWidgets('closing the window with agents running asks first; "Stop and quit" stops every agent', (t) async {
    final (m, _, pc) = await _setup(agents: [
      const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5),
      const AgentInfo(name: 'helper', createdMs: 0, localLevel: 3),
    ]);
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    for (final a in ['jarvis', 'helper']) {
      await m.startAgent(AgentRunSpec(agent: a, cli: AgentCli.claude, workDir: '/home/owner'),
          auth: const PasswordAuth('correct horse battery'));
    }
    await _settle(t);
    final ctx = t.element(find.byType(HomeScreen));
    var answer = confirmQuitWithAgents(ctx, m.liveRuns.length);
    await _settle(t);
    expect(find.text('2 agents are running in this window. Closing the window stops them.'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await _settle(t);
    expect(await answer, isFalse);
    expect(m.liveRuns, hasLength(2));

    answer = confirmQuitWithAgents(ctx, m.liveRuns.length);
    await _settle(t);
    await t.tap(find.byKey(const Key('code-quit-stop')));
    await _settle(t);
    expect(await answer, isTrue);
    await m.stopAllRuns();
    await _settle(t);
    expect(m.liveRuns, isEmpty);
    expect(pc.ptys.every((p) => p.signals.contains(ProcessSignal.sighup)), isTrue);
  });

  testWidgets('an agent that ignores SIGHUP is killed after 3 s', (t) async {
    final (m, _, pc) = await _setup(
      agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)],
      computer: FakeAgentComputer(exitOnHangup: false),
    );
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: '/home/owner'),
        auth: const PasswordAuth('correct horse battery'));
    final stopping = m.stopRun(m.runOf('jarvis')!);
    await t.pump(const Duration(seconds: 1));
    expect(pc.last.signals, [ProcessSignal.sighup]);
    expect(m.runOf('jarvis')!.state, AgentRunState.stopping);
    await t.pump(const Duration(seconds: 3));
    await stopping;
    expect(pc.last.signals, [ProcessSignal.sighup, ProcessSignal.sigkill]);
    expect(m.runOf('jarvis')!.state, AgentRunState.exited);
  });

  testWidgets('after the keys were locked, Restart asks for the password again', (t) async {
    final (m, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: '/home/owner'),
        auth: const PasswordAuth('correct horse battery'));
    await _settle(t);
    m.forgetAgentTokens();
    await t.tap(find.byKey(const Key('code-restart')));
    await _settle(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(find.byKey(const Key('owner-password')), findsOneWidget);
  });

  testWidgets('Code mode is offered once to an owner with agents, and the answer is remembered', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-code-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    final (m, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, settledLook(store));
    await _settle(t);
    expect(find.byKey(const Key('code-offer')), findsOneWidget);
    await t.tap(find.byKey(const Key('code-offer-later')));
    await _settle(t);
    expect(find.byKey(const Key('code-offer')), findsNothing);
    expect(json.decode(File(store.path).readAsStringSync())['code_offered'], true);
    expect(Appearance.load(store).canOfferCode, isFalse);

    // Without agents, or without a settings file to remember the answer in, there is no offer.
    final (m2, _, _) = await _setup();
    await m2.refreshAgents();
    await _app(t, m2, settledLook(AppearanceStore('${dir.path}/other.json')));
    await _settle(t);
    expect(find.byKey(const Key('code-offer')), findsNothing);
    final (m3, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await m3.refreshAgents();
    await _app(t, m3, Appearance());
    await _settle(t);
    expect(find.byKey(const Key('code-offer')), findsNothing);

    // "Switch to Code mode" turns it on.
    final (m4, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await m4.refreshAgents();
    final look = settledLook(AppearanceStore('${dir.path}/third.json'));
    await _app(t, m4, look);
    await _settle(t);
    await t.tap(find.byKey(const Key('code-offer-try')));
    await _settle(t);
    expect(look.ui, InterfaceMode.code);
    expect(find.byKey(const Key('agent-dock')), findsOneWidget);
  });

  testWidgets('Russian: the dock and the dialog speak Russian', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final (m, _, _) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, Appearance(ui: InterfaceMode.code));
    expect(find.text(l10nFor('ru').codeEmptyTitle), findsOneWidget);
    await t.tap(find.byKey(const Key('code-start-empty')));
    await _settle(t);
    expect(find.text(l10nFor('ru').codeStartTitle), findsOneWidget);
  });

  testWidgets('Agents → AI apps: what is installed is marked; Claude Code starts in Code mode', (t) async {
    // Linux: Claude Code and Cursor installed; Codex and Claude Desktop are not.
    final (m, _, pc) = await _setup(
      computer: FakeAgentComputer(installed: const {'/usr/local/bin/claude', '/usr/bin/cursor'}),
    );
    final look = Appearance();
    await _app(t, m, look, size: const Size(1440, 2400));
    await t.tap(find.byKey(const Key('agents-button')));
    await _settle(t);
    expect(find.byKey(const Key('detected-claudeCode')), findsOneWidget);
    expect(find.byKey(const Key('app-start-claudeCode')), findsOneWidget);
    expect(find.byKey(const Key('detected-cursor')), findsOneWidget);
    expect(find.byKey(const Key('app-connect-cursor')), findsOneWidget);
    expect(find.byKey(const Key('detected-codex')), findsNothing);
    expect(find.byKey(const Key('detected-claudeDesktop')), findsNothing);
    // The role preset is a setting: its footnote is behind its "?".
    await t.tap(find.byKey(const Key('help-role-preset')));
    await _settle(t);
    expect(
        find.descendant(
            of: find.byKey(const Key('help-role-preset-card')),
            matching: find.text('The daemon checks permissions. Agents have no owner commands.')),
        findsOneWidget);
    await t.tap(find.byKey(const Key('help-role-preset')));
    await _settle(t);

    // Start in Code mode → "Start agent" with Claude Code; the window is in Chat mode, so the start switches it to Code.
    await t.tap(find.byKey(const Key('app-start-claudeCode')));
    await _settle(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    await t.enterText(find.byKey(const Key('agent-name')), 'dev');
    await t.tap(find.descendant(of: find.byType(StartAgentDialog), matching: find.byKey(const Key('role-assistant'))));
    await _settle(t);
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.last.launch.command.first, '/usr/local/bin/claude');
    expect(look.ui, InterfaceMode.code);
    expect(find.byKey(const Key('agent-dock')), findsOneWidget);
    expect(m.agents.single.localLevel, 5, reason: 'Assistant: data label 5');
  });

  testWidgets('macOS detection: apps in /Applications; Claude Desktop and Codex connect, Codex also runs in Code mode',
      (t) async {
    final (m, _, _) = await _setup(
      computer: FakeAgentComputer(macos: true, installed: const {'/Applications/Claude.app', '/opt/homebrew/bin/codex'}),
    );
    await _app(t, m, Appearance());
    await t.tap(find.byKey(const Key('agents-button')));
    await _settle(t);
    expect(find.byKey(const Key('detected-claudeDesktop')), findsOneWidget);
    expect(find.byKey(const Key('app-connect-claudeDesktop')), findsOneWidget);
    expect(find.byKey(const Key('app-connect-codex')), findsOneWidget);
    expect(find.byKey(const Key('app-start-codex')), findsOneWidget);
    expect(find.byKey(const Key('detected-claudeCode')), findsNothing);
    expect(find.byKey(const Key('detected-cursor')), findsNothing);
  });

  testWidgets('role preset: nothing chosen at first; the choice is saved and proposed for new agents', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-code-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    final look = settledLook(store);
    expect(look.rolePreset, isNull, reason: 'Q-15: no silent default');
    final (m, d, _) = await _setup();
    await _app(t, m, look, size: const Size(1440, 2400));
    await t.tap(find.byKey(const Key('agents-button')));
    await _settle(t);
    await t.tap(find.byKey(const Key('role-frontDesk')));
    await _settle(t);
    expect(json.decode(File(store.path).readAsStringSync())['role_preset'], 'frontDesk');
    expect(Appearance.load(store).rolePreset, RolePreset.frontDesk);

    // Settings → Agents shows the same choice.
    await t.tap(find.byKey(const Key('nav-settings')));
    await _settle(t);
    await t.tap(find.byKey(const Key('settings-agents')));
    await _settle(t);
    expect(find.byKey(const Key('role-preset')), findsOneWidget);
    await t.tap(find.byKey(const Key('settings-open-agents')));
    await _settle(t);
    expect(find.byKey(const Key('ai-apps')), findsOneWidget);

    // A new agent from "Start agent" gets data label 0 without picking it again.
    await t.tap(find.byKey(const Key('app-start-claudeCode')));
    await _settle(t);
    await t.enterText(find.byKey(const Key('agent-name')), 'desk');
    await _start(t);
    expect(d.agentList.single.localLevel, 0);
  });

  testWidgets('Settings: sections on the left; Profile first, then General; each part in its section', (t) async {
    final (m, _, _) = await _setup();
    await _app(t, m, Appearance());
    await t.tap(find.byKey(const Key('nav-settings')));
    await _settle(t);
    for (final s in ['profile', 'general', 'interface', 'network', 'security', 'agents', 'advanced']) {
      expect(find.byKey(Key('settings-$s')), findsOneWidget);
    }
    expect(find.byKey(const Key('profile-card')), findsOneWidget);
    expect(find.byKey(const Key('theme-dark')), findsNothing);
    await t.tap(find.byKey(const Key('settings-general')));
    await _settle(t);
    expect(find.byKey(const Key('theme-dark')), findsOneWidget);
    expect(find.byKey(const Key('ui-code')), findsNothing);
    await t.tap(find.byKey(const Key('settings-interface')));
    await _settle(t);
    expect(find.byKey(const Key('ui-code')), findsOneWidget);
    await t.tap(find.byKey(const Key('settings-advanced')));
    await _settle(t);
    expect(find.byKey(const Key('cli-button')), findsOneWidget);
    expect(find.byKey(const Key('updates-card')), findsOneWidget);
  });

  // Windows has no Code mode yet (D-134). The control is the same window on Linux.
  for (final windows in [true, false]) {
    testWidgets('${windows ? 'Windows' : 'Control, Linux'}: Code mode is '
        '${windows ? 'not offered, and Settings says it is coming' : 'offered'}', (t) async {
      final (m, _, _) = await _setup(
        agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)],
        computer: windows
            ? FakeAgentComputer(
                windows: true,
                env: const {'USERPROFILE': r'C:\Users\o', 'Path': r'C:\Windows\System32'},
                installed: const {r'C:\Users\o\.local\bin\claude.exe'},
              )
            : FakeAgentComputer(),
      );
      expect(m.codeAvailable, !windows);
      expect(m.codeComing, windows);
      // A Code interface chosen before: the terminals' dock only where Code mode exists.
      await _app(t, m, Appearance(ui: InterfaceMode.code), size: const Size(1440, 2400));
      expect(find.byKey(const Key('agent-dock')), windows ? findsNothing : findsOneWidget);
      // Agents → AI apps: Claude Code is found either way; started in a terminal only where Code mode exists.
      await t.tap(find.byKey(const Key('agents-button')));
      await _settle(t);
      expect(find.byKey(const Key('detected-claudeCode')), findsOneWidget);
      expect(find.byKey(const Key('app-start-claudeCode')), windows ? findsNothing : findsOneWidget);
      // Settings → Interface: Code turned off, with the reason in plain sight.
      await _openInterfaceSettings(t);
      expect(find.byKey(const Key('ui-code-coming')), windows ? findsOneWidget : findsNothing);
      if (windows) expect(find.text(l10nFor('en').settingsInterfaceCodeComing), findsOneWidget);
      final mode = t.widget<SegmentedButton<InterfaceMode>>(find.byType(SegmentedButton<InterfaceMode>));
      expect(mode.segments.firstWhere((s) => s.value == InterfaceMode.code).enabled, !windows);
      expect(mode.selected, {if (windows) InterfaceMode.chat else InterfaceMode.code});
    });
  }

  test('an agent\'s own folder is never made at the top of the disk: without a home folder the start stops', () {
    for (final env in <Map<String, String>>[{}, {'HOME': '/'}, {'HOME': '//'}, {'HOME': ''}, {'HOME': 'owner'}]) {
      final pc = FakeAgentComputer(env: env);
      expect(() => pc.host.prepareOwnFolder('jarvis'), throwsA(isA<FileSystemException>()), reason: '$env');
      expect(pc.createdFolders, isEmpty, reason: '$env');
    }
    // Control: with a home folder, the agent's folder is made under it.
    final pc = FakeAgentComputer();
    pc.host.prepareOwnFolder('jarvis');
    expect(pc.createdFolders, ['/home/owner/Antenna/agents/jarvis']);
  });

  // T16: Windows folders, from the environment Windows gives (any case), never under a drive's root.
  test('Windows: the agent\'s own folder is under USERPROFILE, and nothing is made without one', () {
    final pc = FakeAgentComputer(windows: true, env: const {'UserProfile': r'C:\Users\o', 'HOME': '/c/Users/o'});
    expect(pc.host.home, r'C:\Users\o', reason: 'USERPROFILE, not a HOME of Git for Windows');
    pc.host.prepareOwnFolder('jarvis');
    expect(pc.createdFolders, [r'C:\Users\o\Antenna\agents\jarvis']);
    expect(pc.host.folderExists(r'C:\Users\o\project'), isTrue);
    expect(pc.host.folderExists('/home/owner/project'), isFalse, reason: 'not a Windows path');
    for (final env in <Map<String, String>>[
      {},
      {'USERPROFILE': r'C:\'},
      {'USERPROFILE': 'C:'},
      {'USERPROFILE': r'Users\o'},
    ]) {
      final bad = FakeAgentComputer(windows: true, env: env);
      expect(() => bad.host.prepareOwnFolder('jarvis'), throwsA(isA<FileSystemException>()), reason: '$env');
      expect(bad.createdFolders, isEmpty, reason: '$env');
    }
  });

  test('Windows: the hooks\' folder is beside the data folder, never in it, and holds no scripts', () {
    expect(codeHooksRoot(const {'LocalAppData': r'C:\Users\o\AppData\Local'}, windows: true),
        r'C:\Users\o\AppData\Local\AntennaCache\code');
    expect(codeHooksRoot(const {'LOCALAPPDATA': 'relative'}, windows: true), isNull);
    expect(codeHooksRoot(const {}, windows: true), isNull);
    // Control: elsewhere, the caches as before.
    expect(codeHooksRoot(const {'HOME': '/home/o'}, macos: false, windows: false), '/home/o/.cache/antenna/code');
    final root = Directory.systemTemp.createTempSync('hooks-root-');
    addTearDown(() => root.deleteSync(recursive: true));
    const cli = r'C:\Program Files\Antenna\antenna.exe';
    final h = FileCodeHooks.create(root.path, windowsCli: cli)!;
    addTearDown(h.close);
    final names = Directory(h.folder).listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, ['events']);
    // The hooks run a bare `antenna`, first in the agent's Path; Codex's `notify` is an argv, so it takes the path.
    expect(h.command(ClaudeHookEvent.stop), 'antenna hook-signal stop');
    expect(h.command(ClaudeHookEvent.toolDone), 'antenna hook-signal tool-done');
    expect(h.notifyArgv, [cli, 'hook-signal', '--notify']);
    expect(h.offerContinue('{"decision":"block","reason":"go on"}'), isTrue, reason: 'no chmod on Windows');
    expect(h.withdrawContinue(), isTrue);
  });

  // T14: the start on Windows through the window's own path: `antenna agent-run` with the agent's argv, no shell.
  test('Windows: Start agent runs antenna agent-run with claude.exe; a .cmd alone is refused before any token',
      () async {
    const antenna = r'C:\Program Files\Antenna\antenna.exe';
    final pc = FakeAgentComputer(
      windows: true,
      hooks: true,
      env: const {'USERPROFILE': r'C:\Users\o', 'Path': r'C:\Users\o\.local\bin;C:\Users\o\AppData\Roaming\npm'},
      installed: {r'C:\Users\o\.local\bin\claude.exe', r'C:\Users\o\AppData\Roaming\npm\codex.cmd', r'C:\t\a.exe'},
    );
    final (m, d, _) = await _setup(
      agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)],
      computer: pc,
      bins: const CoreBinaries(daemon: r'C:\Program Files\Antenna\antennad.exe', cli: antenna, bundled: true),
    );
    const auth = PasswordAuth('correct horse battery');
    expect(m.codeAvailable, isFalse, reason: 'not offered until the start is checked on a Windows computer');

    expect(await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: r'C:\Users\o\app'),
        auth: auth), isNull);
    final l = pc.last.launch;
    expect(l.executable, antenna);
    expect(l.arguments, ['agent-run']);
    expect(l.command.first, r'C:\Users\o\.local\bin\claude.exe');
    expect(l.workingDirectory, r'C:\Users\o\app');
    expect(l.environment['ANTENNA_AGENT_TOKEN'], startsWith('xat_'));
    expect(l.environment[codeHooksVar], pc.hookChannels.single.folder, reason: 'Claude Code\'s hooks find it there');
    expect(l.environment['Path']!.split(';').first, r'C:\Program Files\Antenna');
    expect(d.agentTerminals, isEmpty, reason: 'no terminal session to register on Windows');
    final run = m.runOf('jarvis')!;
    await m.stopRun(run);
    expect(pc.last.signals, [ProcessSignal.sighup], reason: 'Stop: agent-run\'s STOP frame');

    // Only a .cmd: refused before a token is asked for.
    final tokens = d.calls.where((c) => c == 'agent_token').length;
    final e = await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.codex, workDir: r'C:\Users\o\app'),
        auth: auth);
    expect(e, isA<AgentLaunchException>().having((e) => e.reason, 'reason', AgentLaunchFailure.shimOnly));
    expect(d.calls.where((c) => c == 'agent_token'), hasLength(tokens));

    // An own command: Windows words, its program found as a full .exe path or by name; never a bare name unresolved.
    expect(await m.startAgent(const AgentRunSpec(
            agent: 'jarvis', cli: AgentCli.custom, workDir: r'C:\Users\o\app', command: r'C:\t\a.exe --x "y z"'),
        auth: auth), isNull);
    expect(pc.last.launch.command, [r'C:\t\a.exe', '--x', 'y z']);
    // The exit code comes from agent-run's EXIT alone: the program's own OSC 6973 is not taken for it.
    pc.last.emit('\x1b]6973;0\x07');
    await pumpEventQueue();
    pc.last.end(5);
    await pumpEventQueue();
    expect(m.runOf('jarvis')!.exitCode, 5);
    expect(await m.startAgent(const AgentRunSpec(
            agent: 'jarvis', cli: AgentCli.custom, workDir: r'C:\Users\o\app', command: 'claude --resume'),
        auth: auth), isNull);
    expect(pc.last.launch.command, [r'C:\Users\o\.local\bin\claude.exe', '--resume']);
    await m.stopRun(m.runOf('jarvis')!);
    for (final bad in [r'C:\t\missing.exe', r'C:\t\a.cmd', 'codex', r'tools\a.exe']) {
      final e = await m.startAgent(
          AgentRunSpec(agent: 'jarvis', cli: AgentCli.custom, workDir: r'C:\Users\o\app', command: bad),
          auth: auth);
      expect(e, isA<AgentLaunchException>().having((e) => e.reason, 'reason', AgentLaunchFailure.noProgram),
          reason: bad);
    }
  });

  testWidgets('Agents: "Start in terminal" in Code mode only, never for a wake agent', (t) async {
    final (m, d, _) = await _setup(agents: [
      const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5),
      const AgentInfo(name: 'wake-buildbot', createdMs: 0, localLevel: 0),
    ]);
    d.wakeRuleList = [
      WakeRuleInfo(
        contact: buildBot.label,
        linkId: buildBot.linkId,
        agent: 'wake-buildbot',
        argv: const ['/usr/local/bin/claude', '-p'],
        mode: 'claude_stream',
        timeoutSecs: 600,
        maxRunsPerHour: 20,
        homeFiles: const [],
        secretEnv: const [],
        createdMs: 0,
      ),
    ];
    final look = Appearance();
    // Tall enough for the agents list below the AI apps (a ListView builds only what is near the screen).
    await _app(t, m, look, size: const Size(1440, 2400));
    await t.tap(find.byKey(const Key('agents-button')));
    await _settle(t);
    expect(find.byKey(const Key('agent-start-jarvis')), findsNothing, reason: 'Chat mode has no terminals');
    look.ui = InterfaceMode.code;
    await _settle(t);
    expect(find.byKey(const Key('agent-start-jarvis')), findsOneWidget);
    expect(find.byKey(const Key('agent-start-wake-buildbot')), findsNothing);
    await t.tap(find.byKey(const Key('agent-start-jarvis')));
    await _settle(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(find.byKey(const Key('code-new-token')), findsOneWidget, reason: 'an existing agent gets a new token');
    await _start(t);
    expect(m.runOf('jarvis')!.alive, isTrue);
    expect(find.text('running in the window'), findsOneWidget);
  });
}
