// SPDX-License-Identifier: AGPL-3.0-only
// The join dialog (side B, SPEC §6, docs/CONTROL.md §6): the invite link, then the code A reads out, typed by B.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/invite_link.dart';
import '../../state/messages.dart';
import '../../state/pairing.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/self_level.dart';
import '../widgets/trust_picker.dart';
import 'pairing_widgets.dart';
import 'sas_view.dart';

Future<void> showJoinDialog(BuildContext context, {String? link}) =>
    showXDialog<void>(context, (_) => JoinDialog(link: link), dismissible: false);

class JoinDialog extends StatefulWidget {
  const JoinDialog({super.key, this.link});
  final String? link;

  @override
  State<JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<JoinDialog> with SelfLevelOnce {
  late final _link = TextEditingController(text: widget.link ?? '');
  final _label = TextEditingController();
  final _auth = OwnerAuthController();

  /// The last join failed as a Touch ID matter: the form asks for the password, with no error.
  bool _fellBack = false;
  int _trust = 2;
  JoinSession? _s;
  String? _formError;

  @override
  void dispose() {
    _s?.removeListener(_changed);
    _s?.dispose();
    _link.dispose();
    _label.dispose();
    _auth.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        final s = _s;
        if (s != null && s.phase == JoinPhase.failed && !_reachedPeer(s)) {
          _fellBack = _auth.fellBack(context.l, AppScope.read(context), s.error);
        }
      });

  Future<void> _start() async {
    if (_trust == 5 && !await confirmSelfOnce()) return;
    if (!mounted) return;
    // x://pair#…, antenna://pair#… or https://antenna.contact/#…, normalized to the form the daemon accepts.
    final link = normalizeInviteLink(_link.text);
    if (link == null) {
      setState(() => _formError = context.l.pairJoinBadLink);
      return;
    }
    final label = _label.text.trim();
    _s?.removeListener(_changed);
    _s?.dispose();
    final m = AppScope.read(context);
    final l = context.l;
    final s = m.startJoin(
        link: link,
        trust: _trust,
        label: label.isEmpty ? null : label,
        auth: _auth.auth(m, touchIdConfirmReason(l, l.pairJoinTitle)));
    _auth.password.clear();
    s.addListener(_changed);
    setState(() {
      _s = s;
      _formError = null;
      _fellBack = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null || (s.phase == JoinPhase.failed && !_reachedPeer(s))) return _form(_fellBack ? null : s?.error);
    return XDialogShell(
      title: context.l.pairJoinTitle,
      icon: Icons.link,
      width: 560,
      onClose: () async {
        if (!s.finished) await s.cancel();
        if (context.mounted) Navigator.pop(context);
      },
      actions: [
        if (!s.finished)
          TextButton(
            onPressed: () async {
              await s.cancel();
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(context.l.pairDecline),
          ),
        if (s.finished) FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonDone)),
      ],
      child: switch (s.phase) {
        JoinPhase.connecting => PairingBusy(context.l.pairJoinConnecting),
        JoinPhase.needCode => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              context.l.pairJoinNeedCode,
              style: XText.bodyDim,
            ),
            const SizedBox(height: 16),
            SasInput(onSubmit: s.submitCode),
          ]),
        JoinPhase.verifying => PairingBusy(context.l.pairJoinVerifying),
        JoinPhase.linked => LinkedSummary(s.linked!),
        JoinPhase.failed => ErrorLine(s.errorText(context.l) ?? context.l.commonFailed, detail: errorDetail(s.error!)),
      },
    );
  }

  /// An error after connecting (wrong code, refusal) is shown in the dialog; before connecting, in the form.
  bool _reachedPeer(JoinSession s) {
    final e = s.error;
    return e is XControlException &&
        (e.code == XErrorCode.sasMismatch || e.code == XErrorCode.rejected || e.code == XErrorCode.pairingFailed);
  }

  Widget _form(Object? error) => XDialogShell(
        title: context.l.pairJoinTitle,
        icon: Icons.link,
        subtitle: context.l.pairJoinSubtitle,
        width: 600,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonCancel)),
          FilledButton(key: const Key('join-start'), onPressed: _start, child: Text(context.l.commonJoin)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const Key('join-link'),
            controller: _link,
            autofocus: true,
            minLines: 2,
            maxLines: 3,
            style: XText.mono.copyWith(color: XColors.text, fontSize: 11),
            decoration: InputDecoration(labelText: context.l.pairInviteLink),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('join-label'),
            controller: _label,
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
            onChanged: (on) => ownComputer(on, fallback: 2, setLevel: (v) => _trust = v),
          ),
          const SizedBox(height: 12),
          OwnerAuthField(controller: _auth, onSubmitted: (_) => _start()),
          if (_formError != null) ErrorLine(_formError!),
          if (error != null) ErrorLine(describeError(context.l, error), detail: errorDetail(error)),
          const SizedBox(height: 8),
          Text(context.l.commonSameAs('antenna join ${context.l.commonLinkPlaceholder} --trust $_trust'), style: XText.monoSmall),
        ]),
      );
}
