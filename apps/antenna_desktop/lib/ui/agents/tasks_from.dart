// SPDX-License-Identifier: AGPL-3.0-only
// Task authority in the window (D-88): whose messages an agent treats as tasks. The choice (the default, contacts at
// trust level 5; only the contacts the owner picks; nobody) is shared by Connect and by "Takes tasks from…" for an
// existing agent, which saves it with the owner password. Task authority is experimental in this preview (D-94): the
// window shows the Experimental tag next to each control that sets it, and only a tooltip on the agents' rows.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/self_level.dart';
import '../widgets/x_buttons.dart';

/// Whose messages are tasks: the default (trust level 5), only some contacts, or nobody.
class TasksChoice extends StatelessWidget {
  const TasksChoice({super.key, required this.contacts, required this.value, required this.onChanged});
  final List<ContactInfo> contacts;
  final List<String>? value;
  final ValueChanged<List<String>?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final mode = value == null ? 0 : (value!.isEmpty ? 2 : 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RadioGroup<int>(
        groupValue: mode,
        onChanged: (v) => onChanged(switch (v) {
          0 => null,
          2 => const [],
          _ => [for (final c in contacts) if (c.trust == 5) c.label],
        }),
        child: Column(children: [
          for (final (i, text) in [(0, l.tasksDefault), (1, l.tasksSome), (2, l.tasksNone)])
            InkWell(
              key: Key('tasks-mode-$i'),
              borderRadius: BorderRadius.circular(XRadius.m),
              onTap: () => onChanged(switch (i) {
                0 => null,
                2 => const [],
                _ => [for (final c in contacts) if (c.trust == 5) c.label],
              }),
              child: Row(children: [
                Radio<int>(value: i),
                const SizedBox(width: 4),
                Expanded(child: Text(text, style: XText.body.copyWith(fontSize: 12))),
              ]),
            ),
        ]),
      ),
      if (mode == 1)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in contacts)
            FilterChip(
              key: Key('tasks-contact-${c.label}'),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(c.label),
                const SizedBox(width: 8),
                TrustBadge(c.trust, size: 15),
                if (c.trust == 5) ...[const SizedBox(width: 4), SelfMark(key: Key('self-mark-${c.label}'))],
              ]),
              selected: value!.contains(c.label),
              onSelected: (v) =>
                  onChanged(v ? [...value!, c.label] : [for (final x in value!) if (x != c.label) x]),
            ),
        ]),
    ]);
  }
}

/// "Takes tasks from…" for an existing agent (owner password).
Future<void> showTasksFromDialog(BuildContext context, String agent) =>
    showXDialog<void>(context, (_) => _TasksDialog(agent: agent));

class _TasksDialog extends StatefulWidget {
  const _TasksDialog({required this.agent});
  final String agent;

  @override
  State<_TasksDialog> createState() => _TasksDialogState();
}

class _TasksDialogState extends State<_TasksDialog> {
  final _auth = OwnerAuthController();
  List<String>? _value;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final a = AppScope.read(context).agents.where((a) => a.name == widget.agent).firstOrNull;
    _value = a == null || a.tasksFromDefault ? null : (a.tasksFrom ?? const []);
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
    final err = await m.setAgentTasks(widget.agent, _auth.auth(m, l.touchIdReasonAgentTasks(cutForPrompt(widget.agent))),
        contacts: _value);
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
    return XDialogShell(
      title: l.tasksTitle(widget.agent),
      icon: Icons.task_alt_rounded,
      titleTag: const ExperimentalTag(key: Key('experimental-tasks-dialog')),
      width: 560,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('tasks-save'),
          style: XButtons.primary(),
          onPressed: _busy ? null : _save,
          child: Text(l.tasksSave),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.tasksAbout, style: XText.bodyDim),
        const SizedBox(height: 8),
        TasksChoice(contacts: m.contacts, value: _value, onChanged: (v) => setState(() => _value = v)),
        const SizedBox(height: 12),
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _save()),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
