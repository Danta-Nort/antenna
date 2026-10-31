// SPDX-License-Identifier: AGPL-3.0-only
// Dropping files onto the conversation attaches them to the composer, like the paperclip button: they wait there and
// go to this link on Send. A quiet hint over the timeline and the composer says who will get them.
//
// The window copies each dropped file into its staging folder before anything else (lib/host/outgoing_staging.dart):
// the source app may delete the file as soon as the drop ends. On macOS the drops
// come from the Runner's own drop view, which stages files, file promises and image data before the drop ends
// (lib/host/window_drop.dart); on Linux from `desktop_drop`.

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../host/outgoing_staging.dart';
import '../../host/window_drop.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';

class FileDropZone extends StatefulWidget {
  const FileDropZone(this.c, {super.key, required this.child});
  final ContactInfo c;
  final Widget child;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  bool _over = false;

  void _hover(bool over) {
    if (mounted && over != _over) setState(() => _over = over);
  }

  /// Attach the dropped files to the composer (public for tests: `flutter test` has no platform drag and drop). Every
  /// path is staged at once: the copies start while the files still exist.
  static Future<void> dropFiles(BuildContext context, String linkId, Iterable<StagedFile> dropped,
      {int failed = 0}) async {
    final m = AppScope.read(context);
    final l = context.l;
    final staging = OutgoingStaging.instance;
    final ready = await Future.wait([
      for (final d in dropped)
        if (d.path.isNotEmpty)
          d.owned || staging == null ? Future.value(d) : staging.stageFile(d.path),
    ]);
    if (failed > 0) m.addLocalNote(l.filesDropNotReceived(failed));
    for (final s in ready) {
      m.stageAttachment(linkId, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Dialog cards over the window must not accept files for this link, nor a link whose history is read-only (no
    // composer to hold them).
    final enable = (ModalRoute.of(context)?.isCurrent ?? true) && !(widget.c.history?.sendBlocked ?? false);
    final zone = Stack(children: [
      Positioned.fill(child: widget.child),
      if (_over)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              key: const Key('drop-overlay'),
              margin: const EdgeInsets.all(12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: XColors.accentSoft.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(XRadius.xl),
                border: Border.all(color: XColors.accentLine, width: 1.5),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.file_upload_outlined, size: 34, color: XColors.accent),
                const SizedBox(height: 8),
                Text(context.l.filesDropTitle(widget.c.label), style: XText.title.copyWith(color: XColors.accent)),
                const SizedBox(height: 4),
                Text(context.l.filesDropHint, style: XText.meta),
              ]),
            ),
          ),
        ),
    ]);
    if (WindowDrop.native) {
      return _NativeDropTarget(
        enable: enable,
        onHover: _hover,
        onDrop: (e) => dropFiles(context, widget.c.linkId, e.items, failed: e.failed),
        child: zone,
      );
    }
    return DropTarget(
      enable: enable,
      onDragEntered: (_) => _hover(true),
      onDragExited: (_) => _hover(false),
      onDragDone: (d) {
        _hover(false);
        unawaited(dropFiles(context, widget.c.linkId, d.files.map((f) => StagedFile(f.path))));
      },
      child: zone,
    );
  }
}

/// The macOS drop target: events from the Runner's drop view, matched against this widget's bounds.
class _NativeDropTarget extends StatefulWidget {
  const _NativeDropTarget({required this.enable, required this.onHover, required this.onDrop, required this.child});
  final bool enable;
  final ValueChanged<bool> onHover;
  final Future<void> Function(WindowDropped e) onDrop;
  final Widget child;

  @override
  State<_NativeDropTarget> createState() => _NativeDropTargetState();
}

class _NativeDropTargetState extends State<_NativeDropTarget> {
  @override
  void initState() {
    super.initState();
    WindowDrop.instance
      ..attach()
      ..addListener(_onEvent);
  }

  @override
  void dispose() {
    WindowDrop.instance.removeListener(_onEvent);
    super.dispose();
  }

  bool _onEvent(WindowDropEvent e) {
    if (!mounted) return false;
    final box = context.findRenderObject();
    final inside = widget.enable &&
        box is RenderBox &&
        box.hasSize &&
        box.paintBounds.contains(box.globalToLocal(e.position));
    switch (e) {
      case WindowDragOver():
        widget.onHover(inside);
        return false;
      case WindowDragExit():
        widget.onHover(false);
        return false;
      case WindowDropped():
        widget.onHover(false);
        if (!inside) return false;
        unawaited(widget.onDrop(e));
        return true;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// For tests: the same as dropping files over the conversation (paths as `desktop_drop` delivers them).
Future<void> dropFilesForTest(BuildContext context, String linkId, List<String> paths) =>
    _FileDropZoneState.dropFiles(context, linkId, paths.map(StagedFile.new));
