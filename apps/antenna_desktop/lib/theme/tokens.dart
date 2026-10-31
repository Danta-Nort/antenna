// SPDX-License-Identifier: AGPL-3.0-only
// Design tokens. Two palettes: light (the default, "light minimalism" reference v2,
// docs/design/reference-light-v2.webp) and dark (from the system or the switch in Settings).
// The only bright color is the logo blue #1560F6 (docs/DESIGN.md, "Brand"). Text contrast against its background is
// WCAG ≥ 4.5:1 in both themes, checked by test/widget/contrast_test.dart.
//
// Colors are read through XColors.*, getters of the current palette: XApp switches the theme (XColors.palette = …) and
// rebuilds the tree. That is why XColors.* and XText.* are not const.

import 'package:flutter/widgets.dart';

/// The palette of one theme. Names describe the role, not the hue.
class XPalette {
  const XPalette({
    required this.brightness,
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bgHover,
    required this.nav,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentFill,
    required this.accentFillHover,
    required this.onAccent,
    required this.accentSoft,
    required this.accentLine,
    required this.outFill,
    required this.outText,
    required this.outMeta,
    required this.text,
    required this.textDim,
    required this.textMute,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.agent,
    required this.onStatus,
    required this.trust,
    required this.avatars,
    required this.scrim,
    required this.shadow,
  });

  final Brightness brightness;

  // Surfaces: window background → panels → fields and incoming bubbles → raised.
  final Color bg0;
  final Color bg1;
  final Color bg2;
  final Color bg3;
  final Color bgHover;

  /// Left navigation.
  final Color nav;

  // Thin borders and dividers.
  final Color line;
  final Color lineStrong;

  /// Accent for text, links and icons on surfaces (≥ 4.5:1 against bg0…bgHover and accentSoft).
  final Color accent;

  /// Fill of primary buttons and counters: the logo blue in both themes; [onAccent] goes on top.
  final Color accentFill;
  final Color accentFillHover;
  final Color onAccent;

  /// Soft fill for the selected item (menu entry, link in the list) and for badges.
  final Color accentSoft;

  /// Outline of the selected item and focus.
  final Color accentLine;

  // Outgoing bubble: fill, text, time and status.
  final Color outFill;
  final Color outText;
  final Color outMeta;

  // Text.
  final Color text;
  final Color textDim;
  final Color textMute;

  // States (as text and icons: ≥ 4.5:1 against surfaces).
  final Color ok;
  final Color warn;
  final Color danger;
  final Color agent;

  /// Text on a state-colored fill (warn/danger/ok).
  final Color onStatus;

  /// Trust levels 1–5 (SPEC §9): from muted to the most prominent.
  final List<Color> trust;

  /// Backgrounds of initials avatars (text on them is [text], contrast ≥ 4.5:1).
  final List<Color> avatars;

  /// Scrim under dialogs and the color of soft shadows.
  final Color scrim;
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  /// Button states of the reference v3 (`lib/ui/widgets/x_buttons.dart`): the primary pressed a step darker than
  /// hover; the destructive button's hover and pressed fills (its red text stays ≥ 4.5:1 on both, contrast test).
  Color get accentFillPressed => Color.alphaBlend(const Color(0x29000000), accentFill);
  Color get dangerHover => Color.alphaBlend(danger.withValues(alpha: 0.08), bg1);
  Color get dangerPressed => Color.alphaBlend(danger.withValues(alpha: 0.14), bg1);

  /// The bubble of my agent's message (D-UI-18): the agent tint, so that it never looks like the owner's own blue
  /// bubble; [text] and [textMute] stay ≥ 4.5:1 on it (contrast test).
  Color get agentFill => Color.alphaBlend(agent.withValues(alpha: isDark ? 0.14 : 0.09), bg1);

  static const brand = Color(0xFF1560F6);

