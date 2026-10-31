// SPDX-License-Identifier: AGPL-3.0-only
// The Code mode wake for Codex (PG-21): the same rules as for Claude Code (D-UI-23, D-UI-25), from Codex's own
// interfaces. Codex 0.160 and later run hooks of the same kind (SessionStart lazily with the first prompt,
// UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop with `decision: block`, Interrupt for Esc), which
// the launch registers with `-c hooks.…`; older ones, or hooks the owner did not trust, only run `notify` after a
// turn, which Codex also runs for its helper threads. The screens are the real Codex 0.160.1's (codex_screens.dart).

import 'dart:convert';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/codex_screens.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _me = 'codex-backend';
String _wakeFrom(String label) => 'New Antenna messages from $label: read your inbox and continue.';

TerminalScreen _s(ClaudeScreen s) => screenOf(s, rows: 30);

var _now = fixedNow;

Future<(AppModel, FakePty, FakeCodeHooks)> _running(WidgetTester t, {ClaudeScreen screen = const ClaudeScreen([])}) async {
  _now = fixedNow;
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)];
  final c = FakeAgentComputer(hooks: true);
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => _now,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.codex, workDir: '/home/owner/shop'),
      auth: PasswordAuth(_pw)), isNull);
  final pty = c.last..emit(drawScreen(screen));
  // The terminal of these tests is as tall as the recorded screens.
  m.runOf(_me)!.terminal.resize(80, 30);
  pty.emit(drawScreen(screen));
  await t.pump();
  return (m, pty, c.hookChannels.single);
}

