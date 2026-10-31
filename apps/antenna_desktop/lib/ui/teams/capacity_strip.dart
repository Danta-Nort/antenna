// SPDX-License-Identifier: AGPL-3.0-only
// A team's capacity strip and its workers (DESIGN "Teams"): per machine the sandbox, the workers of all teams against
// the machine's limit, each slot of the budget used and free (with the daemon's reason when one cannot start), the
// local models in memory, and the work waiting. Facts from `team_capacity`; a daemon without it gets the same facts
// derived from the budget, and the strip says so.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import 'team_dialogs.dart';
import 'team_widgets.dart';
import 'worker_view.dart';

class CapacityStrip extends StatelessWidget {
  const CapacityStrip(this.t, {super.key});
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final c = m.capacity(t.name);
    if (c == null) return const SizedBox.shrink();
    Widget cell(String label, String value, {Key? key, Color? color, String? tip}) {
      final w = Column(key: key, crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label.toUpperCase(), style: XText.overline),
        const SizedBox(height: 4),
        Text(value, style: XText.body.copyWith(color: color ?? XColors.text, fontWeight: FontWeight.w500)),
      ]);
      return tip == null ? w : Tooltip(message: tip, child: w);
    }

    return Container(
      key: const Key('capacity-strip'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: XColors.bg1,
        borderRadius: BorderRadius.circular(XRadius.l),
        border: Border.all(color: XColors.line),
      ),
      child: Wrap(spacing: 32, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.start, children: [
        cell(
          l.teamCapMachine,
          c.derived ? l.teamCapThisComputer : l.teamCapMachineFacts(c.sandbox, c.machineWorkers, c.machineMax),
          key: const Key('cap-machine'),
          color: !c.derived && c.sandbox == 'none' ? XColors.danger : null,
          tip: c.derived ? l.teamCapDerivedTip : (c.sandbox == 'none' ? l.teamCapNoSandboxTip : null),
        ),
        cell(l.teamCapWorkers, l.teamCapWorkersOf(c.teamWorkers, c.teamMax), key: const Key('cap-workers')),
        for (final s in c.slots)
          cell(
            '${s.slot.role} · ${workerKindLabel(l, s.slot.kind, model: s.slot.model)}',
            s.unavailable != null ? l.teamCapSlotUnavailable(s.used, s.slot.max) : l.teamCapSlotUse(s.used, s.slot.max, s.free),
            key: Key('cap-slot-${s.slot.role}-${s.slot.kind}'),
            color: s.unavailable != null ? XColors.warn : null,
            tip: s.unavailable,
          ),
        cell(l.teamCapModels, c.modelsLoaded.isEmpty ? l.teamCapModelsNone : c.modelsLoaded.join(', '), key: const Key('cap-models')),
        // Own computers that lend themselves (My devices): listed by the daemon; no worker runs there yet.
        if (c.otherMachines.isNotEmpty)
          cell(l.teamCapOtherMachines, c.otherMachines.join(', '),
              key: const Key('cap-other-machines'), tip: l.teamCapOtherMachinesTip),
        cell(l.teamCapQueued, l.teamCapQueuedValue(c.openTasks, c.queuedTurns), key: const Key('cap-queued')),
      ]),
    );
  }
}

/// The team's workers: each with its state, role, kind and task; a click shows its output and Stop.
class WorkersStrip extends StatelessWidget {
  const WorkersStrip(this.t, {super.key});
  final TeamInfo t;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final ws = [...t.workers]..sort((a, b) => (a.stopped ? 1 : 0).compareTo(b.stopped ? 1 : 0));
    if (ws.isEmpty) {
      return Text(t.lead == null ? l.teamNoWorkersOwner : l.teamNoWorkersLead(t.lead!), style: XText.bodyDim);
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [for (final w in ws) _WorkerChip(w)]);
  }
}

class _WorkerChip extends StatelessWidget {
  const _WorkerChip(this.w);
  final WorkerInfo w;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final live = m.workerLive[w.name];
    final doing = w.task == null ? workerStateLabel(l, w.state) : l.workerOnTask(workerStateLabel(l, w.state), w.task!.substring(0, 6));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('worker-${w.name}'),
        borderRadius: BorderRadius.circular(XRadius.m),
        onTap: () => showWorkerDialog(context, w.name),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          decoration: BoxDecoration(
            color: XColors.bg1,
            borderRadius: BorderRadius.circular(XRadius.m),
            border: Border.all(color: XColors.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            WorkerMonogram(w.name, size: 24),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(w.name, style: XText.label.copyWith(color: XColors.text)),
                const SizedBox(width: 8),
                WorkerDot(w.state),
                if (live != null && live.running && live.activity != null) ...[
                  const SizedBox(width: 4),
                  Text(activityLabel(l, live.activity!), style: XText.meta),
                ],
              ]),
              const SizedBox(height: 2),
              Text('${workerKindLabel(l, w.kind, model: w.model)} · $doing', style: XText.meta),
            ]),
            if (w.ceiling case final c? when c < 5) ...[const SizedBox(width: 8), CeilingChip(c)],
          ]),
        ),
      ),
    );
  }
}

/// A worker's details: what it is, what it does, its live output, and Stop (no password: it only takes work away).
Future<void> showWorkerDialog(BuildContext context, String name) => showTeamPanel(
      context,
      (ctx) => WorkerPanel(name),
    );
