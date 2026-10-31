// SPDX-License-Identifier: AGPL-3.0-only
// "Screenshot" under a Code mode terminal (D-UI-27) on the fake daemon, a fake pseudo-terminal, fake hooks and a fake
// screenshot tool writing into a real temporary folder: Claude Code at its prompt gets the image's path as one
// bracketed paste and no Enter; a running turn or a dialog makes it wait (never typed into a dialog); a program that did
// not ask for bracketed paste gets nothing; Codex gets nothing typed and the owner the path; no tool: no button.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/screenshot.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_shot.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _me = 'claude-backend';

/// Claude Code asks for bracketed paste when it starts.
const _bracketed = '\x1b[?2004h';

Future<(AppModel, FakePty, FakeCodeHooks?, FakeCapture, ScreenshotStore)> _running(WidgetTester t,
    {AgentCli cli = AgentCli.claude, ClaudeScreen screen = _idleAuto, bool bracketed = true, bool tool = true}) async {
  final dir = Directory.systemTemp.createTempSync('antenna-shot-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final store = ScreenshotStore('${dir.path}/screenshots');
  final capture = FakeCapture();
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)];
  final c = FakeAgentComputer(hooks: true, shots: store, capture: tool ? capture : null);
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  expect(await m.startAgent(AgentRunSpec(agent: _me, cli: cli, workDir: '/home/owner/shop'), auth: PasswordAuth(_pw)), isNull);
  final pty = c.last..emit('${bracketed ? _bracketed : ''}${drawScreen(screen)}');
  await t.pump();
  return (m, pty, c.hookChannels.firstOrNull, capture, store);
}

