// SPDX-License-Identifier: AGPL-3.0-only
// The button system of the reference v3 (2026-10-03): primary is solid brand blue, secondary is neutral with a 1 px
// border, tertiary is accent text, destructive is red (text, or a soft red fill for the one action that removes
// something). Radius 8, labels on the Body size; hover, pressed, disabled and keyboard focus are all visible, focus as
// a 2 px ring outside the button, and nothing ripples (a desktop app, not a touch screen). The app's ThemeData maps
// FilledButton → primary, OutlinedButton → secondary, TextButton → tertiary and IconButton → [XButtons.icon], so
// every button in the window has the same states; a screen picks a style here only for a destructive action or a
// deliberate exception.

import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class XButtons {
  static const double radius = XRadius.m;

  static const _shape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radius))),
  );
  static const _noOverlay = WidgetStatePropertyAll<Color>(Colors.transparent);
  static const _flat = WidgetStatePropertyAll<double>(0);
  static const _size = WidgetStatePropertyAll<Size>(Size(64, 40));
  static const _pad = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 8));
  static const _click = WidgetStatePropertyAll<MouseCursor>(SystemMouseCursors.click);

  static BorderSide _ring(Color c) => BorderSide(color: c, width: 2, strokeAlign: BorderSide.strokeAlignOutside);

  static TextStyle _label(FontWeight w) =>
      TextStyle(fontFamily: XFonts.sans, fontWeight: w, fontSize: XType.body, height: 20 / 14, letterSpacing: 0.1);

  /// The one action a card or dialog is for (Approve, Create, Send).
  static ButtonStyle primary() => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return XColors.bg3;
          if (s.contains(WidgetState.pressed)) return XColors.accentFillPressed;
          if (s.contains(WidgetState.hovered)) return XColors.accentFillHover;
          return XColors.accentFill;
        }),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.onAccent),
        iconColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.onAccent),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? _ring(XColors.accentLine) : null),
        overlayColor: _noOverlay,
        elevation: _flat,
        minimumSize: _size,
        padding: _pad,
        textStyle: WidgetStatePropertyAll(_label(FontWeight.w600)),
        shape: _shape,
        mouseCursor: _click,
        splashFactory: NoSplash.splashFactory,
      );

  /// The other choice (Deny, Cancel next to a primary, Copy): neutral, a 1 px border.
  static ButtonStyle secondary() => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return XColors.bg2;
          if (s.contains(WidgetState.pressed)) return XColors.bg3;
          if (s.contains(WidgetState.hovered)) return XColors.bgHover;
          return XColors.bg1;
        }),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.text),
        iconColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.textDim),
        side: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.focused)) return _ring(XColors.accent);
          if (s.contains(WidgetState.disabled)) return BorderSide(color: XColors.line);
          if (s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)) {
            return BorderSide(color: XColors.textMute);
          }
          return BorderSide(color: XColors.lineStrong);
        }),
        overlayColor: _noOverlay,
        elevation: _flat,
        minimumSize: _size,
        padding: _pad,
        textStyle: WidgetStatePropertyAll(_label(FontWeight.w500)),
        shape: _shape,
        mouseCursor: _click,
        splashFactory: NoSplash.splashFactory,
      );

  static ButtonStyle _text(Color color, {Color? hover, Color? pressed}) => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return Colors.transparent;
          if (s.contains(WidgetState.pressed)) return pressed ?? XColors.bg3;
          if (s.contains(WidgetState.hovered)) return hover ?? XColors.bgHover;
          return Colors.transparent;
        }),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : color),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : color),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? _ring(color) : null),
        overlayColor: _noOverlay,
        elevation: _flat,
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
        textStyle: WidgetStatePropertyAll(_label(FontWeight.w500)),
        shape: _shape,
        mouseCursor: _click,
        splashFactory: NoSplash.splashFactory,
      );

  /// A way to see more or a minor action (Details, Cancel, Retry): accent text.
  static ButtonStyle tertiary() => _text(XColors.accent);

  /// Something that refuses or stops (deny everything from a contact for an hour, Stop): red text.
  static ButtonStyle destructive() =>
      _text(XColors.danger, hover: XColors.dangerHover, pressed: XColors.dangerPressed);

  /// The one action that removes something for good (Remove contact): red text on a soft red fill, as the reference's
  /// destructive button.
  static ButtonStyle destructiveFilled() => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return XColors.bg2;
          if (s.contains(WidgetState.pressed)) return XColors.dangerPressed;
          return XColors.dangerHover;
        }),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.danger),
        iconColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? XColors.textMute : XColors.danger),
        side: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.focused)) return _ring(XColors.danger);
          if (s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)) {
            return BorderSide(color: XColors.danger.withValues(alpha: 0.45));
          }
          return BorderSide(color: XColors.danger.withValues(alpha: 0.2));
        }),
        overlayColor: _noOverlay,
        elevation: _flat,
        minimumSize: _size,
        padding: _pad,
        textStyle: WidgetStatePropertyAll(_label(FontWeight.w600)),
        shape: _shape,
        mouseCursor: _click,
        splashFactory: NoSplash.splashFactory,
      );

  /// Icon buttons (close, copy, the card toggle): a quiet square that fills on hover and press, a ring on focus.
  /// [selected] keeps the fill for a toggle that is on.
  static ButtonStyle icon({bool selected = false}) => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return Colors.transparent;
          if (selected) return XColors.accentSoft;
          if (s.contains(WidgetState.pressed)) return XColors.bg3;
          if (s.contains(WidgetState.hovered)) return XColors.bgHover;
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return XColors.textMute.withValues(alpha: 0.6);
          if (selected) return XColors.accent;
          if (s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)) return XColors.text;
          return XColors.textDim;
        }),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? _ring(XColors.accentLine) : null),
        overlayColor: _noOverlay,
        minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: _shape,
        mouseCursor: _click,
        splashFactory: NoSplash.splashFactory,
      );
}
