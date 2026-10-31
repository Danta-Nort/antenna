// SPDX-License-Identifier: AGPL-3.0-only
// A task in full (DESIGN "Teams"): the brief and the conversation of the task (who wrote, reported, reviewed, checked
// and applied it, with their words), the worker's live output while it works; Changes (the diff the daemon makes from
// the result's commit), Checks (the last run in the check sandbox), Log (the team's audit trail for this task); and
// the owner's actions the task's state allows: Accept, Request changes, Answer, Assign, Apply to the team's branch,
// Cancel. Everything a worker or a check wrote is data from that worker: plain text, never a link or markup. "Urgent:
// interrupt the worker now" (CONTROL §33, experimental) sends the changes with `urgent`: the worker's turn is
// interrupted and the task returns to it at once, so changes can also be asked while it is assigned or worked on.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/local_models.dart' show plainModelText;
import '../../state/messages.dart' show errorDetail;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import 'team_dialogs.dart' show shortCommit;
import 'team_widgets.dart';
import 'worker_view.dart';

Future<void> showTaskDialog(BuildContext context, String id, {int tab = 0}) =>
    showXDialog<void>(context, (_) => TaskDialog(id, initialTab: tab));

class TaskDialog extends StatefulWidget {
  const TaskDialog(this.id, {super.key, this.initialTab = 0});
  final String id;
  final int initialTab;

