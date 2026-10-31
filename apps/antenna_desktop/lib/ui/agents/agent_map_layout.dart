// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's geometry, in map coordinates (the canvas's zoom and pan are the view's, agent_map_canvas.dart):
// where each group, card and line goes, from the graph and the owner's arrangement only, so the same facts and the
// same arrangement always draw the same picture.
//
// The automatic arrangement has three columns whatever the window's size: the owner's other computers on the left,
// this computer in the middle, the contacts on the right (an own computer is never a contact, however many of either
// there are: D-UI-47's placement fix). The owner may move any group anywhere and reorder the cards inside a group; a
// group or card the arrangement does not know is placed automatically, below whatever is already in its column.
//
// A line leaves each card on the side facing the other group. A line between two agents of one group (a team, a
// local connection, their recent messages) stays inside the group: an arc in a lane along the group's side with fewer
// lines leaving it. Lines are drawn by kind with weight and colour only, never dashed (dashes read as disappearing
// messages).

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/rendering.dart';

import '../../state/agent_map.dart';
import '../../theme/x_theme.dart';

/// Group and card metrics (the 8 px grid), in map coordinates.
abstract final class MapMetrics {
  static const header = 44.0;
  static const node = 48.0;
  static const nodeGap = 4.0;
  static const pad = 8.0;
  static const clusterGap = 24.0;
  static const column = 256.0;
  static const gap = 144.0;

  /// The lane inside a group for the lines between its own agents.
  static const lane = 64.0;

  /// Space kept around the groups (labels and arcs that stick out stay reachable).
  static const margin = 64.0;

  /// A line ends this far outside its card: at the edge of the handle (port) there, so its arrowhead shows.
  static const port = 6.0;

  static double clusterHeight(int nodes) => header + nodes * node + math.max(0, nodes - 1) * nodeGap + pad;

  /// The top of slot [i] below a group's top.
  static double slotTop(int i) => header + i * (node + nodeGap);
}

/// One line: a cubic curve from [p0] (the end on this computer) to [p3], its midpoint and where its end marks go.
final class LineGeometry {
  const LineGeometry(this.edge, this.p0, this.c1, this.c2, this.p3, {this.lane});
  final MapEdge edge;
  final Offset p0;
  final Offset c1;
  final Offset c2;
  final Offset p3;

  /// A line inside a group: `true` when its lane is on the group's right, `false` on its left; `null` between groups.
  final bool? lane;

  Offset at(double t) {
    final u = 1 - t;
    return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t);
  }

  Offset get mid => at(0.5);

  Path get path => Path()
    ..moveTo(p0.dx, p0.dy)
    ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p3.dx, p3.dy);

  /// The distance from [p] to the curve (sampled).
  double distanceTo(Offset p) {
    var best = double.infinity;
    var prev = p0;
    for (var i = 1; i <= 32; i++) {
      final next = at(i / 32);
      best = math.min(best, _segment(p, prev, next));
      prev = next;
    }
    return best;
  }

  /// Where an end's "tasks" mark goes: near that end, above the line (inside the lane for a line inside a group).
  Offset tasksAt({required bool start}) {
    final end = start ? p0 : p3;
    if (lane case final right?) return Offset(end.dx + (right ? 30 : -30), end.dy - 14);
    return at(start ? 0.16 : 0.84) - const Offset(0, 14);
  }

  static double _segment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}

/// The card [node] being dragged to [slot] of its group (the others make room).
typedef MapMove = ({String node, int slot});

final class MapLayout {
  const MapLayout({
    required this.clusters,
    required this.nodes,
    required this.slots,
    required this.lanes,
    required this.lines,
    required this.bounds,
  });

  /// Each group's rectangle.
  final Map<String, Rect> clusters;

  /// Each card's rectangle (its slot; a dragged card's own rectangle is the view's).
  final Map<String, Rect> nodes;

  /// Each group's cards, first to last.
  final Map<String, List<String>> slots;

  /// The groups with a lane: `true` on the right, `false` on the left.
  final Map<String, bool> lanes;
  final List<LineGeometry> lines;

