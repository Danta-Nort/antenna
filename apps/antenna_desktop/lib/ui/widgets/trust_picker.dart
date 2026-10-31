// SPDX-License-Identifier: AGPL-3.0-only
// Trust level 1–5 picker (SPEC §9) with a hint on what the level means and which network mode it gives (SPEC §4).
// Level 5 "Self" is for the owner's own computers: picking it asks the owner to accept that first (self_level.dart).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import 'badges.dart' show SectionLabel;
import 'self_level.dart';

class TrustPicker extends StatelessWidget {
  const TrustPicker({super.key, required this.value, required this.onChanged, this.showHint = true, this.confirmSelf});
  final int value;
  final ValueChanged<int> onChanged;
  final bool showHint;

  /// Asked before level 5 is picked; `true` lets the choice through, `false` keeps [value]. Default: the level-5
  /// warning ([confirmSelfLevel]) every time.
  final Future<bool> Function()? confirmSelf;

  Future<void> _pick(BuildContext context, int level) async {
    if (level == 5 && value != 5) {
      final ok = await (confirmSelf ?? () => confirmSelfLevel(context))();
      if (!ok || !context.mounted) return;
    }
    onChanged(level);
  }

  @override
  Widget build(BuildContext context) {
    final t = TrustLevel.of(value);
    final mode = TrustLevel.defaultNetMode(value);
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Two groups (D-UI-30): people at levels 1-4, and the owner's own devices at ∞ — its own color (danger,
      // "the moment of choosing") says this is not a level like the others, right where it is picked. Once chosen,
      // it reads as the quiet TrustBadge everywhere else in the window.
      SectionLabel(l.trustGroupPeople),
      Row(children: [
        for (final p in TrustLevel.all.where((x) => x.level < 5)) ...[
          Expanded(child: _Cell(p, selected: p.level == value, onTap: () => _pick(context, p.level))),
          if (p.level < 4) const SizedBox(width: 6),
        ],
      ]),
      const SizedBox(height: 12),
      SectionLabel(l.trustGroupDevices),
      _Cell(TrustLevel.of(5), selected: value == 5, onTap: () => _pick(context, 5), danger: true),
      if (showHint) ...[
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '${value == 5 ? l.trustSelfName : t.name(l)}: ',
              style: XText.bodyDim.copyWith(color: XColors.trustColor(value)),
            ),
            // Level 5 is the owner's own computer: what goes without asking, rather than where files land.
            TextSpan(
              text: value == 5
                  ? '${l.trustPickerSelf} '
                  : '${l.trustPickerRights(t.files(l).toLowerCase(), t.tasks(l).toLowerCase())} ',
              style: XText.bodyDim,
            ),
            TextSpan(
              text: mode == 'relay_only' ? l.trustPickerRelay : l.trustPickerDirect,
              style: XText.bodyDim.copyWith(color: XColors.textMute),
            ),
          ]),
          style: const TextStyle(fontSize: 12.5),
        ),
      ],
    ]);
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.l, {required this.selected, required this.onTap, this.danger = false});
  final TrustLevel l;
  final bool selected;
  final VoidCallback onTap;

  /// ∞ "My computer" (D-UI-30): the danger colour, always, right where it is chosen — not the quiet colour the
  /// resting badge uses everywhere else.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = danger ? XColors.danger : XColors.trustColor(l.level);
    final nameStyle = XText.monoSmall.copyWith(fontSize: 10, color: selected ? c : XColors.textMute);
    return InkWell(
      key: Key('trust-${l.level}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(XRadius.s),
      child: AnimatedContainer(
        duration: XMotion.fast,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.12) : XColors.bg2,
          borderRadius: BorderRadius.circular(XRadius.s),
          border: Border.all(color: selected ? c.withValues(alpha: 0.8) : (danger ? c.withValues(alpha: 0.4) : XColors.line)),
          boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 12, spreadRadius: -3)] : null,
        ),
        child: Column(children: [
          Text(trustGlyph(l.level), style: XText.monoStrong.copyWith(color: selected ? c : XColors.textDim, fontSize: 15)),
          const SizedBox(height: 2),
          // A long name (Acquaintance) shrinks slightly in a narrow card instead of being cut with an ellipsis; an invisible
          // line of normal height keeps the space, so the level digits stay on one line.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Stack(alignment: Alignment.center, children: [
              Text(' ', style: nameStyle),
              FittedBox(fit: BoxFit.scaleDown, child: Text(l.name(context.l), maxLines: 1, style: nameStyle)),
            ]),
          ),
        ]),
      ),
    );
  }
}
