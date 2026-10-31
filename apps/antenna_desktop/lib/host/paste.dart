// SPDX-License-Identifier: AGPL-3.0-only
// Paste from other apps.
//
// Synthetic paste (macOS): dictation apps (Superwhisper, Wispr Flow), clipboard managers and text expanders put text
// on the pasteboard and post a Cmd+V whose Command exists only in the key event's flags. Flutter 3.47 drops that event
// (flutter/flutter#184571): it falls through to Edit > Paste, whose `paste:` changes the text view the engine keeps for
// accessibility, never the Flutter field, so the text "disappears". The Runner (macos/Runner/ComposerInput.swift)
// catches such a Cmd+V before Flutter sees it, reads the pasteboard text at once (the app may put the old clipboard
// back a moment later) and sends it here over `antenna/paste` as `paste {text?}`; Edit > Paste from the menu bar
// arrives the same way. [pasteIntoFocus] then does what Cmd+V does.
//
// Images: Flutter's clipboard API has text only; [ClipboardImages] asks the Runner over `antenna/clipboard` (`image` →
// PNG bytes or null): NSPasteboard on macOS (ComposerInput.swift), GTK on Linux (linux/runner/clipboard_channel.cc).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Insert [text] where the keyboard focus is, as a paste would: in a text field at the cursor, replacing the
/// selection, with the cursor after the inserted text (the same steps as `EditableTextState.pasteText`, with text the
/// caller already has). Without text (an image on the clipboard) or outside a text field (the agent's terminal), the
/// focused widget gets the ordinary paste intent: the composer attaches an image, the terminal pastes the clipboard.
void pasteIntoFocus(String? text) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return;
  final editable = ctx.findAncestorStateOfType<EditableTextState>();
  if (text != null && text.isNotEmpty && editable != null) {
    if (editable.widget.readOnly) return;
    final v = editable.textEditingValue;
    final sel = v.selection;
    if (!sel.isValid) return;
    final collapsed = v.copyWith(selection: TextSelection.collapsed(offset: math.max(sel.baseOffset, sel.extentOffset)));
    editable.userUpdateTextEditingValue(collapsed.replaced(sel, text), SelectionChangedCause.keyboard);
    return;
  }
  Actions.maybeInvoke(ctx, const PasteTextIntent(SelectionChangedCause.keyboard));
}

/// The `antenna/paste` channel from the macOS Runner.
class PasteBridge {
  PasteBridge._();
  static final instance = PasteBridge._();

  static const channel = MethodChannel('antenna/paste');
  bool _attached = false;

  /// Listen to the Runner (once; nothing arrives on Linux).
  void attach() {
    if (_attached) return;
    _attached = true;
    channel.setMethodCallHandler(handle);
  }

  /// A message from the Runner (public for tests).
  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    if (call.method != 'paste') return null;
    final a = call.arguments;
    final text = a is Map ? a['text'] : null;
    pasteIntoFocus(text is String ? text : null);
    return null;
  }
}

/// Image data on the system clipboard, as PNG. Replaced in tests.
abstract class ClipboardImages {
  Future<Uint8List?> read();

  static ClipboardImages instance = RunnerClipboardImages();
}

/// The Runner's reader: `antenna/clipboard` `image`. A Runner without it (`flutter test`, an older build) or a
/// failure means no image.
class RunnerClipboardImages implements ClipboardImages {
  static const channel = MethodChannel('antenna/clipboard');

  @override
  Future<Uint8List?> read() async {
    try {
      final bytes = await channel.invokeMethod<Uint8List>('image');
      return bytes == null || bytes.isEmpty ? null : bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('clipboard image: $e');
      return null;
    }
  }
}
