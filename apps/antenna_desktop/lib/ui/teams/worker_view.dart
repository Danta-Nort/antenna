// SPDX-License-Identifier: AGPL-3.0-only
// A worker's live output (DESIGN "Teams"): what its current turn writes, as the daemon streams it on `team_watch`, the
// tool it uses, and how its last turn ended. Read-only: the window never types into a worker (the daemon runs it, and
// its turns come only from its tasks). The text is the worker's output, data: shown as plain text, never a link.
// A daemon without `team_watch` gives only the worker's last `detail` (the tail of its last turn), and the view says
// so. The same view stands in a task's detail, a worker's panel and the worker's tab in the Code mode dock.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/local_models.dart' show plainModelText;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/badges.dart';
import 'team_widgets.dart';

/// [worker]'s live output, newest at the bottom. [task]: only the output of a turn on this task.
class LiveOutput extends StatefulWidget {
  const LiveOutput(this.worker, {super.key, this.task, this.height = 220, this.expand = false});
  final String worker;
  final String? task;
  final double height;

  /// Take the height the parent gives (the dock) instead of [height].
  final bool expand;

  @override
  State<LiveOutput> createState() => _LiveOutputState();
}

class _LiveOutputState extends State<LiveOutput> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The view follows new output while the owner reads its end; scrolled up, it stays where the owner reads.
  bool _follow = true;

  void _toBottom() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final live = m.workerLive[widget.worker];
    final info = m.teamOfWorker(widget.worker)?.worker(widget.worker);
    final mine = live != null && (widget.task == null || live.task == null || live.task == widget.task);
    final String body;
    final String status;
    if (mine && (live.text.isNotEmpty || live.running)) {
      body = live.text;
      status = live.running
          ? (live.activity != null ? activityLabel(l, live.activity!) : l.workerWriting)
          : l.workerTurnEnded(live.ended ?? 'done');
    } else if (info != null && info.detail.isNotEmpty) {
      body = plainModelText(info.detail);
      status = m.teamWatchAbsent ? l.workerDetailOnly : l.workerLastTurn;
    } else {
      body = '';
      status = info?.busy ?? false ? l.workerWriting : l.workerNoOutput;
    }
    if (live?.running ?? false) _toBottom();
    final box = Container(
      key: Key('live-${widget.worker}'),
      decoration: BoxDecoration(
        color: XColors.bg2,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            if (live?.running ?? false) ...[
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
            ] else ...[
              Icon(Icons.notes_rounded, size: 14, color: XColors.textMute),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(status, key: Key('live-status-${widget.worker}'), style: XText.meta)),
            if (mine && live.turn != null) Text(l.workerTurn(live.turn!), style: XText.meta),
          ]),
        ),
        Divider(height: 1, color: XColors.line),
        Expanded(
          child: body.isEmpty
              ? Center(child: Text(l.workerNoOutputYet, style: XText.meta))
              : NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    // Only the owner's own scrolling changes it (a drag or the wheel), not the jump to the end.
                    if (n.dragDetails != null || n.metrics.pixels < n.metrics.maxScrollExtent - 24) {
                      _follow = n.metrics.pixels >= n.metrics.maxScrollExtent - 24;
                    }
                    return false;
                  },
                  child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: SelectableText(body,
                        key: Key('live-text-${widget.worker}'), style: XText.mono.copyWith(color: XColors.text, height: 1.5)),
                  ),
                ),
                ),
        ),
      ]),
    );
    return widget.expand ? box : SizedBox(height: widget.height, child: box);
  }
}

