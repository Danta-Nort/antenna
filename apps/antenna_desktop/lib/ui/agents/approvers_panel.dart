// SPDX-License-Identifier: AGPL-3.0-only
// The approvers and what they answered (CONTROL §31, PG-57; experimental): each agent the owner named, with whose
// requests and which kinds it answers, **Change…** and **Revoke** (no password: it only takes away, D-84), and the
// latest answers given in the owner's place: approved, denied, or not counted, by whom, what, its reason (the agent's
// own words, quoted) and when. On the Agents page once there is anything to show, and as a dialog from an approval
// card's **Change**.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../approvals/approval_card.dart' show actionLabel;
import '../approvals/approver_notes.dart' show delegateWhyWords;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';
import 'approver_dialog.dart';

/// The approvers and every answer the daemon keeps (newest first).
Future<void> showApproversDialog(BuildContext context) =>
    showXDialog<void>(context, (_) => const ApproversDialog());

class ApproversDialog extends StatefulWidget {
  const ApproversDialog({super.key});

  @override
  State<ApproversDialog> createState() => _ApproversDialogState();
}

class _ApproversDialogState extends State<ApproversDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshApprovers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    return XDialogShell(
      key: const Key('approvers-dialog'),
      title: l.approversTitle,
      icon: Icons.how_to_reg_outlined,
      titleTag: const ExperimentalTag(),
      subtitle: l.approversAbout,
      width: 720,
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose))],
      child: m.approversSupported
          ? const ApproversList(answersShown: 200)
          : Text(l.approverNeedsNewer, style: XText.bodyDim),
    );
  }
}

/// The Agents page's section: shown once the daemon has an approver or an answer to show.
class ApproversSection extends StatelessWidget {
  const ApproversSection({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final r = m.approvers;
    if (!m.approversKnown || r == null || (r.approvers.isEmpty && r.answers.isEmpty)) return const SizedBox.shrink();
    return Column(key: const Key('approvers-section'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Row(children: [
        Flexible(child: Text(l.approversTitle, style: XText.h2)),
        const SizedBox(width: 8),
        const ExperimentalTag(),
      ]),
      const SizedBox(height: 8),
      Text(l.approversAbout, style: XText.bodyDim),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
        child: const ApproversList(answersShown: 3),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

/// The approvers with Change… and Revoke, then the latest [answersShown] answers.
class ApproversList extends StatefulWidget {
  const ApproversList({super.key, required this.answersShown});
  final int answersShown;

  @override
  State<ApproversList> createState() => _ApproversListState();
}

class _ApproversListState extends State<ApproversList> {
  Object? _error;
  bool _busy = false;

  Future<void> _revoke(ApproverInfo a) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).removeApprover(a.agent, contact: a.contact);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final r = m.approvers ?? const ApproversReply();
    final now = m.now();
    final answers = r.answers.take(widget.answersShown).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (r.approvers.isEmpty) Text(l.approversNone, key: const Key('approvers-none'), style: XText.bodyDim),
      for (final a in r.approvers)
        Padding(
          key: Key('approver-row-${a.contact ?? ''}/${a.agent}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            XAvatar(a.agent,
                size: 34,
                agent: true,
                picture: a.contact == null
                    ? m.pictureOfMine(agent: a.agent)
                    : (a.linkId == null ? null : m.pictureOfContact(a.linkId!, agent: a.agent))),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(approverName(l, a.agent, a.contact), style: XText.title),
                Text(approverScope(l, a.agents, a.kinds), style: XText.meta.copyWith(color: XColors.accent)),
                Text(l.approversSince(shortStamp(l, DateTime.fromMillisecondsSinceEpoch(a.createdMs), now)),
                    style: XText.meta),
                if (a.stale)
                  Text(l.approverStale(a.contact ?? ''),
                      key: Key('approver-row-stale-${a.agent}'), style: XText.meta.copyWith(color: XColors.warn)),
              ]),
            ),
            TextButton(
              key: Key('approver-change-${a.contact ?? ''}/${a.agent}'),
              style: XButtons.tertiary(),
              onPressed: _busy ? null : () => showApproverDialog(context, agent: a.agent, contact: a.contact),
              child: Text(l.approversChange),
            ),
            TextButton(
              key: Key('approver-revoke-${a.contact ?? ''}/${a.agent}'),
              style: XButtons.destructive(),
              onPressed: _busy ? null : () => _revoke(a),
              child: Text(l.approversRevoke),
            ),
          ]),
        ),
      if (_error case final e?) ErrorLine(describeError(l, e), detail: errorDetail(e)),
      const SizedBox(height: 12),
      Text(l.approversAnswersTitle, style: XText.label),
      const SizedBox(height: 4),
      if (answers.isEmpty) Text(l.approversAnswersNone, style: XText.bodyDim),
      for (final d in answers) _AnswerRow(d, now: now),
      if (r.answers.length > answers.length)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('approvers-all-answers'),
            style: XButtons.tertiary(),
            onPressed: () => showApproversDialog(context),
            child: Text(l.approversAllAnswers(r.answers.length)),
          ),
        ),
    ]);
  }
}

/// One answer given in the owner's place: who, the decision, what, its reason (quoted), when.
class _AnswerRow extends StatelessWidget {
  const _AnswerRow(this.d, {required this.now});
  final DelegatedAnswer d;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final who = approverName(l, d.approver, d.device);
    final what = d.target == null ? actionLabel(l, d.action) : '${actionLabel(l, d.action)} → ${d.target}';
    final (icon, color, line) = switch (d.decision) {
      AnswerDecision.approved =>
        (Icons.check_circle_outline, XColors.ok, l.approversAnswerApproved(who, d.requester, what)),
      AnswerDecision.denied => (Icons.block, XColors.danger, l.approversAnswerDenied(who, d.requester, what)),
      _ => (Icons.do_not_disturb_on_outlined, XColors.warn, l.approversAnswerRefused(who, d.requester, what)),
    };
    return Padding(
      key: Key('approver-answer-${d.approvalId}-${d.atMs}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line, style: XText.body),
            // The approver's words, quoted; for an answer that did not count, why, in this window's language when the
            // daemon gives the code, else in the daemon's words, plain
            if (d.decision == AnswerDecision.refused && d.why != null)
              Text(
                  delegateWhyWords(l,
                      why: d.why!, agent: d.approver, device: d.device, requester: d.requester, message: d.reason),
                  key: Key('approver-answer-why-${d.approvalId}'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: XText.meta)
            else if (d.reason.isNotEmpty)
              d.decision == AnswerDecision.refused
                  ? Text(d.reason, maxLines: 3, overflow: TextOverflow.ellipsis, style: XText.meta)
                  : Text('“${d.reason}”', maxLines: 3, overflow: TextOverflow.ellipsis, style: XText.bodyDim),
          ]),
        ),
        const SizedBox(width: 8),
        Text(shortStamp(l, DateTime.fromMillisecondsSinceEpoch(d.atMs), now), style: XText.meta),
      ]),
    );
  }
}
