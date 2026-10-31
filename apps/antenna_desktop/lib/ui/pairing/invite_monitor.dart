// SPDX-License-Identifier: AGPL-3.0-only
// An invite created outside the window (`antenna invite`), shown from the pending invites list and confirmed through
// `pairing_confirm` (docs/CONTROL.md §6).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import 'pairing_widgets.dart';
import 'sas_view.dart';

Future<void> showInviteMonitor(BuildContext context, String id) =>
    showXDialog<void>(context, (_) => InviteMonitor(id: id));

class InviteMonitor extends StatefulWidget {
  const InviteMonitor({super.key, required this.id});
  final String id;

  @override
  State<InviteMonitor> createState() => _InviteMonitorState();
}

class _InviteMonitorState extends State<InviteMonitor> {
  final _auth = OwnerAuthController();
  bool _emoji = false;
  Object? _error;
  bool _busy = false;
  Timer? _tick;

  /// The daemon refused the confirmation without the code (`code_required`, or `bad_request` from a daemon older
  /// than D-95): the code field is shown from then on.
  String? _codeFallback;

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
    _auth.dispose();
    super.dispose();
  }

  /// [code] is typed by the owner; the window never fills it in (CONTROL §6, F-4). `null`: the owner's click on "The
  /// contact confirmed — codes match" (D-95), sent with the password and without a code.
  Future<void> _confirm(InviteInfo i, String? code) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() => _busy = true);
    final err = await m.confirmInvite(i.id, _auth.auth(m, touchIdConfirmReason(l, l.pairConfirmedCodeTitle)), code: code);
    if (!mounted) return;
    _auth.password.clear();
    final fallback = code == null &&
        err is XControlException &&
        (err.code == XErrorCode.codeRequired || err.code == XErrorCode.badRequest);
    final touchFellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      if (touchFellBack) {
        _error = null;
      } else if (fallback) {
        // The daemon wants the code after all: the code field, with the reason, instead of an error.
        _codeFallback = err.code;
        _error = null;
      } else {
        _error = err;
      }
    });
    if (err == null) Navigator.pop(context);
  }

  Future<void> _reveal() async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() => _busy = true);
    final err = await m.revealInvites(_auth.auth(m, touchIdConfirmReason(l, l.pairRevealLinkAndCode)));
    if (!mounted) return;
    _auth.password.clear();
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
    });
  }

  Future<void> _cancel(InviteInfo i) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() => _busy = true);
    final err = await m.cancelInvite(i.id, _auth.auth(m, touchIdConfirmReason(l, l.pairBurnInvite)));
    if (!mounted) return;
    _auth.password.clear();
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
    });
    if (err == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final i = m.invites[widget.id];
    if (i == null) {
      return XDialogShell(title: context.l.inviteTitle, child: Text(context.l.pairInviteNotFound, style: XText.bodyDim));
    }
    final left = DateTime.fromMillisecondsSinceEpoch(i.expiresMs).difference(m.now());
    // D-95: one click with the password when the daemon offers it and has not asked for the code since.
    final byButton = i.needsConfirm && i.confirmWithoutCode && _codeFallback == null;
    return XDialogShell(
      title: i.label == null ? context.l.inviteTitle : context.l.inviteTitleNamed(i.label!),
      icon: Icons.qr_code_2,
      width: 640,
      actions: [
        if (!i.finished)
          TextButton(
              onPressed: _busy ? null : () => _cancel(i),
              child: Text(_auth.usesTouch(m) ? context.l.pairBurnInvite : context.l.pairBurnWithPassword)),
        if (!i.revealed && !i.finished && !i.needsConfirm)
          FilledButton(
            key: const Key('invite-reveal'),
            onPressed: _busy ? null : _reveal,
            child: Text(context.l.pairRevealLinkAndCode),
          ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _PhaseChip(i.phase),
          const SizedBox(width: 8),
          TrustBadge(i.trust, size: 18, showName: true),
          const Spacer(),
          Text(context.l.pairBurnsIn(countdown(left)), style: XText.mono.copyWith(color: XColors.warn)),
        ]),
        const SizedBox(height: 16),
        if (byButton) ...[
          Text(context.l.pairMonitorPeerEnteredMatch, style: XText.bodyDim),
          const SizedBox(height: 12),
          OwnerAuthField(controller: _auth),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ConfirmMatchButton(
              key: const Key('monitor-confirm-match'),
              onPressed: _busy ? null : () => _confirm(i, null),
            ),
          ),
        ] else if (i.needsConfirm) ...[
          if (_codeFallback == XErrorCode.codeRequired) ...[
            PairingNote(context.l.pairCodeRequired, key: const Key('monitor-code-required')),
            const SizedBox(height: 12),
          ],
          SasInput(
            title: context.l.pairConfirmedCodeTitle,
            submitLabel: context.l.pairConfirmLink,
            submitKey: const Key('monitor-confirm'),
            allowIncomplete: true,
            enabled: !_busy,
            onSubmit: (code) => _confirm(i, code),
            footer: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                context.l.pairMonitorPeerEntered,
                style: XText.bodyDim,
              ),
              const SizedBox(height: 12),
              OwnerAuthField(controller: _auth),
            ]),
          ),
        ] else if (!i.revealed)
          Text(
            i.finished
                ? context.l.pairInviteFinished(i.result ?? i.phase)
                : context.l.pairSecretHidden,
            style: XText.bodyDim,
          )
        else if (i.sas == null)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            QrView(i.link, size: 168),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InviteLinkBox(i.link),
                if (i.linkApp != null && i.linkApp != i.link) ...[
                  const SizedBox(height: 8),
                  InviteAppLinkRow(i.linkApp!),
                ],
              ]),
            ),
          ])
        else ...[
          Row(children: [
            Expanded(child: Text(context.l.pairThisInviteCode, style: XText.title)),
            if (i.sasEmoji != null) SasModeSwitch(emoji: _emoji, onChanged: (v) => setState(() => _emoji = v)),
          ]),
          const SizedBox(height: 12),
          SasDisplay(code: i.sas!, emoji: _emoji),
          const SizedBox(height: 8),
          Text(
            context.l.pairReadCodeToContact,
            style: XText.bodyDim,
          ),
        ],
        if (!i.finished && !i.needsConfirm) ...[
          const SizedBox(height: 16),
          OwnerAuthField(controller: _auth),
        ],
        if (_error != null) ErrorLine(describeConfirmError(context.l, _error!), detail: errorDetail(_error!)),
        const SizedBox(height: 8),
        Text(
            context.l.commonSameAs(byButton
                ? 'antenna pairing confirm ${i.id}'
                : 'antenna pairing confirm ${i.id} --code ${context.l.commonCodePlaceholder}'),
            style: XText.monoSmall),
      ]),
    );
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip(this.phase);
  final String phase;

  @override
  Widget build(BuildContext context) {
    final (text, color) = invitePhaseLabel(context.l, phase);
    return XPill(text, color: color, icon: Icons.circle);
  }
}

/// Label of an invite stage.
(String, Color) invitePhaseLabel(AppLocalizations l, String phase) => switch (phase) {
      'waiting' => (l.invitePhaseWaiting, XColors.textDim),
      'code_ready' => (l.invitePhaseCodeReady, XColors.accent),
      'peer_entered_code' => (l.invitePhasePeerEntered, XColors.accent),
      'needs_confirm' => (l.invitePhaseNeedsConfirm, XColors.warn),
      'finishing' => (l.invitePhaseFinishing, XColors.accent),
      'linked' => (l.invitePhaseLinked, XColors.ok),
      'failed' => (l.invitePhaseFailed, XColors.danger),
      _ => (phase, XColors.textDim),
    };
