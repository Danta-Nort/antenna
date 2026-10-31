// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's pieces (CONTROL §30, D-123, D-UI-47; experimental): the legend, the "tasks" mark, a line's label, a
// cluster's card, a node's tile, its handle and a local agent's menu. Everything they show comes from the graph
// (state/agent_map.dart).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart' show AgentConnection;
import '../../state/agent_map.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart' show AgentRef;
import '../widgets/badges.dart';
import '../widgets/profile_picture.dart';
import 'agent_connect_dialog.dart';
import 'agent_map_layout.dart';
import 'agent_map_text.dart';
import 'ai_apps_card.dart' show agoOf;
import 'local_connect_dialog.dart';

/// One line per kind of line, so the map reads without a guide; recent messages only while their layer shows.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key, this.recent = false});
  final bool recent;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget item(MapEdgeKind k, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 12, child: CustomPaint(painter: MapLegendLine(k))),
          const SizedBox(width: 8),
          Text(text, style: XText.meta),
        ]);
    return Wrap(key: const Key('agent-map-legend'), spacing: 24, runSpacing: 8, children: [
      item(MapEdgeKind.configured, l.mapLegendConfigured),
      item(MapEdgeKind.waiting, l.mapLegendWaiting),
      if (recent) item(MapEdgeKind.traffic, l.mapLegendTraffic),
      item(MapEdgeKind.team, l.mapLegendTeam),
      Row(mainAxisSize: MainAxisSize.min, children: [
        const MapTasksMark(),
        const SizedBox(width: 8),
        Text(l.mapLegendTasks, style: XText.meta),
      ]),
    ]);
  }
}

class MapLegendLine extends CustomPainter {
  MapLegendLine(this.kind);
  final MapEdgeKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final s = lineStyle(kind);
    canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        Paint()
          ..color = s.color
          ..strokeWidth = s.width
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(MapLegendLine old) => old.kind != kind;
}

/// The small "tasks" mark: that end takes the other end's messages as tasks.
class MapTasksMark extends StatelessWidget {
  const MapTasksMark({super.key, this.tip});
  final String? tip;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: XColors.accentSoft,
        borderRadius: BorderRadius.circular(XRadius.s),
        border: Border.all(color: XColors.accentLine),
      ),
      child: Text(context.l.mapTasksMark, style: XText.meta.copyWith(color: XColors.accent, fontWeight: FontWeight.w600)),
    );
    return tip == null ? mark : Tooltip(message: tip, child: mark);
  }
}

/// A label on a line: the waiting computer, when the last message went, the team. A tap selects the line.
class MapLinePill extends StatelessWidget {
  const MapLinePill({super.key, required this.text, required this.color, this.onTap});
  final String text;
  final Color color;
  final void Function(Offset global)? onTap;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: XColors.bg1,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Text(text, textAlign: TextAlign.center, maxLines: 3, style: XText.meta.copyWith(color: color)),
    );
    if (onTap == null) return pill;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTapUp: (d) => onTap!(d.globalPosition), child: pill),
    );
  }
}

/// The small circle at the middle of a connection: a bigger target than the line itself. A tap selects the line.
class MapLineDot extends StatelessWidget {
  const MapLineDot({super.key, required this.color, required this.onTap});
  final Color color;
  final void Function(Offset global) onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => onTap(d.globalPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: XColors.bg1,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
            ),
          ),
        ),
      );
}

/// The labels on the lines of [lay] (a tap selects the line: [onPick] with its key and where it was tapped), and the
/// "tasks" marks at their ends; placed in the map's coordinates from the layout's top-left corner. [pending]: lines
/// whose disconnect is running.
List<Widget> mapLineMarks(AppLocalizations l, AgentMapGraph g, MapLayout lay,
    {required DateTime now, required Set<String> pending, required void Function(String key, Offset global) onPick}) {
  final origin = lay.bounds.topLeft;
  final out = <Widget>[];
  for (final line in lay.lines) {
    final e = line.edge;
    final local = g.node(e.local);
    final other = g.node(e.other);
    if (local == null || other == null) continue;
    Widget at(Offset p, double w, Widget child) => Positioned(
        left: p.dx - w / 2 - origin.dx, top: p.dy - 28 - origin.dy, width: w, height: 56, child: Center(child: child));
    void pick(Offset global) => onPick(e.key, global);
    final key = Key('agent-map-line-${e.key}');
    switch (e.kind) {
      case MapEdgeKind.waiting:
        out.add(at(line.mid, 132,
            MapLinePill(key: key, text: l.mapWaitingOn(e.waitingOn ?? ''), color: XColors.textMute, onTap: pick)));
      case MapEdgeKind.traffic:
        final when = agoOf(l, DateTime.fromMillisecondsSinceEpoch(e.lastMs ?? 0), now);
        final label = MapLinePill(key: key, text: l.mapTrafficLabel(when), color: XColors.textMute, onTap: pick);
        out.add(at(line.mid, 132, label));
      case MapEdgeKind.team:
        out.add(at(line.mid, 140, MapLinePill(key: key, text: e.team ?? '', color: XColors.agent, onTap: pick)));
      case MapEdgeKind.configured:
        final mid = line.mid - origin;
        out.add(Positioned(
          left: mid.dx - 10,
          top: mid.dy - 10,
          width: 20,
          height: 20,
          child: MapLineDot(key: key, color: pending.contains(e.key) ? XColors.textMute : XColors.accent, onTap: pick),
        ));
    }
    if (!e.removable) continue;
    if (e.tasksLocal) {
      out.add(at(
          line.tasksAt(start: true),
          64,
          MapTasksMark(
              key: Key('agent-map-tasks-${e.key}-here'),
              tip: l.mapTasksTip(local.name, e.inside ? other.name : (other.contact ?? '')))));
    }
    if (e.tasksOther) {
      out.add(at(
          line.tasksAt(start: false),
          64,
          MapTasksMark(
              key: Key('agent-map-tasks-${e.key}-there'),
              tip: e.inside ? l.mapTasksTip(other.name, local.name) : l.mapTasksTipThere(other.name))));
    }
  }
  return out;
}

