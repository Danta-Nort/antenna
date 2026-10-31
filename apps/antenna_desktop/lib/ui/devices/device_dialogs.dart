// SPDX-License-Identifier: AGPL-3.0-only
// "Revoke this computer" (PG-25): for a lost or stolen own computer. It says plainly what happens and what does not:
// the link to it is wiped here (the history stays unless asked), the owner's other computers are told and stop
// accepting its keys at once, the owner revokes it on each of them too, and contacts linked only to it can be told only
// another way. The password, as for `revoke`.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';

Future<void> showRevokeDeviceDialog(BuildContext context, DeviceInfo d) =>
    showXDialog<void>(context, (_) => _RevokeDialog(d));

class _RevokeDialog extends StatefulWidget {
  const _RevokeDialog(this.d);
  final DeviceInfo d;

  @override
  State<_RevokeDialog> createState() => _RevokeDialogState();
}

class _RevokeDialogState extends State<_RevokeDialog> {
  final _auth = OwnerAuthController();
  bool _deleteHistory = false;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _revoke() async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await m.deviceRevoke(widget.d, _auth.auth(m, touchIdConfirmReason(l, l.devicesRevokeTitle(widget.d.contact))),
        deleteHistory: _deleteHistory);
    _auth.password.clear();
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context);
      return;
    }
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final d = widget.d.contact;
    Widget point(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: XColors.textDim)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: XText.body)),
          ]),
        );
    return XDialogShell(
      key: const Key('device-revoke-dialog'),
      title: l.devicesRevokeTitle(d),
      icon: Icons.phonelink_erase_outlined,
      width: 560,
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('device-revoke-confirm'),
          style: XButtons.destructiveFilled(),
          onPressed: _busy ? null : _revoke,
          child: Text(l.devicesRevokeConfirm),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.devicesRevokeWhen, style: XText.bodyDim),
        const SizedBox(height: 16),
        point(Icons.link_off_rounded, l.devicesRevokeLink(d)),
        point(Icons.devices_outlined, l.devicesRevokeOthers(d)),
        point(Icons.fingerprint, l.devicesRevokeTouchId(d)),
        point(Icons.people_outline, l.devicesRevokeContacts(d)),
        const SizedBox(height: 4),
        Row(children: [
          Checkbox(
            key: const Key('device-revoke-history'),
            value: _deleteHistory,
            onChanged: _busy ? null : (v) => setState(() => _deleteHistory = v ?? false),
          ),
          const SizedBox(width: 4),
          Flexible(child: Text(l.devicesRevokeDeleteHistory, style: XText.body)),
        ]),
        const SizedBox(height: 8),
        OwnerAuthField(controller: _auth, autofocus: true, onSubmitted: (_) => _busy ? null : _revoke()),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('antenna devices revoke $d', style: XText.monoSmall),
        ),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
