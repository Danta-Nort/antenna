// SPDX-License-Identifier: AGPL-3.0-only
// What sits on top of the agent map's canvas (D-UI-47): a line's popover (what the line means, in words, and what can
// be done with it), the hover tip, the status strip that says how every action went (running, done, refused with the
// reason) and the canvas's controls (zoom, Fit, Arrange automatically, Show recent messages). Every word about a line
// comes from the graph, so the popover, the tip and the dialogs say the same thing.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart' show OtherSide, OtherSideState;
import '../../state/agent_map.dart';
import '../../theme/x_theme.dart';
import '../widgets/x_buttons.dart';
import 'agent_map_text.dart';
import 'ai_apps_card.dart' show agoOf;

/// A line in words: a title (its two ends, where they are) and what it does, one fact per line.
({String title, List<String> facts}) mapLineText(AppLocalizations l, AgentMapGraph g, MapEdge e, DateTime now) {
  final a = g.node(e.local);
  final b = g.node(e.other);
  if (a == null || b == null) return (title: '', facts: const []);
  final an = mapEndName(l, a);
  final bn = mapEndName(l, b);
  final where = e.inside ? l.devicesThisComputer : (b.person ? null : b.contact);
  final suffix = where == null ? '' : ' · $where';
  switch (e.kind) {
    case MapEdgeKind.traffic:
      final when = agoOf(l, DateTime.fromMillisecondsSinceEpoch(e.lastMs ?? 0), now);
      return (
        title: '${l.mapTrafficTitle(an, bn)}$suffix',
        facts: [l.mapTrafficCounts(e.sent, e.received, when), l.mapTrafficNotLine, l.mapTrafficHow(a.name)],
      );
    case MapEdgeKind.team:
      return (title: '$an → $bn', facts: [l.mapTeamLine(a.name, e.team ?? '', b.name)]);
    case MapEdgeKind.configured || MapEdgeKind.waiting:
      final arrow = e.mutual ? '↔' : (e.toOther ? '→' : '←');
      final contact = b.contact ?? '';
      return (
        title: '$an $arrow $bn$suffix',
        facts: [
          if (e.kind == MapEdgeKind.waiting) l.mapWaitingOn(e.waitingOn ?? contact),
          if (e.toOther)
            e.inside
                ? l.mapConnectPeerLine(a.name, b.name)
                : (b.person ? l.mapConnectHerePerson(a.name, b.name) : l.mapConnectHereLine(a.name, b.name, contact)),
          if (e.toLocal) l.mapConnectPeerLine(b.name, an),
          if (e.tasksLocal) l.mapTasksTip(a.name, e.inside ? b.name : contact),
          if (e.tasksOther) e.inside ? l.mapTasksTip(b.name, a.name) : l.mapTasksTipThere(b.name),
          if (!e.toOther && !e.inside) l.mapSetThere(contact),
          if (e.inside) l.mapLocalDropsUnread,
        ],
      );
  }
}

/// What became of the other side, in one line; `null` when there is nothing to add (both sides on this computer).
String? otherSideLine(AppLocalizations l, OtherSide s, String computer) => switch (s.state) {
      OtherSideState.requested => l.mapConnectRequested(computer),
      OtherSideState.unchanged => l.mapConnectUnchanged(computer),
      OtherSideState.contactDecides => l.mapConnectContactDecides(computer),
      OtherSideState.person => l.mapConnectPersonSide(computer),
      OtherSideState.notAsked => l.mapConnectNotAsked(computer),
      OtherSideState.unsupported => l.mapConnectUnsupported(computer),
      OtherSideState.unreachable => l.mapConnectUnreachable(computer),
      OtherSideState.refused => l.mapConnectRefused(computer, [s.message, s.code].whereType<String>().join(' · ')),
      OtherSideState.local => null,
      final x => l.mapConnectOtherState(x),
    };

