// SPDX-License-Identifier: AGPL-3.0-only
// What Claude Code is doing, from its hook events and the owner's keys (claude_state.dart, D-UI-25): the hooks set the
// state; keys that fire no hook (Esc, Ctrl+C, menus, history) make it unknown; text is a draft until it is submitted
// or cleared; the terminal's own answers to the program are not the owner. And the route of an automatic line.

import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';

ClaudeTracker _after(List<Object> steps) {
  final t = ClaudeTracker();
  for (final s in steps) {
    if (s is ClaudeHookEvent) {
      t.onHook(s);
    } else {
      t.onOwnerInput(s as String);
    }
  }
  return t;
}

void main() {
  group('hook events', () {
    test('nothing yet: unknown, and the hooks are not known to work', () {
      final t = ClaudeTracker();
      expect((t.state, t.hooksSeen, t.draft), (ClaudeState.unknown, false, false));
    });
    test('a session: start idle; prompt and tools working; a permission dialog; stop idle; end', () {
      final t = ClaudeTracker()..onHook(ClaudeHookEvent.start);
      expect((t.state, t.hooksSeen), (ClaudeState.idle, true));
      for (final (e, s) in [
        (ClaudeHookEvent.prompt, ClaudeState.working),
        (ClaudeHookEvent.tool, ClaudeState.working),
        (ClaudeHookEvent.permission, ClaudeState.dialog),
        (ClaudeHookEvent.toolDone, ClaudeState.working),
        (ClaudeHookEvent.notifyPermission, ClaudeState.dialog),
        (ClaudeHookEvent.stop, ClaudeState.idle),
        (ClaudeHookEvent.continued, ClaudeState.working),
        (ClaudeHookEvent.notifyIdle, ClaudeState.idle),
        (ClaudeHookEvent.end, ClaudeState.ended),
      ]) {
        t.onHook(e);
        expect(t.state, s, reason: e.name);
      }
    });
    test('every event word round-trips (what the hook script writes)', () {
      for (final e in ClaudeHookEvent.values) {
        expect(ClaudeHookEvent.parse(e.word), e);
      }
      expect(ClaudeHookEvent.parse('Stop'), isNull);
      expect(ClaudeHookEvent.parse('stop now'), isNull);
    });
  });

  group('the owner\'s keys', () {
    test('text is a draft; Enter submits it; the prompt hook clears it too', () {
      final t = _after([ClaudeHookEvent.start, 'h', 'i']);
      expect((t.state, t.draft), (ClaudeState.idle, true), reason: 'typing does not open anything');
      t.onOwnerInput('\r');
      expect((t.state, t.draft), (ClaudeState.unknown, false), reason: 'a prompt or a command: the next hook tells');
      t.onHook(ClaudeHookEvent.prompt);
      expect(t.state, ClaudeState.working);
      t.onOwnerInput('queued text');
      expect(t.draft, isTrue);
      t.onHook(ClaudeHookEvent.prompt);
      expect(t.draft, isFalse);
    });
    test('Ctrl+C clears the draft (checked on 2.1.289); in a turn it interrupts, which fires no hook', () {
      final t = _after([ClaudeHookEvent.start, 'draft text', '\x03']);
      expect((t.state, t.draft), (ClaudeState.unknown, false));
      final w = _after([ClaudeHookEvent.prompt, '\x03']);
      expect(w.state, ClaudeState.unknown);
    });
    test('Esc in a dialog or a turn, arrows, Tab, Shift+Tab, Ctrl+R: unknown until the next hook', () {
      for (final key in ['\x1b', '\x1b[A', '\t', '\x1b[Z', '\x12']) {
        expect(_after([ClaudeHookEvent.permission, key]).state, ClaudeState.unknown, reason: 'dialog + ${key.codeUnits}');
        expect(_after([ClaudeHookEvent.prompt, key]).state, ClaudeState.unknown, reason: 'turn + ${key.codeUnits}');
        expect(_after([ClaudeHookEvent.stop, key]).state, ClaudeState.unknown, reason: 'idle + ${key.codeUnits}');
      }
      expect(_after([ClaudeHookEvent.permission, '\x1b', ClaudeHookEvent.stop]).state, ClaudeState.idle);
    });
    test('a digit in a dialog answers it: not a draft, the state unknown', () {
      final t = _after([ClaudeHookEvent.permission, '1']);
      expect((t.state, t.draft), (ClaudeState.unknown, false));
    });
    test('the owner\'s paste is a draft; Backspace keeps what is known', () {
      expect(_after([ClaudeHookEvent.stop, '\x1b[200~text\x1b[201~']).draft, isTrue);
      final t = _after([ClaudeHookEvent.stop, 'a', '\x7f']);
      expect((t.state, t.draft), (ClaudeState.idle, true), reason: 'only the screen can tell it is empty again');
    });
    test('the terminal\'s own answers and focus reports are not the owner', () {
      for (final auto in ['\x1b[I', '\x1b[O', '\x1b[?62;22c', '\x1b[>0;276;0c', '\x1b[24;80R', '\x1b]11;rgb:0000/0000/0000\x07']) {
        expect(classifyInput(auto), OwnerInput.automatic, reason: auto.codeUnits.toString());
        final t = _after([ClaudeHookEvent.stop, auto]);
        expect((t.state, t.draft), (ClaudeState.idle, false));
      }
    });
    test('a session that ended stays ended', () {
      expect(_after([ClaudeHookEvent.end, '\x1b', '\r']).state, ClaudeState.ended);
    });
  });

  group('the route of an automatic line', () {
    final idle = screenOf(claude289IdleAuto);
    final unknownLayout = screenOf(const ClaudeScreen(['> ', ''], cursor: (0, 2)));
    test('idle by the hooks: typed, whatever the layout (no screen parsing needed)', () {
      expect(lineRoute(_after([ClaudeHookEvent.stop]), idle), LineRoute.type);
      expect(lineRoute(_after([ClaudeHookEvent.stop]), unknownLayout), LineRoute.type);
    });
    test('working: left for the Stop hook; a dialog or the end: wait', () {
      expect(lineRoute(_after([ClaudeHookEvent.prompt]), idle), LineRoute.continueTurn);
      expect(lineRoute(_after([ClaudeHookEvent.permission]), idle), LineRoute.wait,
          reason: 'the hooks say a dialog is open, whatever the screen shows');
      expect(lineRoute(_after([ClaudeHookEvent.end]), idle), LineRoute.wait);
    });
    test('idle with a draft: wait, unless the screen shows the prompt empty again', () {
      expect(lineRoute(_after([ClaudeHookEvent.stop, 'x']), screenOf(claude289DraftTry)), LineRoute.wait);
      expect(lineRoute(_after([ClaudeHookEvent.stop, 'x', '\x7f']), idle), LineRoute.type);
    });
    test('idle by the hooks but a dialog on screen (a forged event): wait', () {
      expect(lineRoute(_after([ClaudeHookEvent.stop]), screenOf(claude289Permission)), LineRoute.wait);
      expect(lineRoute(_after([ClaudeHookEvent.stop]), screenOf(claudePermission)), LineRoute.wait);
    });
    test('2.1.306 "Read outside the working directories": the recorded hooks say dialog; no line is typed into it', () {
      // The canary's hook events of 2026-10-22, in order: a quick reply started a turn, three file tools ran, the
      // fourth (a Glob above the project folder) opened the new dialog.
      final t = _after([
        ClaudeHookEvent.start,
        ClaudeHookEvent.prompt,
        for (var i = 0; i < 3; i++) ...[ClaudeHookEvent.tool, ClaudeHookEvent.toolDone],
        ClaudeHookEvent.tool,
        ClaudeHookEvent.permission,
      ]);
      final dialog = screenOf(claude306ReadOutside);
      expect(t.state, ClaudeState.dialog);
      expect(lineRoute(t, dialog), LineRoute.wait, reason: 'Enter would allow reads outside the project for good');
      expect(lineRoute(t, idle), LineRoute.wait, reason: 'the hooks first: a dialog, whatever the screen shows');
      expect(lineRoute(_after([ClaudeHookEvent.stop]), dialog), LineRoute.wait, reason: 'a forged idle event');
      expect(lineRoute(ClaudeTracker(), dialog), LineRoute.wait, reason: 'no hooks: the screen fallback');
      expect(lineRoute(_after([ClaudeHookEvent.permission, '\x1b']), dialog), LineRoute.wait,
          reason: 'Esc made the state unknown, and the dialog is still on the screen');
    });
    test('unknown: the screen fallback decides', () {
      expect(lineRoute(ClaudeTracker(), idle), LineRoute.type);
      expect(lineRoute(ClaudeTracker(), unknownLayout), LineRoute.wait, reason: 'not recognised: nothing typed');
      expect(lineRoute(_after([ClaudeHookEvent.prompt, '\x1b']), screenOf(claude289AfterTurn)), LineRoute.type,
          reason: 'Esc interrupted the turn (no hook): the screen shows the empty prompt');
    });
  });
}
