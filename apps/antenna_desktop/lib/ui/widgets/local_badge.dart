// SPDX-License-Identifier: AGPL-3.0-only
// The "Local" badge (D-96, docs/LOCAL-ASSISTANT.md §7.5): "Local · runs on this Mac" ("this computer" on Linux). It is
// a fact from the daemon, never a guess: shown only for an agent whose `local_agents` entry says `runtime: "local"`,
// that is, this daemon launched the model's runtime itself. Never from a name, an app scan or a contact's word (the
// rule of vendor marks, D-UI-18). The tooltip says what is always true: the model runs here without internet, and its
// replies go only where its conversation goes.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';

/// A local agent's state in plain words.
String localAgentStateLabel(AppLocalizations l, String state) => switch (state) {
      LocalAgentState.sleeping => l.localStateSleeping,
      LocalAgentState.waiting => l.localStateWaiting,
      LocalAgentState.loading => l.localStateLoading,
      LocalAgentState.idle => l.localStateReady,
      LocalAgentState.busy => l.localStateWorking,
      LocalAgentState.failed => l.localStateFailed,
      LocalAgentState.noModel => l.localStateNoModel,
      final s => s,
    };

/// The color of a local agent's state dot.
Color localAgentStateColor(String state) => switch (state) {
      LocalAgentState.idle => XColors.ok,
      LocalAgentState.busy || LocalAgentState.loading => XColors.accent,
      LocalAgentState.waiting => XColors.warn,
      LocalAgentState.failed || LocalAgentState.noModel => XColors.danger,
      _ => XColors.textMute,
    };

/// The badge for [agent], or nothing when the daemon does not say it runs the agent's model here.
class LocalBadge extends StatelessWidget {
  const LocalBadge(this.agent, {super.key, this.short = false});
  final LocalAgentInfo? agent;

  /// Only "Local" (the chat list, where the row is narrow); the tooltip is the same.
  final bool short;

  @override
  Widget build(BuildContext context) {
    final a = agent;
    if (a == null || !a.runsHere) return const SizedBox.shrink();
    final l = context.l;
    final mac = AppScope.maybeOf(context)?.localOnMac ?? false;
    final text = short ? l.localBadgeShort : (mac ? l.localBadgeMac : l.localBadgeComputer);
    return Tooltip(
      message: l.localBadgeTip,
      child: Container(
        key: Key('local-badge-${a.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Color.alphaBlend(XColors.ok.withValues(alpha: XColors.isDark ? 0.16 : 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(mac ? Icons.laptop_mac_rounded : Icons.computer_rounded, size: 12, color: XColors.ok),
          const SizedBox(width: 4),
          Text(text, style: XText.meta.copyWith(color: XColors.ok, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
