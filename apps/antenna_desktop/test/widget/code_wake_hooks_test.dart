// SPDX-License-Identifier: AGPL-3.0-only
// The Code mode wake driven by Claude Code's hooks (D-UI-25), on the fake daemon, a fake pseudo-terminal and a fake
// hook channel: idle by the hooks → the line is typed whatever the screen layout; a turn running → the line is left
// for the turn's Stop hook and nothing is typed; a dialog, a draft or a forged "idle" with a dialog on screen →
// nothing; Esc that interrupts without a hook → the screen fallback; hooks that never report and a screen not
// recognised → "wake unavailable", nothing typed.

import 'dart:convert';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart' show TerminalKey;

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
String _wakeFrom(String label) => 'New Antenna messages from $label: read your inbox and continue.';

/// A screen in a layout no Claude Code version drew: the hooks must not need the layout.
const _otherLayout = ClaudeScreen(['claude> ', ''], cursor: (0, 8));

/// The model's clock: tests move it on with fake time where elapsed time matters.
var _now = fixedNow;

Future<(AppModel, FakePty, FakeCodeHooks)> _running(WidgetTester t,
    {ClaudeScreen screen = _otherLayout, List<ApprovalInfo> approvals = const []}) async {
  _now = fixedNow;
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [...approvals])
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
  if (approvals.isNotEmpty) await m.refreshApprovals();
  expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: '/home/owner/shop'),
      auth: PasswordAuth(_pw)), isNull);
  final pty = c.last..emit(drawScreen(screen));
  await t.pump();
  return (m, pty, c.hookChannels.single);
}