/// A computer or a contact: a rounded card with its header (the handle to move the whole group); the nodes are laid
/// over it. An own computer that has not reported itself says so.
class MapClusterBox extends StatelessWidget {
  const MapClusterBox(this.c, {super.key, this.moving = false});
  final MapCluster c;

  /// Being dragged: lifted.
  final bool moving;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final linux = c.kind == MapClusterKind.here
        ? m.devices?.self.os == 'linux' || !(m.agentHost?.macos ?? true)
        : m.ownDevices.where((d) => d.contact == c.title).firstOrNull?.status?.os == 'linux';
    final presence = c.online == null ? null : (c.online! ? l.devicesOnline : l.devicesOffline);
    final (String title, Widget? badge, String? meta) = switch (c.kind) {
      MapClusterKind.here => (l.devicesThisComputer, null, c.title.isEmpty ? null : c.title),
      MapClusterKind.ownComputer => (
          c.title,
          const TrustBadge(5, size: 16),
          c.reportMissing ? [l.mapReportMissing, ?presence].join(' · ') : presence
        ),
      MapClusterKind.contact => (c.title, TrustBadge(c.trust, size: 16), presence),
    };
    // An own computer's picture as My devices shows it; otherwise the computer or person icon.
    final own = c.kind == MapClusterKind.ownComputer ? m.pictureOfContactLabel(c.title) : null;
    final face = own != null
        ? PictureFace(own, size: 24, label: c.title)
        : Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: c.kind == MapClusterKind.contact ? XColors.bg2 : XColors.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              c.kind == MapClusterKind.contact
                  ? Icons.person_outline
                  : (linux ? Icons.dns_outlined : Icons.laptop_mac_outlined),
              size: 14,
              color: c.kind == MapClusterKind.contact ? XColors.textDim : XColors.accent,
            ),
          );
    Widget metaText = Text(meta ?? '', style: XText.meta);
    if (c.reportMissing) {
      metaText = Tooltip(
        message: l.mapReportMissingTip(c.title),
        child: Text(meta ?? '',
            key: Key('agent-map-report-missing-${c.id}'), style: XText.meta.copyWith(color: XColors.warn)),
      );
    }
    return Container(
      key: Key('agent-map-cluster-${c.id}'),
      decoration: xPanel(
        fill: XColors.bg1,
        border: moving ? XColors.accent : (c.kind == MapClusterKind.here ? XColors.accentLine : XColors.line),
        radius: XRadius.l,
        glow: moving ? 1.6 : 0.6,
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: 24,
        child: Row(children: [
          face,
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(children: [
                Text(title, style: XText.body.copyWith(fontWeight: FontWeight.w600)),
                if (badge != null) ...[const SizedBox(width: 8), badge],
              ]),
            ),
          ),
          if (meta != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: metaText),
            ),
          ],
        ]),
      ),
    );
  }
}

enum MapTileState { normal, source, valid, over }

/// One agent or person: its picture with a status dot, the name, the kind line; this computer's agents have a menu.
class MapNodeTile extends StatelessWidget {
  const MapNodeTile(this.n, {super.key, required this.kind, required this.state, this.menu, this.moving = false});
  final MapNode n;
  final String kind;
  final MapTileState state;
  final Widget? menu;