  @override
  State<TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<TaskDialog> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this, initialIndex: widget.initialTab);
  final _comment = TextEditingController();

  /// The comment box is open for this verdict (`changes`: Request changes or Answer).
  String? _composing;

  /// "Urgent: interrupt the worker now" for the next request for changes.
  bool _urgent = false;
  Object? _error;
  TaskDiffReply? _diff;
  Object? _diffError;
  bool _diffLoading = false;
  List<TeamLogEntry>? _log;
  String? _assignTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(AppScope.read(context).loadTask(widget.id));
      if (widget.initialTab == 1) unawaited(_loadDiff());
      if (widget.initialTab == 3) unawaited(_loadLog());
    });
    _tabs.addListener(() {
      if (_tabs.index == 1 && _diff == null && !_diffLoading) unawaited(_loadDiff());
      if (_tabs.index == 3 && _log == null) unawaited(_loadLog());
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _loadDiff() async {
    setState(() => _diffLoading = true);
    final (d, e) = await AppScope.read(context).taskDiff(widget.id);
    if (!mounted) return;
    setState(() {
      _diff = d;
      _diffError = e;
      _diffLoading = false;
    });
  }

  Future<void> _loadLog() async {
    final m = AppScope.read(context);
    final t = m.task(widget.id);
    if (t == null) return;
    final (entries, _) = await m.teamLog(t.team);
    if (!mounted) return;
    setState(() => _log = [for (final e in entries) if (e.task == t.id) e]);
  }

  Future<Object?> _review(String verdict) async {
    final err = await AppScope.read(context).reviewTask(widget.id, verdict,
        comments: _comment.text.trim(), urgent: _urgent && verdict == TaskVerdict.changes);
    if (!mounted) return err;
    setState(() {
      _error = err;
      if (err == null) {
        _composing = null;
        _urgent = false;
        _comment.clear();
        _diff = null;
        _log = null;
      }
    });
    return null;
  }

  Future<Object?> _apply() async {
    final err = await AppScope.read(context).applyTask(widget.id);
    if (mounted) setState(() => _error = err);
    return null;
  }

  Future<Object?> _assign() async {
    final w = _assignTo;
    if (w == null) return null;
    final err = await AppScope.read(context).assignTask(widget.id, w);
    if (mounted) setState(() => _error = err);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final t = m.task(widget.id);
    final team = t == null ? null : m.team(t.team);
    if (t == null || team == null) {
      return XDialogShell(title: l.taskTitle, icon: Icons.task_alt_rounded, child: Text(l.errNotFound, style: XText.bodyDim));
    }
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 880, maxHeight: (size.height - 48).clamp(400, 760)),
        child: Container(
          key: Key('task-dialog-${t.shortId}'),
          decoration: xPanel(fill: XColors.bg1, border: XColors.isDark ? XColors.lineStrong : XColors.line, radius: XRadius.xl, glow: 1.6),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, style: XText.h2),
                  const SizedBox(height: 4),
                  Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    TeamChip(taskStateLabel(l, t.state), key: const Key('task-state'), color: taskStateColor(t.state)),
                    Text('#${t.shortId}', style: XText.monoSmall),
                    Text(l.taskOfTeam(team.name), style: XText.meta),
                    if (t.round > 1) Text(l.taskRound(t.round), style: XText.meta),
                    if (t.ceiling case final c?) CeilingChip(c),
                  ]),
                ]),
              ),
              IconButton(
                tooltip: l.taskCopyId,
                onPressed: () => Clipboard.setData(ClipboardData(text: t.id)),
                icon: const Icon(Icons.copy_rounded, size: 16),
              ),
              IconButton(
                tooltip: l.commonClose,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, size: 18),
              ),
            ]),
            const SizedBox(height: 8),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: XText.label.copyWith(fontWeight: FontWeight.w600),
              tabs: [
                Tab(key: const Key('task-tab-overview'), text: l.taskTabOverview),
                Tab(key: const Key('task-tab-changes'), text: l.taskTabChanges),
                Tab(key: const Key('task-tab-checks'), text: l.taskTabChecks),
                Tab(key: const Key('task-tab-log'), text: l.taskTabLog),
              ],
            ),
            Divider(height: 1, color: XColors.line),
            Expanded(
              child: TabBarView(controller: _tabs, children: [
                _Overview(t, team),
                _Changes(t, diff: _diff, error: _diffError, loading: _diffLoading),
                _Checks(t, team),
                _Log(_log),
              ]),
            ),
            if (_error case final e?) ErrorLine(describeTeamError(l, e), detail: errorDetail(e)),
            if (_composing != null) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('task-comment'),
                controller: _comment,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: t.state == TaskState.blocked ? l.taskAnswerHint : l.taskChangesHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _actions(context, t, team),
          ]),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, TaskInfo t, TeamInfo team) {
    final l = context.l;
    final cancel = BusyButton(
      key: const Key('task-cancel'),
      label: l.taskCancel,
      style: BusyStyle.destructive,
      onRun: () => _review(TaskVerdict.cancel),
    );
    final buttons = <Widget>[];
    // Urgent changes (CONTROL §33): next to the comment for a result under review, and for a task its worker has or
    // works on now, where it is what offers changes at all.
    final working = {TaskState.assigned, TaskState.working, TaskState.returned}.contains(t.state);
    final reviewing = t.state == TaskState.submitted || t.state == TaskState.accepted;
    final urgentOffered = (working && (_composing == null || _composing == TaskVerdict.changes)) ||
        (reviewing && _composing == TaskVerdict.changes);
    if (urgentOffered) buttons.add(_UrgentSwitch(on: _urgent, onChanged: (v) => setState(() => _urgent = v)));
    if (_composing != null) {
      buttons.addAll([
        TextButton(
          onPressed: () => setState(() {
            _composing = null;
            _comment.clear();
          }),
          child: Text(l.commonCancel),
        ),
        BusyButton(
          key: const Key('task-send-comment'),
          label: t.state == TaskState.blocked ? l.taskSendAnswer : l.taskSendChanges,
          style: BusyStyle.filled,
          icon: Icons.send_rounded,
          onRun: () => _review(TaskVerdict.changes),
        ),
      ]);
    } else {
      switch (t.state) {
        case TaskState.submitted:
          buttons.addAll([
            cancel,
            OutlinedButton(
              key: const Key('task-changes'),
              onPressed: () => setState(() => _composing = TaskVerdict.changes),
              child: Text(l.taskRequestChanges),
            ),
            BusyButton(
              key: const Key('task-accept'),
              label: l.taskAccept,
              style: BusyStyle.filled,
              icon: Icons.check_rounded,
              onRun: () => _review(TaskVerdict.accept),
            ),
          ]);
        case TaskState.blocked:
          buttons.addAll([
            cancel,
            FilledButton.icon(
              key: const Key('task-answer'),
              onPressed: () => setState(() => _composing = TaskVerdict.changes),
              icon: const Icon(Icons.reply_rounded, size: 16),
              label: Text(l.taskAnswer),
            ),
          ]);
        case TaskState.accepted:
          buttons.addAll([
            cancel,
            OutlinedButton(
              key: const Key('task-changes'),
              onPressed: () => setState(() => _composing = TaskVerdict.changes),
              child: Text(l.taskRequestChanges),
            ),
            BusyButton(
              key: const Key('task-apply'),
              label: l.taskApplyTo(team.integration),
              style: BusyStyle.filled,
              icon: Icons.merge_rounded,
              onRun: _apply,
            ),
          ]);
        case TaskState.open:
          final free = [
            for (final w in team.workers)
              if (!w.stopped && w.task == null) w.name,
          ];
          buttons.addAll([
            cancel,
            if (free.isEmpty)
              Text(l.taskNoFreeWorker, style: XText.meta)
            else ...[
              DropdownButton<String>(
                key: const Key('task-assign-to'),
                value: _assignTo != null && free.contains(_assignTo) ? _assignTo : null,
                hint: Text(l.taskAssignPick),
                items: [for (final n in free) DropdownMenuItem(value: n, child: Text(n))],
                onChanged: (v) => setState(() => _assignTo = v),
              ),
              BusyButton(
                key: const Key('task-assign'),
                label: l.taskAssign,
                style: BusyStyle.filled,
                enabled: _assignTo != null,
                onRun: _assign,
              ),
            ],
          ]);
        case TaskState.assigned || TaskState.working || TaskState.returned:
          buttons.add(cancel);
          // Changes for a task in progress only as urgent: the worker is interrupted and gets them at once.
          if (_urgent) {
            buttons.add(OutlinedButton(
              key: const Key('task-changes'),
              onPressed: () => setState(() => _composing = TaskVerdict.changes),
              child: Text(l.taskRequestChanges),
            ));
          }
        default:
          break;
      }
    }
    return Row(children: [
      Expanded(child: Text(_note(l, t, team), key: const Key('task-next'), style: XText.meta)),
      const SizedBox(width: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
    ]);
  }

  /// What happens next, in one line.
  String _note(AppLocalizations l, TaskInfo t, TeamInfo team) => switch (t.state) {
        TaskState.open => team.lead == null ? l.taskNextOpenOwner : l.taskNextOpenLead(team.lead!),
        TaskState.assigned || TaskState.working => l.taskNextWorking(t.assignee ?? ''),
        TaskState.returned => l.taskNextReturned(t.assignee ?? ''),
        TaskState.submitted => team.lead == null ? l.taskNextReviewOwner : l.taskNextReviewLead(team.lead!),
        TaskState.blocked => l.taskNextBlocked,
        TaskState.accepted => l.taskNextAccepted(team.integration),
        TaskState.done => l.taskNextDone(team.integration, team.target),
        _ => '',
      };
}

