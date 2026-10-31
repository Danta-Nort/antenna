// SPDX-License-Identifier: AGPL-3.0-only
// The app's ThemeData built from the current palette, plus styling helpers: panels, soft shadows (light theme),
// thin glowing borders (dark theme).

import 'package:flutter/material.dart';

import 'buttons.dart';
import 'tokens.dart';

export 'tokens.dart';

ThemeData buildXTheme([XPalette? palette]) {
  final p = palette ?? XColors.palette;
  final scheme = (p.isDark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
    primary: p.accentFill,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    surface: p.bg1,
    onSurface: p.text,
    onSurfaceVariant: p.textDim,
    surfaceContainerHighest: p.bg3,
    surfaceContainerHigh: p.bg2,
    surfaceContainer: p.bg2,
    surfaceContainerLow: p.bg1,
    surfaceContainerLowest: p.bg1,
    outline: p.lineStrong,
    outlineVariant: p.line,
    error: p.danger,
    onError: p.onStatus,
    shadow: p.shadow,
    scrim: p.scrim,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg0,
    canvasColor: p.bg1,
    fontFamily: XFonts.sans,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
    hoverColor: p.bgHover,
    focusColor: p.accentSoft,
    highlightColor: Colors.transparent,
  );
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(XRadius.m),
        borderSide: BorderSide(color: c, width: w),
      );
  final label = TextStyle(
    fontFamily: XFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    letterSpacing: 0.2,
    color: p.textDim,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text, fontFamily: XFonts.sans),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.isDark ? p.bg3 : XColors.inverseSurface,
        borderRadius: BorderRadius.circular(XRadius.s),
        border: p.isDark ? Border.all(color: p.lineStrong) : null,
      ),
      textStyle: TextStyle(fontFamily: XFonts.sans, fontSize: 12, color: p.isDark ? p.text : XColors.inverseText),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.bg2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(fontFamily: XFonts.sans, fontSize: 14, color: p.textMute),
      labelStyle: label,
      floatingLabelStyle: label.copyWith(color: p.accent),
      helperStyle: TextStyle(fontFamily: XFonts.sans, fontSize: XType.small, color: p.textMute),
      prefixIconColor: p.textMute,
      suffixIconColor: p.textMute,
      border: border(p.line),
      enabledBorder: border(p.line),
      focusedBorder: border(p.accentLine, 1.5),
      errorBorder: border(p.danger.withValues(alpha: 0.7)),
      focusedErrorBorder: border(p.danger, 1.5),
      errorStyle: TextStyle(fontFamily: XFonts.sans, fontSize: 12, color: p.danger),
    ),
    // One button system (reference v3, `buttons.dart`): every Filled, Outlined, Text and Icon button gets its states.
    filledButtonTheme: FilledButtonThemeData(style: XButtons.primary()),
    outlinedButtonTheme: OutlinedButtonThemeData(style: XButtons.secondary()),
    textButtonTheme: TextButtonThemeData(style: XButtons.tertiary()),
    iconButtonTheme: IconButtonThemeData(style: XButtons.icon()),
    iconTheme: IconThemeData(color: p.textDim, size: 18),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accentFill,
      inactiveTrackColor: p.line,
      thumbColor: p.accentFill,
      overlayColor: p.accentFill.withValues(alpha: 0.12),
      trackHeight: 2,
      tickMarkShape: SliderTickMarkShape.noTickMark,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.lineStrong.withValues(alpha: 0.9)),
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(4),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Colors.transparent, elevation: 0),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.isDark ? p.bg3 : XColors.inverseSurface,
      contentTextStyle: TextStyle(fontFamily: XFonts.sans, fontSize: XType.body, color: p.isDark ? p.text : XColors.inverseText),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XRadius.m)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.bg1,
      selectedColor: p.accentSoft,
      side: BorderSide(color: p.lineStrong),
      labelStyle: TextStyle(fontFamily: XFonts.sans, fontSize: XType.caption, color: p.text),
      secondaryLabelStyle: TextStyle(fontFamily: XFonts.sans, fontSize: XType.caption, color: p.accent),
      checkmarkColor: p.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XRadius.m)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentFill : null),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      side: BorderSide(color: p.lineStrong, width: 1.5),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentFill : p.bg3),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.textMute),
      trackOutlineColor: WidgetStatePropertyAll(p.lineStrong),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accentFill.withValues(alpha: 0.22),
    ),
  );
}

/// Soft shadow of the light theme (empty in the dark theme, where depth comes from layers and glow).
List<BoxShadow> xSoftShadow([double strength = 1]) => XColors.isDark
    ? const []
    : [
        BoxShadow(
          color: XColors.shadow.withValues(alpha: 0.07 * strength),
          blurRadius: 24 * strength,
          offset: Offset(0, 6 * strength),
          spreadRadius: -4,
        ),
        BoxShadow(color: XColors.shadow.withValues(alpha: 0.04 * strength), blurRadius: 2, offset: const Offset(0, 1)),
      ];

/// Panel with a thin border; [glow] 0…1 is a soft shadow in the light theme and an accent glow in the dark theme.
BoxDecoration xPanel({
  Color? fill,
  Color? border,
  double radius = XRadius.l,
  double glow = 0,
  Color? glowColor,
  Gradient? gradient,
}) {
  final List<BoxShadow>? shadow;
  if (glow <= 0) {
    shadow = null;
  } else if (!XColors.isDark) {
    shadow = xSoftShadow(glow);
  } else {
    final g = glowColor ?? XColors.accent;
    shadow = [
      BoxShadow(color: g.withValues(alpha: 0.22 * glow), blurRadius: 22, spreadRadius: -4),
      BoxShadow(color: g.withValues(alpha: 0.10 * glow), blurRadius: 3, spreadRadius: 0),
    ];
  }
  return BoxDecoration(
    color: gradient == null ? (fill ?? XColors.bg1) : null,
    gradient: gradient,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border ?? XColors.line, width: 1),
    boxShadow: shadow,
  );
}

/// Selection (selected item, focus): a soft fill of [color] and an outline; with a glow in the dark theme.
BoxDecoration xGlow({double radius = XRadius.m, double strength = 1, Color? color, Color? fill}) {
  final c = color ?? XColors.accent;
  final accentDefault = color == null;
  if (!XColors.isDark) {
    return BoxDecoration(
      color: fill ?? (accentDefault ? XColors.accentSoft : Color.alphaBlend(c.withValues(alpha: 0.08), XColors.bg1)),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
          color: accentDefault ? XColors.accentLine.withValues(alpha: 0.6 * strength) : c.withValues(alpha: 0.45 * strength)),
    );
  }
  return BoxDecoration(
    color: fill ?? Color.alphaBlend(c.withValues(alpha: 0.06), XColors.bg2),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: c.withValues(alpha: 0.55 * strength + 0.1)),
    boxShadow: [BoxShadow(color: c.withValues(alpha: 0.20 * strength), blurRadius: 16, spreadRadius: -3)],
  );
}
