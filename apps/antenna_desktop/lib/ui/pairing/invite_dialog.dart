// SPDX-License-Identifier: AGPL-3.0-only
// The invite dialog (side A, SPEC §6, docs/CONTROL.md §6): the form, then the link + QR with its TTL, the code to read
// out, and the confirmation once the contact entered the code.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/pairing.dart';
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/self_level.dart';
import '../widgets/trust_picker.dart';
import 'pairing_widgets.dart';
import 'sas_view.dart';

Future<void> showInviteDialog(BuildContext context, {int? trust, Duration? ttl, String? label}) =>
    showXDialog<void>(context, (_) => InviteDialog(trust: trust, ttl: ttl, label: label), dismissible: false);

class InviteDialog extends StatefulWidget {
  const InviteDialog({super.key, this.trust, this.ttl, this.label});
  final int? trust;
  final Duration? ttl;
  final String? label;

  @override
  State<InviteDialog> createState() => _InviteDialogState();
}

const _ttls = <Duration>[Duration(minutes: 5), Duration(minutes: 10), Duration(hours: 1), Duration(hours: 24)];

String _ttlLabel(AppLocalizations l, Duration d) => switch (d.inMinutes) {
      5 => l.pairTtl5m,
      10 => l.pairTtl10m,
      60 => l.pairTtl1h,
      _ => l.pairTtl24h,
    };

class _InviteDialogState extends State<InviteDialog> with SelfLevelOnce {
  late int _trust = widget.trust ?? 2; // D-25: default 2, as in the SPEC §6 example

  /// Where "This is my own computer" goes back to when unticked.
  late final int _defaultTrust = widget.trust == null || widget.trust == 5 ? 2 : widget.trust!;
  late Duration _ttl = widget.ttl ?? const Duration(minutes: 10);
  late final _label = TextEditingController(text: widget.label ?? '');
  final _auth = OwnerAuthController();

