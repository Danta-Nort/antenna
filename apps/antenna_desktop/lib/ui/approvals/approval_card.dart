// SPDX-License-Identifier: AGPL-3.0-only
// One approval request (SPEC §9): the full panel in the list and the compact card in the conversation the request is
// about (D-UI-15). Rights are shown structurally ("Read · Write · Commands · Send"), and the request text separately,
// only as a quote that cannot affect the layout. Approving needs the owner password (Q-12a) or, when Touch ID is on, one
// touch whose signature covers this request and its fingerprint (D-102); denying needs neither (D-84). When Touch ID
// cannot do it this time (cancelled, unavailable, the password due), the same password prompt opens, saying why.
// Layout and buttons follow the reference v3 (style, not a pixel copy). After the owner approves a request the daemon
// carries out by itself (x-control/6), the same card says it is finishing, then leaves, or shows why it failed.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/approval_alerts.dart';
import '../../state/approval_finish.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/pictures.dart';
import '../../state/touch_id.dart';
import '../../theme/ai_logos.dart' show AiBrand;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/touch_id_text.dart';
import '../widgets/agent_logo.dart' show knownAgentBrand;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'approvals_view.dart' show showApprovalsDialog;
import 'approver_notes.dart';

/// One request that failed alone in a batch, in words: who asked, for what, its ID, why.
String batchFailureLine(AppLocalizations l, ApprovalResult r, ApprovalInfo? a) => l.approvalsItemFailed(
      a?.requester ?? '—',
      a == null ? '—' : approvalWhat(l, a),
      r.id,
      r.error == null ? '—' : describeError(l, r.error!),
    );

