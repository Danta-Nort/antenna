// SPDX-License-Identifier: AGPL-3.0-only
// A team's board (DESIGN "Teams"): the team's facts, the lead's request to apply its branch (the one approval the
// default rules keep for the owner), the capacity strip, the workers, and the tasks in columns by state. The board is
// derived from `team_show` (principle 4): the daemon's task records are the truth, the columns only a view of them.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/teams.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/experimental_tag.dart';
import 'capacity_strip.dart';
import 'task_card.dart';
import 'team_dialogs.dart';
import 'team_widgets.dart';

/// A column's width on a board that scrolls sideways.
const boardColumnWidth = 232.0;

class TeamBoard extends StatelessWidget {
  const TeamBoard(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final t = m.team(name);
    if (t == null) return const SizedBox.shrink();
    final board = boardOf(t);
    final columns = [
      for (final c in BoardColumn.values)
        if (c != BoardColumn.cancelled || board[c]!.isNotEmpty) c,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Header(t),
          const SizedBox(height: 8),
          _Facts(t),
          if (m.teamErrors[name] case final e?) ...[
            const SizedBox(height: 8),
            Text(describeTeamError(l, e), style: XText.bodyDim.copyWith(color: XColors.danger)),
          ],
          if (t.applyRequest != null) ...[const SizedBox(height: 16), ApplyBanner(t)],
          const SizedBox(height: 16),
          CapacityStrip(t),
          const SizedBox(height: 12),
          WorkersStrip(t),
          const SizedBox(height: 16),
        ]),
      ),
      Divider(height: 1, color: XColors.line),
      Expanded(
        child: ColoredBox(
          color: XColors.bg0,
          child: LayoutBuilder(builder: (context, c) {
            // Every column in view when they fit at their narrowest; otherwise fixed columns that scroll sideways.
            final fit = (c.maxWidth - 32 - boardColumnGap * (columns.length - 1)) / columns.length;
            if (fit >= boardColumnMin) {
              return Padding(
                key: const Key('team-board'),
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < columns.length; i++) ...[
                    if (i > 0) const SizedBox(width: boardColumnGap),
                    Expanded(child: _Column(t, columns[i], board[columns[i]]!)),
                  ],
                ]),
              );
            }
            return Scrollbar(
              child: SingleChildScrollView(
                key: const Key('team-board'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < columns.length; i++) ...[
                    if (i > 0) const SizedBox(width: boardColumnGap),
                    SizedBox(width: boardColumnWidth, child: _Column(t, columns[i], board[columns[i]]!)),
                  ],
                ]),
              ),
            );
          }),
        ),
      ),
    ]);
  }
}

/// The gap between the board's columns.
const boardColumnGap = 8.0;

/// The narrowest a column gets before the board scrolls sideways.
const boardColumnMin = 184.0;

class _Header extends StatelessWidget {
  const _Header(this.t);
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.read(context);
    final l = context.l;
    final title = [
      IconButton(
        key: const Key('team-back'),
        tooltip: l.teamBackToTeams,
        onPressed: () => m.openBoard(null),
        icon: const Icon(Icons.arrow_back_rounded, size: 20),
      ),
      const SizedBox(width: 4),
      Flexible(child: Text(t.name, style: XText.h1, maxLines: 1, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 12),
      TeamChip(t.active ? l.teamActive : l.teamStopped, color: t.active ? XColors.ok : XColors.textMute),
      const SizedBox(width: 8),
      const ExperimentalTag(),
    ];
    final actions = [
      OutlinedButton.icon(
        key: const Key('task-new'),
        onPressed: t.active ? () => showNewTaskDialog(context, t) : null,
        icon: const Icon(Icons.add_task_rounded, size: 16),
        label: Text(l.taskNew),
      ),
      OutlinedButton.icon(
        key: const Key('worker-add'),
        onPressed: t.active ? () => showAddWorkerDialog(context, t) : null,
        icon: const Icon(Icons.person_add_alt_rounded, size: 16),
        label: Text(l.workerAdd),
      ),
      OutlinedButton.icon(
        key: const Key('team-apply'),
        onPressed: () => showApplyTeamDialog(context, t),
        icon: const Icon(Icons.merge_rounded, size: 16),
        label: Text(l.teamApplyTo(t.target)),
      ),
    ];
    final menu = PopupMenuButton<String>(
        key: const Key('team-menu'),
        tooltip: l.teamMenu,
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        onSelected: (v) => unawaited(switch (v) {
          'log' => showTeamLogDialog(context, t),
          'stop' => confirmStopTeam(context, t),
          'activate' => reactivateTeam(context, t),
          'remove' => confirmRemoveTeam(context, t),
          _ => Future<void>.value(),
        }),
        itemBuilder: (_) => [
          PopupMenuItem(key: const Key('team-log'), value: 'log', child: Text(l.teamLog)),
          if (t.active)
            PopupMenuItem(key: const Key('team-stop'), value: 'stop', child: Text(l.teamStop))
          else
            PopupMenuItem(key: const Key('team-activate'), value: 'activate', child: Text(l.teamActivate)),
          PopupMenuItem(
            key: const Key('team-remove'),
            value: 'remove',
            child: Text(l.teamRemove, style: TextStyle(color: XColors.danger)),
          ),
        ],
      );
    // The actions go under the title where the window leaves less room (Code mode's terminals).
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 980) {
        return Row(children: [
          ...title,
          const Spacer(),
          for (final a in actions) ...[a, const SizedBox(width: 8)],
          menu,
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [...title, const Spacer(), menu]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 44),
          child: Wrap(spacing: 8, runSpacing: 8, children: actions),
        ),
      ]);
    });
  }
}