  /// The last invite failed as a Touch ID matter: the form asks for the password, with no error.
  bool _fellBack = false;
  InviteSession? _s;
  bool _emoji = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _s?.expiresAt != null && !_s!.finished) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _s?.removeListener(_changed);
    _s?.dispose();
    _label.dispose();
    _auth.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        final s = _s;
        if (s != null && s.link == null && s.phase == InvitePhase.failed) {
          _fellBack = _auth.fellBack(context.l, AppScope.read(context), s.error);
        }
      });

  Future<void> _start() async {
    // An invite opened at level 5 (`/invite --trust 5`) is accepted here before it is created.
    if (_trust == 5 && !await confirmSelfOnce()) return;
    if (!mounted) return;
    final m = AppScope.read(context);
    final label = _label.text.trim();
    _s?.removeListener(_changed);
    _s?.dispose();
    final l = context.l;
    final s = m.startInvite(
        trust: _trust,
        ttl: _ttl,
        label: label.isEmpty ? null : label,
        auth: _auth.auth(m, touchIdConfirmReason(l, l.commonInvite)));
    _auth.password.clear();
    s.addListener(_changed);
    setState(() {
      _s = s;
      _fellBack = false;
    });
  }

  Future<void> _cancelInvite() async {
    final id = _s?.inviteId;
    if (id == null) return Navigator.pop(context);
    final m = AppScope.read(context);
    final (done, err) = await confirmOwner(context,
        action: context.l.pairBurnInvite, cli: 'antenna pairing cancel $id', run: (auth) => m.cancelInvite(id, auth));
    if (!mounted || (!done && err == null)) return;
    if (err == null) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    // The form stays while there is no invite (or it was not created, for example because of a wrong password).
    if (s == null || (s.link == null && s.phase == InvitePhase.failed)) return _form(_fellBack ? null : s?.error);
    if (s.link == null) {
      return XDialogShell(
        title: context.l.commonInvite,
        icon: Icons.qr_code_2,
        child: PairingBusy(context.l.pairCreatingLink),
      );
    }
    final m = AppScope.of(context);
    final left = s.expiresAt!.difference(m.now());
    final actions = <Widget>[
      if (!s.finished)
        TextButton(onPressed: _cancelInvite, child: Text(context.l.pairCancelInvite)),
      if (!s.finished)
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l.pairHideUntil(hhmm(s.expiresAt!))),
        ),
      if (s.finished) FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonDone)),
    ];
    return XDialogShell(
      title: s.label == null ? context.l.inviteTitle : context.l.inviteTitleNamed(s.label!),
      icon: Icons.qr_code_2,
      width: 640,
      actions: actions,
      child: switch (s.phase) {
        InvitePhase.creating || InvitePhase.waitingPeer => _waiting(s, left),
        InvitePhase.codeShown => _code(s, waitingFor: context.l.pairWaitingPeerCode),
        InvitePhase.needConfirm => _confirm(s),
        InvitePhase.confirming => PairingBusy(context.l.pairConfirming),
        InvitePhase.linked => LinkedSummary(s.linked!),
        InvitePhase.failed => ErrorLine(s.errorText(context.l) ?? context.l.commonFailed, detail: errorDetail(s.error!)),
      },
    );
  }

  Widget _form(Object? error) => XDialogShell(
        title: context.l.commonInvite,
        icon: Icons.qr_code_2,
        subtitle: context.l.pairInviteSubtitle,
        width: 600,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonCancel)),
          FilledButton(key: const Key('invite-create'), onPressed: _start, child: Text(context.l.pairCreateLink)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const Key('invite-label'),
            controller: _label,
            autofocus: true,
            style: XText.body,
            decoration: InputDecoration(labelText: context.l.pairContactName),
          ),
          const SizedBox(height: 16),
          Text(context.l.pairYourTrust, style: XText.label),
          const SizedBox(height: 8),
          TrustPicker(value: _trust, onChanged: (v) => setState(() => _trust = v), confirmSelf: confirmSelfOnce),
          const SizedBox(height: 8),
          OwnComputerToggle(
            value: _trust == 5,
            onChanged: (on) => ownComputer(on, fallback: _defaultTrust, setLevel: (v) => _trust = v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Text(context.l.pairLinkLifetime, style: XText.label),
            const SizedBox(width: 12),
            for (final d in _ttls) ...[
              ChoiceChip(
                label: Text(_ttlLabel(context.l, d), style: XText.monoSmall.copyWith(color: d == _ttl ? XColors.accent : XColors.textDim)),
                selected: d == _ttl,
                onSelected: (_) => setState(() => _ttl = d),
                showCheckmark: false,
                side: BorderSide(color: d == _ttl ? XColors.accent.withValues(alpha: 0.7) : XColors.line),
                selectedColor: XColors.accent.withValues(alpha: 0.12),
                backgroundColor: XColors.bg2,
              ),
              const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          OwnerAuthField(controller: _auth, onSubmitted: (_) => _start()),
          if (error != null) ErrorLine(describeError(context.l, error), detail: errorDetail(error)),
          const SizedBox(height: 8),
          Text(context.l.commonSameAs('antenna invite --trust $_trust --ttl ${_ttl.inMinutes}m'), style: XText.monoSmall),
        ]),
      );

  Widget _waiting(InviteSession s, Duration left) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        QrView(s.link!),
        const SizedBox(width: 24),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              TrustBadge(s.trust, size: 20, showName: true),
              const SizedBox(width: 8),
              XPill(
                netModeLabel(context.l, s.netMode ?? ''),
                icon: s.netMode == 'relay_only' ? Icons.cell_tower_outlined : Icons.swap_horiz,
                tooltip: netModeHint(context.l, s.netMode ?? ''),
              ),
            ]),
            const SizedBox(height: 16),
            InviteLinkBox(s.link!),
            if (s.linkApp != null && s.linkApp != s.link) ...[
              const SizedBox(height: 8),
              InviteAppLinkRow(s.linkApp!),
            ],
            const SizedBox(height: 8),
            Text(context.l.pairLinkSecret, style: XText.monoSmall),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.timer_outlined, size: 15, color: XColors.warn),
              const SizedBox(width: 8),
              Text(context.l.pairBurnsIn(countdown(left)), style: XText.mono.copyWith(color: XColors.warn)),
            ]),
            const SizedBox(height: 16),
            PairingSteps([
              context.l.pairStepShare,
              context.l.pairStepOpens,
              context.l.pairStepReadOut,
              context.l.pairStepConfirmHere,
            ], active: 0),
          ]),
        ),
      ]);

  Widget _code(InviteSession s, {required String waitingFor}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(context.l.pairCodeTitle, style: XText.title)),
          if (s.sasEmoji != null) SasModeSwitch(emoji: _emoji, onChanged: (v) => setState(() => _emoji = v)),
        ]),
        const SizedBox(height: 16),
        SasDisplay(code: s.sas!, emoji: _emoji),
        const SizedBox(height: 16),
        Row(children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: XColors.accent)),
          const SizedBox(width: 8),
          Expanded(child: Text(waitingFor, style: XText.bodyDim)),
        ]),
        if (s.attempts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            context.l.pairFailedAttempts(s.attempts.last.attempts, s.attempts.last.max),
            style: XText.monoSmall.copyWith(color: XColors.warn),
          ),
        ],
        const SizedBox(height: 16),
        PairingSteps([
          context.l.pairStepShareShort,
          context.l.pairStepOpened,
          context.l.pairStepReadOutLong,
          context.l.pairStepConfirmWhen,
        ], active: 2),
      ]);

  Widget _confirm(InviteSession s) {
    final l = context.l;
    final name = s.label ?? l.pairContactFallback;
    final byButton = s.confirmByButton;
    final reject = TextButton(key: const Key('invite-reject'), onPressed: s.reject, child: Text(l.pairReject));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: xGlow(radius: XRadius.m, color: XColors.ok, strength: 0.6),
        child: Row(children: [
          Icon(Icons.check_circle_outline, color: XColors.ok, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(byButton ? l.pairPeerEnteredCodeMatch(name) : l.pairPeerEnteredCode(name), style: XText.body),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      if (byButton) ...[
        // D-95: the daemon offered the confirmation without the code (only this invite showed a code), so the owner's
        // click after the contact's "they match" is the confirmation. Nothing is sent before the click.
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          reject,
          const SizedBox(width: 8),
          ConfirmMatchButton(key: const Key('invite-confirm-match'), onPressed: s.confirmMatch),
        ]),
        if (s.confirmError != null) ErrorLine(s.confirmErrorText(l)!, detail: errorDetail(s.confirmError!)),
        const SizedBox(height: 8),
        Text(l.commonSameAs('antenna pairing confirm ${s.inviteId ?? '<id>'}'), style: XText.monoSmall),
      ] else ...[
        if (s.codeFallback == XErrorCode.codeRequired) ...[
          PairingNote(l.pairCodeRequired, key: const Key('confirm-code-required')),
          const SizedBox(height: 12),
        ],
        // The code is not shown here: the owner types it (CONTROL §6, F-4), and the window never fills it in. No
        // second password is needed: the monitoring connection already passed the password check on creation (D-UI-4).
        SasInput(
          key: const Key('confirm-code'),
          title: l.pairConfirmedCodeTitle,
          submitLabel: l.pairConfirmLink,
          submitKey: const Key('invite-confirm'),
          allowIncomplete: true,
          onSubmit: s.confirmWithCode,
          footer: s.confirmError == null ? null : ErrorLine(s.confirmErrorText(l)!, detail: errorDetail(s.confirmError!)),
        ),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: reject),
        Text(l.commonSameAs('antenna pairing confirm ${s.inviteId ?? '<id>'} --code ${l.commonCodePlaceholder}'),
            style: XText.monoSmall),
      ],
    ]);
  }
}