  static const light = XPalette(
    brightness: Brightness.light,
    bg0: Color(0xFFF5F7FB),
    bg1: Color(0xFFFFFFFF),
    bg2: Color(0xFFF1F4F9),
    bg3: Color(0xFFE8EDF5),
    bgHover: Color(0xFFF0F4FB),
    nav: Color(0xFFF5F7FB),
    line: Color(0xFFE5EAF1),
    lineStrong: Color(0xFFD2DBE7),
    accent: Color(0xFF1458E4),
    accentFill: brand,
    accentFillHover: Color(0xFF0F55E0),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE9F0FE),
    accentLine: Color(0xFFADC6FA),
    outFill: brand,
    outText: Color(0xFFFFFFFF),
    outMeta: Color(0xFFF0F5FF),
    text: Color(0xFF0B1B3A),
    textDim: Color(0xFF475570),
    textMute: Color(0xFF5B6880),
    ok: Color(0xFF0B7A55),
    warn: Color(0xFF975800),
    danger: Color(0xFFC42338),
    agent: Color(0xFF6447D4),
    onStatus: Color(0xFFFFFFFF),
    trust: [
      Color(0xFF5B6880), // 1 Observer: gray-blue
      Color(0xFF3B64A0), // 2 Acquaintance: steel
      Color(0xFF1458E4), // 3 Colleague: brand blue
      Color(0xFF087570), // 4 Partner: teal
      Color(0xFF0B2F8A), // 5 Self: deep blue, filled badge
    ],
    avatars: [Color(0xFFE3ECFD), Color(0xFFDDF1EC), Color(0xFFECE6FB), Color(0xFFFBEBDD), Color(0xFFE5ECF4)],
    scrim: Color(0x660B1B3A),
    shadow: Color(0xFF0B1B3A),
  );

  static const dark = XPalette(
    brightness: Brightness.dark,
    bg0: Color(0xFF050A14),
    bg1: Color(0xFF08111F),
    bg2: Color(0xFF0C172A),
    bg3: Color(0xFF112038),
    bgHover: Color(0xFF14284A),
    nav: Color(0xFF060D19),
    line: Color(0xFF182842),
    lineStrong: Color(0xFF24406A),
    accent: Color(0xFF7AA7FF),
    accentFill: brand,
    accentFillHover: Color(0xFF0F55E0),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF12274A),
    accentLine: Color(0xFF2D5294),
    outFill: brand,
    outText: Color(0xFFFFFFFF),
    outMeta: Color(0xFFF0F5FF),
    text: Color(0xFFE3ECF8),
    textDim: Color(0xFF9EB0CA),
    textMute: Color(0xFF8396B6),
    ok: Color(0xFF5CD6A9),
    warn: Color(0xFFE7B867),
    danger: Color(0xFFFF7A87),
    agent: Color(0xFFA79BFF),
    onStatus: Color(0xFF041426),
    trust: [
      Color(0xFF8395B3), // 1 Observer
      Color(0xFF7FA9DB), // 2 Acquaintance
      Color(0xFF6CC6FF), // 3 Colleague
      Color(0xFF4FDDD6), // 4 Partner
      Color(0xFFE6F6FF), // 5 Self
    ],
    avatars: [Color(0xFF1B3D66), Color(0xFF173A57), Color(0xFF22355E), Color(0xFF14425A), Color(0xFF263A63)],
    scrim: Color(0xCC02060E),
    shadow: Color(0xFF000000),
  );
}

/// Colors of the current theme (getters). Names describe the role.
abstract final class XColors {
  /// The current palette; only XApp (and tests) change it.
  static XPalette palette = XPalette.light;

  static const brand = XPalette.brand;

  /// The mark's white on blue (icon, agent avatar).
  static const markOnBrand = Color(0xFFFFFFFF);

  /// QR code: dark modules on a light field in any theme, so that any camera can read it.
  static const qrPaper = Color(0xFFFFFFFF);
  static const qrInk = Color(0xFF0B1B3A);

  /// Tooltips and snack bars are dark in the light theme (as on macOS).
  static const inverseSurface = Color(0xFF0B1B3A);
  static const inverseText = Color(0xFFFFFFFF);

  static bool get isDark => palette.isDark;
  static Color get bg0 => palette.bg0;
  static Color get bg1 => palette.bg1;
  static Color get bg2 => palette.bg2;
  static Color get bg3 => palette.bg3;
  static Color get bgHover => palette.bgHover;
  static Color get nav => palette.nav;
  static Color get line => palette.line;
  static Color get lineStrong => palette.lineStrong;
  static Color get accent => palette.accent;
  static Color get accentFill => palette.accentFill;
  static Color get accentFillHover => palette.accentFillHover;
  static Color get accentFillPressed => palette.accentFillPressed;
  static Color get dangerHover => palette.dangerHover;
  static Color get dangerPressed => palette.dangerPressed;
  static Color get onAccent => palette.onAccent;
  static Color get accentSoft => palette.accentSoft;
  static Color get accentLine => palette.accentLine;
  static Color get outFill => palette.outFill;
  static Color get outText => palette.outText;
  static Color get outMeta => palette.outMeta;
  static Color get text => palette.text;
  static Color get textDim => palette.textDim;
  static Color get textMute => palette.textMute;
  static Color get ok => palette.ok;
  static Color get warn => palette.warn;
  static Color get danger => palette.danger;
  static Color get agent => palette.agent;
  static Color get agentFill => palette.agentFill;
  static Color get onStatus => palette.onStatus;
  static Color get scrim => palette.scrim;
  static Color get shadow => palette.shadow;
  static List<Color> get trust => palette.trust;
  static List<Color> get avatars => palette.avatars;

  static Color trustColor(int level) => palette.trust[(level.clamp(1, 5)) - 1];
}

/// Fonts: IBM Plex Sans for the interface, IBM Plex Mono for codes, keys and facts.
abstract final class XFonts {
  static const sans = 'Plex Sans';
  static const mono = 'Plex Mono';
}

/// Spacing on an 8 px grid with a 4 px half step for tight inline gaps (reference v3: 4, 8, 16, 24, 32, 48). Spacing
/// literals in `lib/ui` stay on this grid too (values up to 2 px are optical nudges); `test/widget/design_tokens_test.dart`
/// checks it.
abstract final class XSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

