// SPDX-License-Identifier: AGPL-3.0-only
// The full-screen viewer of pictures (D-UI-46): one at a time over the whole window, Previous and Next across the
// conversation, zoom, and the file's actions (Save as…, Copy, Show in Finder, Open) on a bar over the picture with its
// name and size. Every picture shown here came from [ViewerImage.load]: the same safe preview (received) or preview
// copy (sent) as the thumbnail, never read again from the original.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import 'file_card.dart' show fileSizeLabel;
import 'file_menu.dart';
import 'image_thumbnail.dart' show loadImageBytes;

/// A picture the full-screen viewer shows: a file of a chat (sent or received), or a file waiting in the composer.
final class ViewerImage {
  const ViewerImage({required this.id, required this.name, required this.load, this.savedPath, this.file, this.size});

  final String id;
  final String name;

  /// The pixels to show (never throws; `null` when there are none).
  final Future<Uint8List?> Function(BuildContext context) load;

  /// A received file the owner accepted: where the daemon saved it (Save as copies it, Show in Finder shows it).
  final String? savedPath;

  /// The chat's file behind the picture: its actions show on the viewer's bar. `null` for a file still in the composer.
  final FileInfo? file;

  /// Bytes, for the bar.
  final int? size;
}

/// The viewer's picture of a chat's file [f]: its safe preview (received) or the preview copy (sent).
ViewerImage viewerImageOf(FileInfo f) => ViewerImage(
      id: f.id,
      name: f.name,
      load: (context) => loadImageBytes(context, f),
      savedPath: f.incoming && f.state == 'accepted' ? f.savedPath : null,
      file: f,
      size: f.size,
    );

/// Opens the full-screen viewer over everything, including the window's navigation.
Future<void> showImageViewer(BuildContext context, List<ViewerImage> images, {required int initialIndex}) =>
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: XMotion.fast,
      pageBuilder: (context, _, _) => ImageViewer(images: images, initialIndex: initialIndex),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ));

