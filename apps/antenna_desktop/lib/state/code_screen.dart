// SPDX-License-Identifier: AGPL-3.0-only
// What the Code mode wake reads from an agent's terminal (D-UI-23, D-UI-25, D-117): the screen as a person sees it,
// the guard that nothing modal is up, the fallback checks for Claude Code's empty prompt and Codex's empty composer,
// and the route a waiting line takes in the CLI's state (typed, left for the Stop hook, or waiting).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xterm/core.dart';

import 'agent_launch.dart' show AgentCli;
import 'claude_state.dart';

/// What the idle checks read from a terminal: the visible rows, which characters are drawn faint, and the cursor.
@immutable
final class TerminalScreen {
  const TerminalScreen(this.rows, {this.faint = const [], this.cursorRow, this.cursorColumn, this.cursorVisible = false});

  /// The screen of [t]: untouched cells as blanks (what a person sees; xterm skips them in its own text).
  factory TerminalScreen.of(Terminal t) {
    final b = t.buffer;
    final rows = <String>[];
    final faint = <List<bool>>[];
    int? cursorColumn;
    final top = math.max(0, b.height - t.viewHeight);
    final cursorLine = top + b.cursorY;
    for (var y = top; y < b.height; y++) {
      final line = b.lines[y];
      final row = StringBuffer();
      final dim = <bool>[];
      for (var x = 0; x < line.length; x++) {
        if (y == cursorLine && x == b.cursorX) cursorColumn = row.length;
        final cp = line.getCodePoint(x);
        final f = line.getAttributes(x) & CellAttr.faint != 0;
        if (cp != 0) {
          final before = row.length;
          row.writeCharCode(cp);
          for (var i = before; i < row.length; i++) {
            dim.add(f);
          }
        } else if (x == 0 || line.getWidth(x - 1) != 2) {
          row.write(' ');
          dim.add(f);
        }
      }
      if (y == cursorLine) cursorColumn ??= row.length;
      rows.add(row.toString());
      faint.add(dim);
    }
    final visibleRow = cursorLine - top;
    return TerminalScreen(rows,
        faint: faint,
        cursorRow: visibleRow >= 0 && visibleRow < rows.length ? visibleRow : null,
        cursorColumn: cursorColumn,
        cursorVisible: t.cursorVisibleMode);
  }

  /// The visible rows (UTF-16 strings).
  final List<String> rows;

  /// Per row, per UTF-16 unit of [rows]: drawn faint (SGR 2).
  final List<List<bool>> faint;

  /// Where the cursor stands: an index into [rows] and a UTF-16 index into that row (`null`: not on the screen).
  final int? cursorRow;
  final int? cursorColumn;

  /// The program shows the cursor (Claude Code hides it while a dialog is up).
  final bool cursorVisible;

  bool isFaint(int row, int index) => row < faint.length && index < faint[row].length && faint[row][index];
}

final _rule = RegExp(r'^─{20,}$');

/// A numbered choice is on the screen (`❯ 1. Yes` in a Claude Code permission or trust dialog, `› 1. Yes, proceed (y)`
/// in a Codex approval or its "Hooks need review", `> 1. Sign in with ChatGPT` on its first start), or a question that
/// waits for one.
final _choice = RegExp(r'^\s*[❯›>]\s*\d+\.\s');

/// The screen agrees that nothing modal is up: the cursor is shown and no numbered choice is visible. Claude Code
/// (2.1.233 and 2.1.289) hides the cursor and draws `❯ 1. Yes` while it asks for permission. Defence in depth on top
/// of the hooks: an agent can write into its own hook folder, but it cannot make the window type into a dialog.
bool screenGuard(TerminalScreen s) => s.cursorVisible && !s.rows.any(_choice.hasMatch);

/// The screen fallback: Claude Code waits for input at an empty prompt. The last rows show its prompt `❯` between two
/// horizontal rules with only status rows below; no "esc to interrupt" (a turn is running); the cursor stands right
/// after `❯ ` and whatever follows it on that row is blank or drawn faint (the placeholder `Try "…"`). A draft is drawn
/// in normal intensity and puts the cursor after itself, so it cannot pass, whatever it says. A permission or trust
/// dialog replaces the prompt with a list (`❯ 1. Yes`) and hides the cursor. Checked on Claude Code 2.1.233 and
/// 2.1.289 (with and without auto mode, whose hint replaces "? for shortcuts"). Anything else is not recognised, and
/// the window then types nothing by itself.
bool claudeCodeReady(TerminalScreen s) {
  final lines = [for (final r in s.rows) r.trimRight()];
  var end = lines.length;
  while (end > 0 && lines[end - 1].trim().isEmpty) {
    end--;
  }
  for (var i = end - 2; i >= 1; i--) {
    final row = lines[i].trimLeft();
    if (!row.startsWith('❯')) continue;
    if (!_rule.hasMatch(lines[i - 1].trim()) || !_rule.hasMatch(lines[i + 1].trim())) continue;
    final below = lines.sublist(i + 2, end);
    // The prompt box is the bottom of the screen: only its status rows follow it.
    if (below.where((l) => l.trim().isNotEmpty).length > 4) return false;
    // A running turn says so in the status row or, in other versions, next to the spinner above the box.
    if (lines.sublist(math.max(0, i - 6), end).any((l) => l.toLowerCase().contains('esc to interrupt'))) return false;
    return screenGuard(s) && _emptyInput(s, i, lines[i].length - row.length);
  }
  return false;
}

