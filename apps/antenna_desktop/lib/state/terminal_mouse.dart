// SPDX-License-Identifier: AGPL-3.0-only
// The mouse wheel in an agent's terminal. Claude Code (2.1.291, recorded in a pseudo-terminal) runs in the alternate
// screen (`CSI ? 1049 h`) and asks for mouse reports (`CSI ? 1000 h`, `1002`, `1003`, SGR `1006`): the alternate screen
// has no scrollback in the terminal, so the program scrolls its own transcript when the terminal reports the wheel.
// xterm 4.0.0 (pinned, STACK "Code mode") reports the wheel with the wrong button codes: 68 and 69 (`64 + 4`, `64 + 5`)
// where the protocol has 64 and 65 (button 4 and 5 are the second group's 0 and 1; adding 4 is the Shift bit), so the
// program read "Shift + wheel" and did not scroll (TROUBLESHOOTING "Scrolling back in the dock's terminal").
// [WheelMouseHandler] reports the wheel with the right codes in every report mode and leaves every other event to the
// package's own handlers. Remove it when the terminal package reports the wheel right.

import 'package:xterm/core.dart';

/// The protocol's code of a wheel [button]: 64 up, 65 down, 66 left, 67 right.
int wheelCode(TerminalMouseButton button) => switch (button) {
      TerminalMouseButton.wheelUp => 64,
      TerminalMouseButton.wheelDown => 65,
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => throw ArgumentError.value(button, 'button', 'not a wheel'),
    };

/// Reports the mouse wheel to a program that asked for it, with the protocol's codes.
class WheelMouseHandler implements TerminalMouseHandler {
  const WheelMouseHandler();

  @override
  String? call(TerminalMouseEvent event) {
    // A wheel has no release; a program that did not ask for the wheel gets arrow keys in the alternate screen
    // (TerminalView's simulateScroll), as in other terminals.
    if (!event.button.isWheel || !event.state.mouseMode.reportScroll) return null;
    if (event.buttonState == TerminalMouseButtonState.up) return null;
    final code = wheelCode(event.button);
    final x = event.position.x + 1, y = event.position.y + 1;
    return switch (event.state.mouseReportMode) {
      MouseReportMode.sgr => '\x1b[<$code;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${32 + code};$x;${y}M',
      // One character per value, 32 + value; past what one character holds the position is 0 (not reported).
      MouseReportMode.normal || MouseReportMode.utf => '\x1b[M${String.fromCharCode(32 + code)}'
          '${_pos(x, event.state.mouseReportMode)}${_pos(y, event.state.mouseReportMode)}',
    };
  }

  static String _pos(int v, MouseReportMode mode) =>
      (mode == MouseReportMode.normal && v > 223) || v > 2015 ? '\x00' : String.fromCharCode(32 + v);
}

/// The mouse handler of an agent's terminal: the wheel as the protocol has it, everything else as the package does.
const agentMouseHandler = CascadeMouseHandler([WheelMouseHandler(), ClickMouseHandler(), UpDownMouseHandler()]);