class _Overview extends StatelessWidget {
  const _Overview(this.t, this.team);
  final TaskInfo t;
  final TeamInfo team;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final worker = t.assignee == null ? null : team.worker(t.assignee!);
    return ListView(padding: const EdgeInsets.only(top: 16), children: [
      Wrap(spacing: 24, runSpacing: 8, children: [
        _Fact(l.taskFactAssignee,
            t.assignee == null ? l.taskFactNobody : '${t.assignee} · ${workerStateLabel(l, worker?.state ?? WorkerState.idle)}'),
        _Fact(l.taskFactCreated, '${actorLabel(l, t.createdBy)} · ${agoLabel(l, t.createdMs, m.now())}'),
        _Fact(l.taskFactCheck, t.check.isEmpty ? l.taskNoCheck : t.check.join(' '), mono: t.check.isNotEmpty),
        if (t.tokens > 0) _Fact(l.taskFactTokens, tokensLabel(t.tokens)),
        if (t.applied case final a?) _Fact(l.taskFactApplied, a.substring(0, a.length.clamp(0, 12)), mono: true),
      ]),
      if (t.ceiling case final c? when c < 4) ...[
        const SizedBox(height: 12),
        Text(l.taskCeilingExplain(c), key: const Key('task-ceiling-note'), style: XText.bodyDim.copyWith(color: XColors.warn)),
      ],
      const SizedBox(height: 16),
      SectionLabel(l.taskBrief),
      Text(t.brief.isEmpty ? l.taskNoBrief : plainModelText(t.brief), key: const Key('task-brief'), style: XText.body),
      if (worker != null && (worker.busy || (m.workerLive[worker.name]?.task == t.id))) ...[
        const SizedBox(height: 16),
        SectionLabel(l.taskLiveOutput(worker.name)),
        LiveOutput(worker.name, task: t.id, height: 200),
      ],
      const SizedBox(height: 16),
      SectionLabel(l.taskConversation),
      for (final s in taskSteps(l, t, team)) _StepRow(s, now: m.now()),
      if (t.notes.isNotEmpty) ...[
        const SizedBox(height: 16),
        SectionLabel(l.taskNotes),
        Text(plainModelText(t.notes), style: XText.mono.copyWith(color: XColors.text)),
      ],
    ]);
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.k, this.v, {this.mono = false});
  final String k;
  final String v;
  final bool mono;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(k.toUpperCase(), style: XText.overline),
        const SizedBox(height: 4),
        Text(v, style: mono ? XText.monoStrong : XText.body),
      ]);
}

