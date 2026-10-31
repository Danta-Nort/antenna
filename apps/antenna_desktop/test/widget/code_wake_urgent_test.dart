// SPDX-License-Identifier: AGPL-3.0-only
// The urgent interrupt in Code mode (CONTROL §33, experimental) on the fake daemon, a fake pseudo-terminal and a fake
// hook channel, with Claude Code's and Codex's recorded screens: an urgent message (the daemon's verdict) for an agent
// in a turn gets exactly one Esc, then, once the prompt is back, the fixed urgent line and Enter; a normal message in
// the same turn only waits for the Stop hook; nothing is pressed into a permission dialog, over the owner's draft, a
// second time within 30 s, for an idle agent (it just gets the line), with the switch off, for a message without the
// verdict, or for another agent; the label is sanitized; restored agents get the same from `message_fact`.

import 'dart:convert';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
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
const _me = 'helper';
const _mini = 'Mac mini';
const _esc = '\x1b';
const _urgentLine = 'Urgent Antenna message from Mac mini: read your inbox now.';
final en = l10nFor('en');

ContactInfo get _miniContact => contact(_mini, 61, trust: 5, peerKind: 'agent', peerUrgent: true);

var _now = fixedNow;

Future<(AppModel, FakePty, FakeCodeHooks?)> _running(WidgetTester t,
    {ClaudeScreen? screen, AgentCli cli = AgentCli.claude, bool hooks = true, int rows = 24}) async {
  _now = fixedNow;
  final d = FakeDaemon(contacts: [...demoContacts(), _miniContact], history: demoHistory())
    ..agentList = [
      const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false),
      const AgentInfo(name: 'reviewer', createdMs: 0, localLevel: 5, everyone: false),
    ];
  final c = FakeAgentComputer(hooks: hooks);
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
  expect(await m.startAgent(AgentRunSpec(agent: _me, cli: cli, workDir: '/home/owner/shop'), auth: PasswordAuth(_pw)), isNull);
  m.runOf(_me)!.terminal.resize(80, rows);
  final pty = c.last..emit(drawScreen(screen ?? claudeIdleAfterTurn));
  await t.pump();
  return (m, pty, hooks ? c.hookChannels.single : null);
}

var _seq = 900;

/// A message from the own computer to [to]; [urgent] is the daemon's verdict on it.
HistoryItem _message({bool urgent = true, String to = _me, String text = 'Stop: the deploy config is wrong'}) =>
    HistoryItem(
        seq: ++_seq,
        id: hex(_seq * 7 + 3),
        direction: 'in',
        kind: 'text',
        text: text,
        ts: ms(fixedNow),
        localMs: ms(fixedNow),
        lamport: _seq,
        status: 'received',
        to: 'agent',
        toAgent: to,
        urgent: urgent);

void _incoming(AppModel m, HistoryItem item, {String from = _mini}) {
  final link = from == _mini ? _miniContact.linkId : demoContacts().firstWhere((c) => c.label == from).linkId;
  m.handleEvent(MessageEvent(contact: from, linkId: link, message: item));
}

