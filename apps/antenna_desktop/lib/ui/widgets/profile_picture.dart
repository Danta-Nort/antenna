// SPDX-License-Identifier: AGPL-3.0-only
// A profile picture in a circle (x-control/7, CONTROL §28): a drawn animal from the window's own assets, or a photo
// from the daemon's rebuilt bytes only (`picture_photo`), never a path and never bytes the window read itself. A thin
// ring keeps a picture with a dark background apart from a dark surface, and a light one from a light surface. An
// agent's picture keeps the small agent badge: a fox says nothing about who writes, the badge says "an agent".

import 'package:flutter/material.dart';

import '../../state/pictures.dart';
import '../../theme/x_theme.dart';

/// [picture] in a circle of [size], with the agent badge when [agentBadge]; [label] names it for screen readers.
class PictureFace extends StatelessWidget {
  const PictureFace(this.picture,
      {super.key, required this.size, required this.label, this.agentBadge = false, this.badgeLeft = false});
  final ShownPicture picture;
  final double size;
  final String label;
  final bool agentBadge;

  /// The badge on the bottom left (the presence dot takes the right).
  final bool badgeLeft;

  @override
  Widget build(BuildContext context) {
    Widget fallback(BuildContext _, Object _, StackTrace? _) => ColoredBox(color: XColors.bg2);
    final Widget image = switch (picture) {
      final DrawnPicture p => Image.asset(
          p.assetFor(size),
          key: Key('picture-drawn-${p.id}'),
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          excludeFromSemantics: true,
          errorBuilder: fallback,
        ),
      final PhotoPicture p => Image.memory(
          p.bytes,
          key: Key('picture-photo-${p.id}'),
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          excludeFromSemantics: true,
          errorBuilder: fallback,
        ),
    };
    final face = Container(
      width: size,
      height: size,
      foregroundDecoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: XColors.isDark ? XColors.lineStrong : XColors.line),
      ),
      child: ClipOval(child: image),
    );
    return Semantics(
      label: label,
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: !agentBadge
            ? face
            : Stack(clipBehavior: Clip.none, children: [
                face,
                Positioned(
                  right: badgeLeft ? null : -2,
                  left: badgeLeft ? -2 : null,
                  bottom: -2,
                  child: AgentBadge(size: (size * 0.46).roundToDouble(), key: const Key('agent-picture-badge')),
                ),
              ]),
      ),
    );
  }
}

/// The small "an agent" badge at the corner of an agent's monogram or picture.
class AgentBadge extends StatelessWidget {
  const AgentBadge({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: XColors.agentFill,
          shape: BoxShape.circle,
          border: Border.all(color: XColors.bg1, width: 1.5),
        ),
        child: Icon(Icons.smart_toy_outlined, size: size * 0.66, color: XColors.agent),
      );
}