var _seq = 1900;
void _incoming(AppModel m, String contact) {
  final link = demoContacts().firstWhere((c) => c.label == contact).linkId;
  m.handleEvent(MessageEvent(
      contact: contact, linkId: link, message: msg(++_seq, false, 'please rerun build 412', fixedNow, to: 'agent', toAgent: _me)));
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m.disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

void main() {
  group('the screen check on Codex 0.160.1', () {
    test('the empty composer is ready; a draft, a running turn, an approval, the hooks review are not', () {
      expect(codexReady(_s(codexIdle)), isTrue);
      expect(codexReady(_s(codexAfterTurn)), isTrue);
      expect(codexReady(_s(codexDraft)), isFalse);
      expect(codexReady(_s(codexWorking)), isFalse, reason: 'the composer keeps its placeholder during a turn');
      expect(codexReady(_s(codexApproval)), isFalse);
      expect(codexReady(_s(codexHooksReview)), isFalse);
      expect(screenGuard(_s(codexApproval)), isFalse, reason: '`› 1.` is a numbered choice too');
      expect(screenGuard(_s(codexHooksReview)), isFalse);
      // Claude Code's check does not take Codex's composer for its own prompt, and the other way round
      expect(claudeCodeReady(_s(codexIdle)), isFalse);
      expect(codexReady(_s(claude289IdleAuto)), isFalse);
      expect(codexLayoutKnown(_s(codexIdle)) && codexLayoutKnown(_s(codexApproval)), isTrue);
      expect(codexLayoutKnown(_s(const ClaudeScreen(['\$ ']))), isFalse);
    });
  });

  testWidgets('the launch registers Codex\'s state hooks and notify, the hook folder in the environment, no token',
      (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexIdle);
    final argv = pty.launch.command;
    expect(argv, containsAllInOrder(['-c', 'notify=${jsonEncode(hooks.notifyArgv)}']));
    final overrides = [for (var i = 0; i + 1 < argv.length; i++) if (argv[i] == '-c') argv[i + 1]];
    for (final e in ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop',
        'Interrupt', 'SessionEnd']) {
      expect(overrides.where((o) => o.startsWith('hooks.$e=')), hasLength(1), reason: e);
    }
    expect(overrides.firstWhere((o) => o.startsWith('hooks.Stop=')),
        r'hooks.Stop=[{hooks=[{type="command",command="/bin/sh \"$ANTENNA_CODE_HOOKS/hook.sh\" stop"}]}]',
        reason: 'the same text every run: Codex keeps the owner\'s trust by its hash');
    expect(pty.launch.environment[codeHooksVar], hooks.folder);
    expect(argv.join(' '), isNot(contains('xat_')));
    await _end(t, m);
  });

  testWidgets('idle by the hooks: the wake line is typed after the quiet time, Enter on its own', (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexAfterTurn);
    hooks
      ..emit(ClaudeHookEvent.start)
      ..emit(ClaudeHookEvent.prompt)
      ..emit(ClaudeHookEvent.stop);
    _incoming(m, emilyName);
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    await _end(t, m);
  });

  testWidgets('a running turn: the line goes to its Stop hook; a helper thread\'s notify does not make it idle',
      (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexWorking);
    hooks
      ..emit(ClaudeHookEvent.start)
      ..emit(ClaudeHookEvent.prompt)
      // Codex names the new conversation in a thread of its own; its notify arrives while the owner's turn runs
      ..emit(ClaudeHookEvent.turnComplete);
    expect(m.runOf(_me)!.claude.state, ClaudeState.working);
    _incoming(m, emilyName);
    await t.pump();
    expect(json.decode(hooks.waiting!)['reason'], _wakeFrom(emilyName));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty, reason: 'nothing typed into a running turn');
    expect(hooks.stop(), isNotNull);
    await t.pump();
    expect(m.lastCodeLine(_me)?.continued, isTrue);
    await _end(t, m);
  });

  testWidgets('an approval (the hooks say so, the screen shows it): nothing, until the owner answers', (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexApproval);
    hooks
      ..emit(ClaudeHookEvent.start)
      ..emit(ClaudeHookEvent.prompt)
      ..emit(ClaudeHookEvent.tool)
      ..emit(ClaudeHookEvent.permission);
    _incoming(m, emilyName);
    await t.pump(const Duration(minutes: 2));
    expect(pty.written, isEmpty);
    // A forged "idle" with the dialog on screen: the screen guard still refuses
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    // Esc cancels it (Codex's Interrupt hook): back at the composer, typed
    hooks.emit(ClaudeHookEvent.interrupt);
    pty.emit(drawScreen(codexAfterTurn));
    // The quiet check that began with the hook restarts after the redraw: 5 s after the last output.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    await _end(t, m);
  });

  testWidgets('the hooks review at the first start (untrusted hooks): nothing typed into it', (t) async {
    final (m, pty, _) = await _running(t, screen: codexHooksReview);
    _incoming(m, emilyName);
    await t.pump(const Duration(minutes: 2));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('notify only (hooks not trusted): typed only at the empty composer, never into a running turn',
      (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexWorking);
    // a helper thread's notify during the owner's turn: "idle" by notify, but the screen shows the running turn
    hooks.emit(ClaudeHookEvent.turnComplete);
    _incoming(m, emilyName);
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    expect(hooks.waiting, isNull, reason: 'no Stop hook to continue with');
    // the turn ends
    pty.emit(drawScreen(codexAfterTurn));
    hooks.emit(ClaudeHookEvent.turnComplete);
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    await _end(t, m);
  });

  testWidgets('the owner\'s draft in Codex: never typed over', (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexIdle);
    hooks
      ..emit(ClaudeHookEvent.start)
      ..emit(ClaudeHookEvent.stop);
    final run = m.runOf(_me)!;
    run.terminal.textInput('work6');
    pty.emit(drawScreen(codexDraft));
    await t.pump();
    pty.written.clear();
    _incoming(m, emilyName);
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  test('the notify script records the turn and the thread, the hooks\' session ID wins', () {
    expect(codeNotifyScript, contains("'{\"type\":\"agent-turn-complete\"'*"));
    expect(codeNotifyScript, contains('session.notify'));
    expect(ClaudeHookEvent.parse('turn-complete'), ClaudeHookEvent.turnComplete);
    expect(ClaudeHookEvent.parse('interrupt'), ClaudeHookEvent.interrupt);
  });
}
