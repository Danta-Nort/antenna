// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's canvas (D-UI-47): a small viewport of its own rather than InteractiveViewer, so that a drag on a
// group, a card or a handle is that thing's own gesture and the map moves only from the empty canvas, and so that a
// plain mouse wheel pans instead of zooming. Pan: a drag on the empty canvas, the mouse wheel, a two-finger trackpad
// scroll. Zoom (0.4–2.0, around the pointer): a trackpad pinch, Ctrl or Cmd with the wheel, the − / + / Fit controls.
// The map is drawn in its own coordinates under one transform; everything on top of it (controls, popovers, the
// status strip) stays the canvas's size.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/agent_map_prefs.dart';

/// Every kind of pointer except a trackpad's two-finger gestures, which arrive as pan-zoom events and pan or zoom the
/// canvas whatever is under them (a trackpad's click and drag arrives as a mouse).
const mapDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

/// The view: zoom and pan, and the canvas's size.
class MapViewController extends ChangeNotifier {
  double scale = 1;

  /// Where the map's origin is drawn in the canvas.
  Offset pan = Offset.zero;

  /// The canvas's size (set by the canvas as it lays out).
  Size size = Size.zero;

  /// The view was set (from the saved one, or by Fit): until then the canvas fits the map when it first has a size.
  bool placed = false;

  MapView get view => (scale: scale, pan: pan);

  Offset toMap(Offset canvas) => (canvas - pan) / scale;
  Offset toCanvas(Offset map) => map * scale + pan;

  void set(double s, Offset p, {bool notify = true}) {
    scale = s.clamp(mapMinScale, mapMaxScale);
    pan = p;
    placed = true;
    if (notify) notifyListeners();
  }

  void panBy(Offset d) => set(scale, pan + d);

  /// Zoom by [factor] keeping the point under [focal] (canvas coordinates) where it is.
  void zoomAt(Offset focal, double factor) {
    final m = toMap(focal);
    final s = (scale * factor).clamp(mapMinScale, mapMaxScale);
    set(s, focal - m * s);
  }

  void zoomCenter(double factor) => zoomAt(size.center(Offset.zero), factor);

  /// Show [content] whole and centred in the canvas less [pad] (the controls above and below), at most at 100 %.
  void fit(Rect content, {bool notify = true, EdgeInsets pad = const EdgeInsets.fromLTRB(16, 56, 16, 56)}) {
    final room = pad.deflateRect(Offset.zero & size);
    if (room.isEmpty || content.isEmpty) return;
    final s = math.min(room.width / content.width, room.height / content.height).clamp(mapMinScale, 1.0).toDouble();
    set(s, room.center - content.center * s, notify: notify);
  }
}

/// The canvas: the map ([map], laid out in map coordinates from [origin], [mapSize] wide and high) under the view's
/// transform, and [overlays] on top. The callbacks get canvas coordinates.
class MapViewport extends StatefulWidget {
  const MapViewport({
    super.key,
    required this.controller,
    required this.origin,
    required this.mapSize,
    required this.map,
    this.overlays = const [],
    this.onTap,
    this.onHover,
    this.onExit,
    this.onViewChanged,
    this.onKey,
    this.focusNode,
    this.onPlace,
  });

  final MapViewController controller;
  final Offset origin;
  final Size mapSize;
  final Widget map;
  final List<Widget> overlays;
  final void Function(Offset canvas)? onTap;
  final void Function(Offset canvas)? onHover;
  final VoidCallback? onExit;

  /// A pan or a zoom ended (the view is worth saving).
  final VoidCallback? onViewChanged;
  final KeyEventResult Function(KeyEvent e)? onKey;
  final FocusNode? focusNode;

  /// The canvas has a size and the view is not set yet: set it now, without notifying (it is called while the canvas
  /// lays out, and the canvas draws with the view it leaves).
  final VoidCallback? onPlace;

  @override
  State<MapViewport> createState() => _MapViewportState();
}

class _MapViewportState extends State<MapViewport> {
  double _pinch = 1;

  MapViewController get _c => widget.controller;

  void _signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final s = event as PointerScrollEvent;
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        // Ctrl or Cmd with the wheel zooms; a wheel step of 100 px is about 1.4×.
        _c.zoomAt(s.localPosition, math.exp(-s.scrollDelta.dy / 300));
      } else {
        _c.panBy(-s.scrollDelta);
      }
      widget.onViewChanged?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: widget.onKey == null ? null : (_, e) => widget.onKey!(e),
      child: LayoutBuilder(builder: (context, constraints) {
        _c.size = constraints.biggest;
        if (!_c.placed && !_c.size.isEmpty) widget.onPlace?.call();
        final s = _c.scale;
        final t = _c.pan + widget.origin * s;
        final matrix = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(t.dx, t.dy, 0);
        return Listener(
          onPointerSignal: _signal,
          onPointerPanZoomStart: (_) => _pinch = 1,
          onPointerPanZoomUpdate: (e) {
            // A trackpad: two fingers pan, a pinch zooms around the fingers.
            _c.panBy(e.panDelta);
            if (e.scale > 0 && e.scale != _pinch) {
              _c.zoomAt(e.localPosition, e.scale / _pinch);
              _pinch = e.scale;
            }
          },
          onPointerPanZoomEnd: (_) => widget.onViewChanged?.call(),
          child: MouseRegion(
            onHover: widget.onHover == null ? null : (e) => widget.onHover!(e.localPosition),
            onExit: widget.onExit == null ? null : (_) => widget.onExit!(),
            child: GestureDetector(
              key: const Key('agent-map-canvas'),
              behavior: HitTestBehavior.opaque,
              supportedDevices: mapDragDevices,
              dragStartBehavior: DragStartBehavior.down,
              onTapUp: widget.onTap == null ? null : (d) => widget.onTap!(d.localPosition),
              onPanUpdate: (d) => _c.panBy(d.delta),
              onPanEnd: (_) => widget.onViewChanged?.call(),
              child: ClipRect(
                child: Stack(children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Transform(
                      transform: matrix,
                      child: SizedBox.fromSize(size: widget.mapSize, child: widget.map),
                    ),
                  ),
                  ...widget.overlays,
                ]),
              ),
            ),
          ),
        );
      }),
    );
  }
}
