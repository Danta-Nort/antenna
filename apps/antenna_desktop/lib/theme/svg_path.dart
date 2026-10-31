// SPDX-License-Identifier: AGPL-3.0-only
// SVG path data (`d`) → a Flutter [Path], for the AI apps' marks (lib/theme/ai_logos.dart). The marks are single-path
// 24×24 icons, so a path parser is all that is needed: no SVG package, no native code, the same pixels on every
// platform and in golden tests. Covers the whole path grammar of SVG 1.1 (M L H V C S Q T A Z, absolute and
// relative, implicit repeats, compact numbers such as `-.5.5` and arc flags without separators).

import 'dart:ui';

/// The path [d] parses into, or throws [FormatException].
Path parseSvgPath(String d) => _SvgPathParser(d).parse();

final class _SvgPathParser {
  _SvgPathParser(this.s);
  final String s;
  int i = 0;

  bool get _end => i >= s.length;

  void _skip() {
    while (!_end) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x2c) {
        i++;
      } else {
        break;
      }
    }
  }

  bool get _numberNext {
    _skip();
    if (_end) return false;
    final c = s[i];
    return c == '-' || c == '+' || c == '.' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39);
  }

  double _num() {
    _skip();
    final start = i;
    if (!_end && (s[i] == '-' || s[i] == '+')) i++;
    var digits = false;
    while (!_end && _isDigit(s.codeUnitAt(i))) {
      i++;
      digits = true;
    }
    if (!_end && s[i] == '.') {
      i++;
      while (!_end && _isDigit(s.codeUnitAt(i))) {
        i++;
        digits = true;
      }
    }
    if (digits && !_end && (s[i] == 'e' || s[i] == 'E')) {
      final save = i;
      i++;
      if (!_end && (s[i] == '-' || s[i] == '+')) i++;
      if (!_end && _isDigit(s.codeUnitAt(i))) {
        while (!_end && _isDigit(s.codeUnitAt(i))) {
          i++;
        }
      } else {
        i = save;
      }
    }
    if (!digits) throw FormatException('expected a number', s, start);
    return double.parse(s.substring(start, i));
  }

  /// An arc flag: a single `0` or `1`, which may run into the next number (`a1 1 0 011 1`).
  bool _flag() {
    _skip();
    if (_end || (s[i] != '0' && s[i] != '1')) throw FormatException('expected an arc flag', s, i);
    return s[i++] == '1';
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static const _commands = 'MmLlHhVvCcSsQqTtAaZz';

  Path parse() {
    final p = Path();
    var cx = 0.0, cy = 0.0; // current point
    var sx = 0.0, sy = 0.0; // subpath start
    double? lcx, lcy; // last cubic control point (for S)
    double? lqx, lqy; // last quadratic control point (for T)
    String? cmd;
    _skip();
    while (!_end) {
      final c = s[i];
      if (_commands.contains(c)) {
        cmd = c;
        i++;
      } else if (cmd == null) {
        throw FormatException('path data must start with a command', s, i);
      } else if (cmd == 'M') {
        cmd = 'L'; // implicit lineto after moveto
      } else if (cmd == 'm') {
        cmd = 'l';
      } else if (cmd == 'Z' || cmd == 'z') {
        throw FormatException('a number after closepath', s, i);
      }
      final rel = cmd == cmd.toLowerCase();
      final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
      var keepCubic = false, keepQuad = false;
      switch (cmd.toUpperCase()) {
        case 'M':
          cx = ox + _num();
          cy = oy + _num();
          sx = cx;
          sy = cy;
          p.moveTo(cx, cy);
        case 'L':
          cx = ox + _num();
          cy = oy + _num();
          p.lineTo(cx, cy);
        case 'H':
          cx = ox + _num();
          p.lineTo(cx, cy);
        case 'V':
          cy = oy + _num();
          p.lineTo(cx, cy);
        case 'C':
          final x1 = ox + _num(), y1 = oy + _num(), x2 = ox + _num(), y2 = oy + _num();
          cx = ox + _num();
          cy = oy + _num();
          p.cubicTo(x1, y1, x2, y2, cx, cy);
          (lcx, lcy, keepCubic) = (x2, y2, true);
        case 'S':
          final x1 = lcx == null ? cx : 2 * cx - lcx, y1 = lcy == null ? cy : 2 * cy - lcy;
          final x2 = ox + _num(), y2 = oy + _num();
          cx = ox + _num();
          cy = oy + _num();
          p.cubicTo(x1, y1, x2, y2, cx, cy);
          (lcx, lcy, keepCubic) = (x2, y2, true);
        case 'Q':
          final x1 = ox + _num(), y1 = oy + _num();
          cx = ox + _num();
          cy = oy + _num();
          p.quadraticBezierTo(x1, y1, cx, cy);
          (lqx, lqy, keepQuad) = (x1, y1, true);
        case 'T':
          final x1 = lqx == null ? cx : 2 * cx - lqx, y1 = lqy == null ? cy : 2 * cy - lqy;
          cx = ox + _num();
          cy = oy + _num();
          p.quadraticBezierTo(x1, y1, cx, cy);
          (lqx, lqy, keepQuad) = (x1, y1, true);
        case 'A':
          final rx = _num().abs(), ry = _num().abs(), rot = _num();
          final large = _flag(), sweep = _flag();
          cx = ox + _num();
          cy = oy + _num();
          if (rx == 0 || ry == 0) {
            p.lineTo(cx, cy);
          } else {
            p.arcToPoint(Offset(cx, cy),
                radius: Radius.elliptical(rx, ry), rotation: rot, largeArc: large, clockwise: sweep);
          }
        case 'Z':
          p.close();
          cx = sx;
          cy = sy;
      }
      if (!keepCubic) lcx = lcy = null;
      if (!keepQuad) lqx = lqy = null;
      _skip();
      // A command letter is needed before the next segment only after closepath.
      if (!_end && (cmd == 'Z' || cmd == 'z') && _numberNext) throw FormatException('a number after closepath', s, i);
    }
    return p;
  }
}