  /// Every group with [MapMetrics.margin] around them: what Fit shows and the canvas spans.
  final Rect bounds;

  /// The groups' own extent, without the margin.
  Rect get content => bounds.deflate(MapMetrics.margin);

  /// The card under [p], if any.
  String? nodeAt(Offset p, {double slop = 0}) {
    for (final e in nodes.entries) {
      if (e.value.inflate(slop).contains(p)) return e.key;
    }
    return null;
  }

  /// The group under [p], if any (the last drawn wins, as on screen).
  String? clusterAt(Offset p) {
    String? hit;
    for (final e in clusters.entries) {
      if (e.value.contains(p)) hit = e.key;
    }
    return hit;
  }

  /// The line nearest to [p] within [slop], of any kind.
  LineGeometry? lineAt(Offset p, {double slop = 6}) {
    LineGeometry? best;
    var d = slop;
    for (final l in lines) {
      final x = l.distanceTo(p);
      if (x <= d) {
        d = x;
        best = l;
      }
    }
    return best;
  }

  /// The slot of [cluster] a card dragged with its top at [top] would take.
  int slotAt(String cluster, double top) {
    final r = clusters[cluster];
    final n = slots[cluster]?.length ?? 0;
    if (r == null || n == 0) return 0;
    return ((top - r.top - MapMetrics.header) / (MapMetrics.node + MapMetrics.nodeGap)).round().clamp(0, n - 1);
  }

  /// The sides a card's handle shows on (`true`: right): both for this computer's agents, which connect either way;
  /// for another computer's, the side facing this computer.
  List<bool> handleSides(AgentMapGraph g, String node) {
    final n = g.node(node);
    if (n == null) return const [];
    if (n.here) return const [false, true];
    final mine = clusters[n.cluster];
    final here = clusters[g.clusters.first.id];
    if (mine == null || here == null) return const [true];
    return [here.center.dx >= mine.center.dx];
  }
}

/// The automatic arrangement: each group's top-left corner, three columns (see the file's header).
Map<String, Offset> defaultPositions(AgentMapGraph g, Map<String, double> widths) {
  final here = g.clusters.first;
  final out = <String, Offset>{};
  final hereX = MapMetrics.column + MapMetrics.gap;
  final rightX = hereX + (widths[here.id] ?? MapMetrics.column) + MapMetrics.gap;
  out[here.id] = Offset(hereX, 0);
  var left = 0.0, right = 0.0;
  for (final c in g.clusters.skip(1)) {
    final h = MapMetrics.clusterHeight(c.nodes.length);
    if (c.kind == MapClusterKind.ownComputer) {
      out[c.id] = Offset(0, left);
      left += h + MapMetrics.clusterGap;
    } else {
      out[c.id] = Offset(rightX, right);
      right += h + MapMetrics.clusterGap;
    }
  }
  return out;
}

/// The cards of [c] in the owner's order ([order]: node IDs; unknown ones dropped, new ones after it in the graph's
/// order), with [move] applied.
List<String> slotsOf(MapCluster c, List<String>? order, MapMove? move) {
  final ids = [for (final n in c.nodes) n.id];
  final known = ids.toSet();
  final out = [
    for (final id in order ?? const <String>[])
      if (known.contains(id)) id,
  ];
  final placed = out.toSet();
  out.addAll(ids.where((id) => !placed.contains(id)));
  if (move != null && out.remove(move.node)) out.insert(move.slot.clamp(0, out.length), move.node);
  return out;
}

