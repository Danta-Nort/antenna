// SPDX-License-Identifier: AGPL-3.0-only
// Design token guard (docs/DESIGN.md, "Visual polish to reference v3"):
// (a) the text styles are on the type scale of the reference v3 (28/36, 20/28, 16/24, 14/20, 12/16, 11/14);
// (b) spacing literals in lib/ui (SizedBox spacers, EdgeInsets, Wrap spacing) are on the 8 px grid with its 4 px half
//     step; values up to 2 px are optical nudges (an icon aligned with a text baseline) and stay;
// (c) font size literals in lib/ui use only the sizes of the scale.

import 'dart:io';

import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// Files outside the scale, each with the reason. The test asks to remove an entry that is no longer needed.
const _exempt = <String, String>{
  // The terminal's cell grid follows its font size (Plex Mono 12.5 px), which Claude Code and Codex lay out against.
  'lib/ui/code/terminal_theme.dart': 'terminal cell metrics',
  // The trust picker is being redrawn for the ∞ level in its own change; it joins the scale with it.
  'lib/ui/widgets/trust_picker.dart': 'redrawn separately',
};

final _num = RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])');

/// Off-grid spacing and off-scale font sizes in [src], as `line: what`.
List<String> designViolations(String src) {
  final out = <String>[];
  final lines = src.split('\n');
  bool onGrid(double v) => v <= 2 || v % 4 == 0;
  void check(int line, String what, Iterable<double> values) {
    for (final v in values) {
      if (!onGrid(v)) out.add('${line + 1}: $what $v');
    }
  }

  Iterable<double> nums(String s) => _num.allMatches(s).map((m) => double.parse(m.group(1)!));
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.trimLeft().startsWith('//')) continue;
    for (final m in RegExp(r'EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(([^()]*)\)').allMatches(l)) {
      check(i, 'EdgeInsets', nums(m.group(1)!));
    }
    for (final m in RegExp(r'SizedBox\((?:width|height): ([^,()]+)\)').allMatches(l)) {
      check(i, 'SizedBox', nums(m.group(1)!));
    }
    for (final m in RegExp(r'\b(?:spacing|runSpacing): (\d+(?:\.\d+)?)\b').allMatches(l)) {
      check(i, 'spacing', [double.parse(m.group(1)!)]);
    }
    for (final m in RegExp(r'fontSize: (\d+(?:\.\d+)?)(?![\w.])').allMatches(l)) {
      final v = double.parse(m.group(1)!);
      if (!XType.sizes.contains(v)) out.add('${i + 1}: fontSize $v');
    }
  }
  return out;
}

void main() {
  test('the text styles follow the type scale of the reference v3', () {
    void scale(String name, double size, double lineHeight, double got, double? height) {
      expect(got, size, reason: '$name size');
      expect((got * (height ?? 0)).round(), lineHeight, reason: '$name line height');
    }

    scale('h1', 28, 36, XText.h1.fontSize!, XText.h1.height);
    scale('h2', 20, 28, XText.h2.fontSize!, XText.h2.height);
    scale('h3 (title)', 16, 24, XText.title.fontSize!, XText.title.height);
    scale('body', 14, 20, XText.body.fontSize!, XText.body.height);
    scale('caption (bodyDim)', 12, 16, XText.bodyDim.fontSize!, XText.bodyDim.height);
    scale('caption (label)', 12, 16, XText.label.fontSize!, XText.label.height);
    scale('small (meta)', 11, 14, XText.meta.fontSize!, XText.meta.height);
    for (final s in [XText.mono, XText.monoSmall, XText.monoStrong, XText.overline, XText.wordmark, XText.tagline]) {
      expect(XType.sizes, contains(s.fontSize), reason: '$s');
    }
    for (final v in [XSpace.xs, XSpace.s, XSpace.m, XSpace.l, XSpace.xl, XSpace.xxl, XSpace.xxxl]) {
      expect(v % 4, 0, reason: 'XSpace $v');
    }
    for (final v in [XRadius.s, XRadius.m, XRadius.l, XRadius.xl, XRadius.xxl, XRadius.bubble]) {
      expect([4, 8, 12, 16, 24], contains(v), reason: 'XRadius $v');
    }
  });

  test('the scanner finds off-grid spacing and off-scale font sizes, and lets nudges and the scale pass', () {
    // A negative control: values the guard must catch, next to values it must let through.
    const bad = '''
      padding: const EdgeInsets.fromLTRB(15, 10, 12, 8),
      const SizedBox(width: 6),
      Wrap(spacing: 10, runSpacing: 8, children: []),
      style: XText.body.copyWith(fontSize: 13.5),
    ''';
    expect(designViolations(bad), ['1: EdgeInsets 15.0', '1: EdgeInsets 10.0', '2: SizedBox 6.0', '3: spacing 10.0',
        '4: fontSize 13.5']);
    const good = '''
      padding: const EdgeInsets.only(top: 1.5, left: 16),
      const SizedBox(height: 2),
      SizedBox(width: dense ? 8 : 12),
      Wrap(spacing: 8, runSpacing: 4, children: []),
      // const SizedBox(width: 7), in a comment
      style: XText.meta.copyWith(fontSize: size * 0.36),
      style: XText.body.copyWith(fontSize: 12),
    ''';
    expect(designViolations(good), isEmpty);
  });

  test('lib/ui keeps spacing on the 8 px grid and font sizes on the type scale', () {
    final found = <String>[];
    final seen = <String>{};
    for (final f in Directory('lib/ui').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart')) continue;
      if (_exempt.containsKey(path)) {
        seen.add(path);
        continue;
      }
      for (final v in designViolations(f.readAsStringSync())) {
        found.add('$path:$v');
      }
    }
    expect(found, isEmpty, reason: 'use the XSpace grid and the XType sizes (lib/theme/tokens.dart)');
    expect(seen, _exempt.keys.toSet(), reason: 'remove exemptions for files that no longer exist');
  });
}
