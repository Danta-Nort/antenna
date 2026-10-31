// SPDX-License-Identifier: AGPL-3.0-only
// Code mode, offered once to an owner who has agents (Chat stays the default for new users), and the question before
// the window closes with agents running in it.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/appearance.dart';
import '../../theme/x_theme.dart';
import '../widgets/dialog_shell.dart';

/// A slim banner above the sections: "Run your agents in this window". Either answer is remembered in window.json.
class CodeOfferBanner extends StatelessWidget {
  const CodeOfferBanner(this.look, {super.key});
  final Appearance look;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Container(
      key: const Key('code-offer'),
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      decoration: BoxDecoration(color: XColors.accentSoft, border: Border(bottom: BorderSide(color: XColors.accentLine))),
      child: Row(children: [
        Icon(Icons.terminal_rounded, size: 20, color: XColors.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.codeOfferTitle, style: XText.title.copyWith(fontSize: 14)),
            const SizedBox(height: 2),
            Text(l.codeOfferBody, style: XText.bodyDim.copyWith(fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 12),
        TextButton(key: const Key('code-offer-later'), onPressed: look.dismissCodeOffer, child: Text(l.codeOfferLater)),
        const SizedBox(width: 4),
        FilledButton(
          key: const Key('code-offer-try'),
          onPressed: () => look.ui = InterfaceMode.code,
          child: Text(l.codeOfferTry),
        ),
      ]),
    );
  }
}

/// The window is closing with [count] agents running: stop them and quit, or stay. `true` means quit.
Future<bool> confirmQuitWithAgents(BuildContext context, int count) async =>
    await showXDialog<bool>(
      context,
      (ctx) => XDialogShell(
        title: ctx.l.codeQuitTitle,
        icon: Icons.terminal_rounded,
        width: 460,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.commonCancel)),
          FilledButton(
            key: const Key('code-quit-stop'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.codeQuitStop),
          ),
        ],
        child: Text(ctx.l.codeQuitBody(count), style: XText.body),
      ),
    ) ??
    false;