/// Places a popover or a tip by [anchor] (canvas coordinates): centred under it, above it when there is no room
/// below, always inside the canvas. Under it rather than beside it, so the line's two ends stay in view.
class MapPopoverLayout extends SingleChildLayoutDelegate {
  MapPopoverLayout(this.anchor, {this.gap = 16});
  final Offset anchor;
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double inside(double v, double extent, double room) =>
        v.clamp(8.0, (room - extent - 8).clamp(8.0, double.infinity));
    final below = anchor.dy + gap;
    final y = below + childSize.height <= size.height - 8 ? below : anchor.dy - gap - childSize.height;
    return Offset(inside(anchor.dx - childSize.width / 2, childSize.width, size.width),
        inside(y, childSize.height, size.height));
  }

  @override
  bool shouldRelayout(MapPopoverLayout old) => old.anchor != anchor || old.gap != gap;
}

/// A selected line's popover: what it means, and Disconnect / Options… / Approve now where they apply.
class MapLinePopover extends StatelessWidget {
  const MapLinePopover({
    super.key,
    required this.title,
    required this.facts,
    required this.onClose,
    this.onDisconnect,
    this.onOptions,
    this.onApprove,
  });
  final String title;
  final List<String> facts;
  final VoidCallback onClose;
  final VoidCallback? onDisconnect;
  final VoidCallback? onOptions;
  final VoidCallback? onApprove;

  static const width = 320.0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final actions = [
      if (onApprove != null)
        FilledButton(
            key: const Key('agent-map-popover-approve'),
            style: XButtons.primary(),
            onPressed: onApprove,
            child: Text(l.mapConnectApproveNow)),
      if (onOptions != null)
        TextButton(
            key: const Key('agent-map-popover-options'),
            style: XButtons.tertiary(),
            onPressed: onOptions,
            child: Text(l.mapOptions)),
      if (onDisconnect != null)
        TextButton(
            key: const Key('agent-map-popover-disconnect'),
            style: XButtons.destructive(),
            onPressed: onDisconnect,
            child: Text(l.mapDisconnectAction)),
    ];
    // Its own taps and drags stay its own: the canvas under it neither deselects nor pans.
    return GestureDetector(
      onTap: () {},
      onPanStart: (_) {},
      child: Container(
        key: const Key('agent-map-popover'),
        width: width,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: xPanel(fill: XColors.bg1, border: XColors.lineStrong, radius: XRadius.l, glow: 1),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child:
                    Text(title, key: const Key('agent-map-popover-title'), style: XText.title.copyWith(fontSize: 14)),
              ),
            ),
            IconButton(
              key: const Key('agent-map-popover-close'),
              tooltip: l.commonClose,
              iconSize: 16,
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, color: XColors.textDim),
            ),
          ]),
          for (final f in facts)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text(f, style: XText.bodyDim.copyWith(color: XColors.text)),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
          ],
          if (onDisconnect != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Text(l.mapDeleteHint, textAlign: TextAlign.end, style: XText.meta),
            ),
        ]),
      ),
    );
  }
}

/// The hover tip of a line: the same words as its popover, smaller.
class MapLineTip extends StatelessWidget {
  const MapLineTip({super.key, required this.title, required this.facts});
  final String title;
  final List<String> facts;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          key: const Key('agent-map-line-tip'),
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.m, glow: 0.6),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: XText.label.copyWith(color: XColors.text)),
            for (final f in facts) Text(f, style: XText.meta),
          ]),
        ),
      );
}

enum MapStatusKind { info, pending, done, failed }

/// One line of feedback on the canvas: a drop that sends nothing, a disconnect running, done or refused.
final class MapStatus {
  const MapStatus(this.kind, this.title, {this.detail, this.action, this.onAction});
  final MapStatusKind kind;
  final String title;
  final String? detail;
  final String? action;
  final VoidCallback? onAction;
}

