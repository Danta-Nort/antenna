// SPDX-License-Identifier: AGPL-3.0-only
// What a Claude Code session in a Code mode terminal is doing, from its own hook events (host/code_hooks.dart) and the
// owner's keys in that terminal, not from its screen (D-UI-25). Codex 0.160 and later report through hooks of the same
// kind (plus Interrupt for Esc), older ones only through `notify` after a turn (PG-21). Pure Dart.
//
// The hooks say "working" (a prompt was submitted, a tool runs), "a permission dialog is open" and "idle at the
// prompt" (Stop, SessionStart). Two transitions fire no hook, and the window sees them as the owner's keys instead: an
// Esc or Ctrl+C that interrupts a turn or closes a dialog, and keys that open one of Claude Code's own menus or recall
// history. After such keys the state is unknown until the next hook, and only the screen fallback may decide
// (code_screen.dart). Text the owner types is a draft until it is submitted (Enter) or cleared (Ctrl+C, checked on
// Claude Code 2.1.289): the window never presses Enter over it.

import '../host/code_hooks.dart';

enum ClaudeState {
  /// No hook event yet, or the owner's keys changed what the hooks last said.
  unknown,

  /// At its prompt, waiting for input (Stop, SessionStart, the idle notification).
  idle,

  /// A turn runs (a prompt was submitted, a tool runs or finished).
  working,

  /// A permission dialog is open: Enter there answers "Yes".
  dialog,

  /// The session ended.
  ended,
}

/// The state machine of one session.
final class ClaudeTracker {
  ClaudeState state = ClaudeState.unknown;

  /// At least one hook event arrived since the start: the hooks work in this Claude Code.
  bool hooksSeen = false;

  /// The owner typed text that was not submitted or cleared yet (or the window pasted a screenshot there).
  bool draft = false;

  /// The owner's last key edited the prompt (Backspace, Delete): a draft may be empty again, which only the screen
  /// check can confirm.
  bool lastEdit = false;

  /// The last event, for the log.
  ClaudeHookEvent? last;

  void onHook(ClaudeHookEvent e) {
    last = e;
    if (e == ClaudeHookEvent.turnComplete) {
      // Codex's notify program: also for its helper threads (a title for a new conversation while the owner's turn
      // runs). With hooks it says nothing they do not say better; without them, a completed turn means the prompt.
      if (!hooksSeen) state = ClaudeState.idle;
      return;
    }
    hooksSeen = true;
    state = switch (e) {
      ClaudeHookEvent.start ||
      ClaudeHookEvent.stop ||
      ClaudeHookEvent.notifyIdle ||
      ClaudeHookEvent.interrupt ||
      ClaudeHookEvent.turnComplete =>
        ClaudeState.idle,
      ClaudeHookEvent.prompt ||
      ClaudeHookEvent.tool ||
      ClaudeHookEvent.toolDone ||
      ClaudeHookEvent.continued =>
        ClaudeState.working,
      ClaudeHookEvent.permission || ClaudeHookEvent.notifyPermission => ClaudeState.dialog,
      ClaudeHookEvent.end => ClaudeState.ended,
    };
    // A submitted prompt took the draft with it; a new session starts with an empty prompt.
    if (e == ClaudeHookEvent.prompt || e == ClaudeHookEvent.start) draft = false;
  }

  /// What the owner typed into the terminal ([data] as the terminal sends it to the program).
  void onOwnerInput(String data) {
    final kind = classifyInput(data);
    if (kind == OwnerInput.automatic) return;
    lastEdit = kind == OwnerInput.edit;
    switch (kind) {
      case OwnerInput.automatic:
        return;
      case OwnerInput.text:
        // In a dialog a digit answers it; anywhere else text goes into the prompt.
        if (state == ClaudeState.dialog) {
          state = ClaudeState.unknown;
        } else {
          draft = true;
        }
      case OwnerInput.enter:
        // Submitted: a prompt (the hook will say "working") or one of Claude Code's own commands, which may open a
        // menu no hook reports.
        draft = false;
        state = _touched(state);
      case OwnerInput.interrupt:
        // Ctrl+C clears the input; during a turn or in a dialog it interrupts, which fires no hook.
        draft = false;
        state = _touched(state);
      case OwnerInput.key:
        // Esc, arrows, Tab, Shift+Tab, Ctrl+R…: may close a dialog, recall history into the prompt or open a menu.
        state = _touched(state);
      case OwnerInput.edit:
        break;
    }
  }

  static ClaudeState _touched(ClaudeState s) => s == ClaudeState.ended ? s : ClaudeState.unknown;
}

enum OwnerInput {
  /// Printable text or a paste: a draft.
  text,

  /// Enter alone.
  enter,

  /// Ctrl+C.
  interrupt,

  /// Backspace / Delete: editing a draft (whether it is empty now, only the screen can tell).
  edit,

  /// Any other key (Esc, arrows, Tab, control keys).
  key,

  /// Not the owner: the terminal's own answers to the program's queries (cursor position, device attributes, colors)
  /// and focus reports.
  automatic,
}

final _automatic = RegExp(r'^\x1b(\[[IO]|\[[\d;?>]*[cRn]|\][^\x07\x1b]*(\x07|\x1b\\)|P[^\x1b]*\x1b\\)$');

/// What kind of input [data] is (one write of the terminal widget).
OwnerInput classifyInput(String data) {
  if (data.isEmpty) return OwnerInput.automatic;
  if (_automatic.hasMatch(data)) return OwnerInput.automatic;
  if (data.startsWith('\x1b[200~')) return OwnerInput.text;
  if (data == '\r' || data == '\n') return OwnerInput.enter;
  if (data == '\x03') return OwnerInput.interrupt;
  if (data == '\x7f' || data == '\x08' || data == '\x1b[3~') return OwnerInput.edit;
  final printable = data.runes.every((r) => r >= 0x20 && r != 0x7f && !(r >= 0x80 && r < 0xa0));
  return printable ? OwnerInput.text : OwnerInput.key;
}