/// The screen shows a Claude Code state the checks know: its prompt box (`❯` between two rules, whatever is in it) or
/// a numbered choice of a dialog. Otherwise the layout is unknown (another version, another program).
bool claudeLayoutKnown(TerminalScreen s) {
  if (s.rows.any(_choice.hasMatch)) return true;
  final lines = [for (final r in s.rows) r.trim()];
  for (var i = 1; i + 1 < lines.length; i++) {
    if (lines[i].startsWith('❯') && _rule.hasMatch(lines[i - 1]) && _rule.hasMatch(lines[i + 1])) return true;
  }
  return false;
}

/// Codex waits for input at an empty composer: its last composer row starts with `›` near the bottom, its footer is
/// below (`? for shortcuts`, `… to send`, `… context left`), no `esc to interrupt` (its spinner row while a turn runs,
/// a few rows above the composer, which keeps showing the placeholder during the turn), and the cursor right after
/// `› ` with only blank or faint text after it (the placeholder `Ask Codex to do anything`). A draft is drawn in normal
/// intensity and moves the cursor; an approval or the hooks' review hides the cursor and lists `› 1. …`. Checked on
/// Codex 0.160.1. `antenna session` reads its panes with the same rule (crates/antenna-cli/src/session/screen.rs).
bool codexReady(TerminalScreen s) {
  final lines = [for (final r in s.rows) r.trimRight()];
  var end = lines.length;
  while (end > 0 && lines[end - 1].trim().isEmpty) {
    end--;
  }
  for (var i = end - 1; i >= 0; i--) {
    final row = lines[i].trimLeft();
    if (!row.startsWith('›')) continue;
    final below = lines.sublist(i + 1, end);
    if (below.where((l) => l.trim().isNotEmpty).length > 4) return false;
    final footer = below.any((l) {
      final x = l.toLowerCase();
      return x.contains('for shortcuts') || x.contains('to send') || x.contains('context left');
    });
    if (!footer) return false;
    if (lines.sublist(math.max(0, i - 8), end).any((l) => l.toLowerCase().contains('esc to interrupt'))) return false;
    return screenGuard(s) && _emptyInput(s, i, lines[i].length - row.length);
  }
  return false;
}

/// The screen shows a Codex layout the checks know: its composer row (`›` at the start) or a dialog's choice.
bool codexLayoutKnown(TerminalScreen s) => s.rows.any((r) => _choice.hasMatch(r) || r.trimLeft().startsWith('›'));

/// A numbered choice of a dialog is on the screen: Enter there would accept it, Esc decline it.
bool choiceOnScreen(TerminalScreen s) => s.rows.any(_choice.hasMatch);

/// The bottom rows that hold a CLI's status and spinner (Claude Code's status row below its prompt box, the spinner
/// row above it; Codex's spinner row a few rows above its composer).
const _statusRows = 12;

/// The screen fallback for "a turn runs" (CONTROL §33: when the hooks cannot say): the CLI's busy hint "esc to
/// interrupt" in its bottom rows (Claude Code 2.1.233 and 2.1.289, Codex 0.160.1), and no numbered choice on the
/// screen.
bool busyScreen(TerminalScreen s) {
  if (choiceOnScreen(s)) return false;
  final rows = [for (final r in s.rows) if (r.trim().isNotEmpty) r];
  return rows.skip(math.max(0, rows.length - _statusRows)).any((r) => r.toLowerCase().contains('esc to interrupt'));
}

/// The screen check of [cli]: [codexReady] for Codex, [claudeCodeReady] otherwise.
bool cliReady(AgentCli cli, TerminalScreen s) => cli == AgentCli.codex ? codexReady(s) : claudeCodeReady(s);

/// Nothing is typed after the prompt mark at [prompt] in row [row]: the cursor stands right after `❯ `, and the rest of
/// the row is blank or faint. The separator right after `❯` may be a no-break space: 2.1.289 and 2.1.290 draw their
/// empty prompt after a turn as `❯` and U+00A0 (seen by the canary, tools/claude-canary.sh). Only that one column: a
/// no-break space typed into the prompt is a draft like any other text.
bool _emptyInput(TerminalScreen s, int row, int prompt) {
  if (s.cursorRow != row || s.cursorColumn != prompt + 2) return false;
  final text = s.rows[row];
  for (var c = prompt + 1; c < text.length; c++) {
    if (text[c] == ' ' || (c == prompt + 1 && text[c] == '\u00a0')) continue;
    if (!s.isFaint(row, c)) return false;
  }
  return true;
}

/// How a waiting line can reach the agent now.
enum LineRoute {
  /// Type it at the prompt.
  type,

  /// A turn runs: leave it for the turn's Stop hook.
  continueTurn,

  /// Not now (a dialog, a draft, the state unknown and the screen not recognised).
  wait,
}

/// The route for an automatic line to [cli] (Claude Code unless said) in [t]'s state on [screen].
LineRoute lineRoute(ClaudeTracker t, TerminalScreen screen, {AgentCli cli = AgentCli.claude}) {
  // Codex without hooks: "idle" comes from notify, which a helper thread's turn sends during the owner's turn too, and
  // there is no Stop hook to continue a turn with.
  final notifyOnly = cli == AgentCli.codex && !t.hooksSeen;
  return switch (t.state) {
    // Idle by the hooks: type, unless the owner has a draft (or the screen shows something modal). The window knows
    // a draft from the owner's keys; only after the owner deleted text may the screen check say it is empty again.
    ClaudeState.idle => notifyOnly
        ? (codexReady(screen) ? LineRoute.type : LineRoute.wait)
        : screenGuard(screen) && (!t.draft || (t.lastEdit && cliReady(cli, screen)))
            ? LineRoute.type
            : LineRoute.wait,
    ClaudeState.working => notifyOnly ? LineRoute.wait : LineRoute.continueTurn,
    ClaudeState.dialog || ClaudeState.ended => LineRoute.wait,
    ClaudeState.unknown => cliReady(cli, screen) ? LineRoute.type : LineRoute.wait,
  };
}
