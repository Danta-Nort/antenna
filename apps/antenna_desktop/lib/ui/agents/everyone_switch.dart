// SPDX-License-Identifier: AGPL-3.0-only
// "Sees messages to everyone" for a NEW agent (v6, CONTROL §20, D-UI-18), in every place the window creates one
// (Connect an AI app, Start agent, Connect an agent): off by default, as in the daemon, with one plain line on what the
// agent will read. These dialogs already ask for the owner password, which turning it on needs. A daemon older than v6
// has no such setting, and the switch is not shown.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';

class NewAgentEveryoneSwitch extends StatelessWidget {
  const NewAgentEveryoneSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!AppScope.of(context).addressing) return const SizedBox.shrink();
    final l = context.l;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 26,
          child: FittedBox(
            child: Switch(key: const Key('new-agent-everyone'), value: value, onChanged: onChanged),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l.agentEveryone, style: XText.label.copyWith(color: XColors.text)),
            ),
            const SizedBox(height: 2),
            Text(
              value ? l.agentEveryoneNewOn : l.agentEveryoneNewOff,
              key: const Key('new-agent-everyone-hint'),
              style: XText.meta,
            ),
          ]),
        ),
      ]),
    );
  }
}
