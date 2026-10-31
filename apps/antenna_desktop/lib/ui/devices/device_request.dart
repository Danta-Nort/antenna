// SPDX-License-Identifier: AGPL-3.0-only
// One approval request of another own computer, answered from here (D-106, experimental). The other computer decides:
// it checks the proof made here against the keys its owner confirmed there, bound to its own one-time challenge and to
// exactly this request and its fingerprint. Approving takes one touch (the window's Touch ID key accepted there) or
// the password typed here (this computer's device key accepted there); denying takes neither (D-84). A quote with a
// secret never travels: the card says so and names the reasons.

import 'package:flutter/material.dart';

import '../../host/touch_id.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/devices.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../approvals/approval_card.dart' show actionLabel, connectionAction, reasonLabel;
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'device_text.dart';

class DeviceRequestCard extends StatefulWidget {
  const DeviceRequestCard(this.device, this.a, {super.key});
  final DeviceInfo device;
  final DeviceApproval a;

  @override
  State<DeviceRequestCard> createState() => _DeviceRequestCardState();
}

class _DeviceRequestCardState extends State<DeviceRequestCard> {
  bool _busy = false;
  Object? _error;

  Future<void> _do(Future<Object?> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await op();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // The owner closed the Touch ID sheet: nothing to say.
      _error = err is TouchIdException && err.reason == TouchIdFailure.cancelled ? null : err;
    });
  }

  Future<void> _approveTouch() {
    final m = AppScope.read(context);
    final l = context.l;
    return _do(() => m.deviceApproveWithTouchId(widget.device, widget.a,
        reason: deviceTouchReason(l, widget.device.contact, widget.a)));
  }

  /// With this computer's device key: confirmed here with the password, or ([touch]) with one touch here (D-131).
  Future<void> _approvePassword({bool touch = false}) async {
    final m = AppScope.read(context);
    final l = context.l;
    await _do(() async => (await confirmOwner(
          context,
          action: l.devicesApprovePasswordAction(widget.device.contact, actionLabel(l, widget.a.action)),
          detail: l.approvalsFingerprintDetail(widget.a.fingerprint),
          cli: 'antenna devices approve ${widget.device.contact} ${widget.a.id}',
          reason: deviceTouchReason(l, widget.device.contact, widget.a),
          touch: touch,
          run: (auth) => m.deviceApproveWithPassword(widget.device, widget.a, auth),
        ))
            .$2);
  }

  Future<void> _deny() {
    final m = AppScope.read(context);
    return _do(() => m.deviceDeny(widget.device, widget.a));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final a = widget.a;
    final d = widget.device;
    final ways = m.approveWays(d);
    final now = m.now();
    final left = Duration(milliseconds: a.expiresMs - (d.status?.atMs ?? a.createdMs)) -
        now.difference(DateTime.fromMillisecondsSinceEpoch(d.receivedMs ?? now.millisecondsSinceEpoch));
    final strong = XText.bodyDim.copyWith(color: XColors.text, fontWeight: FontWeight.w500);
    return Container(
      key: Key('device-request-${a.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XAvatar(a.requester,
              size: 32,
              agent: a.byAgent && !connectionAction(a.action),
              picture: a.byAgent && !connectionAction(a.action) ? m.pictureOfContact(d.linkId, agent: a.requester) : null),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: a.requester == 'owner' ? l.approvalsYou : a.requester, style: strong),
              TextSpan(text: ' ${a.requester == 'owner' ? l.approvalsYouAsk : l.approvalsAsks} ', style: XText.bodyDim),
              TextSpan(text: actionLabel(l, a.action), style: strong.copyWith(color: XColors.warn)),
              if (a.target != null) TextSpan(text: '  →  ${a.target}', style: strong),
            ])),
          ),
          const SizedBox(width: 8),
          Text(expiresIn(l, left), key: Key('device-request-expires-${a.id}'), style: XText.monoSmall),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 44, top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(l.approvalsFromContact, style: XText.monoSmall),
              Text(a.contact, style: XText.label.copyWith(color: XColors.text)),
              TrustBadge(a.contactTrust, size: 16),
              for (final r in a.reasons) XPill(reasonLabel(l, r)),
            ]),
            if (a.quoteWithheld) ...[
              const SizedBox(height: 8),
              Row(key: Key('device-request-withheld-${a.id}'), children: [
                Icon(Icons.visibility_off_outlined, size: 15, color: XColors.textDim),
                const SizedBox(width: 8),
                Expanded(child: Text(l.devicesQuoteWithheld(d.contact), style: XText.bodyDim)),
              ]),
            ] else if (a.quote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: XColors.bg1,
                  borderRadius: BorderRadius.circular(XRadius.m),
                  border: Border(left: BorderSide(color: XColors.lineStrong, width: 3)),
                ),
                // A quote, plain text, never a link: the request's text is the requester's.
                child: Text(a.quote, maxLines: 4, overflow: TextOverflow.ellipsis, style: XText.mono.copyWith(fontSize: 12)),
              ),
            ],
            // Approver agents (CONTROL §31): that computer accepts an answer from this computer's agents for it
            if (a.approvers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(key: Key('device-request-approvers-${a.id}'), children: [
                Icon(Icons.how_to_reg_outlined, size: 16, color: XColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l.devicesRequestApprovers(a.approvers.join(', ')),
                      style: XText.meta.copyWith(color: XColors.accent)),
                ),
              ]),
            ],
            const SizedBox(height: 8),
            Text(l.approvalsFingerprintLine(a.fingerprint, a.id), style: XText.monoSmall),
            if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
          ]),
        ),
        const SizedBox(height: 12),
        if (ways.isEmpty)
          Row(key: Key('device-request-cannot-${a.id}'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 16, color: XColors.textDim),
            const SizedBox(width: 8),
            Expanded(child: Text(l.devicesCannotApprove(d.contact), style: XText.bodyDim)),
            const SizedBox(width: 8),
            OutlinedButton(
              key: Key('device-deny-${a.id}'),
              style: XButtons.secondary(),
              onPressed: _busy ? null : _deny,
              child: Text(l.approvalsDeny),
            ),
          ])
        else
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              key: Key('device-deny-${a.id}'),
              style: XButtons.secondary(),
              onPressed: _busy ? null : _deny,
              child: Text(l.approvalsDeny),
            ),
            if (ways.contains(DeviceApproveWay.touchId) && ways.contains(DeviceApproveWay.password))
              TextButton(
                key: Key('device-approve-password-${a.id}'),
                style: XButtons.tertiary(),
                onPressed: _busy ? null : _approvePassword,
                child: Text(l.approvalsUsePassword),
              ),
            if (ways.first == DeviceApproveWay.touchId)
              FilledButton.icon(
                key: Key('device-approve-touchid-${a.id}'),
                style: XButtons.primary(),
                onPressed: _busy ? null : _approveTouch,
                icon: const Icon(Icons.fingerprint, size: 18),
                label: Text(l.approvalsApproveTouchId),
              )
            else if (m.touchIdReady) ...[
              // Only the device key is accepted there: one touch here stands for this computer's password (D-131).
              TextButton(
                key: Key('device-approve-password-${a.id}'),
                style: XButtons.tertiary(),
                onPressed: _busy ? null : _approvePassword,
                child: Text(l.approvalsUsePassword),
              ),
              FilledButton.icon(
                key: Key('device-approve-${a.id}'),
                style: XButtons.primary(),
                onPressed: _busy ? null : () => _approvePassword(touch: true),
                icon: const Icon(Icons.fingerprint, size: 18),
                label: Text(l.approvalsApproveTouchId),
              ),
            ] else
              FilledButton(
                key: Key('device-approve-${a.id}'),
                style: XButtons.primary(),
                onPressed: _busy ? null : _approvePassword,
                child: Text(l.devicesApproveWithPassword),
              ),
          ]),
        if (a.completes) ...[
          const SizedBox(height: 8),
          Text(l.devicesContinuesThere(d.contact), textAlign: TextAlign.end, style: XText.meta),
        ],
      ]),
    );
  }
}