/// One request: the full panel in the list, a compact card in the conversation ([inChat]). Both show what exactly
/// would be allowed, structurally, and the request text only as a quote (SPEC §9): an approval is never blind.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard(this.a, {super.key, this.interactive = true, this.inChat = false, this.sameAgent, this.finish});
  final ApprovalInfo a;
  final bool interactive;

  /// Approved, and the daemon is finishing the action (or failed to): no Approve / Deny any more.
  final ApprovalFinish? finish;

  /// In the conversation: "Waiting for your approval", Approve / Deny, and "Details" opens the full list.
  final bool inChat;

  /// In the conversation, on the last of several pending requests from one agent: all of them (this one included),
  /// for "Approve all from this agent" with one password.
  final List<ApprovalInfo>? sameAgent;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  Object? _error;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // In the conversation nothing else redraws the countdown once a second (the list dialog does it for its cards).
    if (widget.inChat) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<String?> _password({required bool approve, bool hour = false, String? note}) {
    final a = widget.a;
    final l = context.l;
    return askOwnerPassword(
      context,
      note: note,
      action: approve
          ? l.approvalsAllowOnceAction(actionLabel(l, a.action))
          : hour
              ? l.approvalsDenyHourAction(a.contact)
              : l.approvalsDenyAction(actionLabel(l, a.action)),
      detail: l.approvalsFingerprintDetail(a.fingerprint),
      cli: approve ? 'antenna approve ${a.id}' : 'antenna deny ${a.id}${hour ? ' --hour' : ''}',
    );
  }

  /// Approve: the owner password, every time. Deny: no password (D-84), unless the daemon is older than that.
  /// [note]: why the password is asked although Touch ID is on.
  Future<void> _decide({required bool approve, bool hour = false, String? note}) async {
    final a = widget.a;
    final m = AppScope.read(context);
    String? pw;
    if (approve) {
      pw = await _password(approve: true, note: note);
      if (pw == null || !mounted) return;
    }
    setState(() => _busy = true);
    var err = approve ? await m.approve(a.id, pw!) : await m.deny(a.id, hour: hour);
    if (!approve && AppModel.denyNeedsPassword(err) && mounted) {
      setState(() => _busy = false);
      pw = await _password(approve: false, hour: hour);
      if (pw == null || !mounted) return;
      setState(() => _busy = true);
      err = await m.deny(a.id, hour: hour, password: pw);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  /// One touch approves this request (D-102); when Touch ID cannot do it this time, the password prompt, saying why.
  Future<void> _approveTouch() async {
    final a = widget.a;
    final l = context.l;
    final m = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await m.approveWithTouchId(a, reason: touchIdApproveReason(l, a));
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) return;
    if (TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) {
      setState(() => _error = err);
      return;
    }
    await _decide(approve: true, note: touchIdFallbackNote(l, m, err));
  }

  /// Every pending request of this agent in the conversation, with one touch or the password typed once (v6
  /// `approve_many`).
  Future<void> _approveAll(List<ApprovalInfo> all) async {
    final a = widget.a;
    final l = context.l;
    final m = AppScope.read(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? note;
    var (results, err) = (<ApprovalResult>[], null as Object?);
    var touched = false;
    if (m.touchIdReady) {
      setState(() => _busy = true);
      (results, err) = await m.approveManyWithTouchId(all, reason: touchIdBatchReason(l, all));
      if (!mounted) return;
      setState(() => _busy = false);
      touched = err == null || TouchIdMixin.fallbackFor(err) == TouchIdFallback.none;
      note = touchIdFallbackNote(l, m, err);
    }
    if (!touched) {
      final pw = await askOwnerPassword(
        context,
        note: note,
        action: l.approvalsApproveAllAction(all.length, a.requester),
        detail: l.approvalsApproveManyDetail(all.map((x) => x.fingerprint).join(', ')),
        cli: 'antenna approve ${all.map((x) => x.id).join(' ')}',
      );
      if (pw == null || !mounted) return;
      setState(() => _busy = true);
      (results, err) = await m.approveMany(all, pw);
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
    // This card may be gone (approved): the per-request failures go to a short message.
    final failed = results.where((r) => !r.ok).toList();
    if (err == null && failed.isNotEmpty) {
      final shown = {for (final x in all) x.id: x};
      messenger?.showSnackBar(SnackBar(
        content: Text([
          '${l.approvalsBatchApproved(results.length - failed.length)} · ${l.approvalsBatchFailed(failed.length)}',
          for (final r in failed) batchFailureLine(l, r, shown[r.id]),
        ].join('\n')),
      ));
    }
  }

  /// Touch ID is on and usable: one touch is the primary action, the password the other way.
  bool get _touch => AppScope.maybeOf(context)?.touchIdReady ?? false;

  Widget _approveButton(BuildContext context) => _touch
      ? FilledButton.icon(
          key: Key('approve-touchid-${widget.a.id}'),
          style: XButtons.primary(),
          onPressed: _busy ? null : _approveTouch,
          icon: const Icon(Icons.fingerprint, size: 18),
          label: Text(context.l.approvalsApproveTouchId),
        )
      : FilledButton(
          key: Key('approve-${widget.a.id}'),
          style: XButtons.primary(),
          onPressed: _busy ? null : () => _decide(approve: true),
          child: Text(context.l.approvalsAllowOnce),
        );

  /// With Touch ID on: approve with the password instead.
  Widget _passwordButton(BuildContext context) => TextButton(
        key: Key('approve-password-${widget.a.id}'),
        style: XButtons.tertiary(),
        onPressed: _busy ? null : () => _decide(approve: true),
        child: Text(context.l.approvalsUsePassword),
      );

  Widget _denyButton(BuildContext context) => OutlinedButton(
        key: Key('deny-${widget.a.id}'),
        style: XButtons.secondary(),
        onPressed: _busy ? null : () => _decide(approve: false),
        child: Text(context.l.approvalsDeny),
      );

  @override
  Widget build(BuildContext context) => widget.inChat ? _chatCard(context) : _panel(context);

  /// "claude-backend wants to send a file → Emily Carter": who, the action highlighted, the recipient.
  InlineSpan _sentence(AppLocalizations l, ApprovalInfo a, {required TextStyle strong, required TextStyle dim}) =>
      TextSpan(children: [
        TextSpan(text: a.requester == 'owner' ? l.approvalsYou : a.requester, style: strong),
        TextSpan(text: ' ${a.requester == 'owner' ? l.approvalsYouAsk : l.approvalsAsks} ', style: dim),
        TextSpan(text: actionLabel(l, a.action), style: strong.copyWith(color: XColors.warn)),
        if (a.target != null) TextSpan(text: '  →  ${a.target}', style: strong),
      ]);

  /// The full panel (the list of requests).
  Widget _panel(BuildContext context) {
    final a = widget.a;
    final l = context.l;
    final m = AppScope.maybeOf(context);
    final now = m?.now() ?? DateTime.now();
    final created = DateTime.fromMillisecondsSinceEpoch(a.createdMs);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XAvatar(a.requester,
              size: 44, agent: a.byAgent && !connectionAction(a.action), brand: _myAgentBrand(context, a), picture: connectionAction(a.action) ? null : _myAgentPicture(context, a)),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text.rich(_sentence(l, a, strong: XText.title, dim: XText.bodyDim.copyWith(fontSize: 14))),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.finish case final f?) _FinishMark(f) else _TimeLeft(a, now),
        ]),
        if (widget.finish case final f?) ...[const SizedBox(height: 8), _FinishLine(f)],
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(l.approvalsFromContact, style: XText.monoSmall),
              XAvatar(a.contact, size: 22, picture: m?.pictureOfContactLabel(a.contact)),
              Text(a.contact, style: XText.label.copyWith(color: XColors.accent, fontSize: 12)),
              if (a.contactTrust > 0) TrustBadge(a.contactTrust, size: 16),
              for (final r in a.reasons) XPill(reasonLabel(l, r)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Text(shortStamp(l, created, now), style: XText.monoSmall),
          ),
        ]),
        // Approver agents (CONTROL §31): who may answer it for the owner; an answer that did not count, and why
        AnswerableByLine(a),
        DelegateRefusedNote(a),
        if (widget.finish?.detailed ?? true) ..._panelDetails(context),
        if (widget.finish case final f?)
          _FinishFooter(f)
        else ...[
          if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
          if (widget.interactive && a.pending) ...[
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              SizedBox(width: 120, child: _denyButton(context)),
              const SizedBox(width: 8),
              if (_touch) ...[_passwordButton(context), const SizedBox(width: 8)],
              SizedBox(width: 220, child: _approveButton(context)),
            ]),
            if (a.completes) const _ContinuesNote(alignEnd: true),
          ],
        ],
      ]),
    );
  }

  /// Rights, the quote and the fingerprint of the full panel.
  List<Widget> _panelDetails(BuildContext context) {
    final a = widget.a;
    final l = context.l;
    return [
      const SizedBox(height: 16),
      Text(l.approvalsPermissions, style: XText.label.copyWith(color: XColors.text, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      // Rights are structural, separate from the contact's text.
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Grant(l.approvalsGrantRead, a.grants.read),
          _Grant(l.approvalsGrantWrite, a.grants.write),
          _Grant(l.cardRightsCommands, a.grants.commands),
          _Grant(l.approvalsGrantSend, a.grants.send),
        ]),
      ),
      if (a.quote.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.approvalsQuoteLabel, style: XText.label.copyWith(color: XColors.text, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _Quote(a.quote, maxLines: 6),
      ],
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        Text(l.approvalsFingerprintLine(a.fingerprint, a.id), style: XText.monoSmall),
        if (widget.interactive && a.pending && widget.finish == null)
          TextButton(
            key: Key('deny-hour-${a.id}'),
            style: XButtons.destructive(),
            onPressed: _busy ? null : () => _decide(approve: false, hour: true),
            child: Text(l.approvalsDenyHour),
          ),
      ]),
    ];
  }

  /// The compact card at the end of the conversation.
  Widget _chatCard(BuildContext context) {
    final a = widget.a;
    final l = context.l;
    final m = AppScope.maybeOf(context);
    final now = m?.now() ?? DateTime.now();
    final grants = [
      (l.approvalsGrantRead, a.grants.read),
      (l.approvalsGrantWrite, a.grants.write),
      (l.cardRightsCommands, a.grants.commands),
      (l.approvalsGrantSend, a.grants.send),
    ];
    return Container(
      key: Key('chat-approval-${a.id}'),
      padding: const EdgeInsets.all(16),
      decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.l, glow: 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XAvatar(a.requester,
              size: 36, agent: a.byAgent && !connectionAction(a.action), brand: _myAgentBrand(context, a), picture: connectionAction(a.action) ? null : _myAgentPicture(context, a)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.finish case final f?) _FinishLine(f) else Text(l.approvalsWaiting, style: XText.title),
              const SizedBox(height: 4),
              Text.rich(_sentence(l, a, strong: XText.bodyDim.copyWith(color: XColors.text, fontWeight: FontWeight.w500),
                  dim: XText.bodyDim)),
            ]),
          ),
          const SizedBox(width: 8),
          if (widget.finish case final f?) _FinishMark(f) else _TimeLeft(a, now),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 48, top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(l.approvalsFromContact, style: XText.monoSmall),
              Text(a.contact, style: XText.label.copyWith(color: XColors.text)),
              if (a.contactTrust > 0) TrustBadge(a.contactTrust, size: 16),
              for (final r in a.reasons) XPill(reasonLabel(l, r)),
            ]),
            AnswerableByLine(a),
            DelegateRefusedNote(a),
            if (widget.finish?.detailed ?? true) ...[
              const SizedBox(height: 8),
              // Rights, structurally, on one wrapped line: "Read none · Write none · Commands none · Send …".
              Wrap(spacing: 16, runSpacing: 4, children: [
                for (final (k, v) in grants)
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '$k ', style: XText.label.copyWith(color: XColors.text)),
                    TextSpan(
                      text: _grantNone(v) ? l.approvalsGrantNone : _grantShown(context, v),
                      style: XText.mono.copyWith(color: _grantNone(v) ? XColors.textMute : XColors.warn),
                    ),
                  ])),
              ]),
              if (a.quote.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Quote(a.quote, maxLines: 3),
              ],
            ],
            if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
          ]),
        ),
        if (widget.finish case final f?) _FinishFooter(f),
        if (widget.interactive && a.pending && widget.finish == null) ...[
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _approveButton(context)),
            const SizedBox(width: 8),
            Expanded(child: _denyButton(context)),
          ]),
          if ((widget.sameAgent?.length ?? 0) > 1) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: Key('approve-all-${a.requester}'),
                style: XButtons.secondary(),
                onPressed: _busy ? null : () => _approveAll(widget.sameAgent!),
                icon: Icon(_touch ? Icons.fingerprint : Icons.done_all_rounded, size: 17, color: XColors.accent),
                label: Text(l.approvalsApproveAllFromAgent(widget.sameAgent!.length)),
              ),
            ),
          ],
          if (a.completes) const _ContinuesNote(),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(l.approvalsFingerprintLine(a.fingerprint, a.id), style: XText.monoSmall)),
            if (_touch) _passwordButton(context),
            TextButton(
              key: Key('approval-details-${a.id}'),
              style: XButtons.tertiary(),
              onPressed: () => showApprovalsDialog(context),
              child: Text(l.approvalsMore),
            ),
          ]),
        ],
      ]),
    );
  }
}

