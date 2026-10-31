// SPDX-License-Identifier: AGPL-3.0-only
// "Questions go to…" for an agent (D-118, PG-18): the owner (the default: the question comes as a card with the
// approval requests), or a contact among the agent's links, to whom a question goes as the agent's message under the
// policy of `send`. Saved with the owner password; experimental (D-94).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';

/// Where [agent]'s questions go (owner password).
Future<void> showEscalateToDialog(BuildContext context, String agent) =>
    showXDialog<void>(context, (_) => _EscalateDialog(agent: agent));

class _EscalateDialog extends StatefulWidget {
  const _EscalateDialog({required this.agent});
  final String agent;

  @override
  State<_EscalateDialog> createState() => _EscalateDialogState();
}

class _EscalateDialogState extends State<_EscalateDialog> {
  final _auth = OwnerAuthController();

  /// `null`: the owner.
  String? _to;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _to = AppScope.read(context).agents.where((a) => a.name == widget.agent).firstOrNull?.escalateTo;
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await m.setAgentEscalate(widget.agent, _auth.auth(m, touchIdConfirmReason(l, l.escalateTitle(widget.agent))),
        to: _to);
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
    final m = AppScope.of(context);
    final l = context.l;
    final a = m.agents.where((x) => x.name == widget.agent).firstOrNull;
    // Only contacts the agent sees (its links; all when it has no list)
    final contacts = [
      for (final c in m.contacts)
        if (a?.links == null || a!.links!.contains(c.label)) c.label,
    ];
    return XDialogShell(
      title: l.escalateTitle(widget.agent),
      icon: Icons.contact_support_outlined,
      titleTag: const ExperimentalTag(key: Key('experimental-escalate-dialog')),
      width: 560,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('escalate-save'),
          style: XButtons.primary(),
          onPressed: _busy ? null : _save,
          child: Text(l.tasksSave),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.escalateAbout, style: XText.bodyDim),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: _to ?? '',
          onChanged: (v) => setState(() => _to = (v == null || v.isEmpty) ? null : v),
          child: Column(children: [
            for (final (value, text, hint) in [
              ('', l.escalateOwner, l.escalateOwnerHint),
              for (final c in contacts) (c, c, l.escalateContactHint(c)),
            ])
              InkWell(
                key: Key('escalate-to-${value.isEmpty ? 'owner' : value}'),
                borderRadius: BorderRadius.circular(XRadius.m),
                onTap: () => setState(() => _to = value.isEmpty ? null : value),
                child: Row(children: [
                  Radio<String>(value: value),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(text, style: XText.body),
                      Text(hint, style: XText.meta),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _save()),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
