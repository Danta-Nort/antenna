// SPDX-License-Identifier: AGPL-3.0-only
// The Agents section: connected agents (the daemon issues their tokens) and "Connect an agent". The daemon, not the
// model, enforces an agent's permissions by the trust level of each contact (SPEC §9). The header's List | Map toggle
// shows the same agents as the agent map (CONTROL §30): a view of the agents, not another section, so the
// navigation keeps its items; the choice is kept while the window runs.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_map.dart';
import '../../state/appearance.dart';
import '../../state/format.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../code/agents_detected.dart';
import '../code/start_agent_dialog.dart';
import '../widgets/badges.dart';
import '../widgets/section_page.dart';
import '../widgets/self_level.dart';
import 'agent_map_view.dart';
import 'agents_dialog.dart';
import 'ai_apps_card.dart';
import 'approver_dialog.dart';
import 'approvers_panel.dart';
import 'local_models_card.dart';
import 'wake_ui.dart';

class AgentsPage extends StatefulWidget {
  const AgentsPage({super.key, this.onOpenChat});

  /// Open a local agent's conversation in Chats.
  final ValueChanged<String>? onOpenChat;

  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends State<AgentsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final m = AppScope.read(context);
      m.refreshAgents();
      m.refreshWake();
      // Approver agents (CONTROL §31): nothing is offered until the daemon answers
      m.refreshApprovers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    // Local agents are listed with their models: they connect no app and hold no token (CONTROL §24).
    final agents = [for (final a in m.agents) if (a.localModel == null) a];
    final map = m.agentsView == AgentsView.map;
    return SectionPage(
      title: l.navAgents,
      subtitle: l.agentAbout,
      // The map's canvas fills the page and pans and zooms by itself (D-UI-47).
      body: map ? const AgentMapView() : null,
      action: Row(mainAxisSize: MainAxisSize.min, children: [
        const _ViewToggle(),
        const SizedBox(width: 16),
        FilledButton.icon(
          key: const Key('agent-connect'),
          onPressed: () => showAgentsDialog(context),
          icon: const Icon(Icons.add, size: 18),
          label: Text(l.agentConnect),
        ),
      ]),
      children: map
          ? const []
          : [
        // The AI apps first (reference v3): found here first, each with its status and its best action.
        if (m.agentHost != null) const AiAppsCard(),
        // Models on this computer and the local agents that run on them (x-control/7; nothing for an older daemon).
        LocalModelsCard(onOpenChat: widget.onOpenChat ?? (agent) => m.selectLocalAgent(agent)),
        if (agents.isEmpty)
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.agentsEmptyTitle, style: XText.title),
              const SizedBox(height: 8),
              Text(
                l.agentsEmptyBody,
                style: XText.bodyDim,
              ),
            ]),
          )
        else
          SectionCard(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(children: [
              for (final a in agents)
                if (AppearanceScope.maybeOf(context)?.ui == InterfaceMode.code &&
                    m.codeAvailable &&
                    !m.isWakeAgent(a.name))
                  AgentRow(
                    a,
                    showEveryone: m.addressing,
                    showCodeWake: true,
                    onStart: () => showStartAgentDialog(context, agent: a.name),
                  )
                else
                  AgentRow(a, showEveryone: m.addressing),
            ]),
          ),
        // Approver agents and what they answered (CONTROL §31; experimental): once there is anything to show.
        const ApproversSection(),
        // The role new agents start with.
        if (m.agentHost != null) const RolePresetCard(),
        const SizedBox(height: 4),
        _Rule(
          Icons.verified_user_outlined,
          l.agentsRuleDaemonTitle,
          l.agentsRuleDaemonBody,
        ),
        _Rule(
          Icons.gpp_maybe_outlined,
          l.agentsRuleApprovalTitle,
          l.agentsRuleApprovalBody,
        ),
        const _ContactAgents(),
        const WakeRulesSection(),
      ],
    );
  }
}

