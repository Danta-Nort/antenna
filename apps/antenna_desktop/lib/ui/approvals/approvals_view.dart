// SPDX-License-Identifier: AGPL-3.0-only
// The list of approval requests (SPEC §9). Each request is an [ApprovalCard] (approval_card.dart): the daemon's
// options are allow once (Approve), deny, and deny everything from the contact for an hour; the same card, compact,
// stands in the conversation the request is about.
// Several requests (v6, D-UI-18): the list selects them and approves them with the password typed once
// (`approve_many`: each request is still approved on its own, with its fingerprint) or denies them without a
// password; a request that fails (expired, changed) is reported alone and the rest go through. Approved requests the
// daemon is still finishing (x-control/6), or failed to finish, stand first, without checkboxes. With Touch ID on
// (D-102), one touch approves the selected list: the signed request names every item and its fingerprint.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/messages.dart';
import '../../state/touch_id.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/touch_id_text.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'approval_card.dart';
import 'approver_notes.dart';
import 'question_card.dart';

export 'approval_card.dart';

Future<void> showApprovalsDialog(BuildContext context) => showXDialog<void>(context, (_) => const ApprovalsDialog());

class ApprovalsDialog extends StatefulWidget {
  const ApprovalsDialog({super.key});

  @override
  State<ApprovalsDialog> createState() => _ApprovalsDialogState();
}

class _ApprovalsDialogState extends State<ApprovalsDialog> {
  Timer? _tick;

  /// Selected request IDs (several requests at once).
  final _selected = <String>{};
  bool _busy = false;

  /// The last batch: what was decided, what failed and why (the failed requests may have left the list already).
  _BatchOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _approveSelected(List<ApprovalInfo> items) async {
    final l = context.l;
    final m = AppScope.read(context);
    String? note;
    if (m.touchIdReady) {
      setState(() => _busy = true);
      final (results, err) = await m.approveManyWithTouchId(items, reason: touchIdBatchReason(l, items));
      if (!mounted) return;
      if (err == null || TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) {
        _done(items, results, err);
        return;
      }
      setState(() => _busy = false);
      note = touchIdFallbackNote(l, m, err);
    }
    final pw = await askOwnerPassword(
      context,
      note: note,
      action: l.approvalsApproveManyAction(items.length),
      detail: l.approvalsApproveManyDetail(items.map((a) => a.fingerprint).join(', ')),
      cli: 'antenna approve ${items.map((a) => a.id).join(' ')}',
    );
    if (pw == null || !mounted) return;
    setState(() => _busy = true);
    final (results, err) = await m.approveMany(items, pw);
    if (!mounted) return;
    _done(items, results, err);
  }

  void _done(List<ApprovalInfo> items, List<ApprovalResult> results, Object? err) {
    setState(() {
      _busy = false;
      _outcome = _BatchOutcome(results, {for (final a in items) a.id: a}, err, approved: true);
      _selected.removeAll([for (final r in results) if (r.ok) r.id]);
    });
  }

  Future<void> _denySelected(List<ApprovalInfo> items) async {
    final l = context.l;
    final m = AppScope.read(context);
    final ids = [for (final a in items) a.id];
    setState(() => _busy = true);
    var (results, err) = await m.denyMany(ids);
    if (AppModel.denyNeedsPassword(err) && mounted) {
      // A daemon older than D-84 still wants the password to deny.
      setState(() => _busy = false);
      final pw = await askOwnerPassword(context, action: l.approvalsDenySelected, cli: 'antenna deny ${ids.join(' ')}');
      if (pw == null || !mounted) return;
      setState(() => _busy = true);
      (results, err) = await m.denyMany(ids, password: pw);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = _BatchOutcome(results, {for (final a in items) a.id: a}, err, approved: false);
      _selected.removeAll([for (final r in results) if (r.ok) r.id]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final list = m.approvals.values.toList()..sort((a, b) => a.createdMs.compareTo(b.createdMs));
    // Decided by an approver agent in the owner's place (CONTROL §31): each stays until the owner dismisses it; its
    // finishing state is shown on the same card.
    final decided = m.decidedByApprovers.values.toList().reversed.toList();
    // Approved, and the daemon is finishing them (or failed to): first, without checkboxes or buttons.
    final done = [for (final f in m.finishing.values) if (!m.decidedByApprovers.containsKey(f.approval.id)) f]
      ..sort((a, b) => a.approval.createdMs.compareTo(b.approval.createdMs));
    final l = context.l;
    // Requests that left (decided elsewhere, expired) are no longer selectable.
    _selected.retainWhere((id) => list.any((a) => a.id == id));
    final selected = [for (final a in list) if (_selected.contains(a.id)) a];
    final several = list.length > 1;
    return XDialogShell(
      title: l.approvalsTitle,
      icon: Icons.gpp_maybe_outlined,
      subtitle: l.approvalsSubtitle,
      width: 680,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (several) ...[
          _BatchBar(
            total: list.length,
            selected: selected.length,
            busy: _busy,
            onSelectAll: (v) => setState(() {
              if (v) {
                _selected.addAll(list.map((a) => a.id));
              } else {
                _selected.clear();
              }
            }),
            touch: m.touchIdReady,
            onApprove: () => _approveSelected(selected),
            onDeny: () => _denySelected(selected),
          ),
          const SizedBox(height: 12),
        ],
        if (_outcome != null) ...[_OutcomePanel(_outcome!), const SizedBox(height: 12)],
        // The agents' questions (D-118) come first: an agent waits for the owner's word
        if (m.questions.isNotEmpty) ...[
          Text(l.questionsTitle, key: const Key('questions-title'), style: XText.title),
          const SizedBox(height: 8),
          for (final q in m.questions) ...[
            QuestionCard(q, key: ValueKey('question-card-${q.id}')),
            const SizedBox(height: 12),
          ],
          if (list.isNotEmpty || done.isNotEmpty) ...[
            Text(l.approvalsTitle, style: XText.title),
            const SizedBox(height: 8),
          ],
        ],
        if (decided.isNotEmpty) ...[
          Text(l.decidedSectionTitle, key: const Key('decided-title'), style: XText.title),
          const SizedBox(height: 8),
          for (final a in decided) ...[
            DecidedCard(a, key: ValueKey('decided-card-${a.id}'), finish: m.finishing[a.id]),
            const SizedBox(height: 12),
          ],
          if (list.isNotEmpty || done.isNotEmpty) ...[
            Text(l.approvalsTitle, style: XText.title),
            const SizedBox(height: 8),
          ],
        ],
        if (list.isEmpty && done.isEmpty && m.questions.isEmpty && decided.isEmpty)
          Text(
            m.hiddenQuietApprovals > 0 ? l.approvalsNoneButQuiet(m.hiddenQuietApprovals) : l.approvalsNone,
            style: XText.bodyDim,
          )
        else ...[
          for (final f in done) ...[
            ApprovalCard(f.approval, key: ValueKey('approval-finish-${f.approval.id}'), finish: f),
            const SizedBox(height: 12),
          ],
          for (final a in list) ...[
            if (several)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 16, right: 8),
                  child: Checkbox(
                    key: Key('select-${a.id}'),
                    value: _selected.contains(a.id),
                    semanticLabel: approvalWhat(l, a),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => v ?? false ? _selected.add(a.id) : _selected.remove(a.id)),
                  ),
                ),
                Expanded(child: ApprovalCard(a)),
              ])
            else
              ApprovalCard(a),
            const SizedBox(height: 12),
          ],
          if (m.hiddenQuietApprovals > 0) Text(l.approvalsMoreQuiet(m.hiddenQuietApprovals), style: XText.monoSmall),
        ],
      ]),
    );
  }
}

