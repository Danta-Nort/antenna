// SPDX-License-Identifier: AGPL-3.0-only
// The macOS title bar in the app's own theme (native feel, reference v3). AppKit draws the title bar from the system's
// appearance, so a light window under a dark system had a dark band over it (and the other way round). The Runner
// (MainFlutterWindow.swift) takes the theme and the band's color from here over the `antenna/window` channel. Other
// systems draw their own decorations: nothing is sent there.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

abstract final class WindowChrome {
  static const channel = MethodChannel('antenna/window');

  /// Only macOS has the handler (tests switch it on).
  static bool enabled = Platform.isMacOS;

  /// The last state sent, so a rebuild sends nothing new.
  static (bool, int)? _sent;

  /// Give the title bar the app's theme ([dark]) and [color] (the navigation's, which the band continues).
  static Future<void> apply({required bool dark, required Color color}) async {
    if (!enabled) return;
    final next = (dark, color.toARGB32());
    if (next == _sent) return;
    _sent = next;
    try {
      await channel.invokeMethod<void>('chrome', {'dark': dark, 'color': next.$2});
    } on MissingPluginException {
      // An older Runner without the handler: the system's title bar stays as it was.
    } on PlatformException {
      // The same: nothing to change in the window.
    }
  }

  /// Forget what was sent (tests).
  static void reset() => _sent = null;
}