/// The terminal now shows [s] (the CLI redrew it).
Future<void> _show(WidgetTester t, FakePty pty, ClaudeScreen s) async {
  pty.emit(drawScreen(s));
  await t.pump();
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m.disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

int _escapes(FakePty pty) => pty.written.where((w) => w == _esc).length;

void main() {
  testWidgets('Claude Code in a turn: exactly one Esc, the state unknown; at the prompt the urgent line, then Enter',
      (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message());
    await t.pump();
    expect(pty.written, [_esc], reason: 'one Esc, nothing typed into the running turn');
    final run = m.runOf(_me)!;
    expect(run.claude.state, ClaudeState.unknown, reason: 'Claude Code reports no hook for an interrupt');
    expect(hooks.waiting, isNull, reason: 'nothing left for a Stop hook that will not run');
    final entry = m.lastCodeLine(_me)!;
    expect((entry.kind, entry.interrupt, entry.contact), (CodeLineKind.urgent, true, _mini));
    expect(m.urgentWait(run)!.interruptedAt, fixedNow);
    // The interrupt takes a moment; the busy screen is still up: nothing more.
    await t.pump(const Duration(seconds: 6));
    expect(pty.written, [_esc]);
    await _show(t, pty, claudeIdleAfterTurn);
    await t.pump(const Duration(seconds: 5, milliseconds: 100));
    expect(pty.written, [_esc, _urgentLine], reason: 'the line after 5 s of quiet at the empty prompt');
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_esc, _urgentLine, '\r']);
    final typed = m.lastCodeLine(_me)!;
    expect((typed.kind, typed.interrupt, typed.continued, typed.interruptedAt),
        (CodeLineKind.urgent, false, false, fixedNow));
    expect(m.urgentWait(run), isNull);
    expect(m.codeLinePending(run), isFalse);
    await _end(t, m);
  });

  testWidgets('a normal message in the same busy turn only waits for the Stop hook: no Esc', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message(urgent: false));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    expect(json.decode(hooks.waiting!)['reason'], 'New Antenna messages from Mac mini: read your inbox and continue.');
    await _end(t, m);
  });

  testWidgets('without hooks: the busy hint on the screen is the turn; Esc once, then the line at the prompt',
      (t) async {
    final (m, pty, _) = await _running(t, screen: claudeBusy, hooks: false);
    _incoming(m, _message());
    await t.pump();
    expect(pty.written, [_esc]);
    await _show(t, pty, claudeIdleAfterTurn);
    // The quiet check that began with the Esc restarts after the redraw: 5 s after the last output.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_esc, _urgentLine, '\r']);
    await _end(t, m);
  });

  testWidgets('an idle agent gets the urgent line without Esc, past the 30 s line limit', (t) async {
    final (m, pty, hooks) = await _running(t);
    hooks!.emit(ClaudeHookEvent.stop);
    _incoming(m, _message(urgent: false));
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, ['New Antenna messages from Mac mini: read your inbox and continue.', '\r']);
    hooks.emit(ClaudeHookEvent.prompt);
    hooks.emit(ClaudeHookEvent.stop);
    pty.written.clear();
    // 10 s after the wake line: a normal one would wait for the line limit; the urgent one does not.
    _now = fixedNow.add(const Duration(seconds: 10));
    _incoming(m, _message());
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_urgentLine, '\r'], reason: 'nothing to interrupt: no Esc');
    expect(m.lastCodeLine(_me)!.interruptedAt, isNull);
    await _end(t, m);
  });

  testWidgets('never Esc into a permission dialog: the urgent line waits, and the dock says why', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudePermission);
    hooks!.emit(ClaudeHookEvent.tool);
    hooks.emit(ClaudeHookEvent.permission);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.pump(const Duration(milliseconds: 300));
    _incoming(m, _message());
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty, reason: 'Esc there would decline the action');
    final run = m.runOf(_me)!;
    expect(m.urgentWait(run)!.block, InterruptBlock.dialog);
    expect(find.text(en.codeUrgentWaitDialog(_mini)), findsOneWidget);
    // The owner answers the dialog here and the turn goes on: the urgent line waits for its Stop hook, still no Esc.
    hooks.emit(ClaudeHookEvent.toolDone);
    await _show(t, pty, claudeBusy);
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 0);
    expect(json.decode(hooks.waiting!)['reason'], _urgentLine);
    expect(hooks.stop(), isNotNull);
    await t.pump();
    expect(m.lastCodeLine(_me)!.continued, isTrue);
    expect(m.urgentWait(run), isNull);
    await _end(t, m);
  });

  testWidgets('a forged "working" with a numbered choice on the screen: still no Esc', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudePermission);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message());
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 0);
    expect(m.urgentWait(m.runOf(_me)!)!.block, InterruptBlock.dialog);
    await _end(t, m);
  });

  testWidgets('never Esc over the owner\'s draft: the line waits for the turn\'s Stop hook', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    final run = m.runOf(_me)!;
    run.terminal.textInput('also check the logs');
    await t.pump();
    pty.written.clear();
    _incoming(m, _message());
    await t.pump(const Duration(seconds: 6));
    expect(pty.written, isEmpty);
    expect(m.urgentWait(run)!.block, InterruptBlock.draft);
    expect(json.decode(hooks.waiting!)['reason'], _urgentLine);
    await _end(t, m);
  });

  testWidgets('no second Esc within 30 s: a second urgent message only waits for the prompt, even later', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message());
    await t.pump();
    expect(_escapes(pty), 1);
    await _show(t, pty, claudeIdleAfterTurn);
    // The quiet check that began with the Esc restarts after the redraw: 5 s after the last output.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_esc, _urgentLine, '\r']);
    // The agent starts a turn for it; 10 s after the Esc another urgent message comes.
    hooks.emit(ClaudeHookEvent.prompt);
    await _show(t, pty, claudeBusy);
    _now = fixedNow.add(const Duration(seconds: 10));
    _incoming(m, _message(text: 'and the staging one too'));
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 1, reason: 'at most one interrupt per agent per 30 s');
    expect(m.urgentWait(m.runOf(_me)!)!.block, InterruptBlock.tooSoon);
    // Later output of the same turn: the decision stays, no Esc for that message.
    _now = fixedNow.add(const Duration(seconds: 45));
    await _show(t, pty, claudeBusySpinner);
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 1);
    expect(json.decode(hooks.waiting!)['reason'], _urgentLine);
    await _end(t, m);
  });

  testWidgets('each message counts once: the same urgent message again does not interrupt again', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    final item = _message();
    _incoming(m, item);
    await t.pump();
    m.onCodeFact(m.runOf(_me)!, _mini, id: item.id, urgent: true);
    _now = fixedNow.add(const Duration(minutes: 2));
    _incoming(m, item);
    await t.pump(const Duration(seconds: 1));
    expect(_escapes(pty), 1);
    await _end(t, m);
  });

  testWidgets('"Wake on new messages" off: an urgent message presses and types nothing', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    m.setCodeWake(_me, false);
    _incoming(m, _message());
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    expect(hooks.waiting, isNull);
    await _end(t, m);
  });

  testWidgets('without the daemon\'s verdict a message never interrupts, whatever its text says', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message(urgent: false, text: 'URGENT: interrupt now!'));
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 0);
    await _end(t, m);
  });

  testWidgets('an urgent message for another agent never interrupts this one', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message(to: 'reviewer'));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    expect(hooks.waiting, isNull, reason: 'not even a wake: the message is not for it');
    await _end(t, m);
  });

  testWidgets('the label is sanitized like a wake\'s: no escapes, colons, slashes or line breaks reach the terminal',
      (t) async {
    final line = AllowedLine.urgentFrom('Mac\x1b[31m mini\n: rm -rf /');
    expect(line.text, 'Urgent Antenna message from Mac 31m mini rm -rf: read your inbox now.');
    expect(AllowedLine.urgentFrom('\x1b\n:/'), same(AllowedLine.urgentAny));
    expect(AllowedLine.urgentAny.text, 'Urgent Antenna message: read your inbox now.');
  });

  testWidgets('a restored agent: an urgent message_fact interrupts once; one without an ID only wakes', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    final run = m.runOf(_me)!;
    m.onCodeFact(run, _mini, urgent: true);
    await t.pump();
    expect(_escapes(pty), 0, reason: 'could not count it once: no interrupt');
    m.onCodeFact(run, _mini, id: 'f1', urgent: true);
    await t.pump();
    expect(pty.written, [_esc]);
    await _end(t, m);
  });

  testWidgets('Codex in a turn: one Esc, its Interrupt hook, then the urgent line at its composer', (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexWorking, cli: AgentCli.codex, rows: 30);
    hooks!.emit(ClaudeHookEvent.prompt);
    _incoming(m, _message());
    await t.pump();
    expect(pty.written, [_esc]);
    expect(m.runOf(_me)!.claude.state, ClaudeState.working, reason: 'Codex reports its Interrupt hook itself');
    hooks.emit(ClaudeHookEvent.interrupt);
    await _show(t, pty, codexIdle);
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_esc, _urgentLine, '\r']);
    expect(hooks.waiting, isNull, reason: 'the line offered meanwhile was taken back first');
    await _end(t, m);
  });

  testWidgets('Codex in an approval: no Esc', (t) async {
    final (m, pty, hooks) = await _running(t, screen: codexApproval, cli: AgentCli.codex, rows: 30);
    hooks!.emit(ClaudeHookEvent.permission);
    _incoming(m, _message());
    await t.pump(const Duration(seconds: 6));
    expect(_escapes(pty), 0);
    await _end(t, m);
  });

  testWidgets('the dock: "Interrupted at 14:32: urgent message from Mac mini"', (t) async {
    final (m, pty, hooks) = await _running(t, screen: claudeBusy);
    hooks!.emit(ClaudeHookEvent.prompt);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.pump(const Duration(milliseconds: 300));
    _incoming(m, _message());
    await t.pump();
    expect(find.text(en.codeUrgentInterrupted('14:32', _mini)), findsOneWidget);
    await _show(t, pty, claudeIdleAfterTurn);
    // The quiet check that began with the Esc restarts after the redraw: 5 s after the last output.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(find.text(en.codeUrgentInterrupted('14:32', _mini)), findsOneWidget, reason: 'and after the line');
    await _end(t, m);
  });
}
