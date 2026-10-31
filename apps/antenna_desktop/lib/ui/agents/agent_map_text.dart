// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's words: the graph from the model, a node's name and kind line, why a node cannot be an end of
// a line, and what a drop that sends nothing means. What another computer said about its agents is its word, shown as
// plain text.

import '../../l10n/l10n.dart';
import '../../state/agent_launch.dart';
import '../../state/agent_map.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../state/code_mode.dart' show AgentRunSpec;
import '../code/code_text.dart';

/// The graph the map draws, from what the model holds now.
AgentMapGraph agentMapOf(AppModel m) => buildAgentMap(
      agents: m.agents,
      localAgents: [for (final a in m.localAgents) a.name],
      wakeAgents: {for (final r in m.wakeRules) if (r.agent.isNotEmpty) r.agent},
      teams: m.teamsSupported ? [for (final t in m.teams) m.team(t.name) ?? t] : const [],
      thisName: m.devices?.self.name ?? '',
      devices: m.devicesSupported ? m.ownDevices : const [],
      contacts: m.contacts,
      traffic: m.agentTraffic?.pairs ?? const [],
      pending: m.pendingConnects,
    );

/// A node's name as the map shows it.
String mapNodeName(AppLocalizations l, MapNode n) => n.kind == MapNodeKind.you ? l.approvalsYou : n.name;

/// One end of a line in words: an agent's name, or "Bob in person".
String mapEndName(AppLocalizations l, MapNode n) => switch (n.kind) {
      MapNodeKind.person => l.mapPersonOf(n.name),
      MapNodeKind.you => l.approvalsYou,
      _ => n.name,
    };

/// The short kind line under a node's name: the program it runs as, when the window knows it.
String mapNodeKind(AppLocalizations l, AppModel m, Appearance? look, MapNode n) {
  switch (n.kind) {
    case MapNodeKind.you || MapNodeKind.person:
      return l.mapKindPerson;
    case MapNodeKind.contactAgent:
      return l.mapKindAgent;
    case MapNodeKind.device:
      // What that computer said it runs as: its word, shown as plain text.
      return switch (n.app) {
        'claude' => programName(l, AgentCli.claude),
        'codex' => programName(l, AgentCli.codex),
        'local' => l.mapKindLocalModel,
        null || '' => l.mapKindAgent,
        final app => app,
      };
    case MapNodeKind.local:
      if (n.team != null) return l.mapKindWorker(n.team!);
      if (n.notConnectable == MapNotConnectable.localModel) return l.mapKindLocalModel;
      if (n.notConnectable == MapNotConnectable.wake) return l.mapKindWake;
      final cli = m.runOf(n.name)?.spec.cli ?? AgentRunSpec.fromJson(n.name, look?.agentRun(n.name))?.cli;
      if (cli != null && cli != AgentCli.custom) return programName(l, cli);
      return m.appOfAgent(n.name)?.name ?? l.mapKindAgent;
  }
}

/// Why [n] cannot be an end of a line, in words.
String? mapWhyNot(AppLocalizations l, MapNode n) => switch (n.notConnectable) {
      MapNotConnectable.wake => l.mapWhyWake,
      MapNotConnectable.worker => l.mapWhyWorker(n.team ?? ''),
      MapNotConnectable.localModel => l.mapWhyLocal,
      MapNotConnectable.remoteLocalModel => l.mapWhyRemoteLocal(n.contact ?? ''),
      MapNotConnectable.you => l.mapWhyYou,
      null => null,
    };

/// A drop that sends nothing, in words.
String dropNoteText(AppLocalizations l, DropNote d) => switch (d.problem) {
      DropProblem.localUnsupported => l.mapDropLocalUnsupported,
      DropProblem.noLocal => l.mapDropNoLocal,
      DropProblem.notConnectable => d.node == null ? l.mapDropNoLocal : (mapWhyNot(l, d.node!) ?? l.mapDropNoLocal),
    };
