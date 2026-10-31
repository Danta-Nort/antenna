// SPDX-License-Identifier: AGPL-3.0-only
// The board's dialogs (DESIGN "Teams"): New task, Add worker, Apply to the project's branch (the owner's approval,
// with the password, pinned to the commit the owner saw), the team's log, Stop, Make active again, Remove. What needs
// the password asks for it each time; nothing is remembered (D-UI-3).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../state/wake.dart' show splitCommand;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'task_dialog.dart' show TeamLogRow, showTaskDialog;
import 'team_widgets.dart';

/// The first [n] digits of a commit.
String shortCommit(String c, [int n = 12]) => c.length <= n ? c : c.substring(0, n);

/// A panel in a dialog (a worker's details).
Future<void> showTeamPanel(BuildContext context, WidgetBuilder builder) => showXDialog<void>(
      context,
      (ctx) => XDialogShell(title: ctx.l.workerTitle, icon: Icons.engineering_outlined, width: 640, child: builder(ctx)),
    );

// New task.

Future<void> showNewTaskDialog(BuildContext context, TeamInfo t) =>
    showXDialog<void>(context, (_) => _NewTask(t), dismissible: false);

class _NewTask extends StatefulWidget {
  const _NewTask(this.t);
  final TeamInfo t;

  @override
  State<_NewTask> createState() => _NewTaskState();
}

class _NewTaskState extends State<_NewTask> {
  final _title = TextEditingController();
  final _brief = TextEditingController();
  late int _check = widget.t.template.checks.isEmpty ? -1 : 0;
  String? _assignee;
  Object? _error;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _brief.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final m = AppScope.read(context);
    final title = _title.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final (task, err) = await m.newTask(TaskNewRequest(
      team: widget.t.name,
      title: title,
      brief: _brief.text.trim(),
      check: _check < 0 ? const [] : widget.t.template.checks[_check],
      assignee: _assignee,
    ));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (task != null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = widget.t;
    final free = [
      for (final w in t.workers)
        if (!w.stopped && w.task == null) w.name,
    ];
    return XDialogShell(
      title: l.taskNewTitle(t.name),
      icon: Icons.add_task_rounded,
      width: 600,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton.icon(
          key: const Key('task-new-create'),
          onPressed: _busy ? null : _create,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded, size: 16),
          label: Text(l.taskNewCreate),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('task-new-title'),
          controller: _title,
          autofocus: true,
          decoration: InputDecoration(labelText: l.taskNewTitleField, hintText: l.taskNewTitleHint),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('task-new-brief'),
          controller: _brief,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(labelText: l.taskNewBrief, hintText: l.taskNewBriefHint, alignLabelWithHint: true),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          key: const Key('task-new-check'),
          initialValue: _check,
          decoration: InputDecoration(labelText: l.taskNewCheck, helperText: l.taskNewCheckHelp),
          items: [
            DropdownMenuItem(value: -1, child: Text(l.taskNoCheck)),
            for (var i = 0; i < t.template.checks.length; i++)
              DropdownMenuItem(value: i, child: Text(t.template.checks[i].join(' '), style: XText.monoStrong)),
          ],
          onChanged: (v) => setState(() => _check = v ?? -1),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          key: const Key('task-new-assignee'),
          initialValue: _assignee,
          decoration: InputDecoration(labelText: l.taskNewAssignee),
          items: [
            DropdownMenuItem(value: null, child: Text(t.lead == null ? l.taskNewAssignLater : l.taskNewLeaveForLead(t.lead!))),
            for (final n in free) DropdownMenuItem(value: n, child: Text(n)),
          ],
          onChanged: (v) => setState(() => _assignee = v),
        ),
        if (free.isEmpty && t.lead == null) ...[
          const SizedBox(height: 8),
          Text(l.taskNewNoFreeWorker, style: XText.meta),
        ],
        const SizedBox(height: 12),
        Text(
          l.commonSameAs('antenna task new ${t.name} "${_title.text.trim().isEmpty ? '…' : _title.text.trim()}"'
              '${_check >= 0 ? ' --check "${t.template.checks[_check].join(' ')}"' : ''}${_assignee == null ? '' : ' --assign $_assignee'}'),
          style: XText.monoSmall,
        ),
        if (_error case final e?) ErrorLine(describeTeamError(l, e), detail: errorDetail(e)),
      ]),
    );
  }
}

// Add worker.

Future<void> showAddWorkerDialog(BuildContext context, TeamInfo t) =>
    showXDialog<void>(context, (_) => _AddWorker(t));

class _AddWorker extends StatefulWidget {
  const _AddWorker(this.t);
  final TeamInfo t;

  @override
  State<_AddWorker> createState() => _AddWorkerState();
}

class _AddWorkerState extends State<_AddWorker> {
  int _slot = 0;
  Object? _error;
  bool _busy = false;