/// The card's state once approved: a small progress mark while the daemon finishes, a warning mark if it failed.
class _FinishMark extends StatelessWidget {
  const _FinishMark(this.f);
  final ApprovalFinish f;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(4),
        child: f.failed
            ? Icon(Icons.error_outline_rounded, size: 20, color: XColors.danger)
            : SizedBox(
                key: Key('approval-finishing-${f.approval.id}'),
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: XColors.accent),
              ),
      );
}

/// "Approved — Antenna is finishing it…", or "Approved, but Antenna could not finish it: …" (the reason).
class _FinishLine extends StatelessWidget {
  const _FinishLine(this.f);
  final ApprovalFinish f;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final err = f.error;
    return Text(
      f.failed ? l.approvalFinishFailed(err == null ? l.commonFailed : describeError(l, err)) : l.approvalFinishing,
      key: Key('approval-finish-line-${f.approval.id}'),
      style: XText.title.copyWith(color: f.failed ? XColors.danger : XColors.text),
    );
  }
}

/// A failed card: the daemon's technical detail and Dismiss; a finishing card has no buttons.
class _FinishFooter extends StatelessWidget {
  const _FinishFooter(this.f);
  final ApprovalFinish f;

  @override
  Widget build(BuildContext context) {
    final err = f.error;
    if (!f.failed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        Expanded(child: Text(err == null ? '' : (errorDetail(err) ?? ''), style: XText.monoSmall)),
        const SizedBox(width: 8),
        OutlinedButton(
          key: Key('approval-dismiss-${f.approval.id}'),
          style: XButtons.secondary(),
          onPressed: () => AppScope.read(context).dismissFinished(f.approval.id),
          child: Text(context.l.approvalDismiss),
        ),
      ]),
    );
  }
}