const _idleAuto = ClaudeScreen([
  '────────────────────────────────────────',
  '❯ \x1b[2mTry "fix lint errors"\x1b[22m',
  '────────────────────────────────────────',
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (1, 2));

String _paste(String path) => '\x1b[200~$path\x1b[201~';

Future<void> _ui(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m
    ..disposeCodeShots()
    ..disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

void main() {
  testWidgets('Claude Code at its prompt: one click, the image\'s path as one bracketed paste, no Enter', (t) async {
    final (m, pty, hooks, capture, store) = await _running(t);
    hooks!.emit(ClaudeHookEvent.start);
    await _ui(t, m);
    await t.tap(find.byKey(const Key('code-shot')));
    await t.pump();
    final path = capture.paths.single;
    expect(path, startsWith('${store.root}/$_me/screenshot-'));
    expect(pty.written, [_paste(path)], reason: 'exactly the path, pasted, nothing else');
    expect(find.text('Screenshot attached to Claude Code\'s prompt: add what to do and press Enter'), findsOneWidget);
    expect(m.codeLineLog.last.kind, CodeLineKind.screenshot);
    // The attachment sits in the prompt: a wake must not press Enter over it.
    m.handleEvent(MessageEvent(
        contact: emilyName,
        linkId: emily.linkId,
        message: msg(990, false, 'hello', fixedNow, to: 'agent', toAgent: _me)));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, [_paste(path)]);
    await _end(t, m);
  });

  testWidgets('Claude Code started with its screenshot folder readable (--add-dir), so it reads the image unasked',
      (t) async {
    final (m, pty, _, _, store) = await _running(t);
    final argv = pty.launch.command;
    expect(argv.sublist(argv.indexOf('--add-dir'), argv.indexOf('--add-dir') + 2), ['--add-dir', '${store.root}/$_me']);
    expect(Directory('${store.root}/$_me').existsSync(), isTrue);
    await _end(t, m);
  });

  testWidgets('a turn runs: the screenshot waits, and is pasted once the turn ends', (t) async {
    final (m, pty, hooks, capture, _) = await _running(t);
    hooks!.emit(ClaudeHookEvent.prompt);
    final res = await m.takeScreenshot(m.runOf(_me)!);
    expect(res.outcome, ShotOutcome.waiting);
    await t.pump(const Duration(seconds: 30));
    expect(pty.written, isEmpty);
    hooks.emit(ClaudeHookEvent.stop);
    pty.emit(drawScreen(_idleAuto));
    await t.pump(shotQuiet);
    await t.pump();
    expect(pty.written, [_paste(capture.paths.single)]);
    expect(m.waitingShot(m.runOf(_me)!), isNull);
    await _end(t, m);
  });

  testWidgets('a permission dialog: never pasted into it; after 2 minutes the screenshot is kept with its path',
      (t) async {
    final (m, pty, hooks, capture, _) = await _running(t, screen: claude289Permission);
    hooks!.emit(ClaudeHookEvent.permission);
    await _ui(t, m);
    await t.tap(find.byKey(const Key('code-shot')));
    await t.pump();
    expect(find.byKey(const Key('code-shot-waiting')), findsOneWidget);
    // The dialog redraws, the owner looks at it: still nothing.
    pty.emit(drawScreen(claude289Permission));
    await t.pump(const Duration(seconds: 60));
    expect(pty.written, isEmpty);
    await t.pump(shotWait);
    await t.pump();
    expect(pty.written, isEmpty);
    expect(find.byKey(const Key('code-shot-kept')), findsOneWidget);
    expect(find.textContaining(capture.paths.single), findsOneWidget);
    await _end(t, m);
  });

  testWidgets('the hooks say idle but a dialog is on screen (a forged event): nothing pasted', (t) async {
    final (m, pty, hooks, _, _) = await _running(t, screen: claude289Permission);
    hooks!.emit(ClaudeHookEvent.stop);
    expect((await m.takeScreenshot(m.runOf(_me)!)).outcome, ShotOutcome.waiting);
    await t.pump(const Duration(seconds: 30));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('a program that did not ask for bracketed paste gets nothing', (t) async {
    final (m, pty, hooks, _, _) = await _running(t, bracketed: false);
    hooks!.emit(ClaudeHookEvent.stop);
    expect((await m.takeScreenshot(m.runOf(_me)!)).outcome, ShotOutcome.waiting);
    await t.pump(const Duration(seconds: 10));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('Codex: nothing typed; the owner gets the path to copy', (t) async {
    final (m, pty, _, capture, _) = await _running(t, cli: AgentCli.codex, screen: const ClaudeScreen(['› ', '']));
    await _ui(t, m);
    await t.tap(find.byKey(const Key('code-shot')));
    await t.pump();
    expect(pty.written, isEmpty);
    expect(find.byKey(const Key('code-shot-kept')), findsOneWidget);
    expect(find.textContaining('give this path to the agent yourself'), findsOneWidget);
    expect(pty.launch.command, isNot(contains('--add-dir')), reason: 'only Claude Code reads the folder');
    expect(capture.paths, hasLength(1));
    await t.tap(find.byKey(const Key('code-shot-dismiss')));
    await t.pump();
    expect(find.byKey(const Key('code-shot-kept')), findsNothing);
    await _end(t, m);
  });

  testWidgets('cancelled with Esc: nothing at all', (t) async {
    final (m, pty, hooks, capture, _) = await _running(t);
    hooks!.emit(ClaudeHookEvent.stop);
    capture.cancel = true;
    expect((await m.takeScreenshot(m.runOf(_me)!)).outcome, ShotOutcome.cancelled);
    await t.pump(const Duration(seconds: 5));
    expect(pty.written, isEmpty);
    expect(m.keptShots, isEmpty);
    await _end(t, m);
  });

  testWidgets('no screenshot tool on this computer: no button', (t) async {
    final (m, _, _, _, _) = await _running(t, tool: false);
    await _ui(t, m);
    expect(find.byKey(const Key('code-quick-bar')), findsOneWidget);
    expect(find.byKey(const Key('code-shot')), findsNothing);
    expect(m.screenshotsAvailable, isFalse);
    await _end(t, m);
  });
}
