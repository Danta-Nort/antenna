// SPDX-License-Identifier: AGPL-3.0-only
// What Claude Code shows in a terminal, row by row, with where the cursor stands and which text is drawn faint: taken
// from the real program on a pseudo-terminal through the window's own emulator (2.1.233 on 2026-10-05, 2.1.289 on
// 2026-10-05, 2.1.306 on 2026-10-22 by the canary), with the welcome banner, account and paths replaced by neutral text. The screen check of the Code mode
// wake reads these (code_screen.dart, `claudeCodeReady`); the hooks come first (claude_state.dart).

import 'package:antenna_desktop/state/code_wake.dart';
import 'package:xterm/core.dart';

/// Faint (SGR 2) text, as Claude Code draws its placeholder.
String faint(String s) => '\x1b[2m$s\x1b[22m';

/// One screen: [rows] (with SGR sequences where the program draws them), the cursor's row and column (`null`: left
/// where the last row ends), and whether the program hid the cursor.
final class ClaudeScreen {
  const ClaudeScreen(this.rows, {this.cursor, this.hidden = false});
  final List<String> rows;
  final (int, int)? cursor;
  final bool hidden;
}

/// Claude Code draws its rules across the whole width; 40 columns fit every dock width the tests use.
final claudeRule = '─' * 40;

/// The banner above the conversation (2.1.233).
const _banner = [
  '╭─── Claude Code v2.1.233 ──────────────────────────────────────────────────╮',
  '│                              Welcome back!                               │',
  '│                     ~/projects/shop                                      │',
  '╰──────────────────────────────────────────────────────────────────────────╯',
  '',
];

/// A fresh session waiting for the first prompt: the faint placeholder after `❯`, the hint "? for shortcuts".
final claudeIdleFresh = ClaudeScreen([
  ..._banner,
  claudeRule,
  '❯ ${faint('Try "write a test for <filepath>"')}',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts',
], cursor: (6, 2));

/// A turn has ended: the prompt is empty again.
final claudeIdleAfterTurn = ClaudeScreen([
  ..._banner,
  '❯ Run the tests',
  '',
  '● All 12 tests pass.',
  '',
  '✻ Brewed for 5s',
  '',
  claudeRule,
  '❯',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts',
], cursor: (12, 2));

/// The owner typed a draft and left it: the hint is gone, the cursor after the text.
final claudeDraft = ClaudeScreen([
  ..._banner,
  claudeRule,
  '❯ hi there',
  claudeRule,
  '  ⏸ manual mode on',
], cursor: (6, 10));

/// A turn is running: the prompt box stays (input is queued), the status row says "esc to interrupt".
final claudeBusy = ClaudeScreen([
  ..._banner,
  '❯ Run the bash command: touch notes.txt',
  '',
  '  Running 1 shell command…',
  '',
  '✽ Calculating… (1s · ↓ 38 tokens · thinking)',
  '',
  claudeRule,
  '❯',
  claudeRule,
  '  ⏸ manual mode on · esc to interrupt',
], cursor: (12, 2));

/// Not from 2.1.233: a running turn as other versions draw it: "esc to interrupt" next to the spinner, above the prompt box.
final claudeBusySpinner = ClaudeScreen([
  ..._banner,
  '✻ Thinking… (12s · esc to interrupt)',
  '',
  claudeRule,
  '❯',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts',
], cursor: (8, 2));

/// A permission dialog: Enter here would answer "Yes". The cursor is hidden.
final claudePermission = ClaudeScreen([
  ..._banner,
  '❯ Run the bash command: touch notes.txt',
  '',
  '  Creating a file named notes.txt',
  '  ⎿  \$ touch notes.txt',
  '',
  claudeRule,
  ' Bash command',
  '',
  '   touch notes.txt',
  '   Create a file named notes.txt',
  '',
  ' Do you want to proceed?',
  ' ❯ 1. Yes',
  '   2. Yes, and always allow access to shop/ from this project',
  '   3. No',
  '',
  ' Esc to cancel · Tab to amend · ctrl+e to explain',
], hidden: true);

/// The banner of 2.1.289.
const _banner289 = [
  ' ▐▛███▛█   Claude Code v2.1.289',
  '▝▜██████▀  Opus · Claude Max',
  '  ▝▝   ▝▝   ~/projects/shop',
  '',
];

/// 2.1.289, manual mode: the faint placeholder, the hint "? for shortcuts" next to the mode.
final claude289IdleManual = ClaudeScreen([
  ..._banner289,
  claudeRule,
  '❯ ${faint('Try "write a test for scenarios.dart"')}',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts',
], cursor: (5, 2));