/// One step of a task's conversation: who, what, when, and their words (data from them).
final class TaskStep {
  const TaskStep({required this.by, required this.what, required this.atMs, this.text = '', this.color});
  final String by;
  final String what;
  final int atMs;
  final String text;
  final Color? color;
}

/// The steps the full task carries: written, the worker's last report, each review, the last check, applied; by time.
List<TaskStep> taskSteps(AppLocalizations l, TaskInfo t, TeamInfo team) {
  final out = <TaskStep>[
    TaskStep(by: actorLabel(l, t.createdBy), what: l.taskStepCreated, atMs: t.createdMs),
    if (t.report case final r?)
      TaskStep(
        by: r.by,
        what: switch (r.state) {
          'submitted' => l.taskStepSubmitted,
          'blocked' => l.taskStepBlocked,
          _ => l.taskStepWorking,
        },
        atMs: r.atMs,
        text: r.summary,
        color: r.state == 'blocked' ? XColors.warn : null,
      ),
    for (final v in t.reviews)
      TaskStep(
        by: actorLabel(l, v.by),
        what: switch (v.verdict) {
          'accept' => l.taskStepAccepted,
          'cancel' => l.taskStepCancelled,
          _ => v.by == 'daemon' ? l.taskStepCheckReturned : l.taskStepChanges,
        },
        atMs: v.atMs,
        text: v.comments,
        color: v.verdict == 'accept' ? XColors.ok : (v.verdict == 'changes' ? XColors.warn : null),
      ),
    if (t.checkRun case final c?)
      TaskStep(
        by: actorLabel(l, c.by),
        what: l.taskStepChecked(checkOutcomeLabel(l, c.outcome)),
        atMs: c.atMs,
        color: checkOutcomeColor(c.outcome),
      ),
    if (t.applied case final a?)
      TaskStep(by: '', what: l.taskStepApplied(team.integration, a.substring(0, a.length.clamp(0, 12))), atMs: t.updatedMs, color: XColors.ok),
  ];
  out.sort((a, b) => a.atMs.compareTo(b.atMs));
  return out;
}