  Future<void> _add() async {
    final s = widget.t.slots[_slot];
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).addTeamWorker(widget.t.name, s.role, kind: s.kind);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final t = widget.t;
    final cap = m.capacity(t.name);
    return XDialogShell(
      title: l.workerAddTitle(t.name),
      icon: Icons.person_add_alt_rounded,
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton.icon(
          key: const Key('worker-add-ok'),
          onPressed: _busy || t.slots.isEmpty ? null : _add,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded, size: 16),
          label: Text(l.workerAddOk),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.workerAddAbout, style: XText.bodyDim),
        const SizedBox(height: 12),
        if (t.slots.isEmpty) Text(l.workerAddNoSlots, style: XText.bodyDim),
        RadioGroup<int>(
          groupValue: _slot,
          onChanged: (v) => setState(() => _slot = v ?? 0),
          // The list tiles paint on the nearest Material: the dialog's panel is a decorated box.
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: [
            for (var i = 0; i < t.slots.length; i++)
              RadioListTile<int>(
                key: Key('worker-add-slot-$i'),
                value: i,
                contentPadding: EdgeInsets.zero,
                title: Text('${t.slots[i].role} · ${workerKindLabel(l, t.slots[i].kind, model: t.slots[i].model)}'),
                subtitle: Text(
                  cap == null
                      ? l.teamCapSlotMax(t.slots[i].max)
                      : l.teamCapSlotUse(cap.slots[i].used, t.slots[i].max, cap.slots[i].free),
                  style: XText.meta,
                ),
              ),
          ]),
          ),
        ),
        const SizedBox(height: 8),
        Text(l.commonSameAs('antenna team add-worker ${t.name} ${t.slots.isEmpty ? '<role>' : t.slots[_slot].role}'),
            style: XText.monoSmall),
        if (_error case final e?) ErrorLine(describeTeamError(l, e), detail: errorDetail(e)),
      ]),
    );
  }
}

// Apply the team's branch to the project's branch.

Future<void> showApplyTeamDialog(BuildContext context, TeamInfo t) =>
    showXDialog<void>(context, (_) => _ApplyTeam(t.name), dismissible: false);

class _ApplyTeam extends StatefulWidget {
  const _ApplyTeam(this.name);
  final String name;

  @override
  State<_ApplyTeam> createState() => _ApplyTeamState();
}

class _ApplyTeamState extends State<_ApplyTeam> {
  final _auth = OwnerAuthController();
  Object? _error;
  bool _busy = false;
  bool _done = false;

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _apply(TeamInfo t, String? commit) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = AppScope.read(context);
    final l = context.l;
    final err = await m.applyTeam(t.name,
        commit: commit, auth: _auth.auth(m, touchIdConfirmReason(l, l.teamApplyTitle(t.target))));
    if (!mounted) return;
    _auth.password.clear();
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
      _done = err == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final t = m.team(widget.name);
    if (t == null) return XDialogShell(title: l.teamApplyTitle('main'), child: Text(l.errNotFound));
    final r = t.applyRequest;
    // What the owner reviews and pins: the team's branch as it is now (a request names the commit of its time).
    final commit = t.integrationCommit ?? r?.commit;
    final moved = r != null && commit != null && r.commit != commit;
    final done = [for (final x in t.tasks) if (x.state == TaskState.done) x];
    return XDialogShell(
      key: const Key('team-apply-dialog'),
      title: l.teamApplyTitle(t.target),
      icon: Icons.merge_rounded,
      width: 620,
      actions: _done
          ? [FilledButton(key: const Key('team-apply-close'), onPressed: () => Navigator.pop(context), child: Text(l.commonDone))]
          : [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              FilledButton.icon(
                key: const Key('team-apply-ok'),
                onPressed: _busy || commit == null ? null : () => _apply(t, commit),
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.merge_rounded, size: 16),
                label: Text(l.teamApplyOk(t.target)),
              ),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_done)
          Row(key: const Key('team-apply-done'), children: [
            Icon(Icons.check_circle_outline_rounded, color: XColors.ok, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(l.teamApplyDone(t.integration, t.target), style: XText.body)),
          ])
        else ...[
          Text(l.teamApplyAbout(t.integration, t.target, t.project), style: XText.body),
          const SizedBox(height: 8),
          Text(l.teamApplyLocalChanges, style: XText.bodyDim),
          const SizedBox(height: 12),
          if (r != null)
            Text(l.teamApplyRequested(r.by, agoLabel(l, r.atMs, m.now()), shortCommit(r.commit)),
                key: const Key('team-apply-requested'), style: XText.bodyDim),
          if (moved) ...[
            const SizedBox(height: 4),
            Text(l.teamApplyMovedSince(shortCommit(commit)), style: XText.bodyDim.copyWith(color: XColors.warn)),
          ],
          if (!t.template.ownerApplies) ...[
            const SizedBox(height: 4),
            Text(l.teamApplyLeadMayToo(t.lead ?? ''), style: XText.meta),
          ],
          const SizedBox(height: 12),
          Text(l.teamApplyIncludes(done.length), style: XText.label.copyWith(color: XColors.text)),
          const SizedBox(height: 4),
          for (final x in done.take(8))
            InkWell(
              onTap: () => unawaited(showTaskDialog(context, x.id, tab: 1)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.check_rounded, size: 14, color: XColors.ok),
                  const SizedBox(width: 8),
                  Text('#${x.shortId}', style: XText.monoSmall),
                  const SizedBox(width: 8),
                  Expanded(child: Text(x.title, style: XText.bodyDim, overflow: TextOverflow.ellipsis)),
                  if (x.result case final res? when !res.textOnly)
                    Text(l.taskDiffStat(res.insertions, res.deletions, res.files), style: XText.meta),
                ]),
              ),
            ),
          if (done.length > 8) Text(l.teamApplyMore(done.length - 8), style: XText.meta),
          const SizedBox(height: 12),
          if (commit != null) Text(l.commonSameAs('antenna team apply ${t.name} --commit ${shortCommit(commit)}'), style: XText.monoSmall),
          const SizedBox(height: 12),
          OwnerAuthField(
            controller: _auth,
            autofocus: true,
            onSubmitted: (_) => _busy || commit == null ? null : _apply(t, commit),
          ),
        ],
        if (_error case final e?) ErrorLine(describeTeamError(l, e), detail: errorDetail(e)),
      ]),
    );
  }
}