/// Under the buttons of a request the daemon carries out by itself: nobody has to tell the agent.
class _ContinuesNote extends StatelessWidget {
  const _ContinuesNote({this.alignEnd = false});
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          context.l.approvalContinuesNote,
          key: const Key('approval-continues-note'),
          textAlign: alignEnd ? TextAlign.end : TextAlign.start,
          style: XText.meta,
        ),
      );
}

/// The requester is one of my agents: its AI's mark when the window knows it (D-UI-18).
AiBrand? _myAgentBrand(BuildContext context, ApprovalInfo a) {
  final m = AppScope.maybeOf(context);
  return a.byAgent && m != null ? knownAgentBrand(m, a.requester) : null;
}

/// The requester is one of my agents: the picture the owner chose for it.
ShownPicture? _myAgentPicture(BuildContext context, ApprovalInfo a) =>
    a.byAgent ? AppScope.maybeOf(context)?.pictureOfMine(agent: a.requester) : null;

/// "Expires in 8 min" as a soft warning pill (never a bare "08:00", which reads as a clock).
class _TimeLeft extends StatelessWidget {
  const _TimeLeft(this.a, this.now);
  final ApprovalInfo a;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final left = DateTime.fromMillisecondsSinceEpoch(a.expiresMs).difference(now);
    return Tooltip(
      message: context.l.approvalsExpiresTooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Color.alphaBlend(XColors.warn.withValues(alpha: 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(XButtons.radius),
        ),
        child: Text(expiresIn(context.l, left),
            key: Key('approval-expires-${a.id}'), style: XText.mono.copyWith(color: XColors.warn)),
      ),
    );
  }
}