/// Lays [g] out with the owner's [positions] (each group's top-left corner) and [order] (each group's cards).
/// [move]: a card being dragged; [floating]: where it is drawn meanwhile (its lines follow it).
MapLayout layoutAgentMap(
  AgentMapGraph g, {
  Map<String, Offset> positions = const {},
  Map<String, List<String>> order = const {},
  MapMove? move,
  ({String node, Rect rect})? floating,
}) {
  // A group with lines between its own agents gets a lane for them.
  final inside = <String>{
    for (final e in g.edges)
      if (g.node(e.local)?.cluster case final c? when c == g.node(e.other)?.cluster) c,
  };
  final widths = {
    for (final c in g.clusters) c.id: MapMetrics.column + (inside.contains(c.id) ? MapMetrics.lane : 0),
  };
  double h(MapCluster c) => MapMetrics.clusterHeight(c.nodes.length);

  // Where each group goes: the owner's place, else the automatic one, pushed below anything already there.
  final auto = defaultPositions(g, widths);
  final clusters = <String, Rect>{};
  for (final c in g.clusters) {
    if (positions[c.id] case final p?) clusters[c.id] = Rect.fromLTWH(p.dx, p.dy, widths[c.id]!, h(c));
  }
  for (final c in g.clusters) {
    if (clusters.containsKey(c.id)) continue;
    var r = Rect.fromLTWH(auto[c.id]!.dx, auto[c.id]!.dy, widths[c.id]!, h(c));
    for (var guard = 0; guard < 400; guard++) {
      final hit = clusters.values.where((o) => o.inflate(MapMetrics.clusterGap / 2).overlaps(r)).firstOrNull;
      if (hit == null) break;
      r = r.translate(0, hit.bottom + MapMetrics.clusterGap - r.top);
    }
    clusters[c.id] = r;
  }

  // The lane goes on the side of the group with fewer lines leaving it (ties: right).
  bool rightOf(String a, String b) => clusters[b]!.center.dx >= clusters[a]!.center.dx;
  final lanes = <String, bool>{};
  for (final id in inside) {
    var l = 0, r = 0;
    for (final e in g.edges) {
      final a = g.node(e.local)?.cluster;
      final b = g.node(e.other)?.cluster;
      if (a == null || b == null || a == b || (a != id && b != id)) continue;
      final other = a == id ? b : a;
      if (rightOf(id, other)) {
        r++;
      } else {
        l++;
      }
    }
    lanes[id] = r <= l;
  }

  final nodes = <String, Rect>{};
  final slots = <String, List<String>>{};
  for (final c in g.clusters) {
    final r = clusters[c.id]!;
    final ids = slotsOf(c, order[c.id], move != null && g.node(move.node)?.cluster == c.id ? move : null);
    slots[c.id] = ids;
    final x = r.left + MapMetrics.pad + (lanes[c.id] == false ? MapMetrics.lane : 0);
    for (final (i, id) in ids.indexed) {
      nodes[id] =
          Rect.fromLTWH(x, r.top + MapMetrics.slotTop(i), MapMetrics.column - 2 * MapMetrics.pad, MapMetrics.node);
    }
  }

  final anchor = {...nodes, if (floating != null) floating.node: floating.rect};
  final lines = <LineGeometry>[];
  for (final e in g.edges) {
    final a = anchor[e.local];
    final b = anchor[e.other];
    final ca = g.node(e.local)?.cluster;
    final cb = g.node(e.other)?.cluster;
    if (a == null || b == null || ca == null || cb == null) continue;
    if (ca == cb) {
      // An arc in the group's lane: deeper the further apart the two cards are.
      final right = lanes[ca] ?? true;
      final dir = right ? 1.0 : -1.0;
      final depth = math.min(MapMetrics.lane - 14, 14 + (b.center.dy - a.center.dy).abs() * 0.12);
      final k = depth / 0.75;
      final p0 = Offset(right ? a.right + MapMetrics.port : a.left - MapMetrics.port, a.center.dy);
      final p3 = Offset(right ? b.right + MapMetrics.port : b.left - MapMetrics.port, b.center.dy);
      lines.add(LineGeometry(e, p0, p0 + Offset(dir * k, 0), p3 + Offset(dir * k, 0), p3, lane: right));
      continue;
    }
    final right = rightOf(ca, cb);
    final p0 = Offset(right ? a.right + MapMetrics.port : a.left - MapMetrics.port, a.center.dy);
    final p3 = Offset(right ? b.left - MapMetrics.port : b.right + MapMetrics.port, b.center.dy);
    final k = math.max((p3.dx - p0.dx).abs() * 0.5, 48.0) * (right ? 1 : -1);
    lines.add(LineGeometry(e, p0, p0 + Offset(k, 0), p3 - Offset(k, 0), p3));
  }

  final all = clusters.values.fold<Rect?>(null, (u, r) => u == null ? r : u.expandToInclude(r)) ?? Rect.zero;
  return MapLayout(
    clusters: clusters,
    nodes: nodes,
    slots: slots,
    lanes: lanes,
    lines: lines,
    bounds: all.inflate(MapMetrics.margin),
  );
}

