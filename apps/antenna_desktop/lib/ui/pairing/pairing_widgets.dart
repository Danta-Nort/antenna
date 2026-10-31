// SPDX-License-Identifier: AGPL-3.0-only
// Pieces the pairing dialogs share: the invite link with its copy button, the app link row, the numbered steps, the
// busy line and the facts of a new link.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import '../widgets/badges.dart';

class InviteLinkBox extends StatelessWidget {
  const InviteLinkBox(this.link, {super.key});
  final String link;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: XColors.bg0.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(XRadius.s),
          border: Border.all(color: XColors.line),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              link,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: XText.mono.copyWith(fontSize: 11, color: XColors.textDim, height: 1.5),
            ),
          ),
          IconButton(
            key: const Key('copy-link'),
            tooltip: context.l.pairCopyLink,
            onPressed: () => Clipboard.setData(ClipboardData(text: link)),
            icon: Icon(Icons.copy_rounded, size: 17, color: XColors.accent),
          ),
        ]),
      );
}

/// `antenna://pair#…`: the same link for the app (open it right here) and for 0.1.0-preview.1 nodes that do not
/// understand the web address. People are sent the web link above.
class InviteAppLinkRow extends StatelessWidget {
  const InviteAppLinkRow(this.link, {super.key});
  final String link;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.open_in_new_rounded, size: 15, color: XColors.textMute),
        const SizedBox(width: 8),
        Expanded(child: Text(context.l.pairAppLinkNote, style: XText.meta)),
        TextButton.icon(
          key: const Key('copy-link-app'),
          onPressed: () => Clipboard.setData(ClipboardData(text: link)),
          icon: const Icon(Icons.copy_rounded, size: 15),
          label: Text(context.l.pairCopyAppLink),
        ),
      ]);
}

class PairingSteps extends StatelessWidget {
  const PairingSteps(this.steps, {super.key, required this.active});
  final List<String> steps;
  final int active;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < active ? XColors.accent.withValues(alpha: 0.15) : null,
                  border: Border.all(color: i <= active ? XColors.accent : XColors.line),
                ),
                child: i < active
                    ? Icon(Icons.check, size: 12, color: XColors.accent)
                    : Text('${i + 1}', style: XText.monoSmall.copyWith(color: i == active ? XColors.accent : XColors.textMute)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  steps[i],
                  style: XText.bodyDim.copyWith(fontSize: 12, color: i == active ? XColors.text : XColors.textDim),
                ),
              ),
            ]),
          ),
      ]);
}

class PairingBusy extends StatelessWidget {
  const PairingBusy(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.6, color: XColors.accent)),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: XText.body)),
        ]),
      );
}

class LinkedSummary extends StatelessWidget {
  const LinkedSummary(this.r, {super.key});
  final LinkedReply r;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: xGlow(radius: XRadius.m, color: XColors.ok, strength: 0.7),
          child: Row(children: [
            Icon(Icons.verified_outlined, color: XColors.ok, size: 24),
            const SizedBox(width: 12),
            Expanded(child: Text(context.l.pairLinked(r.contact), style: XText.title)),
          ]),
        ),
        const SizedBox(height: 16),
        FactRow(context.l.pairFactLinkId, shortHex(r.linkId, head: 10, tail: 6)),
        FactRow(context.l.pairFactLevel, '${r.trust} · ${TrustLevel.of(r.trust).name(context.l)}'),
        FactRow(context.l.pairFactNetwork, netModeLabel(context.l, r.netMode)),
        FactRow(context.l.factsTlsPairing, r.kxGroup, valueColor: XColors.accent),
        FactRow(context.l.pairFactPairingTime, context.l.pairMs(r.pairingMs)),
      ]);
}

/// "The contact confirmed — codes match" (D-95): side A's confirmation without retyping the code, shown only when the
/// daemon offers it. The click is the owner's explicit action; nothing is confirmed before it.
class ConfirmMatchButton extends StatelessWidget {
  const ConfirmMatchButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.check_rounded, size: 18),
        label: Text(context.l.pairConfirmMatch),
      );
}

/// One line of explanation next to a pairing step (why the code is asked for after all).
class PairingNote extends StatelessWidget {
  const PairingNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.info_outline_rounded, size: 16, color: XColors.warn),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.bodyDim)),
      ]);
}