  /// Being dragged to another slot: lifted.
  final bool moving;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    // The same pictures as everywhere else: an agent's through AgentAvatar (mine by name, a contact's by its link), a
    // person's the contact's, the owner's own one.
    final mine = n.kind == MapNodeKind.you ? m.pictureOfMine() : null;
    final picture = switch (n.kind) {
      MapNodeKind.local => AgentAvatar(AgentRef(n.name, mine: true), size: 32),
      MapNodeKind.device || MapNodeKind.contactAgent => AgentAvatar(AgentRef(n.name, contact: n.contact), size: 32),
      MapNodeKind.person => XAvatar(n.name, size: 32, picture: m.pictureOfContactLabel(n.name)),
      MapNodeKind.you when mine != null => XAvatar(l.approvalsYou, size: 32, picture: mine),
      MapNodeKind.you => Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
          child: Icon(Icons.person_outline, size: 18, color: XColors.accent),
        ),
    };
    final why = mapWhyNot(l, n);
    final hot = state == MapTileState.over || state == MapTileState.source || moving;
    final tile = Container(
      key: Key('agent-map-node-${n.id}'),
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
      decoration: BoxDecoration(
        color: state == MapTileState.normal || state == MapTileState.source ? XColors.bg2 : XColors.accentSoft,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(
          color: hot ? XColors.accent : (state == MapTileState.valid ? XColors.accentLine : XColors.line),
          width: hot ? 2 : 1,
        ),
        boxShadow: moving ? [BoxShadow(color: XColors.shadow, blurRadius: 16, offset: const Offset(0, 4))] : null,
      ),
      child: Row(children: [
        SizedBox(
          width: 32,
          height: 32,
          child: Stack(clipBehavior: Clip.none, children: [
            picture,
            if (n.live case final live?)
              Positioned(right: -2, top: -2, child: PresenceDot(key: Key('agent-map-dot-${n.id}'), online: live, size: 10)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(mapNodeName(l, n), maxLines: 1, style: XText.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(kind, maxLines: 1, style: XText.meta.copyWith(color: why == null ? XColors.textDim : XColors.textMute)),
            ),
          ]),
        ),
        if (why != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.link_off_rounded, size: 16, color: XColors.textMute),
          ),
        ?menu,
      ]),
    );
    return why == null ? tile : Tooltip(message: why, child: tile);
  }
}

/// A handle (port) on a card's side: dragging from it draws a line; the card's body moves the card.
class MapHandle extends StatelessWidget {
  const MapHandle({super.key, required this.active});

  /// A line is being drawn from it.
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: context.l.mapHandleTip,
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: active ? XColors.accent : XColors.bg1,
                shape: BoxShape.circle,
                border: Border.all(color: XColors.accent, width: 2),
              ),
            ),
          ),
        ),
      );
}

/// A local agent's menu: Connect to… (the keyboard path to the same dialogs) and Disconnect… for its counterpart.
class MapNodeMenu extends StatelessWidget {
  const MapNodeMenu(this.n, {super.key, required this.graph, required this.local, this.onDone});
  final MapNode n;
  final AgentMapGraph graph;

  /// The daemon knows connections between two agents of this computer.
  final bool local;

  /// A dialog closed with this outcome (the map's status strip says it too).
  final void Function(String agent, String other, String computer, ConnectOutcome? outcome, {required bool disconnect})?
      onDone;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final cp = m.agents.where((a) => a.name == n.name).firstOrNull?.counterpart;
    return SizedBox(
      width: 28,
      height: 28,
      child: PopupMenuButton<String>(
        key: Key('agent-map-menu-${n.name}'),
        tooltip: l.mapNodeMenu(n.name),
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(Icons.more_horiz, size: 16, color: XColors.textDim),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'connect', key: Key('agent-map-connect-to-${n.name}'), child: Text(l.mapConnectTo)),
          if (cp != null)
            PopupMenuItem(value: 'disconnect', key: Key('agent-map-disconnect-${n.name}'), child: Text(l.mapDisconnect)),
        ],
        onSelected: (v) async {
          if (v == 'connect') {
            final other = await showCounterpartPicker(context, graph: graph, local: n, here: local);
            if (other == null || !context.mounted) return;
            if (other.here) {
              final out = await showLocalConnectDialog(context, from: n, to: other);
              onDone?.call(n.name, other.name, '', out, disconnect: false);
            } else {
              final out = await showAgentConnectDialog(context, graph: graph, local: n, other: other);
              onDone?.call(n.name, mapEndName(l, other), other.contact ?? '', out, disconnect: false);
            }
          } else if (cp != null && cp.local) {
            final out = await showLocalDisconnectDialog(context, agent: n.name, other: cp.agent ?? '');
            onDone?.call(n.name, cp.agent ?? '', '', out, disconnect: true);
          } else if (cp != null) {
            final other = graph.node(remoteNodeId(cp.contact, cp.agent));
            final out = await showAgentDisconnectDialog(context,
                agent: n.name,
                contact: cp.contact,
                peerAgent: cp.agent,
                own: other != null && graph.own(other),
                onlyThere: false);
            onDone?.call(n.name, cp.agent ?? l.mapPersonOf(cp.contact), cp.contact, out, disconnect: true);
          }
        },
      ),
    );
  }
}
