// SPDX-License-Identifier: AGPL-3.0-only
// Trust level 5 "Self" means "my own computer" (maintainer decision 2026-10-05): the daemon asks no approval for
// files (with secrets too) or for secrets in messages and streams to such a contact, accepts its clean and suspicious
// files by itself (a threat stays in quarantine), and its tasks run without confirmation. So the window asks the
// owner to accept that before level 5 is chosen anywhere: the trust picker, `/trust 5`, an invite or a join at level
// 5. The trust command itself still needs the owner password afterwards, as every trust change does.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import 'dialog_shell.dart';
import 'x_buttons.dart';

/// The level-5 warning. `true`: the owner accepted level 5; `false` (Cancel, closed): keep the previous level.
/// ∞ "My computer" (D-UI-30) is the danger colour here, right at the moment of choosing it; everywhere else (the
/// trust badge once chosen) it is a quiet neutral mark.
Future<bool> confirmSelfLevel(BuildContext context) async =>
    await showXDialog<bool>(
      context,
      (ctx) => XDialogShell(
        key: const Key('self-warning'),
        title: ctx.l.selfWarnTitle,
        leading: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: XColors.danger.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(Icons.all_inclusive_rounded, size: 18, color: XColors.danger),
        ),
        width: 500,
        actions: [
          OutlinedButton(
            key: const Key('self-cancel'),
            style: XButtons.secondary(),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonCancel),
          ),
          FilledButton(
            key: const Key('self-accept'),
            style: XButtons.primary(),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.selfWarnAccept),
          ),
        ],
        child: Text(ctx.l.selfWarnBody, style: XText.body),
      ),
    ) ??
    false;

/// A form that picks a trust level (invite, join): the level-5 warning is shown once per form, the first time level
/// 5 is chosen there, whether through the picker, the "own computer" box or on submit.
mixin SelfLevelOnce<T extends StatefulWidget> on State<T> {
  bool _selfAccepted = false;

  /// `true` when the owner accepted level 5 in this form (now or before).
  Future<bool> confirmSelfOnce() async {
    if (_selfAccepted) return true;
    final ok = await confirmSelfLevel(context);
    if (ok) _selfAccepted = true;
    return ok;
  }

  /// The [OwnComputerToggle] changed: on sets level 5 (accepted first), off goes back to the form's [fallback] level.
  Future<void> ownComputer(bool on, {required int fallback, required ValueChanged<int> setLevel}) async {
    if (on && !await confirmSelfOnce()) return;
    if (!mounted) return;
    setState(() => setLevel(on ? 5 : fallback));
  }
}

/// "This is my own computer (level 5)" in the invite and join forms, so that linking one's own machines is one tick
/// and no per-file clicks afterwards. Ticked exactly when the form's level is 5: it follows the picker and the picker
/// follows it.
class OwnComputerToggle extends StatelessWidget {
  const OwnComputerToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        key: const Key('own-computer'),
        borderRadius: BorderRadius.circular(XRadius.s),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Checkbox(
              key: const Key('own-computer-box'),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              value: value,
              onChanged: (v) => onChanged(v ?? false),
            ),
            Icon(Icons.all_inclusive_rounded, size: 17, color: value ? XColors.trustColor(5) : XColors.textMute),
            const SizedBox(width: 8),
            Expanded(child: Text(context.l.selfOwnComputerToggle, style: XText.body.copyWith(fontSize: 14))),
          ]),
        ),
      );
}

/// A contact's label with the "own computer" mark when it is at level 5 (Agents: whose messages are tasks).
String labelWithSelfMark(AppLocalizations l, String label, int? trust) => trust == 5 ? l.selfMarkedName(label) : label;

/// The small "own computer" mark next to a level-5 contact's trust badge.
class SelfMark extends StatelessWidget {
  const SelfMark({super.key, this.size = 15});
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: context.l.trustSelfName,
        child: Icon(Icons.all_inclusive_rounded, size: size, color: XColors.trustColor(5)),
      );
}
