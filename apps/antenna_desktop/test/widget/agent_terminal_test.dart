// SPDX-License-Identifier: AGPL-3.0-only
// Scrolling back in an agent's terminal (ui/code/agent_terminal.dart, state/terminal_mouse.dart). The dock's terminal
// could not be scrolled back: Claude Code asked something, the output went on, and the question was gone.
// On the main screen: the wheel scrolls the bounded scrollback, new output keeps the view where the person reads, and
// "Jump to the latest" brings it to the end. On the alternate screen (where Claude Code runs, with mouse reports on):
// the wheel reaches the program with the protocol's codes (64 up, 65 down), which xterm 4.0.0 got wrong (68, 69).

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/agent_launch.dart' show AgentCli;
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/terminal_mouse.dart';
import 'package:antenna_desktop/ui/code/agent_terminal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

AgentRun _run() =>
    AgentRun(1, const AgentRunSpec(agent: 'volna', cli: AgentCli.claude, workDir: '/tmp'), platform: TerminalTargetPlatform.linux);

Future<void> _show(WidgetTester t, AgentRun r) async {
  t.view.physicalSize = const Size(800, 600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox(width: 640, height: 400, child: AgentTerminal(r))),
  ));
  await t.pump();
}

/// The terminal's own scroll position (its main screen's scrollback).
ScrollPosition _pos(WidgetTester t) =>
    t.state<ScrollableState>(find.descendant(of: find.byType(TerminalView), matching: find.byType(Scrollable)).first)
        .position;

/// A wheel turn over the terminal: [dy] < 0 scrolls up (back), as a mouse wheel or a trackpad sends it.
Future<void> _wheel(WidgetTester t, double dy) async {
  final p = TestPointer(7, PointerDeviceKind.mouse);
  final at = t.getCenter(find.byType(TerminalView));
  t.binding.handlePointerEvent(p.hover(at));
  t.binding.handlePointerEvent(p.scroll(Offset(0, dy)));
  await t.pump();
  await t.pump();
}

final _latest = find.byKey(const Key('code-terminal-latest-volna'));

void main() {
  testWidgets('scrolled back, new output does not move the view; Jump to the latest brings it to the end', (t) async {
    final r = _run();
    for (var i = 1; i <= 300; i++) {
      r.terminal.write('line $i\r\n');
    }
    await _show(t, r);
    final p = _pos(t);
    expect(p.pixels, p.maxScrollExtent, reason: 'at the end at first');
    expect(_latest, findsNothing);

    await _wheel(t, -600);
    final reading = p.pixels;
    expect(reading, lessThan(p.maxScrollExtent - 100), reason: 'the wheel scrolled back');
    expect(_latest, findsOneWidget);

    // The agent goes on writing: the view stays on what the person reads
    for (var i = 301; i <= 340; i++) {
      r.terminal.write('line $i\r\n');
    }
    await t.pump();
    await t.pump();
    expect(p.pixels, reading, reason: 'not yanked down');
    expect(p.maxScrollExtent, greaterThan(reading + 600));
    expect(_latest, findsOneWidget);

    await t.tap(_latest);
    await t.pump();
    await t.pump();
    expect(p.pixels, p.maxScrollExtent);
    expect(_latest, findsNothing);

    // At the end, new output is followed
    for (var i = 341; i <= 360; i++) {
      r.terminal.write('line $i\r\n');
    }
    await t.pump();
    await t.pump();
    expect(p.pixels, p.maxScrollExtent);
  });

  test('the scrollback is bounded', () {
    final r = _run();
    for (var i = 0; i < AgentRun.scrollbackLines + 500; i++) {
      r.terminal.write('line $i\r\n');
    }
    expect(r.terminal.buffer.lines.length, lessThanOrEqualTo(AgentRun.scrollbackLines));
  });

  testWidgets('on the alternate screen with mouse reports, the wheel reaches the program as 64 and 65', (t) async {
    final r = _run();
    final sent = <String>[];
    r.terminal.onOutput = sent.add;
    // What Claude Code 2.1.291 writes when it starts (recorded in a pseudo-terminal)
    r.terminal.write('\x1b[?1049h\x1b[2J\x1b[H\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
    await _show(t, r);
    expect(r.terminal.isUsingAltBuffer, isTrue);
    await _wheel(t, -60);
    await _wheel(t, 60);
    final wheel = sent.where((s) => s.startsWith('\x1b[<6')).toList();
    expect(wheel.where((s) => s.startsWith('\x1b[<64;')), isNotEmpty, reason: 'wheel up: $wheel');
    expect(wheel.where((s) => s.startsWith('\x1b[<65;')), isNotEmpty, reason: 'wheel down: $wheel');
    expect(wheel.where((s) => s.startsWith('\x1b[<68;') || s.startsWith('\x1b[<69;')), isEmpty,
        reason: 'not Shift + wheel');
    expect(_latest, findsNothing, reason: 'the program owns the alternate screen');
  });

  test('every report mode carries the wheel with the protocol codes', () {
    final term = Terminal(mouseHandler: agentMouseHandler)..write('\x1b[?1000h');
    final out = <String>[];
    term.onOutput = out.add;
    term.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(4, 9));
    expect(out.last, '\x1b[M${String.fromCharCode(32 + 64)}${String.fromCharCode(37)}${String.fromCharCode(42)}');
    term.write('\x1b[?1015h');
    term.mouseInput(TerminalMouseButton.wheelDown, TerminalMouseButtonState.down, const CellOffset(4, 9));
    expect(out.last, '\x1b[97;5;10M');
    term.write('\x1b[?1006h');
    term.mouseInput(TerminalMouseButton.wheelDown, TerminalMouseButtonState.down, const CellOffset(4, 9));
    expect(out.last, '\x1b[<65;5;10M');
    // Clicks stay the package's
    term.mouseInput(TerminalMouseButton.left, TerminalMouseButtonState.down, const CellOffset(4, 9));
    expect(out.last, '\x1b[<0;5;10M');
    // No mouse reports asked for: nothing is reported (the view sends arrow keys in the alternate screen)
    final quiet = Terminal(mouseHandler: agentMouseHandler);
    expect(quiet.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(0, 0)), isFalse);
  });
}
