// SPDX-License-Identifier: AGPL-3.0-only
// The Teams section (D-111, DESIGN "Teams"; experimental): the owner's teams of agents, each a card with its project,
// lead, workers and where its tasks stand; New team; a team's card opens its board (team_board.dart). Everything shown
// is the daemon's: `team_list` / `team_show`, read again on every `team` event.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/teams.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/section_page.dart';
import 'new_team_dialog.dart';
import 'team_board.dart';
import 'team_widgets.dart';

class TeamsPage extends StatelessWidget {
  const TeamsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final open = m.openTeam;
    if (open != null && m.team(open) != null) return TeamBoard(open, key: ValueKey('board-$open'));
    return SectionPage(
      title: l.teamsTitle,
      subtitle: l.teamsAbout,
      action: FilledButton.icon(
        key: const Key('team-new'),
        onPressed: () => showNewTeamDialog(context),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: Text(l.teamNew),
      ),
      children: [
        const Align(alignment: Alignment.centerLeft, child: ExperimentalTag(key: Key('experimental-teams'))),
        const SizedBox(height: 16),
        if (m.teamsError case final e?) ErrorLine(describeTeamError(l, e)),
        if (!m.teamsLoaded && m.teamsError == null)
          Text(l.commonLoading, style: XText.meta)
        else if (m.teams.isEmpty)
          const _Empty()
        else
          for (final t in m.teams) _TeamCard(m.team(t.name) ?? t, key: Key('team-card-${t.name}')),
      ],
    );
  }
}

/// No team yet: what a team is, in three steps, and New team.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget step(IconData icon, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
              child: Icon(icon, size: 16, color: XColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: XText.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(text, style: XText.bodyDim),
              ]),
            ),
          ]),
        );
    return SectionCard(
      key: const Key('teams-empty'),
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.teamsEmptyTitle, style: XText.title),
        const SizedBox(height: 4),
        Text(l.teamsEmptyBody, style: XText.bodyDim),
        const SizedBox(height: 20),
        step(Icons.folder_open_rounded, l.teamsStep1Title, l.teamsStep1),
        step(Icons.account_tree_outlined, l.teamsStep2Title, l.teamsStep2),
        step(Icons.verified_outlined, l.teamsStep3Title, l.teamsStep3),
        const SizedBox(height: 4),
        FilledButton.icon(
          key: const Key('team-new-empty'),
          onPressed: () => showNewTeamDialog(context),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(l.teamNew),
        ),
      ]),
    );
  }
}

/// The counts of a team's tasks by column, without the empty ones: "1 open · 2 working · 1 in review".
String boardSummary(AppLocalizations l, TeamInfo t) {
  final board = boardOf(t);
  final parts = [
    for (final c in BoardColumn.values)
      if (board[c]!.isNotEmpty && c != BoardColumn.cancelled) '${columnLabel(l, c)} ${board[c]!.length}',
  ];
  return parts.isEmpty ? l.teamNoTasks : parts.join(' · ');
}

class _TeamCard extends StatelessWidget {
  const _TeamCard(this.t, {super.key});
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.read(context);
    final l = context.l;
    final live = t.workers.where((w) => !w.stopped).length;
    final busy = t.workers.where((w) => w.busy).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('team-open-${t.name}'),
          borderRadius: BorderRadius.circular(XRadius.l),
          onTap: () => m.openBoard(t.name),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
                child: Icon(Icons.groups_2_outlined, size: 20, color: XColors.accent),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(t.name, style: XText.title),
                    TeamChip(t.active ? l.teamActive : l.teamStopped, color: t.active ? XColors.ok : XColors.textMute),
                    if (t.applyRequest != null)
                      TeamChip(l.teamApplyWaitingChip(t.target),
                          key: Key('team-apply-waiting-${t.name}'), color: XColors.accent, icon: Icons.merge_rounded),
                  ]),
                  const SizedBox(height: 4),
                  Text(t.project, style: XText.mono, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                    [
                      t.lead == null ? l.teamLedByYou : l.teamLedBy(t.lead!),
                      l.teamWorkersCount(live),
                      if (busy > 0) l.teamWorkersBusy(busy),
                      boardSummary(l, t),
                    ].join(' · '),
                    style: XText.bodyDim,
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: XColors.textMute),
            ]),
          ),
        ),
      ),
    );
  }
}
