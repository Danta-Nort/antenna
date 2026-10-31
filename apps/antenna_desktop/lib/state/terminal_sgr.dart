// SPDX-License-Identifier: AGPL-3.0-only
// What an agent's program writes, adjusted for the terminal emulator. xterm 4.0.0 (pinned, STACK "Code mode") reads
// some "Select Graphic Rendition" sequences (SGR, `CSI … m`) wrong, and the wrong attribute then sticks to everything
// after it: modern CLIs switch an attribute off with its own code (`CSI 22 m`, `CSI 39 m`), not with `CSI 0 m`.
// - `CSI > 4 ; 2 m` / `CSI > 4 m` set and reset xterm's modifyOtherKeys (XTMODKEYS), `CSI ? 4 m` asks for it
//   (XTQMODKEYS). xterm 4.0.0 ignores the `>` / `?` and reads SGR 4, underline (and 2, dim). Claude Code 2.1.233 writes
//   `CSI > 4 m` on exit, when it leaves the alternate screen and when it leaves raw input mode, and `CSI > 4 ; 2 m` at
//   start when its environment names iTerm2, kitty, WezTerm, Ghostty, tmux, Windows Terminal or Warp: every following
//   line came out underlined (TROUBLESHOOTING "Code mode terminal: underlined lines").
// - `CSI 22 m` (normal intensity) ends dim but not bold: after the first bold word everything was bold.
// - Colon sub-parameters (ITU T.416) lose the colon: `CSI 4:3 m` (curly underline) and `CSI 4:0 m` (no underline)
//   become 43 and 40, background colors; `CSI 38:2::R:G:B m` becomes one unknown number.
// - `CSI 58 ; 5 ; N m` (underline color) is unknown, so its arguments run as codes of their own (5 blink, 1 bold,
//   4 underline…), and `CSI 59 m` does not undo them. `CSI 38 ; 5 m` without the index throws in the parser.
// Only such sequences are rewritten, into codes xterm 4.0.0 reads as meant (every underline style is its one
// underline, the underline color is dropped); every other character passes unchanged. The rewrite relies on 4.0.0's
// own readings (`21` ends bold there): a terminal package that parses SGR itself (xterm2 ≥ 5.0.0 does) replaces it.

/// The SGR filter for one program's output stream. A sequence cut between two reads waits for the rest.
final class SgrFilter {
  /// An escape sequence still without its final character after this many characters is not held any longer: it goes
  /// to the terminal as it is.
  static const maxSequence = 256;

  String _held = '';

  /// The next piece of output, ready for the terminal (empty while a sequence waits for its end).
  String add(String chunk) {
    final s = _held.isEmpty ? chunk : '$_held$chunk';
    _held = '';
    var esc = s.indexOf('\x1b');
    if (esc < 0) return s;
    final out = StringBuffer();
    var done = 0;
    while (esc >= 0) {
      if (esc + 1 == s.length) return _hold(out, s, done, esc);
      if (s.codeUnitAt(esc + 1) != 0x5b) {
        esc = s.indexOf('\x1b', esc + 1);
        continue;
      }
      // A CSI sequence ends at its first final character (0x40…0x7E); xterm 4.0.0 skips everything else up to it.
      var end = esc + 2;
      while (end < s.length && !_isFinal(s.codeUnitAt(end))) {
        end++;
      }
      if (end == s.length) {
        if (end - esc <= maxSequence) return _hold(out, s, done, esc);
        break;
      }
      if (s.codeUnitAt(end) == 0x6d) {
        final fixed = _sgr(s.substring(esc + 2, end));
        if (fixed != null) {
          out
            ..write(s.substring(done, esc))
            ..write(fixed);
          done = end + 1;
        }
      }
      esc = s.indexOf('\x1b', end + 1);
    }
    out.write(s.substring(done));
    return out.toString();
  }

  String _hold(StringBuffer out, String s, int done, int from) {
    _held = s.substring(from);
    out.write(s.substring(done, from));
    return out.toString();
  }
}

bool _isFinal(int c) => c >= 0x40 && c <= 0x7e;

/// A parameter's value: empty is the default 0; `null` if it is not a number.
int? _num(String p) => p.isEmpty ? 0 : int.tryParse(p);

/// What replaces `CSI <p> m` ('' drops it), or `null` when xterm 4.0.0 reads it as meant.
String? _sgr(String p) {
  if (p.isEmpty) return null;
  final first = p.codeUnitAt(0);
  // `<` `=` `>` `?`: a private sequence (XTMODKEYS, XTQMODKEYS), not SGR. This terminal has no such modes.
  if (first >= 0x3c && first <= 0x3f) return '';
  for (var i = 0; i < p.length; i++) {
    final c = p.codeUnitAt(i);
    if (c < 0x30 || c > 0x3b) return null; // not only digits, `:` and `;`: left to the terminal as it is
  }
  // xterm 4.0.0 takes a leading `;` for a private marker and loses the default 0 before it.
  var changed = first == 0x3b || p.contains(':');
  final groups = p.split(';');
  final codes = <int>[];
  for (var i = 0; i < groups.length; i++) {
    final parts = groups[i].split(':');
    final code = _num(parts[0]);
    if (code == null) {
      changed = true;
      continue;
    }
    if (parts.length > 1) {
      // Sub-parameters: the underline style (`4:0` none, `4:1`…`4:5` single, double, curly, dotted, dashed) and colors.
      // The underline color (`58:…`) and anything else with sub-parameters has nothing to map to.
      switch (code) {
        case 4:
          codes.add((_num(parts[1]) ?? 0) == 0 ? 24 : 4);
        case 38 || 48:
          if (_colonColor(parts) case final c?) codes.addAll([code, ...c]);
      }
      continue;
    }
    switch (code) {
      case 22:
        // In xterm 4.0.0, 21 ends bold and 22 ends only dim.
        codes.addAll(const [21, 22]);
        changed = true;
      case 59:
        changed = true;
      case 38 || 48 || 58:
        // The color follows as parameters of its own: `5 ; N` or `2 ; R ; G ; B`.
        final mode = i + 1 < groups.length ? _num(groups[i + 1]) : null;
        final n = switch (mode) {
          5 => 1,
          2 => 3,
          _ => 0,
        };
        final args = [for (var k = i + 2; k < i + 2 + n && k < groups.length; k++) _num(groups[k])];
        i += 1 + n;
        if (code != 58 && n > 0 && args.length == n && args.every((a) => a != null && a <= 255)) {
          codes.addAll([code, mode!, ...args.cast<int>()]);
        } else {
          changed = true;
        }
      default:
        codes.add(code);
    }
  }
  if (!changed) return null;
  return codes.isEmpty ? '' : '\x1b[${codes.join(';')}m';
}

/// `38:5:N`, `38:2::R:G:B` (T.416, with an empty color space) and `38:2:R:G:B` (the short form many programs write) as
/// the arguments xterm 4.0.0 reads after `38`; `null` for anything else.
List<int>? _colonColor(List<String> parts) {
  final v = [for (final p in parts.skip(1)) _num(p)];
  final args = switch (v) {
    [5, final n] => [5, n],
    [2, _, final r, final g, final b] => [2, r, g, b],
    [2, final r, final g, final b] => [2, r, g, b],
    _ => const <int?>[],
  };
  if (args.isEmpty || args.any((a) => a == null || a > 255)) return null;
  return args.cast<int>();
}