/// The project, the branches, the lead and the rules, in one line each where they fit.
class _Facts extends StatelessWidget {
  const _Facts(this.t);
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget fact(IconData icon, String text, {Key? key, bool mono = false}) => Row(key: key, mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: XColors.textMute),
          const SizedBox(width: 4),
          Flexible(child: Text(text, style: mono ? XText.mono : XText.bodyDim, overflow: TextOverflow.ellipsis)),
        ]);
    final tpl = t.template;
    return Padding(
      padding: const EdgeInsets.only(left: 44),
      child: Wrap(spacing: 16, runSpacing: 4, children: [
        fact(Icons.folder_outlined, t.project, mono: true),
        fact(Icons.call_split_rounded, l.teamBranches(t.integration, t.target), mono: true),
        fact(Icons.flag_outlined, t.lead == null ? l.teamLedByYou : l.teamLedBy(t.lead!), key: const Key('team-lead')),
        fact(Icons.terminal_rounded, tpl.commands ? l.teamRuleCommands : l.teamRuleNoCommands),
        fact(Icons.verified_user_outlined, tpl.ownerApplies ? l.teamRuleOwnerApplies(t.target) : l.teamRuleLeadApplies(t.target),
            key: const Key('team-apply-rule')),
        if (tpl.checks.isNotEmpty)
          fact(Icons.fact_check_outlined, l.teamRuleChecks(tpl.checks.map((c) => c.join(' ')).join(', '))),
        if (tpl.localOnly) fact(Icons.lock_outline, l.teamRuleLocalOnly),
      ]),
    );
  }
}

/// The lead asks to put the team's branch on the project's branch: only the owner can (the template's rule).
class ApplyBanner extends StatelessWidget {
  const ApplyBanner(this.t, {super.key});
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.read(context);
    final l = context.l;
    final r = t.applyRequest!;
    return Container(
      key: const Key('team-apply-banner'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: XColors.accentSoft,
        borderRadius: BorderRadius.circular(XRadius.l),
        border: Border.all(color: XColors.accentLine.withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        Icon(Icons.merge_rounded, size: 20, color: XColors.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.teamApplyAsks(r.by, t.target), style: XText.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(l.teamApplyAsksDetail(t.integration, r.commit.substring(0, r.commit.length.clamp(0, 12)),
                agoLabel(l, r.atMs, m.now())), style: XText.bodyDim),
          ]),
        ),
        const SizedBox(width: 12),
        FilledButton(
          key: const Key('team-apply-review'),
          onPressed: () => showApplyTeamDialog(context, t),
          child: Text(l.teamApplyReview),
        ),
      ]),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column(this.t, this.c, this.tasks);
  final TeamInfo t;
  final BoardColumn c;
  final List<TaskInfo> tasks;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Container(
      key: Key('col-${c.name}'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.l)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(children: [
            Flexible(
              child: Text(columnLabel(l, c),
                  style: XText.label.copyWith(color: XColors.text, fontWeight: FontWeight.w600), maxLines: 1),
            ),
            const SizedBox(width: 8),
            Text('${tasks.length}', style: XText.meta),
          ]),
        ),
        Expanded(
          child: tasks.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Text(l.teamColumnEmpty, style: XText.meta),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 8), children: [
                  for (final x in tasks) TaskCard(t, x, key: Key('task-card-${x.shortId}')),
                ]),
        ),
      ]),
    );
  }
}