/// List | Map.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return Tooltip(
      message: l.agentsViewTip,
      child: SegmentedButton<AgentsView>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          textStyle: XText.label,
          side: BorderSide(color: XColors.lineStrong),
          selectedBackgroundColor: XColors.accentSoft,
          selectedForegroundColor: XColors.accent,
          foregroundColor: XColors.textDim,
        ),
        segments: [
          ButtonSegment(
            value: AgentsView.list,
            icon: const Icon(Icons.view_agenda_outlined, size: 16),
            label: Text(l.agentsViewList, key: const Key('agents-view-list')),
          ),
          ButtonSegment(
            value: AgentsView.map,
            icon: const Icon(Icons.hub_outlined, size: 16),
            label: Text(l.agentsViewMap, key: const Key('agents-view-map')),
          ),
        ],
        selected: {m.agentsView},
        onSelectionChanged: (s) => m.setAgentsView(s.first),
      ),
    );
  }
}

/// Contacts' agents (v5, CONTROL §17): who writes to you on a contact's behalf. Nodes on preview.1 do not announce
/// agents, and right after linking the contact's kind may still be unknown.
class _ContactAgents extends StatelessWidget {
  const _ContactAgents();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final rows = [
      for (final c in m.contacts)
        for (final a in c.agents) (c, a),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Text(l.contactAgentsTitle, style: XText.h2),
      const SizedBox(height: 8),
      Text(l.contactAgentsAbout, style: XText.bodyDim),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
        child: rows.isEmpty
            ? Text(l.contactAgentsEmpty, style: XText.bodyDim)
            : Column(children: [
                for (final (c, a) in rows)
                  Padding(
                    key: Key('contact-agent-${c.label}-${a.name}'),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      XAvatar(a.name, size: 34, agent: true, picture: m.pictureOfContact(c.linkId, agent: a.name)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.viaContactAgent(c.label, a.name), style: XText.title.copyWith(fontSize: 14)),
                          Text(
                            a.state == 'revoked'
                                ? l.cardAgentRevoked
                                : l.cardAgentSince(formatDate(l, DateTime.fromMillisecondsSinceEpoch(a.sinceMs))),
                            style: XText.meta,
                          ),
                          if (m.approverOf(a.name, contact: c.label) case final ap?)
                            Text(
                              ap.stale ? l.approverStale(c.label) : l.approverRow(approverScope(l, ap.agents, ap.kinds)),
                              key: Key('contact-agent-approver-line-${c.label}-${a.name}'),
                              style: XText.meta.copyWith(color: ap.stale ? XColors.warn : XColors.accent),
                            ),
                        ]),
                      ),
                      TrustBadge(c.trust, size: 18, showName: true),
                      if (c.trust == 5) ...[const SizedBox(width: 8), const SelfMark(size: 17)],
                      // An own computer's agent can answer this computer's requests (CONTROL §31; experimental)
                      if (c.trust == 5 && m.approversKnown && a.state != 'revoked') ...[
                        const SizedBox(width: 4),
                        IconButton(
                          key: Key('contact-agent-approver-${c.label}-${a.name}'),
                          tooltip: '${l.approverAction} · ${l.experimentalTag}',
                          onPressed: () => showApproverDialog(context, agent: a.name, contact: c.label),
                          icon: Icon(
                              m.approverOf(a.name, contact: c.label) == null
                                  ? Icons.how_to_reg_outlined
                                  : Icons.how_to_reg,
                              size: 18,
                              color: m.approverOf(a.name, contact: c.label) == null ? null : XColors.accent),
                        ),
                      ],
                    ]),
                  ),
              ]),
      ),
    ]);
  }
}

class _Rule extends StatelessWidget {
  const _Rule(this.icon, this.title, this.text);
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 17, color: XColors.accent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: XText.title.copyWith(fontSize: 14)),
              const SizedBox(height: 2),
              Text(text, style: XText.bodyDim),
            ]),
          ),
        ]),
      );
}
