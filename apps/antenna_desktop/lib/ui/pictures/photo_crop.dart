// SPDX-License-Identifier: AGPL-3.0-only
// The owner's own photo for a profile picture: shown in a square viewport where the owner moves and zooms it (the
// image always covers the square), then the visible square is drawn again at 512 × 512 and encoded as a PNG by the
// engine: pixels only, so nothing of the original file (EXIF location, camera, comments) reaches the daemon. The daemon
// still checks and rebuilds that PNG itself before it is announced (CONTROL §28); the window never shows these bytes as
// the picture, only what `picture_photo` returns.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';

/// The side of the PNG the window hands to the daemon.
const photoSide = 512;

/// The largest photo file the window opens (the daemon refuses files over 32 MiB itself).
const photoMaxBytes = 32 << 20;

/// Decode [bytes] for the crop step; a large photo is decoded at most [maxShort] pixels on its shorter side (enough to
/// zoom in four times on a 512 px square, without holding a 48-megapixel bitmap). Throws when the engine cannot decode
/// the file (HEIC on Linux, a broken file).
Future<ui.Image> decodePhoto(Uint8List bytes, {int maxShort = 2048}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? desc;
  ui.Codec? codec;
  try {
    desc = await ui.ImageDescriptor.encoded(buffer);
    final short = math.min(desc.width, desc.height);
    if (short <= 0) throw StateError('empty image');
    int? w, h;
    if (short > maxShort) {
      final k = maxShort / short;
      w = (desc.width * k).round();
      h = (desc.height * k).round();
    }
    codec = await desc.instantiateCodec(targetWidth: w, targetHeight: h);
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    desc?.dispose();
    buffer.dispose();
  }
}

/// Draw [src] (a square in [image]'s pixels) at [side] × [side] and encode it as a PNG (no metadata).
Future<Uint8List> renderSquarePng(ui.Image image, Rect src, {int side = photoSide}) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    image,
    src,
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  final picture = rec.endRecording();
  final out = await picture.toImage(side, side);
  picture.dispose();
  try {
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('png encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    out.dispose();
  }
}

/// The scale at which [image] just covers a square of [viewport], and the matrix that centers it there.
Matrix4 coverMatrix(ui.Image image, double viewport) {
  final s = viewport / math.min(image.width, image.height);
  return _matrix(s, (viewport - image.width * s) / 2, (viewport - image.height * s) / 2);
}

/// A uniform scale on every axis, as InteractiveViewer makes it (it reads the scale with `getMaxScaleOnAxis`).
Matrix4 _matrix(double s, double tx, double ty) => Matrix4.diagonal3Values(s, s, s)..setTranslationRaw(tx, ty, 0);

/// The square of [image] (in its pixels) that [m] shows in a viewport of [viewport].
Rect visibleSquare(Matrix4 m, ui.Image image, double viewport) {
  final r = MatrixUtils.inverseTransformRect(m, Rect.fromLTWH(0, 0, viewport, viewport));
  final full = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  return r.intersect(full);
}

/// The square viewport: pan and zoom, the image always covering it, and the circle contacts will see.
class PhotoCropView extends StatefulWidget {
  const PhotoCropView({super.key, required this.image, required this.controller, this.viewport = 320});
  final ui.Image image;
  final TransformationController controller;
  final double viewport;

  @override
  State<PhotoCropView> createState() => _PhotoCropViewState();
}

class _PhotoCropViewState extends State<PhotoCropView> {
  late final double _cover = widget.viewport / math.min(widget.image.width, widget.image.height);

  double get _scale => widget.controller.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Zoom to [s] around the viewport's center, keeping the image over the whole square.
  void _zoom(double s) {
    final v = widget.viewport;
    final m = widget.controller.value;
    final old = _scale;
    final t = m.getTranslation();
    // The image point under the center stays under it
    final cx = (v / 2 - t.x) / old;
    final cy = (v / 2 - t.y) / old;
    final w = widget.image.width * s;
    final h = widget.image.height * s;
    final tx = (v / 2 - cx * s).clamp(v - w, 0.0);
    final ty = (v / 2 - cy * s).clamp(v - h, 0.0);
    widget.controller.value = _matrix(s, tx, ty);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.viewport;
    final max = _cover * 4;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(XRadius.m),
        child: SizedBox(
          key: const Key('picture-crop-viewport'),
          width: v,
          height: v,
          child: Stack(children: [
            InteractiveViewer(
              transformationController: widget.controller,
              constrained: false,
              minScale: _cover,
              maxScale: max,
              boundaryMargin: EdgeInsets.zero,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: widget.image.width.toDouble(),
                height: widget.image.height.toDouble(),
                child: RawImage(image: widget.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              ),
            ),
            IgnorePointer(child: CustomPaint(size: Size(v, v), painter: _CircleMask(XColors.scrim))),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: v,
        child: Row(children: [
          Icon(Icons.photo_size_select_small_rounded, size: 16, color: XColors.textDim),
          Expanded(
            child: Slider(
              key: const Key('picture-crop-zoom'),
              value: _scale.clamp(_cover, max),
              min: _cover,
              max: max,
              label: context.l.pictureZoom,
              semanticFormatterCallback: (_) => context.l.pictureZoom,
              onChanged: _zoom,
            ),
          ),
          Icon(Icons.photo_size_select_large_rounded, size: 16, color: XColors.textDim),
        ]),
      ),
    ]);
  }
}

/// Darkens the corners outside the circle a picture is drawn in, with a thin ring on the circle.
class _CircleMask extends CustomPainter {
  _CircleMask(this.scrim);
  final Color scrim;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final circle = Path()..addOval(r.deflate(1));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(r), circle),
      Paint()..color = scrim.withValues(alpha: 0.55),
    );
    canvas.drawPath(
      circle,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_CircleMask old) => old.scrim != scrim;
}
