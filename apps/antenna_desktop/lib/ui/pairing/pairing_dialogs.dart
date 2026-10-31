// SPDX-License-Identifier: AGPL-3.0-only
// Creating a link (SPEC §6, docs/CONTROL.md §6): the choice between an invite (invite_dialog.dart: link + QR, TTL,
// code, confirmation on side A) and a join (join_dialog.dart: link → code on side B); invites created outside the
// window are confirmed in invite_monitor.dart. There is no "it matches" button: B types the code, and A confirms after
// hearing "it matched".

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import '../widgets/dialog_shell.dart';
import 'invite_dialog.dart';
import 'join_dialog.dart';

export 'invite_dialog.dart';
export 'invite_monitor.dart';
export 'join_dialog.dart';

/// Choice: invite or join.
Future<void> showPairingMenu(BuildContext context) => showXDialog<void>(
      context,
      (ctx) => XDialogShell(
        title: ctx.l.pairNewContact,
        icon: Icons.add_link,
        subtitle: ctx.l.pairNewContactSubtitle,
        width: 560,
        child: Row(children: [
          Expanded(
            child: _Choice(
              icon: Icons.qr_code_2,
              title: ctx.l.commonInvite,
              text: ctx.l.pairInviteChoice,
              cli: 'antenna invite',
              onTap: () {
                Navigator.pop(ctx);
                showInviteDialog(context);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Choice(
              icon: Icons.link,
              title: ctx.l.commonJoin,
              text: ctx.l.pairJoinChoice,
              cli: 'antenna join',
              onTap: () {
                Navigator.pop(ctx);
                showJoinDialog(context);
              },
            ),
          ),
        ]),
      ),
    );

class _Choice extends StatelessWidget {
  const _Choice({required this.icon, required this.title, required this.text, required this.cli, required this.onTap});
  final IconData icon;
  final String title;
  final String text;
  final String cli;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XRadius.l),
        child: Container(
          height: 170,
          padding: const EdgeInsets.all(16),
          decoration: xGlow(radius: XRadius.l, strength: 0.5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: XColors.accent, size: 26),
            const SizedBox(height: 12),
            Text(title, style: XText.title),
            const SizedBox(height: 8),
            Expanded(child: Text(text, style: XText.bodyDim.copyWith(fontSize: 12))),
            Text(cli, style: XText.monoSmall),
          ]),
        ),
      );
}
