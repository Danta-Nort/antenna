// SPDX-License-Identifier: AGPL-3.0-only
// What an approval card says about approver agents (CONTROL §31, PG-57; experimental): on a pending request, who may
// answer it in the owner's place (`answerable_by`) and, when an agent's answer did not count, why and that the owner
// answers (`delegate_refused`); and a request an approver decided (`decided_by`): approved or denied by whom, on which
// of the owner's computers, with its reason quoted as the agent's own words, and **Change** to the approvers. The
// reason is the agent's text: data, shown as a quote, never acted on.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/approval_finish.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../agents/approver_dialog.dart' show approverLabelName, approverName;
import '../agents/approvers_panel.dart' show showApproversDialog;
import '../app_scope.dart';
import '../widgets/badges.dart';
import '../widgets/x_buttons.dart';
import 'approval_card.dart' show approvalWhat;

/// Why an approver's answer did not count, in words; an unknown reason in the daemon's words.
String delegateWhyText(AppLocalizations l, ApprovalInfo a, DelegateNote n) => delegateWhyWords(l,
    why: n.why, agent: n.agent, device: n.device, requester: a.requester, message: n.message);

/// The same for any answer that did not count (a card's note, a row of the approvers' answers): [why] is the
/// daemon's code, [message] its words for a code this window does not know.
String delegateWhyWords(AppLocalizations l,
    {required String why,
    required String agent,
    required String? device,
    required String requester,
    required String message}) {
  final who = approverName(l, agent, device);
  return switch (why) {
    DelegateWhy.scope => l.delegateWhyScope(who),
    DelegateWhy.self => l.delegateWhySelf(who),
    DelegateWhy.chain => l.delegateWhyChain(requester),
    DelegateWhy.tainted => l.delegateWhyTainted(who),
    DelegateWhy.outside => l.delegateWhyOutside,
    DelegateWhy.levelChanged => l.delegateWhyLevelChanged,
    DelegateWhy.unverified => l.delegateWhyUnverified(device ?? who),
    _ => message.isEmpty ? why : message,
  };
}

/// "volna may answer this for you" on a pending request.
class AnswerableByLine extends StatelessWidget {
  const AnswerableByLine(this.a, {super.key});
  final ApprovalInfo a;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (!a.pending || a.answerableBy.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: Key('approval-answerable-${a.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(Icons.how_to_reg_outlined, size: 16, color: XColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l.approvalAnswerableBy(a.answerableBy.map((x) => approverLabelName(l, x)).join(', ')),
            style: XText.meta.copyWith(color: XColors.accent),
          ),
        ),
      ]),
    );
  }
}

/// An agent answered a pending request, but the answer did not count: why, and that the person answers.
class DelegateRefusedNote extends StatelessWidget {
  const DelegateRefusedNote(this.a, {super.key});
  final ApprovalInfo a;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final n = a.delegateRefused;
    if (!a.pending || n == null) return const SizedBox.shrink();
    return Container(
      key: Key('approval-refused-${a.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: xPanel(
        fill: Color.alphaBlend(XColors.warn.withValues(alpha: 0.08), XColors.bg1),
        border: XColors.warn.withValues(alpha: 0.4),
        radius: XRadius.m,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.do_not_disturb_on_outlined, size: 16, color: XColors.warn),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.approvalRefusedTitle(approverName(l, n.agent, n.device)),
                style: XText.label.copyWith(color: XColors.text)),
            Text(delegateWhyText(l, a, n), key: Key('approval-refused-why-${a.id}'), style: XText.bodyDim),
            Text(l.approvalRefusedYours, style: XText.meta),
          ]),
        ),
      ]),
    );
  }
}

/// A request an approver decided in the owner's place, until the owner dismisses it: in the conversation the request
/// is about ([inChat]) and in Approval requests. The finishing state of an approved request the daemon carries out
/// ([finish]) is shown here too, so the request has one card.
class DecidedCard extends StatelessWidget {
  const DecidedCard(this.a, {super.key, this.inChat = false, this.finish});
  final ApprovalInfo a;
  final bool inChat;
  final ApprovalFinish? finish;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final by = a.decidedBy!;
    final who = approverName(l, by.agent, by.device);
    final denied = a.state == 'denied';
    final f = finish;
    final title = denied
        ? (by.device == null ? l.decidedDeniedBy(by.agent) : l.decidedDeniedByOn(by.agent, by.device!))
        : (by.device == null ? l.decidedApprovedBy(by.agent) : l.decidedApprovedByOn(by.agent, by.device!));
    return Container(
      key: Key('decided-${a.id}'),
      padding: const EdgeInsets.all(16),
      decoration: xPanel(fill: inChat ? XColors.bg1 : XColors.bg2, border: XColors.line, radius: XRadius.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XAvatar(by.agent,
              size: inChat ? 36 : 44,
              agent: true,
              picture: by.device == null ? m.pictureOfMine(agent: by.agent) : null),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(denied ? Icons.block : Icons.check_circle_outline,
                    size: 18, color: denied ? XColors.danger : XColors.ok),
                const SizedBox(width: 8),
                Flexible(child: Text(title, key: Key('decided-title-${a.id}'), style: XText.title)),
              ]),
              const SizedBox(height: 4),
              Text(l.decidedWhat(a.requester, approvalWhat(l, a)), style: XText.bodyDim),
            ]),
          ),
          const SizedBox(width: 8),
          Text(shortStamp(l, DateTime.fromMillisecondsSinceEpoch(by.atMs), m.now()), style: XText.meta),
        ]),
        if (by.reason.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l.decidedReasonLabel(who), style: XText.meta),
          const SizedBox(height: 4),
          // The approver's words: a quote in its own box, plain text, never a link or markup
          Container(
            key: Key('decided-reason-${a.id}'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: inChat ? XColors.bg2 : XColors.bg1,
              border: Border(left: BorderSide(color: XColors.lineStrong, width: 3)),
            ),
            child: Text(by.reason, maxLines: 4, overflow: TextOverflow.ellipsis, style: XText.body),
          ),
        ],
        if (f != null) ...[
          const SizedBox(height: 8),
          Text(
            f.failed
                ? l.approvalFinishFailed(f.error == null ? l.commonFailed : describeError(l, f.error!))
                : l.decidedFinishing,
            key: Key('decided-finish-${a.id}'),
            style: XText.meta.copyWith(color: f.failed ? XColors.danger : XColors.textDim),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(l.approvalsFingerprintLine(a.fingerprint, a.id), style: XText.monoSmall)),
          TextButton(
            key: Key('decided-change-${a.id}'),
            style: XButtons.tertiary(),
            onPressed: () => showApproversDialog(context),
            child: Text(l.decidedChange),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: Key('decided-dismiss-${a.id}'),
            style: XButtons.secondary(),
            onPressed: () {
              final m = AppScope.read(context);
              m.dismissDecided(a.id);
              if (f != null && f.failed) m.dismissFinished(a.id);
            },
            child: Text(l.approvalDismiss),
          ),
        ]),
      ]),
    );
  }
}