var _seq = 900;
void _incoming(AppModel m, String contact, String text) {
  final link = demoContacts().firstWhere((c) => c.label == contact).linkId;
  m.handleEvent(MessageEvent(
      contact: contact, linkId: link, message: msg(++_seq, false, text, fixedNow, to: 'agent', toAgent: _me)));
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m.disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

void main() {
  testWidgets('the launch registers the state hooks next to the policy hooks, for this session only', (t) async {
    final (m, pty, hooks) = await _running(t);
    final argv = pty.launch.command;
    final settings = json.decode(argv[argv.indexOf('--settings') + 1]) as Map<String, Object?>;
    final h = settings['hooks']! as Map<String, Object?>;
    expect(h.keys, containsAll(['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse',
        'Notification', 'Stop', 'SessionEnd']));
    final pre = (h['PreToolUse']! as List).cast<Map<String, Object?>>();
    expect(pre.map((e) => ((e['hooks']! as List).single as Map)['command']),
        [contains('hook claude-code'), hooks.command(ClaudeHookEvent.tool)],
        reason: 'the daemon\'s policy hook stays, the state hook joins it');
    expect(json.encode(settings), isNot(contains('xat_')), reason: 'no token in the settings');
    await _end(t, m);
  });

  testWidgets('idle by the hooks: the line is typed after the quiet time, in a layout the screen check does not know',
      (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.start);
    _incoming(m, emilyName, 'please rerun build 412');
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    expect(hooks.offers, isEmpty);
    await _end(t, m);
  });

  testWidgets('a turn runs: the line is left for its Stop hook and nothing is typed; the hook continues the turn',
      (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.prompt);
    _incoming(m, emilyName, 'status?');
    await t.pump();
    expect(hooks.waiting, json.encode({'decision': 'block', 'reason': _wakeFrom(emilyName)}));
    // A second contact while the turn runs: the waiting line is rewritten to name nobody.
    _incoming(m, jordanName, 'and me');
    await t.pump();
    expect(json.decode(hooks.waiting!)['reason'], 'New Antenna messages: read your inbox and continue.');
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty, reason: 'nothing typed into a running turn');
    expect(hooks.stop(), isNotNull, reason: 'the Stop hook prints the continuation');
    await t.pump();
    final last = m.lastCodeLine(_me)!;
    expect((last.kind, last.continued, last.contact), (CodeLineKind.wake, true, null));
    expect(m.codeLinePending(m.runOf(_me)!), isFalse);
    // The continued turn ends: nothing more.
    hooks.stop(active: true);
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('the Stop hook could not continue (stop_hook_active): the window takes the line back and types it',
      (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.prompt);
    _incoming(m, emilyName, 'status?');
    await t.pump();
    expect(hooks.waiting, isNotNull);
    hooks.stop(active: true);
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(hooks.waiting, isNull, reason: 'withdrawn before typing');
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    await _end(t, m);
  });

  testWidgets('a permission dialog by the hooks: nothing, however idle the screen looks', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claude289IdleAuto);
    hooks
      ..emit(ClaudeHookEvent.prompt)
      ..emit(ClaudeHookEvent.tool)
      ..emit(ClaudeHookEvent.permission);
    _incoming(m, emilyName, 'hello');
    await t.pump(const Duration(minutes: 3));
    expect(pty.written, isEmpty);
    // Answered with Yes: the tool runs, the turn ends, the waiting line went to the Stop hook.
    hooks.emit(ClaudeHookEvent.toolDone);
    await t.pump();
    expect(hooks.stop(), isNotNull);
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('a forged "idle" while a dialog is on screen: nothing typed (the screen guard)', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claude289Permission);
    hooks.emit(ClaudeHookEvent.stop);
    _incoming(m, emilyName, 'hello');
    await t.pump(const Duration(minutes: 2));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('the owner\'s draft: never typed over; after the owner sends it and the turn ends, the wake comes',
      (t) async {
    final (m, pty, hooks) = await _running(t, screen: claude289IdleAuto);
    hooks.emit(ClaudeHookEvent.stop);
    final run = m.runOf(_me)!;
    run.terminal.textInput('Try "fix lint errors"');
    pty.emit(drawScreen(claude289DraftTry));
    await t.pump();
    pty.written.clear();
    _incoming(m, emilyName, 'hello');
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty, reason: 'a draft, even one that reads like the placeholder');
    run.terminal.textInput('\r');
    hooks.emit(ClaudeHookEvent.prompt);
    await t.pump();
    pty.written.clear();
    expect(hooks.stop(), isNotNull, reason: 'the turn the owner started ends with the waiting line');
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('Esc interrupts a turn (no hook fires): the screen fallback sees the empty prompt and types', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claude289Busy);
    hooks.emit(ClaudeHookEvent.prompt);
    _incoming(m, emilyName, 'hello');
    await t.pump();
    expect(hooks.waiting, isNotNull);
    final run = m.runOf(_me)!;
    run.terminal.keyInput(TerminalKey.escape);
    pty.emit(drawScreen(claude289AfterTurn));
    await t.pump();
    expect(run.claude.state, ClaudeState.unknown);
    pty.written.clear();
    // The quiet check that began with the Esc restarts after the redraw: 5 s after the last output.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_wakeFrom(emilyName), '\r']);
    expect(hooks.waiting, isNull, reason: 'the continuation was taken back first');
    await _end(t, m);
  });

  testWidgets('hooks that never report and a screen not recognised: nothing typed, the dock says wake is unavailable',
      (t) async {
    final (m, pty, _) = await _running(t);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.pump(const Duration(milliseconds: 300));
    _incoming(m, emilyName, 'hello');
    _now = fixedNow.add(const Duration(seconds: 10));
    await t.pump(const Duration(seconds: 10));
    expect(m.codeWakeUnavailable(m.runOf(_me)!), isFalse, reason: 'the hooks still have time to report');
    _now = fixedNow.add(const Duration(seconds: 25));
    _incoming(m, emilyName, 'hello again');
    await t.pump(const Duration(seconds: 15));
    expect(m.codeWakeUnavailable(m.runOf(_me)!), isTrue);
    await t.pump();
    expect(find.text('Wake is unavailable for this Claude Code version: its hooks do not report and its screen is not '
        'recognised. New messages wait in the chat.'), findsOneWidget);
    expect(pty.written, isEmpty);
    await _end(t, m);
  });

  testWidgets('the owner answered one of its questions (D-118): the answered line, once; another agent\'s: nothing',
      (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.stop);
    EscalationInfo answered(String id, String agent) => EscalationInfo(
        id: id,
        agent: agent,
        to: 'owner',
        question: 'May I?',
        state: EscalationState.answered,
        createdMs: 0,
        answer: 'Yes');
    m.handleEvent(EscalationEvent(answered('e1', 'someone-else')));
    await t.pump(const Duration(seconds: 6));
    expect(pty.written, isEmpty);
    m.handleEvent(EscalationEvent(answered('e2', _me)));
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, ['Your question was answered: read your inbox and continue.', '\r']);
    expect(m.lastCodeLine(_me)?.kind, CodeLineKind.answered);
    await _end(t, m);
  });

  testWidgets('a request waits for it as an approver (CONTROL §31): its own line, once per request; a message covers '
      'it; another agent\'s or another computer\'s approver: nothing', (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.stop);
    ApprovalInfo waiting(String id, List<String> by) => ApprovalInfo(
          id: id,
          state: 'pending',
          requester: 'builder',
          contact: emilyName,
          contactTrust: 4,
          action: 'send_message',
          grants: const Grants(read: '-', write: '-', commands: '-', send: 'text'),
          quote: '',
          fingerprint: '5e11c0aa',
          createdMs: ms(fixedNow),
          expiresMs: ms(fixedNow.add(const Duration(minutes: 10))),
          answerableBy: by,
        );
    m.handleEvent(ApprovalEvent(waiting('k1', ['someone-else', '$_me@Mac mini'])));
    await t.pump(const Duration(seconds: 6));
    expect(pty.written, isEmpty, reason: 'not this agent, or this name on another computer');
    m.handleEvent(ApprovalEvent(waiting('k2', ['someone-else', _me])));
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    const line = 'An approval request waits for your answer: read approvals_to_answer and answer it.';
    expect(pty.written, [line, '\r']);
    expect(m.lastCodeLine(_me)?.kind, CodeLineKind.toAnswer);
    // The same request again (a refusal re-announces it; another computer's status lists it): once
    await t.pump(const Duration(seconds: 31));
    hooks.emit(ClaudeHookEvent.stop);
    m.handleEvent(ApprovalEvent(waiting('k2', [_me])));
    m.onCodeToAnswer(_me, '/k2');
    await t.pump(const Duration(seconds: 6));
    expect(pty.written, [line, '\r']);
    // A new request and a message together: the wake line covers both (the inbox carries the facts too)
    m.handleEvent(ApprovalEvent(waiting('k3', [_me])));
    _incoming(m, emilyName, 'the report?');
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written.skip(2), [_wakeFrom(emilyName), '\r']);
    expect(m.codeLinePending(m.runOf(_me)!), isFalse, reason: 'the wake answered the request\'s line too');
    await _end(t, m);
  });

  testWidgets('a request of another own computer that this agent may answer (its status names it): the same line, once',
      (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks.emit(ClaudeHookEvent.stop);
    final now = ms(fixedNow);
    DeviceApproval asks(String id, List<String> approvers) => DeviceApproval(
        id: id,
        action: 'send_message',
        requester: 'session-2',
        contact: 'MacBook',
        fingerprint: '0011223344556677',
        createdMs: now,
        expiresMs: now + 600000,
        approvers: approvers);
    (m.daemon as FakeDaemon)
      ..devicesEnabled = true
      ..devicesState = DevicesReply(
        self: const ThisDevice(name: 'MacBook', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
        devices: [
          DeviceInfo(
            contact: buildBotName,
            linkId: buildBot.linkId,
            presence: 'online',
            supported: true,
            status: DeviceView(
              atMs: now,
              name: 'ci',
              os: 'linux',
              arch: 'x86_64',
              version: 'antennad 0.2.0',
              approvals: [asks('k1', const ['someone-else']), asks('k2', const [_me])],
            ),
          ),
        ],
      );
    await m.refreshDevices();
    await m.refreshDevices();
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, ['An approval request waits for your answer: read approvals_to_answer and answer it.', '\r']);
    await t.pump(const Duration(seconds: 31));
    hooks.emit(ClaudeHookEvent.stop);
    await m.refreshDevices();
    await t.pump(const Duration(seconds: 6));
    expect(pty.written.length, 2, reason: 'read again: the same request does not wake it twice');
    await _end(t, m);
  });

  testWidgets('the run ends: the hook channel is closed', (t) async {
    final (m, pty, hooks) = await _running(t);
    pty.end(0);
    await t.pump(const Duration(milliseconds: 100));
    expect(hooks.closed, isTrue);
    await _end(t, m);
  });
}