/// How a line of each kind is drawn: weight and colour (never dashes).
({Color color, double width}) lineStyle(MapEdgeKind k) => switch (k) {
      MapEdgeKind.configured => (color: XColors.accent, width: 2.0),
      MapEdgeKind.waiting => (color: XColors.textMute.withValues(alpha: 0.75), width: 2.0),
      MapEdgeKind.traffic => (color: XColors.textMute.withValues(alpha: 0.6), width: 1.25),
      MapEdgeKind.team => (color: XColors.agent.withValues(alpha: 0.8), width: 1.25),
    };

/// The lines under the cards, the selected one highlighted, the ones being disconnected faded, and the live line
/// while the owner draws one. Painted in map coordinates shifted by [origin] (the canvas's top-left).
class MapLinesPainter extends CustomPainter {
  MapLinesPainter(this.layout,
      {required this.origin, this.drag, this.highlight, this.selected, this.pending = const {}, required this.palette});
  final MapLayout layout;
  final Offset origin;

  /// The line being drawn: from an anchor to the pointer.
  final (Offset, Offset)? drag;

  /// The line under the pointer, and the selected one (edge keys).
  final String? highlight;
  final String? selected;

  /// Lines whose disconnect is running.
  final Set<String> pending;

  /// The palette the lines were laid out with (repaints when the theme changes).
  final XPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-origin.dx, -origin.dy);
    for (final l in layout.lines) {
      final s = lineStyle(l.edge.kind);
      final key = l.edge.key;
      final color = pending.contains(key) ? s.color.withValues(alpha: s.color.a * 0.35) : s.color;
      final picked = key == selected;
      if (picked) {
        // A soft glow under the selected line.
        canvas.drawPath(
            l.path,
            Paint()
              ..color = s.color.withValues(alpha: 0.22)
              ..strokeWidth = s.width + 10
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
      final paint = Paint()
        ..color = color
        ..strokeWidth = picked ? s.width + 2 : (key == highlight ? s.width + 1.5 : s.width)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(l.path, paint);
      // Recent messages are history: no arrowheads, whatever the counts say.
      if (l.edge.kind == MapEdgeKind.traffic) continue;
      final fill = Paint()..color = color;
      // Where messages without an address go: an arrow into that end (both ends when both sides point at each other).
      if (l.edge.toOther) _arrow(canvas, l.p3, l.c2, fill);
      if (l.edge.toLocal) _arrow(canvas, l.p0, l.c1, fill);
    }
    if (drag case (final from, final to)) {
      final p = Paint()
        ..color = XColors.accent
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final dx = (to.dx - from.dx) * 0.5;
      canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..cubicTo(from.dx + dx, from.dy, to.dx - dx, to.dy, to.dx, to.dy),
          p);
      canvas.drawCircle(to, 4, Paint()..color = XColors.accent);
    }
    canvas.restore();
  }

  /// A small filled arrowhead at [tip], pointing away from [from] (the curve's control point near that end).
  static void _arrow(Canvas canvas, Offset tip, Offset from, Paint paint) {
    final d = tip - from;
    final len = d.distance;
    if (len == 0) return;
    final u = d / len;
    final n = Offset(-u.dy, u.dx);
    final base = tip - u * 8;
    canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(base.dx + n.dx * 4, base.dy + n.dy * 4)
          ..lineTo(base.dx - n.dx * 4, base.dy - n.dy * 4)
          ..close(),
        paint);
  }

  @override
  bool shouldRepaint(MapLinesPainter old) =>
      old.layout != layout ||
      old.origin != origin ||
      old.drag != drag ||
      old.highlight != highlight ||
      old.selected != selected ||
      !setEquals(old.pending, pending) ||
      old.palette != palette;
}
