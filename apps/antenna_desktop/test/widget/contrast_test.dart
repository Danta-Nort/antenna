// SPDX-License-Identifier: AGPL-3.0-only
// Text contrast against the background is WCAG 2.x ≥ 4.5:1 in both themes (normal text, AA). The pairs are the ones
// the window actually uses: text and accent on every surface, white on the logo blue, outgoing bubble captions, level
// badges.

import 'dart:math' as math;

import 'package:antenna_desktop/theme/tokens.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

double _lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _lum(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);
double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Map<String, (Color, Color)> pairs(XPalette p) {
  final surfaces = {
    'bg0': p.bg0,
    'bg1': p.bg1,
    'bg2': p.bg2,
    'bgHover': p.bgHover,
    'nav': p.nav,
    'accentSoft': p.accentSoft,
  };
  final texts = {
    'text': p.text,
    'textDim': p.textDim,
    'textMute': p.textMute,
    'accent': p.accent,
    'ok': p.ok,
    'warn': p.warn,
    'danger': p.danger,
    'agent': p.agent,
  };
  final out = <String, (Color, Color)>{};
  for (final t in texts.entries) {
    for (final s in surfaces.entries) {
      out['${t.key} on ${s.key}'] = (t.value, s.value);
    }
  }
  out['text on bg3'] = (p.text, p.bg3);
  out['textDim on bg3'] = (p.textDim, p.bg3);
  out['onAccent on accentFill'] = (p.onAccent, p.accentFill);
  out['onAccent on accentFillHover'] = (p.onAccent, p.accentFillHover);
  out['onAccent on accentFillPressed'] = (p.onAccent, p.accentFillPressed);
  out['danger on dangerHover'] = (p.danger, p.dangerHover);
  out['danger on dangerPressed'] = (p.danger, p.dangerPressed);
  out['outText on outFill'] = (p.outText, p.outFill);
  out['outMeta on outFill'] = (p.outMeta, p.outFill);
  // My agent's bubble (D-UI-18): its text, the time and the author line.
  out['text on agentFill'] = (p.text, p.agentFill);
  out['textMute on agentFill'] = (p.textMute, p.agentFill);
  out['accent on agentFill'] = (p.accent, p.agentFill);
  // The Experimental tag (D-94) draws its text on its own fill, whatever surface it sits on.
  out['experimental tag: textDim on bg2'] = (p.textDim, p.bg2);
  // The "Secure" indicator (reference v3): each state's word on its own tint (10 % light, 14 % dark, over bg1).
  for (final (name, c) in [('ok', p.ok), ('textDim', p.textDim), ('textMute', p.textMute), ('danger', p.danger),
    ('warn', p.warn)]) {
    out['secure indicator: $name on its tint'] = (c, Color.alphaBlend(c.withValues(alpha: p.isDark ? 0.14 : 0.10), p.bg1));
  }
  // The popover card (bg2 in the dark theme) and the agent monogram (bg3 in the dark theme, D-UI-24).
  out['popover: text on bg2'] = (p.text, p.bg2);
  out['popover: textMute on bg2'] = (p.textMute, p.bg2);
  out['agent monogram: textDim on bg3'] = (p.textDim, p.bg3);
  out['agent badge: agent on agentFill'] = (p.agent, p.agentFill);
  // Local models (CONTROL §24): the Local badge and the model chips, each color on its own tint (10 % light, 16 %
  // dark, over bg1); the model rows on bg2 (facts, the license link, a failure).
  for (final (name, c) in [('ok', p.ok), ('warn', p.warn), ('textDim', p.textDim), ('textMute', p.textMute)]) {
    out['local chip: $name on its tint'] = (c, Color.alphaBlend(c.withValues(alpha: p.isDark ? 0.16 : 0.10), p.bg1));
  }
  out['local model row: textDim on bg2'] = (p.textDim, p.bg2);
  out['local model row: textMute on bg2'] = (p.textMute, p.bg2);
  out['local model row: accent on bg2'] = (p.accent, p.bg2);
  out['local model row: danger on bg2'] = (p.danger, p.bg2);
  for (final s in {'warn': p.warn, 'danger': p.danger, 'ok': p.ok}.entries) {
    out['onStatus on ${s.key}'] = (p.onStatus, s.value);
    // Soft state chips: the color on its own 8–10 % fill.
    out['${s.key} on its tint'] = (s.value, Color.alphaBlend(s.value.withValues(alpha: 0.10), p.bg1));
  }
  for (var i = 0; i < 5; i++) {
    final c = p.trust[i];
    out['trust ${i + 1} on bg1'] = (c, p.bg1);
    out['trust ${i + 1} on badge'] = (c, Color.alphaBlend(c.withValues(alpha: p.isDark ? 0.13 : 0.09), p.bg1));
    out['trust ${i + 1} on accentSoft'] = (c, p.accentSoft);
    out['text on avatar ${i + 1}'] = (p.text, p.avatars[i]);
  }
  if (!p.isDark) out['onAccent on trust 5 (filled)'] = (p.onAccent, p.trust[4]);
  out['inverseText on inverseSurface'] = (XColors.inverseText, XColors.inverseSurface);
  out['markOnBrand on brand'] = (XColors.markOnBrand, XColors.brand);
  return out;
}

void main() {
  for (final (name, p) in [('light', XPalette.light), ('dark', XPalette.dark)]) {
    test('WCAG ≥ 4.5:1 — $name theme', () {
      final failed = <String>[];
      for (final e in pairs(p).entries) {
        final (fg, bg) = e.value;
        final c = contrast(fg, bg);
        if (c < 4.5) failed.add('${e.key}: ${_hex(fg)} on ${_hex(bg)} = ${c.toStringAsFixed(2)}');
      }
      expect(failed, isEmpty);
    });
  }

  test('brand blue: white text on #1560F6 passes AA (5.2:1)', () {
    expect(contrast(const Color(0xFFFFFFFF), XColors.brand), closeTo(5.20, 0.01));
  });
}
