// SPDX-License-Identifier: AGPL-3.0-only
// The mark next to an agent's name in the conversation (D-UI-18), by the same rule as the agent avatars (`XAvatar`):
// the mark of the AI the agent runs on only for this node's own agents, and only when the window knows it as a fact:
// the CLI it started in a terminal (Code mode) or the AI app it connected (Agents → AI apps). Never from a name: a
// contact chooses its agents' names, so a name proves nothing, and a contact's agent always gets the neutral agent mark
// with its name.

import 'package:flutter/material.dart';

import '../../state/agent_launch.dart' show AgentCli;
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../state/code_mode.dart' show AgentRunSpec;
import '../../theme/ai_logos.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import 'ai_logo.dart';

/// Whose agent: one of this node's ([mine]) or one of the contact's.
final class AgentRef {
  const AgentRef(this.name, {this.mine = false, this.contact, this.linkId, this.brand});

  /// The agent's name in the link.
  final String name;

  /// An agent of this node (the owner's), not of the contact.
  final bool mine;

  /// For a contact's agent: the contact's label.
  final String? contact;

  /// For a contact's agent: the link, when the caller has it (its picture is looked up by the link, else by [contact]).
  final String? linkId;

  /// For [mine]: the AI the window knows the agent runs on ([knownAgentBrand]).
  final AiBrand? brand;
}

/// The AI one of this node's agents runs on, as the window knows it: the CLI it started for the agent in Code mode (in
/// this session, or the last start remembered in [look]), or the AI app it connected the agent for. `null`: not known
/// as a fact.
AiBrand? knownAgentBrand(AppModel m, String agent, {Appearance? look}) {
  switch (m.runOf(agent)?.spec.cli ?? AgentRunSpec.fromJson(agent, look?.agentRun(agent))?.cli) {
    case AgentCli.claude:
      return AiBrand.claudecode;
    case AgentCli.codex:
      return AiBrand.openai;
    case AgentCli.custom || null:
      break;
  }
  final app = m.appOfAgent(agent);
  return app == null ? null : brandOfApp(app.id);
}

/// The mark of the AI an agent runs on, or `null` when there is none the window may draw: the caller then shows the
/// neutral agent icon. Only my agent with a known AI ([AgentRef.brand]) gets one; a contact's agent never does.
Widget? agentServiceLogo(AgentRef agent, {double size = 14}) {
  final brand = agent.mine ? agent.brand : null;
  if (brand == null || !aiMarks.containsKey(brand)) return null;
  return AiLogo(brand: brand, label: agent.name, size: size + 4, circle: true);
}

/// The mark shown before an agent's name: its AI's mark, or the generic agent icon.
class AgentMark extends StatelessWidget {
  const AgentMark(this.agent, {super.key, this.size = 14, this.color});
  final AgentRef agent;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.maybeOf(context);
    final ref = agent.mine && agent.brand == null && m != null
        ? AgentRef(agent.name, mine: true, brand: knownAgentBrand(m, agent.name, look: AppearanceScope.maybeOf(context)))
        : agent;
    return agentServiceLogo(ref, size: size) ??
        Icon(Icons.smart_toy_outlined, key: const Key('agent-mark-generic'), size: size, color: color ?? XColors.agent);
  }
}
