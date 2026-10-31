// SPDX-License-Identifier: AGPL-3.0-only
// The agent's card in the Agents list (CONTROL §30, D-123): its default counterpart, "Default counterpart: session-2 ·
// Mac mini" (or "· This computer" for another agent here), the other agents of this computer it is connected to
// ("Connected on this computer: …"), and the other own computers' agents connected to it ("Connected from: …", a line
// only the other side drew), each with Disconnect…. From the daemon's `session.counterpart`, `session.local_routes`
// and the devices' statuses; nothing for an older daemon, which sends none of them.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/x_buttons.dart';
import 'agent_connect_dialog.dart';
import 'local_connect_dialog.dart';

class AgentConnectionLines extends StatelessWidget {
  const AgentConnectionLines(this.agent, {super.key});
  final AgentInfo agent;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final cp = agent.counterpart;
    final own = {for (final d in m.ownDevices) d.contact};
    final from = [
      for (final d in m.devicesSupported ? m.ownDevices : const <DeviceInfo>[])
        for (final x in d.status?.agents ?? const <DeviceAgent>[])
          if (x.counterpart == agent.name && !(cp?.contact == d.contact && cp?.agent == x.name)) (d.contact, x.name),
    ];
    final here = [
      for (final r in agent.localRoutes ?? const <LocalRoute>[])
        if (!(cp != null && cp.local && cp.agent == r.agent)) r.agent,
    ];
    if (cp == null && from.isEmpty && here.isEmpty) return const SizedBox.shrink();
    Widget row(Key key, String text, VoidCallback onDisconnect, Key button) => Row(key: key, children: [
          Icon(Icons.hub_outlined, size: 14, color: XColors.accent),
          const SizedBox(width: 4),
          Flexible(child: Text(text, style: XText.meta.copyWith(color: XColors.accent))),
          const SizedBox(width: 8),
          SizedBox(
            height: 24,
            child: TextButton(
              key: button,
              style: XButtons.tertiary(),
              onPressed: m.connectionsSupported ? onDisconnect : null,
              child: Text(l.mapDisconnect, style: XText.meta.copyWith(color: XColors.accent)),
            ),
          ),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (cp != null && cp.local)
        row(
          Key('agent-counterpart-${agent.name}'),
          l.agentCounterpart('${cp.agent} · ${l.devicesThisComputer}'),
          () => showLocalDisconnectDialog(context, agent: agent.name, other: cp.agent ?? ''),
          Key('agent-counterpart-disconnect-${agent.name}'),
        )
      else if (cp != null)
        row(
          Key('agent-counterpart-${agent.name}'),
          l.agentCounterpart(cp.agent == null ? l.mapPersonOf(cp.contact) : '${cp.agent} · ${cp.contact}'),
          () => showAgentDisconnectDialog(context,
              agent: agent.name, contact: cp.contact, peerAgent: cp.agent, own: own.contains(cp.contact), onlyThere: false),
          Key('agent-counterpart-disconnect-${agent.name}'),
        ),
      for (final other in here)
        row(
          Key('agent-local-route-${agent.name}-$other'),
          l.agentLocalRoute(other),
          () => showLocalDisconnectDialog(context, agent: agent.name, other: other),
          Key('agent-local-route-disconnect-${agent.name}-$other'),
        ),
      for (final (contact, peer) in from)
        row(
          Key('agent-connected-from-${agent.name}-$contact-$peer'),
          l.agentConnectedFrom('$peer · $contact'),
          () => showAgentDisconnectDialog(context,
              agent: agent.name, contact: contact, peerAgent: peer, own: true, onlyThere: true),
          Key('agent-connected-from-disconnect-${agent.name}-$contact-$peer'),
        ),
    ]);
  }
}