/// The request text: as is, monospaced, no markup, in its own box: it cannot pass itself off as part of the UI.
class _Quote extends StatelessWidget {
  const _Quote(this.text, {required this.maxLines});
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.m),
        child: Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: XText.mono.copyWith(color: XColors.textDim, height: 1.45),
        ),
      );
}

// The daemon writes "no rights" as "-" or "none" (antenna-core grants_for).
bool _grantNone(String v) => v.isEmpty || v == '-' || v == 'none';
String _grantShown(BuildContext context, String v) => v == 'text' ? context.l.approvalsGrantText : v;

class _Grant extends StatelessWidget {
  const _Grant(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final none = _grantNone(v);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: XText.label.copyWith(color: XColors.text, fontWeight: FontWeight.w600, fontSize: 12)),
          const SizedBox(height: 4),
          Text(none ? context.l.approvalsGrantNone : _grantShown(context, v),
              style: XText.mono.copyWith(color: none ? XColors.textMute : XColors.warn)),
        ]),
      ),
    );
  }
}

/// The request's action in plain words.
String actionLabel(AppLocalizations l, String action) => switch (action) {
      'send_message' => l.actionSendMessage,
      'check:exec' => l.actionExec,
      'check:write' => l.actionWrite,
      'check:read' => l.actionRead,
      'share_file' => l.actionShareFile,
      'request_file' => l.actionRequestFile,
      'accept_file' => l.actionAcceptFile,
      'connect_agent' => l.actionConnectAgent,
      'disconnect_agent' => l.actionDisconnectAgent,
      _ => action,
    };

/// Another own computer asks to set or clear its agent's counterpart (CONTROL §30): the requester is that computer.
bool connectionAction(String action) => action == 'connect_agent' || action == 'disconnect_agent';

/// What the request would do, in a few words: the action and, for a send, the recipient ("send a message → Emily").
String approvalWhat(AppLocalizations l, ApprovalInfo a) =>
    a.target == null ? actionLabel(l, a.action) : '${actionLabel(l, a.action)} → ${a.target}';

/// The system notification about a request (D-84, D-114): a new one here or on another own computer, or one about
/// to run out. The agent, the action, the contact's label, the computer and the time left only, never the request
/// text (it may show on a locked screen; an [ApprovalAlert] has no field for it).
(String, String) approvalNotification(AppLocalizations l, ApprovalAlert a) {
  final title = switch ((a.kind, a.device)) {
    (ApprovalAlertKind.arrived, null) => l.notifyApprovalTitle,
    (ApprovalAlertKind.arrived, final d?) => l.notifyDeviceApprovalTitle(d),
    (ApprovalAlertKind.expiresSoon, null) => l.notifyApprovalSoonTitle,
    (ApprovalAlertKind.expiresSoon, final d?) => l.notifyDeviceApprovalSoonTitle(d),
  };
  final what = a.target == null ? actionLabel(l, a.action) : '${actionLabel(l, a.action)} → ${a.target}';
  final body = l.notifyApprovalBody(a.requester, what);
  final left = a.left;
  if (left == null || left <= Duration.zero) return (title, body);
  // Whole minutes, rounded up: "expires in 1 min" until the last second.
  return (title, '$body · ${l.notifyApprovalLeft((left.inSeconds + 59) ~/ 60)}');
}

/// The reason (machine-readable, from the policy engine) in plain words; an unknown one as is.
String reasonLabel(AppLocalizations l, String r) {
  if (r.startsWith('secret:')) return l.reasonSecret(r.substring(7));
  if (r.startsWith('cross_link:')) return l.reasonCrossLink(r.substring(11));
  if (r == 'no_write_down') return 'no write down';
  if (r == 'agent_connect') return l.reasonAgentConnect;
  if (r.startsWith('tainted:')) return 'taint: ${r.substring(8)}';
  return r;
}
