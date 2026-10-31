// SPDX-License-Identifier: AGPL-3.0-only
// Text of the agent terminal, for copying. xterm 4.0.0's own `Buffer.getText` skips every cell nothing was printed
// into, but full-screen CLIs (Claude Code, Codex) lay out words by moving the cursor, so the gaps between words are
// exactly such cells and copied text came out as "Accessingworkspace:". Here an untouched cell is the blank it is on
// screen, except the right half of a double-width character (TROUBLESHOOTING "Code mode").

import 'dart:math' as math;

import 'package:xterm/core.dart';

/// The text of [range] (the whole visible screen and scrollback if `null`), lines joined like on screen: a wrapped
/// line continues the previous one, trailing blanks of a row are dropped unless the next row continues it.
String terminalText(Buffer buffer, [BufferRange? range]) {
  final r = (range ?? BufferRangeLine(CellOffset(0, 0), CellOffset(buffer.viewWidth - 1, buffer.height - 1))).normalized;
  final out = StringBuffer();
  for (final seg in r.toSegments()) {
    if (seg.line < 0 || seg.line >= buffer.height) continue;
    final line = buffer.lines[seg.line];
    if (!(seg.line == r.begin.y || seg.line == 0 || line.isWrapped)) out.write('\n');
    final from = math.max(seg.start ?? 0, 0);
    final to = math.min(seg.end ?? line.length, line.length);
    final row = StringBuffer();
    for (var x = from; x < to; x++) {
      final cp = line.getCodePoint(x);
      if (cp != 0) {
        row.writeCharCode(cp);
      } else if (x == 0 || line.getWidth(x - 1) != 2) {
        row.write(' ');
      }
    }
    final continues = seg.line + 1 < buffer.height && buffer.lines[seg.line + 1].isWrapped;
    out.write(continues ? row.toString() : row.toString().trimRight());
  }
  return out.toString();
}
