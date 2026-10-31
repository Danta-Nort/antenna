// SPDX-License-Identifier: AGPL-3.0-only
// How the owner arranged the agent map in this window (D-UI-47): where each group is, the order of the cards in each
// group, the view (zoom and pan) and whether the recent-messages layer shows. Kept in the window's settings file
// (`agent_map` in window.json, appearance.dart), never in the daemon: it is the window's own way of drawing the
// daemon's facts, so another window, another computer and the daemon know nothing of it. Read leniently: a malformed
// entry is dropped, never a reason not to open the map.

import 'dart:ui' show Offset;

/// The view: the zoom ([scale], 0.4–2.0) and where the map's origin is in the canvas ([pan], in screen pixels).
typedef MapView = ({double scale, Offset pan});

const mapMinScale = 0.4;
const mapMaxScale = 2.0;

/// At most this many groups and cards per group are kept: the file stays small however many contacts come and go.
const _maxEntries = 200;

/// A coordinate the map accepts back from the file: finite and within a generous canvas.
bool _sane(Object? v) => v is num && v.isFinite && v.abs() <= 1e6;

final class AgentMapPrefs {
  const AgentMapPrefs({this.clusters = const {}, this.order = const {}, this.view, this.recent = false});

  /// From the settings file's `agent_map` value; anything else gives the defaults.
  factory AgentMapPrefs.fromJson(Object? j) {
    if (j is! Map) return const AgentMapPrefs();
    final clusters = <String, Offset>{};
    if (j['clusters'] case final Map<Object?, Object?> m) {
      for (final e in m.entries.take(_maxEntries)) {
        final v = e.value;
        if (e.key is String && v is List && v.length == 2 && _sane(v[0]) && _sane(v[1])) {
          clusters[e.key as String] = Offset((v[0] as num).toDouble(), (v[1] as num).toDouble());
        }
      }
    }
    final order = <String, List<String>>{};
    if (j['order'] case final Map<Object?, Object?> m) {
      for (final e in m.entries.take(_maxEntries)) {
        final v = e.value;
        if (e.key is String && v is List) {
          order[e.key as String] = [for (final n in v.take(_maxEntries)) if (n is String) n];
        }
      }
    }
    MapView? view;
    if (j['view'] case [final s, final x, final y] when _sane(s) && _sane(x) && _sane(y) && (s as num) > 0) {
      view = (
        scale: s.toDouble().clamp(mapMinScale, mapMaxScale),
        pan: Offset((x as num).toDouble(), (y as num).toDouble()),
      );
    }
    return AgentMapPrefs(clusters: clusters, order: order, view: view, recent: j['recent'] == true);
  }

  /// Each group's top-left corner, in map coordinates, by cluster ID (`here`, `c/<contact>`).
  final Map<String, Offset> clusters;

  /// The order of the cards in a group, by cluster ID: node IDs, first to last.
  final Map<String, List<String>> order;

  /// The last view; `null`: fit the map into the canvas.
  final MapView? view;

  /// The recent-messages layer is shown (off by default).
  final bool recent;

  /// Nothing set: the file gets no `agent_map` entry.
  bool get isEmpty => clusters.isEmpty && order.isEmpty && view == null && !recent;

  AgentMapPrefs copyWith({
    Map<String, Offset>? clusters,
    Map<String, List<String>>? order,
    MapView? view,
    bool clearView = false,
    bool? recent,
  }) =>
      AgentMapPrefs(
        clusters: clusters ?? this.clusters,
        order: order ?? this.order,
        view: clearView ? null : (view ?? this.view),
        recent: recent ?? this.recent,
      );

  Map<String, Object?> toJson() {
    double r(double v) => (v * 10).roundToDouble() / 10;
    return {
      if (clusters.isNotEmpty) 'clusters': {for (final e in clusters.entries) e.key: [r(e.value.dx), r(e.value.dy)]},
      if (order.isNotEmpty) 'order': order,
      if (view case final v?) 'view': [(v.scale * 1000).roundToDouble() / 1000, r(v.pan.dx), r(v.pan.dy)],
      if (recent) 'recent': true,
    };
  }
}
