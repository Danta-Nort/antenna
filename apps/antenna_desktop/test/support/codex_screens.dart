// SPDX-License-Identifier: AGPL-3.0-only
// What Codex shows in a terminal, row by row, with the cursor and the faint text: taken from the real Codex CLI 0.160.1
// on 2026-10-06 (in tmux, 100 × 30, read with `capture-pane -e`), with the folder path and the model replaced by
// neutral text and the rows trimmed to 80 columns. Codex ran against a local stand-in for its model endpoint, so no
// account was involved; the screens are the CLI's own. The Codex wake's screen check reads these (code_screen.dart,
// `codexReady`; PG-21).

import 'claude_screens.dart' show ClaudeScreen, faint;

const _banner = [
  '',
  '  >_ OpenAI Codex (v0.160.1)',
  '     ~/projects/shop',
  '',
  '  Well, well, well. An idea approaches.',
  '',
  '  To get started, describe a task or try one of these commands:',
  '',
  '  /init - create an AGENTS.md file with instructions for Codex',
  '  /status - show current session configuration',
  '  /permissions - choose what Codex is allowed to do',
  '  /model - choose what model and reasoning effort to use',
  '  /review - review any changes and find issues',
];

List<String> _pad(List<String> rows, int to) => [...rows, for (var i = rows.length; i < to; i++) ''];

/// A fresh session at its empty composer: `›`, the faint placeholder, the cursor after `› `, the footer below.
final codexIdle = ClaudeScreen([
  ..._pad(_banner, 26),
  '› ${faint('Ask Codex to do anything')}',
  '',
  '  model default · ~/projects/shop',
  '  ? for shortcuts                          ⚠ 1 warning · f2 to view',
], cursor: (26, 2));

/// The owner typed a draft: normal intensity, the cursor after it, "? for shortcuts" gone from the footer.
final codexDraft = ClaudeScreen([
  ..._pad(_banner, 26),
  '› work6',
  '',
  '  model default · ~/projects/shop',
  '                                           ⚠ 1 warning · f2 to view',
], cursor: (26, 7));

/// A turn runs: the composer shows its placeholder again, the spinner row above it says "esc to interrupt".
final codexWorking = ClaudeScreen([
  ..._pad(_banner, 15),
  '› work6',
  ..._pad(const [], 7),
  '◦ Working (1s • esc to interrupt)',
  '',
  '',
  '› ${faint('Ask Codex to do anything')}',
  '',
  '  model default · ~/projects/shop',
  '  ? for shortcuts                          ⚠ 2 warnings · f2 to view',
], cursor: (26, 2));

/// After a turn: the reply, "Worked for …", the empty composer.
final codexAfterTurn = ClaudeScreen([
  ..._pad(_banner, 15),
  '› work6',
  '',
  '',
  '• ok',
  '',
  '  Worked for 6s • 7:54 AM',
  ..._pad(const [], 5),
  '› ${faint('Ask Codex to do anything')}',
  '',
  '  model default · ~/projects/shop',
  '  ? for shortcuts                          ⚠ 2 warnings · f2 to view',
], cursor: (26, 2));

/// An approval: the cursor hidden, numbered choices with `›`; "y" here would answer "Yes".
final codexApproval = ClaudeScreen([
  ..._pad(const [], 10),
  '› ask',
  '',
  '',
  '• Running touch probe',
  '',
  '',
  '  Would you like to run the following command?',
  '',
  '  Environment: local',
  '',
  '  Reason: Create a probe file?',
  '',
  '  \$ touch probe',
  '',
  '',
  '› 1. Yes, proceed (y)',
  "  2. Yes, and don't ask again for `touch probe` (p)",
  '  3. No, and tell Codex what to do differently (esc)',
  '',
  '  Press enter to confirm or esc to cancel',
], hidden: true);

/// The first start with Antenna's hooks: Codex asks the owner to trust them (answered by the owner, never the window).
final codexHooksReview = ClaudeScreen([
  '',
  '  Hooks need review',
  '  8 hooks are new or changed.',
  '  Hooks can run outside the sandbox after you trust them.',
  '',
  '',
  '› 1. Review hooks',
  '  2. Trust all and continue',
  "  3. Continue without trusting (hooks won't run)",
  '',
  '  enter confirm · esc skip',
], hidden: true);
