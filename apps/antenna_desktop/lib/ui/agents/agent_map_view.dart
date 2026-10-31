// SPDX-License-Identifier: AGPL-3.0-only
// Agents → Map (CONTROL §30, D-123, D-UI-38, D-UI-47; experimental): an editor of who works with whom. The owner's
// other computers on the left, this computer in the middle, the contacts on the right, as long as the owner leaves
// them there: groups and cards move where the owner drags them, and the window remembers it (its settings file, never
// the daemon). Dragging from a card's handle draws a line: to another computer's agent or person, or (a daemon that
// knows local connections) to another agent of this computer; nothing is sent before the owner confirms in the
// dialog. Clicking a line selects it: a popover says what it means, with Disconnect; Delete or Backspace does the
// same. Recent messages are history, an optional layer that is off by default and can never be disconnected. Every
// action says how it went in the status strip. Everything drawn comes from the daemon (state/agent_map.dart); the
// window keeps only how it is arranged.

import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart' show OtherSideState;
import '../../state/agent_map.dart';
import '../../state/agent_map_prefs.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../widgets/experimental_tag.dart';
import 'agent_connect_dialog.dart';
import 'agent_map_canvas.dart';
import 'agent_map_layout.dart';
import 'agent_map_popover.dart';
import 'agent_map_text.dart';
import 'agent_map_widgets.dart';
import 'local_connect_dialog.dart';

class AgentMapView extends StatefulWidget {
  const AgentMapView({super.key});

  @override
  State<AgentMapView> createState() => AgentMapViewState();
}

class AgentMapViewState extends State<AgentMapView> {
  final _view = MapViewController();
  final _focus = FocusNode(debugLabel: 'agent-map');
  final _canvas = GlobalKey();
  AppModel? _model;
  Appearance? _look;
  AgentMapPrefs _prefs = const AgentMapPrefs();
  bool _loaded = false;

  AgentMapGraph? _graph;
  MapLayout? _layout;

  /// Fit the map whenever its extent changes, until the owner moves the view (no saved view yet).
  bool _autoFit = true;
  Rect? _fittedFor;
  bool _fitNext = false;

  // Drawing a line from a handle (map coordinates).
  String? _lineFrom;
  Offset? _lineAt;

  // Moving a group, or a card within its group.
  String? _moveCluster;
  Offset? _clusterAt;
  String? _moveNode;
  Rect? _nodeRect;
  int _nodeSlot = 0;
  Offset _grab = Offset.zero;

  // The selected line (and where it was clicked, in map coordinates); the line under the pointer.
  String? _selected;
  Offset? _selectedAt;
  String? _hot;
  Offset? _hoverAt;

  /// Lines whose disconnect is running: drawn faded.
  final _pending = <String>{};
  MapStatus? _status;
  Timer? _statusTimer;
  Timer? _saveTimer;

  /// The current layout and view, for tests that click a line where it is drawn.
  @visibleForTesting
  MapLayout? get layout => _layout;
  @visibleForTesting
  MapViewController get view => _view;

  /// Where [map] (map coordinates) is on the screen.
  @visibleForTesting
  Offset globalOf(Offset map) => _box.localToGlobal(_view.toCanvas(map));

  @override
  void initState() {
    super.initState();
    _view.addListener(_onView);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final m = AppScope.read(context);
      _model = m..watchAgentMap();
      unawaited(m.refreshAgentMap());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _look = AppearanceScope.read(context);
    _prefs = _look?.agentMap ?? const AgentMapPrefs();
    _autoFit = _prefs.view == null;
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) _save(_prefs.copyWith(view: _view.view));
    _saveTimer?.cancel();
    _statusTimer?.cancel();
    _model?.unwatchAgentMap();
    _view
      ..removeListener(_onView)
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onView() {
    if (mounted) setState(() {});
  }

  RenderBox get _box => _canvas.currentContext!.findRenderObject()! as RenderBox;
  Offset _mapOf(Offset global) => _view.toMap(_box.globalToLocal(global));

  void _save(AgentMapPrefs p) {
    _prefs = p;
    _look?.agentMap = p;
  }

