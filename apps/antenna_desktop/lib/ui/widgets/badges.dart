// SPDX-License-Identifier: AGPL-3.0-only
// Small marks: trust level, avatar, presence, delivery status, the E2E · PQ chip.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/facts.dart';
import '../../state/pictures.dart';
import '../../state/trust.dart';
import '../../theme/ai_logos.dart';
import '../../theme/antenna_mark.dart';
import '../../theme/x_theme.dart';
import 'ai_logo.dart';
import 'profile_picture.dart';

/// Trust level badge 1–5 (SPEC §9): a small, quiet mark. The higher the level, the more visible it is: level 5 is
/// filled in the light theme, and the glow grows in the dark theme.
class TrustBadge extends StatelessWidget {
  const TrustBadge(this.level, {super.key, this.size = 20, this.showName = false});

  final int level;
  final double size;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final l = level.clamp(1, 5);
    final c = XColors.trustColor(l);
    final filled = !XColors.isDark && l == 5;
    final box = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? c : Color.alphaBlend(c.withValues(alpha: XColors.isDark ? 0.13 : 0.09), XColors.bg1),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: c.withValues(alpha: XColors.isDark ? 0.75 : 0.4)),
        boxShadow: XColors.isDark
            ? [BoxShadow(color: c.withValues(alpha: 0.15 + 0.17 * (l - 1)), blurRadius: size * 0.6, spreadRadius: -1)]
            : null,
      ),
      child: Text(
        trustGlyph(l),
        style: XText.monoStrong.copyWith(color: filled ? XColors.onAccent : c, fontSize: size * 0.58, height: 1),
      ),
    );
    final name = TrustLevel.of(level).name(context.l);
    final tip = l == 5 ? context.l.badgeTrustTooltipSelf(name) : context.l.badgeTrustTooltip(level, name);
    if (!showName) return Tooltip(message: tip, child: box);
    return Tooltip(
      message: tip,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        box,
        const SizedBox(width: 8),
        Text(name, style: XText.label.copyWith(color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Avatar: the profile picture when there is one ([picture]), else initials in a circle; an agent gets the Antenna mark
/// on blue (the daemon reports it in `peer_kind`), or its picture with the agent badge.
class XAvatar extends StatelessWidget {
  const XAvatar(this.label, {super.key, this.size = 40, this.agent = false, this.presence, this.brand, this.picture});

  final String label;
  final double size;
  final bool agent;

  /// The AI one of this node's agents runs on, only when the window knows it as a fact (`knownAgentBrand`: the AI app
  /// it connected, the CLI it started). Never guessed from a name: a contact chooses its agents' names, so a contact's
  /// agent (and a contact whose side is an agent) always keeps the neutral Antenna mark (D-UI-18).
  final AiBrand? brand;

  /// `true`: online, `false`: offline, `null`: not shown (levels 1–2, SPEC §4).
  final bool? presence;

  /// The profile picture the window may draw (CONTROL §28): the owner's own, one of the owner's agents', or what a
  /// contact announced; `null` keeps the initials or the marks.
  final ShownPicture? picture;

  String get _initials {
    final parts = label.trim().split(RegExp(r'[\s_\-./·•|]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final hue = label.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xffff) % 5;
    final Widget face;
    final ai = agent ? brand : null;
    final chosen = picture;
    if (chosen != null) {
      // The owner's choice wins over the AI's mark; the agent badge stays, out of the presence dot's corner
      face = PictureFace(chosen, size: size, label: label, agentBadge: agent, badgeLeft: presence != null);
    } else if (ai != null && aiMarks.containsKey(ai)) {
      face = AiLogo(brand: ai, label: label, size: size, circle: true);
    } else if (agent) {
      face = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: XColors.brand, shape: BoxShape.circle),
        child: AntennaMark(height: size * 0.6, color: XColors.markOnBrand),
      );
    } else {
      face = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: XColors.isDark ? null : XColors.avatars[hue],
          gradient: XColors.isDark
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [XColors.avatars[hue], XColors.bg2],
                )
              : null,
          shape: BoxShape.circle,
          border: XColors.isDark ? Border.all(color: XColors.accent.withValues(alpha: 0.35)) : null,
        ),
        child: Text(
          _initials,
          style: XText.title.copyWith(fontSize: size * 0.36, color: XColors.text, height: 1, fontWeight: FontWeight.w600),
        ),
      );
    }
    if (presence == null) return face;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        face,
        Positioned(
          right: -1,
          bottom: -1,
          child: PresenceDot(online: presence!, size: size * 0.3),
        ),
      ]),
    );
  }
}

class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.online, this.size = 9});
  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = online ? XColors.ok : XColors.textMute;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: online ? c : XColors.bg1,
        shape: BoxShape.circle,
        border: Border.all(color: online ? XColors.bg1 : c, width: online ? 2 : 1.4),
      ),
    );
  }
}

/// Delivery status of an outgoing message.
class DeliveryMark extends StatelessWidget {
  const DeliveryMark(this.delivery, {super.key, this.size = 14, this.onFill = false});
  final Delivery delivery;
  final double size;