// The log.

Future<void> showTeamLogDialog(BuildContext context, TeamInfo t) => showXDialog<void>(context, (_) => _TeamLog(t.name));

class _TeamLog extends StatefulWidget {
  const _TeamLog(this.name);
  final String name;

  @override
  State<_TeamLog> createState() => _TeamLogState();
}

class _TeamLogState extends State<_TeamLog> {
  List<TeamLogEntry>? _entries;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final (e, err) = await AppScope.read(context).teamLog(widget.name);
      if (mounted) {
        setState(() {
          _entries = e;
          _error = err;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final e = _entries;
    return XDialogShell(
      key: const Key('team-log-dialog'),
      title: l.teamLogTitle(widget.name),
      icon: Icons.receipt_long_outlined,
      width: 760,
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.teamLogAbout, style: XText.bodyDim),
        const SizedBox(height: 12),
        if (_error case final err?) ErrorLine(describeTeamError(l, err)),
        if (e == null && _error == null) Text(l.commonLoading, style: XText.meta),
        if (e != null && e.isEmpty) Text(l.teamLogEmpty, style: XText.meta),
        if (e != null) for (final x in e.reversed) TeamLogRow(x),
      ]),
    );
  }
}

// Stop, make active again, remove.

Future<void> confirmStopTeam(BuildContext context, TeamInfo t) async {
  final l = context.l;
  final ok = await showXDialog<bool>(
    context,
    (ctx) => XDialogShell(
      title: l.teamStopTitle(t.name),
      icon: Icons.stop_circle_outlined,
      width: 480,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.commonCancel)),
        TextButton(
          key: const Key('team-stop-ok'),
          style: XButtons.destructive(),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l.teamStop),
        ),
      ],
      child: Text(l.teamStopAbout, style: XText.body),
    ),
  );
  if (ok != true || !context.mounted) return;
  final err = await AppScope.read(context).stopTeam(t.name);
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeTeamError(l, err))));
  }
}

Future<void> reactivateTeam(BuildContext context, TeamInfo t) async {
  final l = context.l;
  final m = AppScope.read(context);
  final (_, err) = await confirmOwner(context,
      action: l.teamActivateAction(t.name),
      detail: l.teamActivateDetail,
      cli: 'antenna team set ${t.name}',
      run: (auth) => m.reactivateTeam(t.name, auth));
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeTeamError(l, err))));
  }
}

Future<void> confirmRemoveTeam(BuildContext context, TeamInfo t) async {
  final l = context.l;
  final ok = await showXDialog<bool>(
    context,
    (ctx) => XDialogShell(
      title: l.teamRemoveTitle(t.name),
      icon: Icons.delete_outline_rounded,
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('team-remove-ok'),
          style: XButtons.destructiveFilled(),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l.teamRemove),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.teamRemoveAbout(t.integration), style: XText.body),
        const SizedBox(height: 8),
        Text(l.commonSameAs('antenna team remove ${t.name} --yes'), style: XText.monoSmall),
      ]),
    ),
  );
  if (ok != true || !context.mounted) return;
  final err = await AppScope.read(context).removeTeam(t.name);
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeTeamError(l, err))));
  }
}

/// A command line split as a shell would (quotes), for check commands; `null` when it does not parse.
List<String>? parseCheckCommand(String s) {
  final argv = splitCommand(s.trim());
  return argv == null || argv.isEmpty ? null : argv;
}
