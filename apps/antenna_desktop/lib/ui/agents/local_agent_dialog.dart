// SPDX-License-Identifier: AGPL-3.0-only
// "Create a local agent" (CONTROL §24 `local_agent_add`): a name and the owner password. The name is prefilled from
// the model's ID and checked as the daemon checks it (`[A-Za-z0-9._-]{1,64}`, not taken by another agent of this
// node); other agents and contacts will address the agent by it. The password goes to the daemon once and is not kept.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/local_models.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';

/// Returns the new agent's name, or `null` when the owner cancelled.
Future<String?> showLocalAgentDialog(BuildContext context, LocalModelInfo model) =>
    showXDialog<String>(context, (_) => LocalAgentDialog(model));

class LocalAgentDialog extends StatefulWidget {
  const LocalAgentDialog(this.model, {super.key});
  final LocalModelInfo model;

  @override
  State<LocalAgentDialog> createState() => _LocalAgentDialogState();
}

class _LocalAgentDialogState extends State<LocalAgentDialog> {
  late final TextEditingController _name;
  final _auth = OwnerAuthController();
  late final Set<String> _taken;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final m = AppScope.read(context);
    _taken = {for (final a in m.agents) a.name, for (final a in m.localAgents) a.name};
    _name = TextEditingController(text: suggestLocalAgentName(widget.model.id, _taken))
      ..addListener(() => setState(() {}));
    _auth.password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _auth.dispose();
    super.dispose();
  }

  String? _nameProblem(AppLocalizations l) {
    final n = _name.text.trim();
    if (!validLocalAgentName(n)) return l.localCreateNameInvalid;
    if (_taken.contains(n)) return l.localCreateNameTaken;
    return null;
  }

  Future<void> _create() async {
    final l = context.l;
    final m = AppScope.read(context);
    if (_busy || _nameProblem(l) != null || !_auth.ready(m)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _name.text.trim();
    final (a, err) =
        await m.addLocalAgent(name, widget.model.id, _auth.auth(m, touchIdConfirmReason(l, l.localCreateTitle)));
    if (!mounted) return;
    if (a != null) {
      _auth.password.clear();
      Navigator.pop(context, a.name);
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
    final problem = _name.text.isEmpty ? null : _nameProblem(l);
    final err = _error;
    return XDialogShell(
      title: l.localCreateTitle,
      icon: Icons.smart_toy_outlined,
      titleTag: const ExperimentalTag(),
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('local-agent-create'),
          onPressed: _busy || problem != null || _name.text.isEmpty || !_auth.ready(AppScope.of(context)) ? null : _create,
          child: Text(_busy ? l.localCreating : l.localCreate),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.localCreateAbout(widget.model.name), style: XText.bodyDim),
        const SizedBox(height: 16),
        TextField(
          key: const Key('local-agent-name'),
          controller: _name,
          autofocus: true,
          style: XText.body.copyWith(fontFamily: XFonts.mono),
          decoration: InputDecoration(
            labelText: l.localCreateName,
            helperText: l.localCreateNameHint,
            helperMaxLines: 2,
            errorText: problem,
          ),
        ),
        const SizedBox(height: 16),
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _create()),
        if (err != null) ErrorLine(describeError(l, err), detail: errorDetail(err)),
      ]),
    );
  }
}