class MapStatusStrip extends StatelessWidget {
  const MapStatusStrip(this.status, {super.key, required this.onClose});
  final MapStatus status;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final icon = switch (s.kind) {
      MapStatusKind.pending => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      MapStatusKind.info => Icon(Icons.info_outline, size: 18, color: XColors.textDim),
      MapStatusKind.done => Icon(Icons.check_circle_rounded, size: 18, color: XColors.ok),
      MapStatusKind.failed => Icon(Icons.error_outline_rounded, size: 18, color: XColors.danger),
    };
    return GestureDetector(
      onTap: () {},
      onPanStart: (_) {},
      child: Container(
        key: const Key('agent-map-status'),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: xPanel(
          fill: XColors.bg1,
          border: s.kind == MapStatusKind.failed ? XColors.danger : XColors.lineStrong,
          radius: XRadius.m,
          glow: 0.8,
        ),
        child: Row(key: Key('agent-map-status-${s.kind.name}'), mainAxisSize: MainAxisSize.min, children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title, key: const Key('agent-map-status-title'), style: XText.body.copyWith(color: XColors.text)),
              if (s.detail case final d?) Text(d, key: const Key('agent-map-status-detail'), style: XText.meta),
            ]),
          ),
          if (s.action case final a?) ...[
            const SizedBox(width: 8),
            TextButton(
                key: const Key('agent-map-status-action'),
                style: XButtons.tertiary(),
                onPressed: s.onAction,
                child: Text(a)),
          ],
          if (s.kind != MapStatusKind.pending)
            IconButton(
              key: const Key('agent-map-status-close'),
              tooltip: context.l.commonClose,
              iconSize: 16,
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, color: XColors.textDim),
            )
          else
            const SizedBox(width: 8),
        ]),
      ),
    );
  }
}

/// The zoom controls: −, the level (a click goes back to 100 %), +, Fit.
class MapZoomControls extends StatelessWidget {
  const MapZoomControls({
    super.key,
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.onFit,
  });
  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget button(String key, IconData icon, String tip, VoidCallback onTap) => IconButton(
          key: Key(key),
          tooltip: tip,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, color: XColors.textDim),
        );
    return _Panel(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        button('agent-map-zoom-out', Icons.remove_rounded, l.mapZoomOut, onZoomOut),
        Tooltip(
          message: l.mapZoomReset,
          child: TextButton(
            key: const Key('agent-map-zoom-level'),
            style: XButtons.tertiary(),
            onPressed: onReset,
            child: SizedBox(
              width: 44,
              child: Text(l.mapZoomLevel((scale * 100).round()),
                  textAlign: TextAlign.center, style: XText.label.copyWith(color: XColors.text)),
            ),
          ),
        ),
        button('agent-map-zoom-in', Icons.add_rounded, l.mapZoomIn, onZoomIn),
        const SizedBox(width: 4),
        Tooltip(
          message: l.mapZoomFitTip,
          child: TextButton.icon(
            key: const Key('agent-map-zoom-fit'),
            style: XButtons.tertiary(),
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen_outlined, size: 18),
            label: Text(l.mapZoomFit),
          ),
        ),
      ]),
    );
  }
}

/// The layer switch and Arrange automatically.
class MapLayoutControls extends StatelessWidget {
  const MapLayoutControls({super.key, required this.recent, required this.onRecent, required this.onArrange});
  final bool recent;
  final ValueChanged<bool> onRecent;
  final VoidCallback onArrange;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return _Panel(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(
          message: l.mapRecentTip,
          child: InkWell(
            borderRadius: BorderRadius.circular(XRadius.m),
            onTap: () => onRecent(!recent),
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(l.mapRecent, style: XText.label.copyWith(color: XColors.text)),
                const SizedBox(width: 4),
                Transform.scale(
                  scale: 0.75,
                  child: Switch(key: const Key('agent-map-recent'), value: recent, onChanged: onRecent),
                ),
              ]),
            ),
          ),
        ),
        Container(width: 1, height: 20, color: XColors.line),
        Tooltip(
          message: l.mapArrangeTip,
          child: TextButton.icon(
            key: const Key('agent-map-arrange'),
            style: XButtons.tertiary(),
            onPressed: onArrange,
            icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
            label: Text(l.mapArrange),
          ),
        ),
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {},
        onPanStart: (_) {},
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.m, glow: 0.6),
          child: child,
        ),
      );
}
