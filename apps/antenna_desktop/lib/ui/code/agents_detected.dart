// SPDX-License-Identifier: AGPL-3.0-only
// The role new agents start with (Agents and Settings → Agents), and the two roles as a choice (also in "Start agent"
// and Connect). The AI apps themselves are in lib/ui/agents/ai_apps_card.dart.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/appearance.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../widgets/popover.dart';
import '../widgets/section_page.dart';

/// "Role preset (applies to new agents)": the data label the window proposes for a new agent. Nothing is chosen until
/// the owner chooses (Q-15).
class RolePresetCard extends StatelessWidget {
  const RolePresetCard({super.key});

  @override
  Widget build(BuildContext context) {
    final look = AppearanceScope.maybeOf(context);
    final l = context.l;
    if (look == null) return const SizedBox.shrink();
    return SectionCard(
      key: const Key('role-preset'),
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(child: Text(l.rolePresetTitle, style: XText.title)),
          const SizedBox(width: 8),
          HelpHint(l.agentsDaemonFootnote, id: 'role-preset', label: l.settingsMoreAbout(l.rolePresetTitle)),
        ]),
        const SizedBox(height: 4),
        RolePresetChoice(
          value: look.rolePreset,
          onChanged: (r) => look.rolePreset = r,
          compact: true,
        ),
      ]),
    );
  }
}

/// The two roles as radio rows (here and in "Start agent" for a new agent).
class RolePresetChoice extends StatelessWidget {
  const RolePresetChoice({super.key, required this.value, required this.onChanged, this.compact = false});
  final RolePreset? value;
  final ValueChanged<RolePreset> onChanged;

  /// One line per role, its explanation behind a "?" (Settings and Agents); otherwise under the role (the dialogs).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return RadioGroup<RolePreset>(
      groupValue: value,
      onChanged: (r) {
        if (r != null) onChanged(r);
      },
      child: Column(children: [
        for (final r in RolePreset.values)
          InkWell(
            key: Key('role-${r.name}'),
            onTap: () => onChanged(r),
            borderRadius: BorderRadius.circular(XRadius.m),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 0 : 8),
              child: compact
                  ? Row(children: [
                      Radio<RolePreset>(value: r),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(r == RolePreset.assistant ? l.rolePresetAssistant : l.rolePresetFrontDesk,
                            style: XText.body.copyWith(fontWeight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      HelpHint(
                        r == RolePreset.assistant ? l.rolePresetAssistantHint : l.rolePresetFrontDeskHint,
                        id: 'role-${r.name}',
                        label: l.settingsMoreAbout(
                            r == RolePreset.assistant ? l.rolePresetAssistant : l.rolePresetFrontDesk),
                      ),
                    ])
                  : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Radio<RolePreset>(value: r),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r == RolePreset.assistant ? l.rolePresetAssistant : l.rolePresetFrontDesk,
                                style: XText.body.copyWith(fontWeight: FontWeight.w500)),
                            const SizedBox(height: 2),
                            Text(r == RolePreset.assistant ? l.rolePresetAssistantHint : l.rolePresetFrontDeskHint,
                                style: XText.meta),
                          ]),
                        ),
                      ),
                    ]),
            ),
          ),
      ]),
    );
  }
}
