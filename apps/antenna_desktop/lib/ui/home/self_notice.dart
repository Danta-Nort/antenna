// SPDX-License-Identifier: AGPL-3.0-only
// Once, after level 5 "Self" came to mean "my own computer" (maintainer decision 2026-10-05): contacts already at
// level 5 now get files, messages and secrets without asking. On the first window start with this meaning the owner
// sees them listed and keeps each at 5 (nothing is sent) or lowers it to 4 (the trust command with the owner password,
// as any trust change). The window remembers in its settings file that the notice was shown; with no level-5 contact
// it is marked as shown without showing, so a later level-5 contact gets the ordinary level-5 warning instead.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../state/messages.dart';
import '../../state/trust.dart' show trustGlyph;
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';

/// Show the notice if it is due, as soon as the contacts are known. `true` once it is settled (shown or not needed).
bool maybeShowSelfNotice(BuildContext context, AppModel m, Appearance? look) {
  if (look == null || !look.selfNoticeDue) return true;
  if (m.phase != Phase.unlocked || !m.contactsLoaded) return false;
  final level5 = [for (final c in m.contacts) if (c.trust == 5) c];
  look.markSelfNoticeShown();
  if (level5.isNotEmpty) {
    // Not from inside a notification of the model: the dialog opens after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) unawaited(showSelfNotice(context, level5));
    });
    WidgetsBinding.instance.scheduleFrame();
  }
  return true;
}

Future<void> showSelfNotice(BuildContext context, List<ContactInfo> contacts) =>
    showXDialog<void>(context, (_) => SelfNoticeDialog(contacts: contacts), dismissible: false);

class SelfNoticeDialog extends StatefulWidget {
  const SelfNoticeDialog({super.key, required this.contacts});
  final List<ContactInfo> contacts;

  @override
  State<SelfNoticeDialog> createState() => _SelfNoticeDialogState();
}

enum _Decision { kept, lowered }

class _SelfNoticeDialogState extends State<SelfNoticeDialog> {
  final _decided = <String, _Decision>{};
  final _errors = <String, Object>{};
  String? _busy;

  Future<void> _lower(ContactInfo c) async {
    final l = context.l;
    final m = AppScope.read(context);
    setState(() => _busy = c.linkId);
    final (done, err) = await confirmOwner(
      context,
      action: l.trustChangeAction(c.label, trustGlyph(5), trustGlyph(4)),
      cli: 'antenna trust ${c.label} 4',
      run: (auth) => m.setTrust(c.linkId, 4, auth),
    );
    if (!mounted) return;
    if (!done && err == null) {
      setState(() => _busy = null);
      return;
    }
    setState(() {
      _busy = null;
      if (err == null) {
        _decided[c.linkId] = _Decision.lowered;
        _errors.remove(c.linkId);
      } else {
        _errors[c.linkId] = err;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return XDialogShell(
      key: const Key('self-notice'),
      title: l.selfNoticeTitle,
      icon: Icons.all_inclusive_rounded,
      subtitle: l.selfNoticeBody,
      width: 620,
      actions: [
        FilledButton(
          key: const Key('self-notice-done'),
          style: XButtons.primary(),
          onPressed: _busy != null ? null : () => Navigator.pop(context),
          child: Text(l.commonDone),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in widget.contacts) _row(context, c),
      ]),
    );
  }

  Widget _row(BuildContext context, ContactInfo c) {
    final l = context.l;
    final decided = _decided[c.linkId];
    final err = _errors[c.linkId];
    final busy = _busy != null;
    return Padding(
      key: Key('self-notice-${c.label}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          XAvatar(c.label,
              size: 34, agent: c.peerKind == 'agent', picture: AppScope.maybeOf(context)?.pictureOfContact(c.linkId)),
          const SizedBox(width: 8),
          Expanded(
            child: Row(children: [
              Flexible(child: Text(c.label, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14))),
              const SizedBox(width: 8),
              TrustBadge(decided == _Decision.lowered ? 4 : 5, size: 18),
            ]),
          ),
          const SizedBox(width: 8),
          switch (decided) {
            _Decision.kept => Text(l.selfNoticeKept, key: Key('self-kept-${c.label}'), style: XText.meta),
            _Decision.lowered =>
              Text(l.selfNoticeLowered, key: Key('self-lowered-${c.label}'), style: XText.meta.copyWith(color: XColors.ok)),
            null => Row(mainAxisSize: MainAxisSize.min, children: [
                OutlinedButton(
                  key: Key('self-keep-${c.label}'),
                  style: XButtons.secondary(),
                  onPressed: busy ? null : () => setState(() => _decided[c.linkId] = _Decision.kept),
                  child: Text(l.selfNoticeKeep),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: Key('self-lower-${c.label}'),
                  style: XButtons.secondary(),
                  onPressed: busy ? null : () => _lower(c),
                  child: Text(l.selfNoticeLower),
                ),
              ]),
          },
        ]),
        if (err != null) ErrorLine(describeError(l, err), detail: errorDetail(err)),
      ]),
    );
  }
}