/// What a batch did: the per-request results, the requests as they were shown, and the error of the whole call.
class _BatchOutcome {
  _BatchOutcome(this.results, this.shown, this.error, {required this.approved});
  final List<ApprovalResult> results;
  final Map<String, ApprovalInfo> shown;
  final Object? error;
  final bool approved;
}

/// "Select all", how many are selected, Deny selected and Approve selected.
class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.total,
    required this.selected,
    required this.busy,
    required this.onSelectAll,
    required this.onApprove,
    required this.onDeny,
    this.touch = false,
  });
  final int total;
  final int selected;
  final bool busy;

  /// One touch approves the selection (Touch ID on).
  final bool touch;
  final ValueChanged<bool> onSelectAll;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final none = selected == 0;
    return Container(
      key: const Key('approvals-batch'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.l),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        children: [
          InkWell(
            key: const Key('approvals-select-all'),
            borderRadius: BorderRadius.circular(XButtons.radius),
            onTap: busy ? null : () => onSelectAll(selected < total),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                tristate: true,
                value: none ? false : (selected == total ? true : null),
                onChanged: busy ? null : (_) => onSelectAll(selected < total),
              ),
              Text(l.approvalsSelectAll, style: XText.label.copyWith(color: XColors.text)),
              const SizedBox(width: 8),
              Text(l.approvalsSelectedCount(selected), style: XText.meta),
              const SizedBox(width: 8),
            ]),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton(
              key: const Key('deny-selected'),
              style: XButtons.secondary(),
              onPressed: busy || none ? null : onDeny,
              child: Text(l.approvalsDenySelected),
            ),
            const SizedBox(width: 8),
            if (touch)
              FilledButton.icon(
                key: const Key('approve-selected'),
                style: XButtons.primary(),
                onPressed: busy || none ? null : onApprove,
                icon: const Icon(Icons.fingerprint, size: 18),
                label: Text(l.approvalsApproveSelected),
              )
            else
              FilledButton(
                key: const Key('approve-selected'),
                style: XButtons.primary(),
                onPressed: busy || none ? null : onApprove,
                child: Text(l.approvalsApproveSelected),
              ),
          ]),
        ],
      ),
    );
  }
}

/// The batch's result: "2 approved · 1 not decided:" and one line per request that failed alone.
class _OutcomePanel extends StatelessWidget {
  const _OutcomePanel(this.o);
  final _BatchOutcome o;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (o.error != null) return ErrorLine(describeError(l, o.error!), detail: errorDetail(o.error!));
    final ok = o.results.where((r) => r.ok).length;
    final failed = o.results.where((r) => !r.ok).toList();
    return Container(
      key: const Key('approvals-outcome'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          [
            o.approved ? l.approvalsBatchApproved(ok) : l.approvalsBatchDenied(ok),
            if (failed.isNotEmpty) l.approvalsBatchFailed(failed.length),
          ].join(' · '),
          style: XText.label.copyWith(color: XColors.text),
        ),
        for (final r in failed)
          Padding(
            key: Key('approvals-failed-${r.id}'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              batchFailureLine(l, r, o.shown[r.id]),
              style: XText.monoSmall.copyWith(color: XColors.danger),
            ),
          ),
      ]),
    );
  }
}