/// Full screen, one picture at a time: Escape, the ✕ or a tap beside the picture closes it; the arrow keys or the
/// on-screen arrows move between the conversation's other pictures (hidden with only one); `+`, `−` and `0` (or the
/// bar's buttons, a pinch or the wheel) zoom, the picture fitting the window is the resting size. The bar names the
/// picture and holds its actions.
class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.images, required this.initialIndex});
  final List<ViewerImage> images;
  final int initialIndex;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late int _index = widget.initialIndex.clamp(0, widget.images.length - 1);
  final _focus = FocusNode();
  final _zoom = TransformationController();
  static const _maxScale = 8.0;

  /// Each picture is loaded once while the viewer is open (paging back does not read it again).
  final _loaded = <String, Future<Uint8List?>>{};

  Future<Uint8List?> _bytes(ViewerImage f) => _loaded[f.id] ??= f.load(context);

  @override
  void dispose() {
    _focus.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _go(int index) {
    if (index < 0 || index >= widget.images.length || index == _index) return;
    setState(() {
      _index = index;
      _zoom.value = Matrix4.identity();
    });
  }

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  /// Zoom by [factor] around the middle of the window.
  void _zoomBy(double factor) {
    final size = MediaQuery.sizeOf(context);
    final target = (_scale * factor).clamp(1.0, _maxScale);
    final k = target / _scale;
    final c = Offset(size.width / 2, size.height / 2);
    setState(() {
      _zoom.value = Matrix4.identity()
        ..translateByDouble(c.dx, c.dy, 0, 1)
        ..scaleByDouble(k, k, 1, 1)
        ..translateByDouble(-c.dx, -c.dy, 0, 1)
        ..multiply(_zoom.value);
      if (target == 1.0) _zoom.value = Matrix4.identity();
    });
  }

  void _fit() => setState(() => _zoom.value = Matrix4.identity());

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _close();
      case LogicalKeyboardKey.arrowLeft:
        _go(_index - 1);
      case LogicalKeyboardKey.arrowRight:
        _go(_index + 1);
      case LogicalKeyboardKey.equal || LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd:
        _zoomBy(1.5);
      case LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract:
        _zoomBy(1 / 1.5);
      case LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0:
        _fit();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = widget.images[_index];
    final file = f.file;
    final m = AppScope.maybeOf(context);
    final actions = file == null || m == null
        ? const <FileAction>[]
        : [
            for (final a in fileActionsOf(m, file))
              if (const {FileAction.saveAs, FileAction.copyImage, FileAction.reveal, FileAction.open}.contains(a)) a,
          ];
    // A Scaffold of its own: what an action says (a snackbar) shows over the viewer, not under it.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          child: Stack(children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('image-viewer-background'),
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(72, 64, 72, 24),
                  child: Center(
                    child: FutureBuilder<Uint8List?>(
                      key: ValueKey(f.id),
                      future: _bytes(f),
                      builder: (context, s) {
                        if (s.connectionState != ConnectionState.done) {
                          return const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
                        }
                        final bytes = s.data;
                        if (bytes == null) {
                          return Text(l.filesPreviewImageError, style: XText.body.copyWith(color: Colors.white));
                        }
                        // A tap on the picture itself does nothing (only beside it closes): zooming and panning a
                        // picture should not close it by accident.
                        return GestureDetector(
                          onTap: () {},
                          child: InteractiveViewer(
                            key: const Key('image-viewer-zoom'),
                            transformationController: _zoom,
                            minScale: 1,
                            maxScale: _maxScale,
                            onInteractionEnd: (_) => setState(() {}),
                            child: Image.memory(bytes,
                                key: Key('image-viewer-image-${f.id}'), fit: BoxFit.contain, gaplessPlayback: true),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            // The bar: which picture, its name and size; zoom; the file's actions; close.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                child: Row(children: [
                  Expanded(
                    child:
                        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      // The name is contact data: plain text.
                      Text(f.name,
                          key: const Key('image-viewer-name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: XText.body.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                      Wrap(spacing: 8, children: [
                        if (widget.images.length > 1)
                          Text(l.filesImageOf(_index + 1, widget.images.length),
                              key: const Key('image-viewer-count'), style: XText.meta.copyWith(color: Colors.white70)),
                        if (f.size != null)
                          Text(fileSizeLabel(f.size!), style: XText.meta.copyWith(color: Colors.white70)),
                        if (_scale > 1.01)
                          Text('${(_scale * 100).round()} %',
                              key: const Key('image-viewer-scale'), style: XText.meta.copyWith(color: Colors.white70)),
                      ]),
                    ]),
                  ),
                  _ViewerButton(
                      key: const Key('image-viewer-zoom-out'),
                      icon: Icons.zoom_out_rounded,
                      tooltip: l.filesViewerZoomOut,
                      onTap: _scale > 1.01 ? () => _zoomBy(1 / 1.5) : null),
                  _ViewerButton(
                      key: const Key('image-viewer-fit'),
                      icon: Icons.fit_screen_outlined,
                      tooltip: l.filesViewerFit,
                      onTap: _scale > 1.01 ? _fit : null),
                  _ViewerButton(
                      key: const Key('image-viewer-zoom-in'),
                      icon: Icons.zoom_in_rounded,
                      tooltip: l.filesViewerZoomIn,
                      onTap: _scale < _maxScale ? () => _zoomBy(1.5) : null),
                  if (actions.isNotEmpty) const SizedBox(width: 12),
                  for (final a in actions)
                    _ViewerButton(
                      key: Key('image-viewer-${a.name}'),
                      icon: fileActionIcon(a),
                      tooltip: fileActionLabel(l, a),
                      onTap: () => runFileAction(context, file!, a),
                    ),
                  const SizedBox(width: 12),
                  _ViewerButton(
                    key: const Key('image-viewer-close'),
                    icon: Icons.close_rounded,
                    tooltip: l.commonClose,
                    onTap: _close,
                  ),
                ]),
              ),
            ),
            if (_index > 0)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _ViewerButton(
                    key: const Key('image-viewer-prev'),
                    icon: Icons.chevron_left_rounded,
                    tooltip: l.filesImagePrevious,
                    onTap: () => _go(_index - 1),
                  ),
                ),
              ),
            if (_index < widget.images.length - 1)
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _ViewerButton(
                    key: const Key('image-viewer-next'),
                    icon: Icons.chevron_right_rounded,
                    tooltip: l.filesImageNext,
                    onTap: () => _go(_index + 1),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _ViewerButton extends StatelessWidget {
  const _ViewerButton({super.key, required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.white.withValues(alpha: onTap == null ? 0.05 : 0.12),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(icon, color: onTap == null ? Colors.white38 : Colors.white, size: 20),
              ),
            ),
          ),
        ),
      );
}