/// A worker's panel: its facts, its task, its live output, and Stop.
class WorkerPanel extends StatelessWidget {
  const WorkerPanel(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final team = m.teamOfWorker(name);
    final w = team?.worker(name);
    if (team == null || w == null) return Text(l.errNotFound, style: XText.bodyDim);
    final task = w.task == null ? null : m.task(w.task!);
    return Column(key: Key('worker-panel-$name'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        WorkerMonogram(name, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: XText.title),
            Text(l.workerOfTeam(team.name, w.role), style: XText.bodyDim),
          ]),
        ),
        TeamChip(workerStateLabel(l, w.state), color: workerStateColor(w.state)),
      ]),
      const SizedBox(height: 16),
      FactRow(l.workerFactKind, workerKindLabel(l, w.kind, model: w.model)),
      FactRow(l.workerFactMachine, w.machine == 'this computer' ? l.teamCapThisComputer : w.machine),
      FactRow(l.workerFactSpawnedBy, actorLabel(l, w.spawnedBy)),
      FactRow(l.workerFactTask, task == null ? (w.task ?? '—') : '${task.shortId} · ${task.title}'),
      FactRow(l.workerFactTurns, l.workerTurnsTokens(w.turns, tokensLabel(w.inputTokens), tokensLabel(w.outputTokens))),
      if (w.queued > 0) FactRow(l.workerFactQueued, '${w.queued}'),
      if (w.ceiling case final c?) FactRow(l.workerFactCeiling, l.teamCeilingTip(c)),
      const SizedBox(height: 12),
      LiveOutput(name, height: 260),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(l.workerReadOnlyNote, style: XText.meta)),
        if (!w.stopped)
          BusyButton(
            key: Key('worker-stop-$name'),
            label: l.workerStop,
            icon: Icons.stop_rounded,
            style: BusyStyle.destructive,
            onRun: () => m.stopTeam(team.name, worker: name),
          ),
      ]),
    ]);
  }
}

/// A worker's tab in the Code mode dock, after the terminals: its state and name, and a mark that the daemon runs it.
class WorkerDockTab extends StatelessWidget {
  const WorkerDockTab(this.w, {super.key, required this.selected});
  final WorkerInfo w;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.read(context);
    final l = context.l;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: l.workerDockTabTip(w.team),
        child: Material(
          color: selected ? XColors.bg1 : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(XRadius.m),
            side: BorderSide(color: selected ? XColors.lineStrong : Colors.transparent),
          ),
          child: InkWell(
            key: Key('dock-worker-tab-${w.name}'),
            borderRadius: BorderRadius.circular(XRadius.m),
            onTap: () => m.showWorkerInDock(w.name),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                WorkerDot(w.state),
                const SizedBox(width: 8),
                Icon(Icons.groups_2_outlined, size: 14, color: XColors.textMute),
                const SizedBox(width: 4),
                Text(w.name, style: XText.label.copyWith(color: selected ? XColors.text : XColors.textDim)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A worker in the Code mode dock: who it is, its task, its live output (read-only), its board and Stop.
class WorkerDockView extends StatelessWidget {
  const WorkerDockView(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final team = m.teamOfWorker(name);
    final w = team?.worker(name);
    if (team == null || w == null) return Center(child: Text(l.errNotFound, style: XText.bodyDim));
    final task = w.task == null ? null : m.task(w.task!);
    return Column(key: Key('dock-worker-$name'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        color: XColors.bg1,
        child: Row(children: [
          WorkerDot(w.state),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.workerDockTitle(name, workerStateLabel(l, w.state)), style: XText.label.copyWith(color: XColors.text)),
              Text(
                task == null ? l.workerOfTeam(team.name, w.role) : l.workerDockTask(team.name, task.shortId, task.title),
                style: XText.meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          TextButton(
            key: Key('dock-worker-board-$name'),
            onPressed: () => m.openBoard(team.name, show: true),
            child: Text(l.workerOpenBoard),
          ),
          if (!w.stopped)
            BusyButton(
              key: Key('dock-worker-stop-$name'),
              label: l.workerStop,
              style: BusyStyle.destructive,
              onRun: () => m.stopTeam(team.name, worker: name),
            ),
        ]),
      ),
      Divider(height: 1, color: XColors.line),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LiveOutput(name, task: w.task, expand: true),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(l.workerReadOnlyNote, style: XText.meta),
      ),
    ]);
  }
}
