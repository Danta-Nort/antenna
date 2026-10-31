// SPDX-License-Identifier: AGPL-3.0-only
// A task's card on the board (DESIGN "Teams"): the title, the short ID, the round and the ceiling it carries, the
// assignee with its state and what its turn writes now, the last note (the worker's report or the latest review),
// the check's outcome, what the result changes, the tokens, and when it last changed. A click opens the task.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/local_models.dart' show plainModelText;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import 'task_dialog.dart';
import 'team_widgets.dart';

/// The last note of [t] (full view): the worker's report, or the latest review's comments when it is newer.
String? lastNote(TaskInfo t) {
  final r = t.report;
  final v = t.reviews.isEmpty ? null : t.reviews.last;
  if (v != null && v.comments.isNotEmpty && (r == null || v.atMs >= r.atMs)) return plainModelText(v.comments);
  if (r != null && r.summary.isNotEmpty) return plainModelText(r.summary);
  return null;
}

class TaskCard extends StatelessWidget {
  const TaskCard(this.team, this.task, {super.key});
  final TeamInfo team;

  /// The summary from the board.
  final TaskInfo task;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final full = m.taskDetails[task.id];
    final t = task;
    final note = full == null ? null : lastNote(full);
    final worker = t.assignee == null ? null : team.worker(t.assignee!);
    final live = t.assignee == null ? null : m.workerLive[t.assignee!];
    final liveLine = live != null && live.running && live.task == t.id ? _lastLine(live.text) : null;
    final check = t.checkRun;
    final r = t.result;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('task-open-${t.shortId}'),
          borderRadius: BorderRadius.circular(XRadius.m),
          onTap: () => showTaskDialog(context, t.id),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: XColors.bg1,
              borderRadius: BorderRadius.circular(XRadius.m),
              border: Border.all(color: t.state == TaskState.blocked ? XColors.warn.withValues(alpha: 0.6) : XColors.line),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, style: XText.body.copyWith(fontWeight: FontWeight.w500), maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('#${t.shortId}', style: XText.monoSmall),
                if (t.state == TaskState.returned || t.state == TaskState.assigned)
                  TeamChip(taskStateLabel(l, t.state), color: taskStateColor(t.state)),
                if (t.round > 1) TeamChip(l.taskRound(t.round), color: XColors.textDim),
                if (t.ceiling case final c? when c < 5) CeilingChip(c, compact: true),
              ]),
              if (t.assignee case final a?) ...[
                const SizedBox(height: 8),
                Row(children: [
                  WorkerMonogram(a),
                  const SizedBox(width: 8),
                  // The team's prefix is the board's own name: the worker's role and number say who it is.
                  Flexible(
                    child: Text(a.startsWith('${team.name}.') ? a.substring(team.name.length + 1) : a,
                        style: XText.label, overflow: TextOverflow.ellipsis),
                  ),
                  if (worker != null) ...[const SizedBox(width: 8), WorkerDot(worker.state)],
                  const SizedBox(width: 8),
                  // Where it runs: this computer in this release (other machines come with My devices).
                  Tooltip(
                    message: l.teamCapThisComputer,
                    child: Icon(Icons.computer_rounded, size: 14, color: XColors.textMute),
                  ),
                ]),
              ] else if (t.state == TaskState.open) ...[
                const SizedBox(height: 8),
                Text(team.lead == null ? l.taskNobodyOwner : l.taskNobodyLead(team.lead!), style: XText.meta),
              ],
              if (liveLine != null) ...[
                const SizedBox(height: 8),
                Row(key: Key('task-live-${t.shortId}'), children: [
                  const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(live!.activity != null ? activityLabel(l, live.activity!) : liveLine,
                        style: XText.monoSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ] else if (note != null) ...[
                const SizedBox(height: 8),
                Text(note, key: Key('task-note-${t.shortId}'), style: XText.bodyDim, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (check != null)
                  TeamChip(
                    l.taskCheckChip(checkOutcomeLabel(l, check.outcome), (check.durationMs / 1000).toStringAsFixed(1)),
                    key: Key('task-check-${t.shortId}'),
                    color: checkOutcomeColor(check.outcome),
                    icon: check.passed ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                  )
                else if (t.check.isEmpty)
                  Text(l.taskNoCheck, style: XText.meta),
                if (r != null && !r.textOnly) Text(l.taskDiffStat(r.insertions, r.deletions, r.files), style: XText.meta),
                if (t.tokens > 0) Text(l.taskTokens(tokensLabel(t.tokens)), style: XText.meta),
                Text(agoLabel(l, t.updatedMs, m.now()), style: XText.meta),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  static String? _lastLine(String text) {
    final lines = text.trimRight().split('\n').where((s) => s.trim().isNotEmpty);
    return lines.isEmpty ? '…' : lines.last.trim();
  }
}