class _StepRow extends StatelessWidget {
  const _StepRow(this.s, {required this.now});
  final TaskStep s;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: s.color ?? XColors.lineStrong, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              if (s.by.isNotEmpty) TextSpan(text: '${s.by} ', style: XText.label.copyWith(color: XColors.text, fontWeight: FontWeight.w600)),
              TextSpan(text: s.what, style: XText.label),
              TextSpan(text: '  ${agoLabel(l, s.atMs, now)}', style: XText.meta),
            ])),
            if (s.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
                child: SelectableText(plainModelText(s.text), style: XText.body),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Changes extends StatelessWidget {
  const _Changes(this.t, {this.diff, this.error, this.loading = false});
  final TaskInfo t;
  final TaskDiffReply? diff;
  final Object? error;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final r = t.result;
    if (r != null && r.textOnly) {
      return ListView(padding: const EdgeInsets.only(top: 16), children: [
        Text(l.taskTextResult, style: XText.bodyDim),
        const SizedBox(height: 8),
        if (t.report case final rep? when rep.summary.isNotEmpty)
          SelectableText(plainModelText(rep.summary), key: const Key('task-text-result'), style: XText.body),
      ]);
    }
    if (loading) return Center(child: Text(l.commonLoading, style: XText.meta));
    if (error != null) return Padding(padding: const EdgeInsets.only(top: 16), child: ErrorLine(describeTeamError(l, error!)));
    final d = diff;
    if (d == null) return Center(child: Text(l.taskNoChangesYet, style: XText.meta));
    final lines = plainModelText(d.diff).split('\n');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            d.commit == null ? l.taskDiffFolder : l.taskDiffCommits(shortCommit(d.base), shortCommit(d.commit!)),
            style: XText.meta,
          ),
        ),
        TextButton.icon(
          key: const Key('task-diff-copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: d.diff)),
          icon: const Icon(Icons.copy_rounded, size: 14),
          label: Text(l.commonCopy),
        ),
      ]),
      if (d.stat.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(plainModelText(d.stat), key: const Key('task-diff-stat'), style: XText.monoSmall),
        ),
      if (d.truncated) Text(l.taskDiffTruncated, style: XText.meta.copyWith(color: XColors.warn)),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: XColors.bg2,
            borderRadius: BorderRadius.circular(XRadius.m),
            border: Border.all(color: XColors.line),
          ),
          child: d.diff.isEmpty
              ? Center(child: Text(l.taskDiffEmpty, style: XText.meta))
              : SelectionArea(
                  child: ListView.builder(
                    key: const Key('task-diff'),
                    padding: const EdgeInsets.all(8),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => _DiffLine(lines[i]),
                  ),
                ),
        ),
      ),
    ]);
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine(this.s);
  final String s;

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color? bg) = switch (s) {
      _ when s.startsWith('+++') || s.startsWith('---') || s.startsWith('diff ') || s.startsWith('index ') =>
        (XColors.textDim, null),
      _ when s.startsWith('+') => (XColors.ok, teamTint(XColors.ok)),
      _ when s.startsWith('-') => (XColors.danger, teamTint(XColors.danger)),
      _ when s.startsWith('@@') => (XColors.accent, null),
      _ => (XColors.text, null),
    };
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(s.isEmpty ? ' ' : s, style: XText.mono.copyWith(color: fg, height: 1.45), softWrap: false),
    );
  }
}

