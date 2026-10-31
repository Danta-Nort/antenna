// SPDX-License-Identifier: AGPL-3.0-only
// The one place where the window decides what it may put into an agent's terminal by itself, and puts it there
// (D-UI-23, D-UI-25, D-117; the urgent interrupt of CONTROL §33). Everything automatic goes through a [RunInput]: the
// fixed lines ([AllowedLine], typed at the empty prompt or left for the turn's Stop hook, by [RunInput.route]) and the
// one key the window presses by itself, Escape for an urgent message ([RunInput.interrupt], allowed only as
// [RunInput.interruptBlock] says). The screen is read here too ([RunInput.screen], [RunInput.screenText]).
//
// The interrupt's rules come from the CLIs' documented keys: in Claude Code "Esc: interrupt Claude, or close a dialog …
// on a permission prompt, Esc declines the action", and Esc twice on an empty prompt opens the rewind menu; Codex shows
// "esc to interrupt" while it works and runs its Interrupt hook when a turn is interrupted. So the window presses Esc
// exactly once, only while a turn runs, never while a dialog is open, never over the owner's unsent text, and at most
// once per 30 s per agent. Claude Code fires no hook for an interrupt ("Stop … does not run if the stoppage occurred
// due to a user interrupt"), so its state becomes unknown and the screen check decides when the prompt is back; Codex
// reports its Interrupt hook.

import 'agent_launch.dart' show AgentCli;
import 'claude_state.dart';
import 'code_lines.dart';
import 'code_mode.dart';
import 'code_screen.dart';

/// Why the window may not interrupt an agent's turn now ([RunInput.interruptBlock]).
enum InterruptBlock {
  /// It may.
  none,

  /// Not Claude Code or Codex (an own command, whose keys are unknown), or its process has ended.
  notCli,

  /// No turn runs: the agent waits at its prompt, or the window cannot tell (nothing to interrupt).
  idle,

  /// A dialog is open (a permission prompt, a question, Codex's hooks review): Esc there declines the action.
  dialog,

  /// The owner has unsent text in the terminal.
  draft,

  /// The window interrupted this agent less than [RunInput.interruptEvery] ago.
  tooSoon,
}

/// What the window may put into one agent's terminal, and when.
final class RunInput {
  RunInput(this.run, {required this.now});

  final AgentRun run;
  final DateTime Function() now;

  /// At most one interrupt per agent in this time (a second urgent message meanwhile waits for the prompt).
  static const interruptEvery = Duration(seconds: 30);

  /// When the window last interrupted this agent (`null`: never).
  DateTime? lastInterrupt;

  /// The screen as the checks read it.
  TerminalScreen screen() => run.screen();

  /// The visible rows as text, trailing blanks removed: what a person sees in the terminal.
  String screenText() => [for (final r in screen().rows) r.trimRight()].join('\n').trimRight();

  /// How a waiting [AllowedLine] can reach the agent now: typed, left for the Stop hook, or not now.
  LineRoute route() => lineRoute(run.claude, screen(), cli: run.spec.cli);

  /// Type [line] (Enter follows in its own write), or paste it ([AllowedLine.paste]). `false`: nothing written.
  bool type(AllowedLine line) => run.typeLine(line);

  /// A turn runs: the hooks say so; or, when they cannot (no hook state yet, the owner's keys made it unknown, or
  /// Codex without hooks, whose `notify` also fires for helper threads), the screen shows the CLI's busy hint.
  bool turnRuns() {
    final t = run.claude;
    final notifyOnly = run.spec.cli == AgentCli.codex && !t.hooksSeen;
    return switch (t.state) {
      ClaudeState.working => notifyOnly ? busyScreen(screen()) : true,
      ClaudeState.dialog || ClaudeState.ended => false,
      ClaudeState.idle => notifyOnly && busyScreen(screen()),
      ClaudeState.unknown => busyScreen(screen()),
    };
  }

  /// Whether the window may press Esc now, and if not, why.
  InterruptBlock interruptBlock() {
    final cli = run.spec.cli;
    if (!run.alive || (cli != AgentCli.claude && cli != AgentCli.codex)) return InterruptBlock.notCli;
    // A dialog first: the hooks' word, or a numbered choice on the screen whatever the hooks said.
    if (run.claude.state == ClaudeState.dialog || choiceOnScreen(screen())) return InterruptBlock.dialog;
    if (run.claude.draft) return InterruptBlock.draft;
    if (!turnRuns()) return InterruptBlock.idle;
    final last = lastInterrupt;
    if (last != null && now().difference(last) < interruptEvery) return InterruptBlock.tooSoon;
    return InterruptBlock.none;
  }

  /// Press Esc once, if [interruptBlock] allows it. `true`: pressed.
  bool interrupt() {
    if (interruptBlock() != InterruptBlock.none) return false;
    run.interrupt();
    lastInterrupt = now();
    return true;
  }
}