/// 2.1.289 in auto mode, as on the maintainer's Mac: the auto-mode hint replaces "? for shortcuts", the effort row
/// above the box.
final claude289IdleAuto = ClaudeScreen([
  ..._banner289,
  '                                                          ◐ medium · /effort',
  claudeRule,
  '❯ ${faint('Try "fix lint errors"')}',
  claudeRule,
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (6, 2));

/// 2.1.289 auto mode with a draft that reads like the placeholder: normal intensity, the cursor after it.
final claude289DraftTry = ClaudeScreen([
  ..._banner289,
  claudeRule,
  '❯ Try "fix lint errors"',
  claudeRule,
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (5, 23));

/// The same draft with the cursor moved back to its start (Home): still a draft.
final claude289DraftTryHome = ClaudeScreen([
  ..._banner289,
  claudeRule,
  '❯ Try "fix lint errors"',
  claudeRule,
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (5, 2));

/// Not seen in a real version: the faint placeholder with the cursor at its end. Only the two signals together mean
/// "empty": the check must not take one for both.
final claude289FaintCursorAway = ClaudeScreen([
  ..._banner289,
  claudeRule,
  '❯ ${faint('Try "fix lint errors"')}',
  claudeRule,
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (5, 23));

/// 2.1.289 after a turn: the empty prompt.
final claude289AfterTurn = ClaudeScreen([
  ..._banner289,
  '❯ Reply with the single word: ok',
  '',
  '● ok',
  '',
  '✻ Worked for 3s · done 6:59 PM',
  '',
  claudeRule,
  '❯',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts',
], cursor: (11, 2));

/// 2.1.289 after a turn, as the canary (tools/claude-canary.sh) read it on 2026-10-05 (the account's settings had
/// `"tui": "fullscreen"`, which keeps the prompt box at the bottom; Haiku from the project's settings): the empty
/// prompt is `❯` and a no-break space (U+00A0), not a plain space.
final claude289AfterTurnNbsp = ClaudeScreen([
  '',
  ' ▐▛███▛█   Claude Code v2.1.289',
  '▝▜██████▀  Haiku 4.5 · Claude Max',
  '  ▝▝   ▝▝   ~/projects/shop',
  '',
  '${faint('▎')} Using Haiku 4.5 (from .claude/settings.json) · /model',
  '',
  '❯ Yes, go ahead.',
  '',
  '● I don\'t have any prior context in this conversation. What would you like me to',
  '  help you with?',
  '',
  '✻ Baked for 3s · done 11:27 PM',
  for (var i = 0; i < 7; i++) '',
  claudeRule,
  '❯\u00a0',
  claudeRule,
  '  ⏸ manual mode on · ? for shortcuts · ← for agents',
], cursor: (21, 2));

/// The same screen with a draft of one no-break space (Option+Space on a Mac) and the cursor moved back to its start:
/// still a draft.
final claude289NbspDraftHome = ClaudeScreen([
  ...claude289AfterTurnNbsp.rows.take(21),
  '❯\u00a0\u00a0',
  ...claude289AfterTurnNbsp.rows.skip(22),
], cursor: (21, 2));

/// 2.1.289 while a turn runs: the box is empty and the cursor in it, the status row says "esc to interrupt".
final claude289Busy = ClaudeScreen([
  ..._banner289,
  '❯ Reply with the single word: ok',
  '',
  '✽ Computing… (1s · thinking)',
  '',
  claudeRule,
  '❯',
  claudeRule,
  '  ⏸ manual mode on · esc to interrupt',
], cursor: (9, 2));

/// 2.1.289's permission dialog (the cursor hidden).
final claude289Permission = ClaudeScreen([
  '❯ Run the bash command: touch notes.txt',
  '',
  '● Creating empty notes.txt file',
  '  ⎿  \$ touch notes.txt',
  '',
  claudeRule,
  ' Bash command',
  ' Create empty notes.txt file',
  '╌' * 40,
  ' touch notes.txt',
  '╌' * 40,
  ' Do you want to proceed?',
  ' ❯ 1. Yes',
  '   2. Yes, and always allow access to',
  '      ~/projects/shop',
  '      from this project',
  '   3. No',
  '',
  ' Esc to cancel · Tab to amend',
], hidden: true);

/// 2.1.306's new dialog "Read outside the working directories" (the setting `permissions.blockReadsOutsideWorkingDirectories`
/// is unset and a file tool reads above the project folder), as the canary recorded it on 2026-10-22: the hooks said
/// `permission` (PermissionRequest), the cursor hidden, a numbered choice whose first item, under Enter, would allow
/// reads outside the working directories for good.
final claude306ReadOutside = ClaudeScreen([
  '  Finding **/*.md',
  '  ⎿  .claude/settings.json',
  '',
  claudeRule,
  ' Read outside the working directories',
  '╌' * 40,
  ' Search(pattern: "**/*", path: "/tmp/scratch-shop")',
  '╌' * 40,
  ' Auto mode and the sandbox read outside the working directories without asking.',
  ' Yes or No answers for this read; the rest is for later reads. Block: the file',
  ' tools refuse reads outside the working directories in every project.',
  ' Sandboxed commands are not changed on this machine (the sandbox is off, its',
  ' filesystem rules are relaxed, a managed read-path lock is on, or the working',
  ' directory name has glob characters). To undo, remove',
  ' permissions.blockReadsOutsideWorkingDirectories from your user settings; file',
  ' tools follow next session, sandboxed commands at once.',
  '',
  ' Allow this read outside the working directories?',
  ' ❯ 1. Yes, and keep allowing any reads outside the working directories',
  '   2. No, and block reads outside the working directories from now on',
  '   3. No, and ask again next time',
  '   4. Yes, but ask again next time',
  '',
  ' Esc to cancel · Tab to amend',
], hidden: true);

/// [s] as a program would draw it: clear the screen, each row, then show or hide the cursor and put it in place.
String drawScreen(ClaudeScreen s) {
  final cursor = s.cursor == null ? '' : '\x1b[${s.cursor!.$1 + 1};${s.cursor!.$2 + 1}H';
  return '\x1b[2J\x1b[H${s.rows.join('\r\n')}${s.hidden ? '\x1b[?25l' : '\x1b[?25h'}$cursor';
}

/// [s] through a terminal emulator of [columns] × [rows], read the way the wake reads a run's terminal.
TerminalScreen screenOf(ClaudeScreen s, {int columns = 80, int rows = 24}) {
  final t = Terminal(maxLines: 1000)..resize(columns, rows);
  t.write(drawScreen(s));
  return TerminalScreen.of(t);
}
