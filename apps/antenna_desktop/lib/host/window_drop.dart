// SPDX-License-Identifier: AGPL-3.0-only
// Drops onto the window on macOS, from the Runner's drop view (macos/Runner/ComposerInput.swift) over the
// `antenna/drop` channel. `desktop_drop` hands its paths to Dart only after the drop has ended, and by then the source
// may have deleted the file: the screenshot thumbnail offers a file in TemporaryItems that is removed as soon as the
// drag ends. The drop view copies (clones) files, receives file promises (screenshots, Photos, Mail, browsers) and
// writes image data into the staging folder before the drop ends, then reports what it staged. Linux keeps
// `desktop_drop` (GTK hands over paths of files that stay; the window copies small ones, `OutgoingStaging`).
//
// Messages from the view: `entered`/`updated` `[x, y]`, `exited`, `dropped {x, y, items: [{path, staged}], failed}`
// (`failed`: promised files the source did not deliver). One drop of promised files may arrive as several `dropped`
// messages, one per file, as the source writes them. To the view: `setStagingRoot <path>`.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'outgoing_staging.dart';

sealed class WindowDropEvent {
  const WindowDropEvent(this.position);

  /// Window coordinates (logical pixels from the top left), like `desktop_drop`'s.
  final Offset position;
}

class WindowDragOver extends WindowDropEvent {
  const WindowDragOver(super.position);
}

class WindowDragExit extends WindowDropEvent {
  const WindowDragExit() : super(Offset.zero);
}

class WindowDropped extends WindowDropEvent {
  const WindowDropped(super.position, this.items, {this.failed = 0});
  final List<StagedFile> items;
  final int failed;
}

/// A drop target: returns `true` when the drop was over it and it took the items.
typedef WindowDropListener = bool Function(WindowDropEvent event);

class WindowDrop {
  WindowDrop._();
  static final instance = WindowDrop._();

  /// The window takes drops through the Runner's view: macOS. Tests switch it on to drive the same code on Linux.
  static bool native = Platform.isMacOS;

  static const channel = MethodChannel('antenna/drop');

  final _listeners = <WindowDropListener>[];
  bool _attached = false;

  /// Listen to the view (once) and tell it where to stage.
  void attach() {
    if (_attached) return;
    _attached = true;
    channel.setMethodCallHandler(handle);
    final root = OutgoingStaging.instance?.root;
    if (root != null) {
      unawaited(channel.invokeMethod<void>('setStagingRoot', root).catchError((Object e) {
        // A Runner without the view (tests, an old build): it stages into the same default folder or not at all.
        debugPrint('antenna/drop: $e');
      }));
    }
  }

  void addListener(WindowDropListener l) => _listeners.add(l);
  void removeListener(WindowDropListener l) => _listeners.remove(l);

  /// A message from the view (public for tests: they feed it messages the way the view sends them).
  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    final event = parse(call);
    if (event == null) return null;
    var taken = false;
    for (final l in List.of(_listeners)) {
      if (l(event)) {
        taken = true;
        break;
      }
    }
    // Dropped where nothing takes files (the contact list, a dialog): the copies are not needed.
    if (event is WindowDropped && !taken) {
      for (final s in event.items) {
        if (s.owned) OutgoingStaging.instance?.release(s.path);
      }
    }
    return null;
  }

  /// The view's message as an event; `null` for anything malformed.
  static WindowDropEvent? parse(MethodCall call) {
    Offset? at(Object? x, Object? y) => x is num && y is num ? Offset(x.toDouble(), y.toDouble()) : null;
    final a = call.arguments;
    switch (call.method) {
      case 'entered' || 'updated':
        if (a is! List || a.length < 2) return null;
        final p = at(a[0], a[1]);
        return p == null ? null : WindowDragOver(p);
      case 'exited':
        return const WindowDragExit();
      case 'dropped':
        if (a is! Map) return null;
        final p = at(a['x'], a['y']);
        if (p == null) return null;
        final staging = OutgoingStaging.instance;
        final items = <StagedFile>[
          for (final i in (a['items'] is List ? a['items'] as List : const <Object?>[]))
            if (i is Map && i['path'] is String && (i['path'] as String).isNotEmpty)
              // Only a path inside the staging folder is the window's to delete, whatever the message says.
              StagedFile(i['path'] as String,
                  owned: i['staged'] == true && (staging?.owns(i['path'] as String) ?? false)),
        ];
        final failed = a['failed'];
        return WindowDropped(p, items, failed: failed is int && failed > 0 ? failed : 0);
    }
    return null;
  }
}