/// Corner radii of the reference v3 (4, 8, 12, 16, 24): small tags; controls (buttons, fields, rows); cards and panels;
/// dialogs, popovers and bubbles.
abstract final class XRadius {
  static const s = 4.0;
  static const m = 8.0;
  static const l = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;
  static const bubble = 16.0;
}

/// The type scale of the reference v3, size/line height: H1 28/36, H2 20/28, H3 16/24, Body 14/20, Caption 12/16,
/// Small 11/14. Plex Sans ships weights 300–600 in the app, so headings are semibold. Font size literals in `lib/ui`
/// use only these sizes (`test/widget/design_tokens_test.dart`); the exceptions are the verification code, which is
/// read out loud, and the terminal, whose cell grid follows its own font size.
abstract final class XType {
  static const h1 = 28.0;
  static const h2 = 20.0;
  static const h3 = 16.0;
  static const body = 14.0;
  static const caption = 12.0;
  static const small = 11.0;

  /// Every size of the scale.
  static const sizes = [h1, h2, h3, body, caption, small];
}

/// Text styles (color from the current palette), on the [XType] scale.
abstract final class XText {
  static const _tab = [FontFeature.tabularFigures()];

  /// The word ANTENNA next to the mark.
  static TextStyle get wordmark => TextStyle(
        fontFamily: XFonts.sans,
        fontWeight: FontWeight.w600,
        fontSize: XType.h3,
        letterSpacing: 4.2,
        color: XColors.text,
      );
  static TextStyle get tagline => TextStyle(
        fontFamily: XFonts.sans,
        fontWeight: FontWeight.w500,
        fontSize: XType.small,
        letterSpacing: 1.6,
        color: XColors.textMute,
      );

  /// H1, 28/36: page titles (Chats, Agents, Settings) and empty states.
  static TextStyle get h1 => TextStyle(
        fontFamily: XFonts.sans,
        fontWeight: FontWeight.w600,
        fontSize: XType.h1,
        height: 36 / 28,
        letterSpacing: -0.3,
        color: XColors.text,
      );

  /// H2, 20/28: the conversation's title and dialog titles.
  static TextStyle get h2 => TextStyle(
      fontFamily: XFonts.sans, fontWeight: FontWeight.w600, fontSize: XType.h2, height: 28 / 20, color: XColors.text);

  /// H3, 16/24: card and section titles.
  static TextStyle get title => TextStyle(
      fontFamily: XFonts.sans, fontWeight: FontWeight.w600, fontSize: XType.h3, height: 24 / 16, color: XColors.text);

  /// Body, 14/20: messages and main text.
  static TextStyle get body =>
      TextStyle(fontFamily: XFonts.sans, fontSize: XType.body, height: 20 / 14, color: XColors.text);

  /// Caption, 12/16: secondary text and explanations.
  static TextStyle get bodyDim =>
      TextStyle(fontFamily: XFonts.sans, fontSize: XType.caption, height: 16 / 12, color: XColors.textDim);

  /// Caption, 12/16, medium: labels of controls and names over bubbles.
  static TextStyle get label => TextStyle(
        fontFamily: XFonts.sans,
        fontWeight: FontWeight.w500,
        fontSize: XType.caption,
        height: 16 / 12,
        letterSpacing: 0.2,
        color: XColors.textDim,
      );

  /// Section header: small, letter-spaced capitals (like "SPACES" in the reference).
  static TextStyle get overline => TextStyle(
        fontFamily: XFonts.sans,
        fontWeight: FontWeight.w600,
        fontSize: XType.small,
        letterSpacing: 1.1,
        color: XColors.textMute,
      );

  /// Small, 11/14: times, metadata and tags; sans-serif, tabular figures.
  static TextStyle get meta => TextStyle(
        fontFamily: XFonts.sans,
        fontSize: XType.small,
        height: 14 / 11,
        color: XColors.textMute,
        fontFeatures: _tab,
      );
  static TextStyle get mono =>
      TextStyle(fontFamily: XFonts.mono, fontSize: XType.caption, color: XColors.textDim, fontFeatures: _tab);
  static TextStyle get monoSmall =>
      TextStyle(fontFamily: XFonts.mono, fontSize: XType.small, color: XColors.textMute, fontFeatures: _tab);
  static TextStyle get monoStrong => TextStyle(
        fontFamily: XFonts.mono,
        fontWeight: FontWeight.w500,
        fontSize: XType.caption,
        color: XColors.text,
        fontFeatures: _tab,
      );

  /// Verification code (SAS): large monospaced digits, read out loud, so outside the type scale.
  static TextStyle get sas => TextStyle(
        fontFamily: XFonts.mono,
        fontWeight: FontWeight.w600,
        fontSize: 40,
        letterSpacing: 10,
        color: XColors.text,
        fontFeatures: _tab,
      );

  /// The verification code where less room is left (the rekey codes).
  static TextStyle get sasCompact => sas.copyWith(fontSize: 34);
}

/// Animation durations of the reference v3: calm, no springy motion (hover 0.15 s, a popover 0.2 s).
abstract final class XMotion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 200);
}