  /// The owner moved the view: keep it (once the gesture settles).
  void _viewMoved() {
    _autoFit = false;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () => _save(_prefs.copyWith(view: _view.view)));
  }

  void _say(MapStatus? s) {
    _statusTimer?.cancel();
    setState(() => _status = s);
    // Information and success fade; a refusal stays until it is closed or replaced.
    if (s != null && (s.kind == MapStatusKind.info || s.kind == MapStatusKind.done)) {
      _statusTimer = Timer(const Duration(seconds: 8), () => mounted ? setState(() => _status = null) : null);
    }
  }

  /// What a dialog or a disconnect ended with, in the status strip.
  void _report(String a, String b, String computer, ConnectOutcome? out, {required bool disconnect}) {
    if (out == null || !mounted) return;
    final l = context.l;
    final reply = out.reply;
    if (reply == null) {
      final e = out.error;
      _say(MapStatus(
        MapStatusKind.failed,
        disconnect ? l.mapStatusDisconnectFailed(a, b) : l.mapStatusConnectFailed(a, b),
        detail: e == null ? null : localErrorText(l, e),
      ));
      return;
    }
    final side = reply.otherSide;
    final id = side.id;
    _say(MapStatus(
      MapStatusKind.done,
      disconnect ? l.mapStatusDisconnected(a, b) : l.mapStatusConnected(a, b),
      detail: otherSideLine(l, side, computer),
      action: side.state == OtherSideState.requested && id != null ? l.mapConnectApproveNow : null,
      onAction: side.state == OtherSideState.requested && id != null
          ? () => showDeviceRequestDialog(context, contact: computer, id: id)
          : null,
    ));
  }

  // Drawing a line.

  void _lineStart(String node, Offset global) {
    if (!(_model?.connectionsSupported ?? false)) return;
    setState(() {
      _deselect();
      _lineFrom = node;
      _lineAt = _mapOf(global);
    });
  }

  void _lineMove(Offset global) {
    if (_lineFrom == null) return;
    setState(() => _lineAt = _mapOf(global));
  }

  String? _target() {
    final at = _lineAt;
    return at == null ? null : _layout?.nodeAt(at, slop: MapMetrics.pad);
  }

  Future<void> _lineEnd() async {
    final from = _lineFrom;
    final to = _target();
    setState(() {
      _lineFrom = null;
      _lineAt = null;
    });
    final g = _graph;
    final m = _model;
    if (from == null || to == null || g == null || m == null) return;
    final l = context.l;
    switch (checkDrop(g, from, to, localRoutes: m.localConnectionsSupported)) {
      case DropConnect(:final local, :final other):
        final out = await showAgentConnectDialog(context, graph: g, local: local, other: other);
        _report(local.name, mapEndName(l, other), other.contact ?? '', out, disconnect: false);
      case DropConnectLocal(:final from, :final to):
        final out = await showLocalConnectDialog(context, from: from, to: to);
        _report(from.name, to.name, '', out, disconnect: false);
      case final DropNote n:
        _say(MapStatus(MapStatusKind.info, dropNoteText(l, n)));
      case null:
        break;
    }
  }

  void _lineCancel() => setState(() {
        _lineFrom = null;
        _lineAt = null;
      });

  // Moving groups and cards.

  void _clusterStart(String id, Offset global) {
    final r = _layout?.clusters[id];
    if (r == null) return;
    final at = _mapOf(global);
    setState(() {
      _deselect();
      // The owner arranges the map now: it is not fitted again under the pointer.
      _autoFit = false;
      _moveCluster = id;
      _grab = at - r.topLeft;
      _clusterAt = r.topLeft;
    });
  }

  void _clusterMove(Offset global) {
    if (_moveCluster == null) return;
    setState(() => _clusterAt = _mapOf(global) - _grab);
  }

  void _clusterEnd() {
    final lay = _layout;
    if (_moveCluster == null || lay == null) return;
    // From the first move on, every group stays where it is drawn now: nothing jumps when another one comes or goes.
    final now = {for (final e in lay.clusters.entries) e.key: e.value.topLeft};
    _save(_prefs.copyWith(clusters: _capped({..._prefs.clusters, ...now})));
    setState(() {
      _moveCluster = null;
      _clusterAt = null;
    });
  }

  /// The groups this window knows, those on the map now first, at most 200.
  Map<String, Offset> _capped(Map<String, Offset> all) {
    final now = _layout?.clusters.keys.toSet() ?? const <String>{};
    final keep = [...all.keys.where(now.contains), ...all.keys.where((k) => !now.contains(k))].take(200);
    return {for (final k in keep) k: all[k]!};
  }

  void _nodeStart(String id, Offset global) {
    final lay = _layout;
    final g = _graph;
    final r = lay?.nodes[id];
    final n = g?.node(id);
    if (lay == null || r == null || n == null) return;
    setState(() {
      _deselect();
      _autoFit = false;
      _moveNode = id;
      _grab = _mapOf(global) - r.topLeft;
      _nodeRect = r;
      _nodeSlot = lay.slots[n.cluster]?.indexOf(id) ?? 0;
    });
  }

  void _nodeMove(Offset global) {
    final id = _moveNode;
    final r = _nodeRect;
    final n = id == null ? null : _graph?.node(id);
    if (n == null || r == null) return;
    final top = _mapOf(global) - _grab;
    setState(() {
      _nodeRect = top & r.size;
      _nodeSlot = _layout?.slotAt(n.cluster, top.dy) ?? _nodeSlot;
    });
  }

  void _nodeEnd() {
    final id = _moveNode;
    final r = _nodeRect;
    final n = id == null ? null : _graph?.node(id);
    final lay = _layout;
    setState(() {
      _moveNode = null;
      _nodeRect = null;
    });
    if (n == null || r == null || lay == null) return;
    final over = lay.clusterAt(r.center);
    if (over != null && over != n.cluster) {
      // An agent belongs to its computer: a drop on another group changes nothing and says why.
      _say(MapStatus(MapStatusKind.info, context.l.mapMoveStays));
      return;
    }
    final slots = lay.slots[n.cluster];
    if (slots == null) return;
    _save(_prefs.copyWith(order: {..._prefs.order, n.cluster: slots}));
  }

  void _nodeCancel() => setState(() {
        _moveNode = null;
        _nodeRect = null;
      });

  // The view.

  void _fit() {
    final lay = _layout;
    if (lay == null) return;
    _view.fit(lay.content.inflate(16));
    _saveTimer?.cancel();
    _save(_prefs.copyWith(view: _view.view));
  }

  void _arrange() {
    setState(() {
      _deselect();
      _prefs = _prefs.copyWith(clusters: const {}, order: const {});
      _fitNext = true;
    });
  }

  void _zoom(double factor) {
    _view.zoomCenter(factor);
    _viewMoved();
  }

  void _setRecent(bool on) {
    setState(() {
      _deselect();
      _save(_prefs.copyWith(recent: on));
    });
  }

  // Selecting and disconnecting lines.

  void _deselect() {
    _selected = null;
    _selectedAt = null;
  }

  void _select(String key, Offset map) {
    setState(() {
      _selected = key;
      _selectedAt = map;
      _hot = null;
    });
    _focus.requestFocus();
  }

  void _tap(Offset canvas) {
    final lay = _layout;
    if (lay == null) return;
    final at = _view.toMap(canvas);
    final line = lay.lineAt(at, slop: 8 / _view.scale);
    if (line != null) {
      _select(line.edge.key, at);
    } else if (_selected != null) {
      setState(_deselect);
    }
  }

  void _hover(Offset canvas) {
    if (_lineFrom != null || _moveCluster != null || _moveNode != null) return;
    final line = _layout?.lineAt(_view.toMap(canvas), slop: 6 / _view.scale);
    final key = line?.edge.key;
    if (key == _hot && (key == null || ((_hoverAt ?? Offset.zero) - canvas).distance < 4)) return;
    setState(() {
      _hot = key;
      _hoverAt = canvas;
    });
  }

  MapEdge? _edge(String? key) => key == null ? null : _graph?.edges.where((e) => e.key == key).firstOrNull;

  /// Disconnect [e] with the defaults: the popover's Disconnect, or Delete.
  Future<void> _disconnect(MapEdge e) async {
    final g = _graph;
    final m = _model;
    if (g == null || m == null) return;
    final req = defaultDisconnectFor(g, e);
    final a = g.node(e.local);
    final b = g.node(e.other);
    if (req == null || a == null || b == null || _pending.contains(e.key)) return;
    final l = context.l;
    final an = mapEndName(l, a);
    final bn = mapEndName(l, b);
    setState(() {
      _deselect();
      _pending.add(e.key);
    });
    _say(MapStatus(MapStatusKind.pending, l.mapStatusDisconnecting(an, bn)));
    final out = await m.disconnectLine(req);
    if (!mounted) return;
    setState(() => _pending.remove(e.key));
    _report(an, bn, e.inside ? '' : (b.contact ?? ''), out, disconnect: true);
  }

  /// Options…: today's disconnect dialog with its choices.
  Future<void> _options(MapEdge e) async {
    final g = _graph;
    final a = g?.node(e.local);
    final b = g?.node(e.other);
    if (g == null || a == null || b == null) return;
    final l = context.l;
    setState(_deselect);
    if (e.inside) {
      final out = await showLocalDisconnectDialog(context, agent: a.name, other: b.name);
      _report(a.name, b.name, '', out, disconnect: true);
    } else {
      final out = await showAgentDisconnectDialog(context,
          agent: a.name, contact: b.contact ?? '', peerAgent: b.agentName, own: g.own(b), onlyThere: !e.toOther);
      _report(a.name, mapEndName(l, b), b.contact ?? '', out, disconnect: true);
    }
  }

  KeyEventResult _key(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape && _selected != null) {
      setState(_deselect);
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _selected != null) {
      // Recent messages, a team and a line set on another computer have nothing to disconnect: the key does nothing.
      final edge = _edge(_selected);
      if (edge != null && _graph != null && defaultDisconnectFor(_graph!, edge) != null) unawaited(_disconnect(edge));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final full = agentMapOf(m);
    final g = _prefs.recent
        ? full
        : AgentMapGraph(full.clusters, [for (final e in full.edges) if (e.kind != MapEdgeKind.traffic) e]);
    _graph = g;
    final supported = m.connectionsSupported;
    final lay = layoutAgentMap(
      g,
      positions: {..._prefs.clusters, if (_moveCluster != null && _clusterAt != null) _moveCluster!: _clusterAt!},
      order: _prefs.order,
      move: _moveNode == null ? null : (node: _moveNode!, slot: _nodeSlot),
      floating: _moveNode != null && _nodeRect != null ? (node: _moveNode!, rect: _nodeRect!) : null,
    );
    _layout = lay;
    if (_selected != null && !lay.lines.any((x) => x.edge.key == _selected)) _deselect();
    if (_hot != null && !lay.lines.any((x) => x.edge.key == _hot)) _hot = null;
    final content = lay.content.inflate(16);
    if (_view.placed && (_fitNext || (_autoFit && content != _fittedFor))) {
      final arranged = _fitNext;
      _fitNext = false;
      _fittedFor = content;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _view.fit(content);
        if (arranged) _save(_prefs.copyWith(view: _view.view));
      });
    }

    return Column(key: const Key('agent-map'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 1), child: ExperimentalTag(key: Key('experimental-agent-map'))),
        const SizedBox(width: 12),
        Expanded(
            child: Text(supported ? l.mapHint : l.mapAbsent,
                key: supported ? null : const Key('agent-map-absent'),
                style: supported ? XText.bodyDim : XText.bodyDim.copyWith(color: XColors.warn))),
      ]),
      const SizedBox(height: 12),
      MapLegend(recent: _prefs.recent),
      const SizedBox(height: 12),
      Expanded(
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: XColors.bg0,
            borderRadius: BorderRadius.circular(XRadius.l),
            border: Border.all(color: XColors.line),
          ),
          child: MapViewport(
            key: _canvas,
            controller: _view,
            origin: lay.bounds.topLeft,
            mapSize: lay.bounds.size,
            focusNode: _focus,
            onKey: _key,
            onTap: _tap,
            onHover: _hover,
            onExit: () {
              if (_hot != null) setState(() => _hot = null);
            },
            onViewChanged: _viewMoved,
            onPlace: () {
              if (_prefs.view case final v?) {
                _view.set(v.scale, v.pan, notify: false);
              } else {
                _view.fit(content, notify: false);
                _fittedFor = content;
              }
              // The controls show the level the canvas was placed at.
              WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
            },
            map: _map(context, m, g, lay, supported),
            overlays: _overlays(context, m, g, lay),
          ),
        ),
      ),
    ]);
  }

  /// The map itself, in map coordinates from the layout's top-left corner.
  Widget _map(BuildContext context, AppModel m, AgentMapGraph g, MapLayout lay, bool supported) {
    final origin = lay.bounds.topLeft;
    Rect at(Rect r) => r.shift(-origin);
    final moving = _moveNode;
    return Stack(clipBehavior: Clip.none, children: [
      for (final c in g.clusters)
        if (lay.clusters[c.id] case final r?)
          Positioned.fromRect(rect: at(r), child: _clusterHandle(c, MapClusterBox(c, moving: _moveCluster == c.id))),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: MapLinesPainter(lay,
                origin: origin,
                palette: XColors.palette,
                highlight: _hot,
                selected: _selected,
                pending: {..._pending},
                drag: _liveLine(lay)),
          ),
        ),
      ),
      for (final n in g.nodes)
        if (n.id != moving)
          if (lay.nodes[n.id] case final r?) Positioned.fromRect(rect: at(r), child: _node(m, g, n, supported)),
      ...mapLineMarks(context.l, g, lay,
          now: m.now(), pending: _pending, onPick: (key, global) => _select(key, _mapOf(global))),
      if (supported && _moveNode == null) ..._handles(g, lay),
      if (moving != null && _nodeRect != null && g.node(moving) != null)
        Positioned.fromRect(rect: at(_nodeRect!), child: _node(m, g, g.node(moving)!, supported)),
    ]);
  }

  /// The line being drawn: from the side of its card nearer the pointer, to the pointer.
  (Offset, Offset)? _liveLine(MapLayout lay) {
    final from = _lineFrom;
    final at = _lineAt;
    final r = from == null ? null : lay.nodes[from];
    if (r == null || at == null) return null;
    final right = at.dx >= r.center.dx;
    return (Offset(right ? r.right : r.left, r.center.dy), at);
  }

  Widget _clusterHandle(MapCluster c, Widget child) => MouseRegion(
        cursor: _moveCluster == c.id ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
        child: GestureDetector(
          supportedDevices: mapDragDevices,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _clusterStart(c.id, d.globalPosition),
          onPanUpdate: (d) => _clusterMove(d.globalPosition),
          onPanEnd: (_) => _clusterEnd(),
          onPanCancel: () => setState(() {
            _moveCluster = null;
            _clusterAt = null;
          }),
          child: child,
        ),
      );

  Widget _node(AppModel m, AgentMapGraph g, MapNode n, bool supported) {
    final from = _lineFrom;
    final target = from == null ? null : _target();
    final drop = from == null || from == n.id
        ? null
        : checkDrop(g, from, n.id, localRoutes: m.localConnectionsSupported);
    final valid = drop is DropConnect || drop is DropConnectLocal;
    final tile = MapNodeTile(
      n,
      kind: mapNodeKind(context.l, m, AppearanceScope.maybeOf(context), n),
      moving: _moveNode == n.id,
      state: from == n.id
          ? MapTileState.source
          : (valid ? (target == n.id ? MapTileState.over : MapTileState.valid) : MapTileState.normal),
      menu: n.kind == MapNodeKind.local && n.connectable && supported
          ? MapNodeMenu(n, graph: g, local: m.localConnectionsSupported, onDone: _menuDone)
          : null,
    );
    return MouseRegion(
      cursor: _moveNode == n.id ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      child: GestureDetector(
        supportedDevices: mapDragDevices,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (d) => _nodeStart(n.id, d.globalPosition),
        onPanUpdate: (d) => _nodeMove(d.globalPosition),
        onPanEnd: (_) => _nodeEnd(),
        onPanCancel: _nodeCancel,
        child: tile,
      ),
    );
  }

  void _menuDone(String agent, String other, String computer, ConnectOutcome? out, {required bool disconnect}) =>
      _report(agent, other, computer, out, disconnect: disconnect);

  /// The handles (ports) of every card a line can start from.
  List<Widget> _handles(AgentMapGraph g, MapLayout lay) {
    final origin = lay.bounds.topLeft;
    return [
      for (final n in g.nodes)
        if (n.connectable && lay.nodes[n.id] != null)
          for (final right in lay.handleSides(g, n.id))
            Positioned(
              left: (right ? lay.nodes[n.id]!.right : lay.nodes[n.id]!.left) - 8 - origin.dx,
              top: lay.nodes[n.id]!.center.dy - 8 - origin.dy,
              width: 16,
              height: 16,
              child: GestureDetector(
                key: Key('agent-map-handle-${n.id}-${right ? 'r' : 'l'}'),
                supportedDevices: mapDragDevices,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (d) => _lineStart(n.id, d.globalPosition),
                onPanUpdate: (d) => _lineMove(d.globalPosition),
                onPanEnd: (_) => unawaited(_lineEnd()),
                onPanCancel: _lineCancel,
                child: MapHandle(active: _lineFrom == n.id),
              ),
            ),
    ];
  }

  /// On top of the canvas: the popover of the selected line, the hover tip, the controls, the status strip.
  List<Widget> _overlays(BuildContext context, AppModel m, AgentMapGraph g, MapLayout lay) {
    final l = context.l;
    final size = _view.size;
    final out = <Widget>[];
    final picked = _edge(_selected);
    if (picked != null && _selectedAt != null) {
      final text = mapLineText(l, g, picked, m.now());
      final req = defaultDisconnectFor(g, picked);
      out.add(Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: MapPopoverLayout(_view.toCanvas(_selectedAt!)),
          child: MapLinePopover(
            title: text.title,
            facts: text.facts,
            onClose: () => setState(_deselect),
            onDisconnect: req == null ? null : () => unawaited(_disconnect(picked)),
            onOptions: req == null ? null : () => unawaited(_options(picked)),
            onApprove: picked.kind == MapEdgeKind.waiting && picked.requestId != null && picked.waitingOn != null
                ? () => showDeviceRequestDialog(context, contact: picked.waitingOn!, id: picked.requestId!)
                : null,
          ),
        ),
      ));
    }
    final hot = _edge(_hot);
    if (hot != null && _hot != _selected && _hoverAt != null) {
      final text = mapLineText(l, g, hot, m.now());
      out.add(Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: MapPopoverLayout(_hoverAt!, gap: 20),
          child: MapLineTip(title: text.title, facts: text.facts),
        ),
      ));
    }
    out.add(Positioned(
      top: 12,
      right: 12,
      child: MapLayoutControls(recent: _prefs.recent, onRecent: _setRecent, onArrange: _arrange),
    ));
    out.add(Positioned(
      bottom: 12,
      right: 12,
      child: MapZoomControls(
        scale: _view.scale,
        onZoomIn: () => _zoom(1.2),
        onZoomOut: () => _zoom(1 / 1.2),
        onReset: () => _zoom(1 / _view.scale),
        onFit: _fit,
      ),
    ));
    if (_status case final s?) {
      // Beside the zoom controls when there is room, above them otherwise.
      final wide = size.width >= 760;
      out.add(Positioned(
        left: 12,
        right: wide ? 320 : 12,
        bottom: wide ? 12 : 64,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: MapStatusStrip(s, onClose: () => _say(null)),
        ),
      ));
    }
    return out;
  }
}