  /// The mark sits on the blue fill of an outgoing bubble: normal statuses use the bubble's caption color.
  final bool onFill;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (icon, color, tip) = switch (delivery) {
      Delivery.sending => (Icons.more_horiz, onFill ? XColors.outMeta : XColors.textMute, l.deliverySending),
      Delivery.delivered => (Icons.done_all, onFill ? XColors.outMeta : XColors.accent, l.deliveryDelivered),
      Delivery.queued => (Icons.schedule, onFill ? XColors.outMeta : XColors.warn, l.deliveryQueued),
      Delivery.failed => (Icons.error_outline, onFill ? XColors.outMeta : XColors.danger, l.cardNotDelivered),
    };
    return Tooltip(message: tip, child: Icon(icon, size: size, color: color));
  }
}

/// The "E2E · PQ" chip, with facts from `contacts` in its tooltip.
class PqChip extends StatelessWidget {
  const PqChip(this.contact, {super.key, this.dense = false});
  final ContactInfo contact;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final f = PqFacts(contact);
    final c = f.pq ? XColors.accent : (f.hasE2e ? XColors.textDim : XColors.textMute);
    final l = context.l;
    return Tooltip(
      richMessage: TextSpan(children: [
        for (final (k, v) in f.lines(l)) ...[
          TextSpan(text: '$k  ', style: XText.monoSmall.copyWith(color: XColors.textDim)),
          TextSpan(text: '$v\n', style: XText.monoSmall.copyWith(color: XColors.text)),
        ],
        TextSpan(text: l.badgeFactsSource, style: XText.monoSmall),
      ]),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 8, vertical: dense ? 2 : 4),
        decoration: BoxDecoration(
          color: f.pq ? XColors.accentSoft : XColors.bg2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: f.pq ? XColors.accentLine.withValues(alpha: 0.6) : XColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(f.pq ? Icons.shield_outlined : Icons.lock_outline, size: dense ? 11 : 13, color: c),
          const SizedBox(width: 4),
          Text(f.badge(l), style: XText.meta.copyWith(color: c, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        ]),
      ),
    );
  }
}

/// A small pill label (network mode, daemon version and so on).
class XPill extends StatelessWidget {
  const XPill(this.text, {super.key, this.icon, this.color, this.tooltip});
  final String text;
  final IconData? icon;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: XColors.line),
        color: XColors.bg2,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: color ?? XColors.textDim), const SizedBox(width: 4)],
        Text(text, style: XText.meta.copyWith(color: color ?? XColors.textDim)),
      ]),
    );
    return tooltip == null ? w : Tooltip(message: tooltip, child: w);
  }
}

/// Unread counter.
class CountBubble extends StatelessWidget {
  const CountBubble(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 20),
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: XColors.accentFill, borderRadius: BorderRadius.circular(10)),
        child: Text('$count',
            style: XText.meta.copyWith(color: XColors.onAccent, fontSize: 11, height: 1, fontWeight: FontWeight.w600)),
      );
}

/// Unread agent-to-agent traffic in a chat (D-UI-44): never a number, just a quiet mark, since a person does not
/// usually count what the AIs discuss among themselves.
class QuietUnreadDot extends StatelessWidget {
  const QuietUnreadDot({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: context.l.chatUnreadBetweenAgentsTip,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: XColors.textMute, shape: BoxShape.circle),
        ),
      );
}

/// Who is on the other side (v5, CONTROL §17): an agent or a person with agents gets a small tag; a person and
/// "unknown" get nothing (right after linking, and with preview.1 nodes, the kind is unknown).
class PeerKindTag extends StatelessWidget {
  const PeerKindTag(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final names = c.activeAgents.map((a) => a.name).join(', ');
    final (text, tip) = switch (c.peerKind) {
      'agent' => (l.peerKindAgent, names.isEmpty ? l.peerKindAgentTip : l.peerKindAgentsTip(names)),
      'mixed' => (l.peerKindMixed, l.peerKindAgentsTip(names)),
      _ => (null, null),
    };
    if (text == null) return const SizedBox.shrink();
    return Tooltip(
      message: tip,
      child: Container(
        key: Key('peer-kind-${c.label}'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: BoxDecoration(
          color: Color.alphaBlend(XColors.agent.withValues(alpha: 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.smart_toy_outlined, size: 11, color: XColors.agent),
          const SizedBox(width: 4),
          Text(text, style: XText.meta.copyWith(fontSize: 11, color: XColors.agent, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// A "key: value" row with a monospaced value.
class FactRow extends StatelessWidget {
  const FactRow(this.k, this.v, {super.key, this.valueColor, this.tooltip});
  final String k;
  final String v;
  final Color? valueColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 124, child: Text(k, style: XText.bodyDim.copyWith(fontSize: 12))),
        const SizedBox(width: 8),
        Expanded(
          child: Text(v, style: XText.mono.copyWith(color: valueColor ?? XColors.text, fontSize: 12)),
        ),
      ]),
    );
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }
}

/// Section header: monospaced, letter-spaced.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Text(text.toUpperCase(), style: XText.overline),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: XColors.line)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}