class _Checks extends StatelessWidget {
  const _Checks(this.t, this.team);
  final TaskInfo t;
  final TeamInfo team;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final c = t.checkRun;
    if (c == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          t.check.isEmpty ? l.taskNoCheckCommand : l.taskCheckNotRun(t.check.join(' ')),
          key: const Key('task-check-none'),
          style: XText.bodyDim,
        ),
      );
    }
    return ListView(padding: const EdgeInsets.only(top: 16), children: [
      Row(children: [
        TeamChip(checkOutcomeLabel(l, c.outcome), key: const Key('task-check-outcome'), color: checkOutcomeColor(c.outcome)),
        const SizedBox(width: 12),
        Expanded(child: Text(c.argv.join(' '), style: XText.monoStrong)),
      ]),
      const SizedBox(height: 12),
      FactRow(l.taskCheckFactExit, c.exitCode?.toString() ?? '—'),
      FactRow(l.taskCheckFactDuration, '${(c.durationMs / 1000).toStringAsFixed(2)} s'),
      FactRow(l.taskCheckFactSandbox, c.sandbox.isEmpty ? '—' : c.sandbox),
      FactRow(l.taskCheckFactBy, '${actorLabel(l, c.by)} · ${agoLabel(l, c.atMs, m.now())}'),
      FactRow(l.taskCheckFactWhat, c.commit == null ? l.taskCheckWhatFolder : shortCommit(c.commit!)),
      if (c.blockedHosts.isNotEmpty)
        FactRow(l.taskCheckFactBlocked, c.blockedHosts.join(', '), valueColor: XColors.warn),
      const SizedBox(height: 8),
      Text(
          team.template.checkHosts.isEmpty
              ? l.taskCheckSandboxNoNet
              : l.taskCheckSandboxNote(team.template.checkHosts.join(', ')),
          style: XText.meta),
      const SizedBox(height: 12),
      SectionLabel(l.taskCheckOutput),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
        child: SelectableText(
          c.output.isEmpty ? l.taskCheckNoOutput : plainModelText(c.output),
          key: const Key('task-check-output'),
          style: XText.mono.copyWith(color: XColors.text, height: 1.45),
        ),
      ),
    ]);
  }
}

class _Log extends StatelessWidget {
  const _Log(this.entries);
  final List<TeamLogEntry>? entries;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final e = entries;
    if (e == null) return Center(child: Text(l.commonLoading, style: XText.meta));
    if (e.isEmpty) return Center(child: Text(l.teamLogEmpty, style: XText.meta));
    return ListView(padding: const EdgeInsets.only(top: 12), children: [for (final x in e.reversed) TeamLogRow(x)]);
  }
}

/// One entry of a team's audit trail: when, who, what, the daemon's decision and its details.
class TeamLogRow extends StatelessWidget {
  const TeamLogRow(this.e, {super.key});
  final TeamLogEntry e;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final bad = {'denied', 'refused', 'failed'}.contains(e.decision);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(formatDateTime(l, DateTime.fromMillisecondsSinceEpoch(e.ts)), style: XText.monoSmall)),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: Text(actorLabel(l, e.actor), style: XText.label, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: e.action, style: XText.mono.copyWith(color: XColors.text)),
            TextSpan(text: '  ${e.decision}', style: XText.mono.copyWith(color: bad ? XColors.danger : XColors.textDim)),
            if (e.task case final t?) TextSpan(text: '  #${t.substring(0, t.length.clamp(0, 6))}', style: XText.monoSmall),
            if (e.detail.isNotEmpty) TextSpan(text: '\n${e.detail}', style: XText.monoSmall),
          ])),
        ),
      ]),
    );
  }
}

/// "Urgent: interrupt the worker now" (CONTROL §33, experimental) next to the review's actions.
class _UrgentSwitch extends StatelessWidget {
  const _UrgentSwitch({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Tooltip(
      message: '${l.taskUrgentTip}\n${l.experimentalTag} · ${l.experimentalTip}',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 26,
          child: FittedBox(child: Switch(key: const Key('task-urgent'), value: on, onChanged: onChanged)),
        ),
        const SizedBox(width: 4),
        Text(l.taskUrgent, style: XText.label.copyWith(color: on ? XColors.danger : XColors.text)),
        const SizedBox(width: 8),
        const ExperimentalTag(key: Key('experimental-task-urgent')),
      ]),
    );
  }
}
