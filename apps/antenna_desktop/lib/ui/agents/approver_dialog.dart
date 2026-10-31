// SPDX-License-Identifier: AGPL-3.0-only
// "Can approve for…" (CONTROL §31, PG-57; experimental): an agent of this computer, or an agent of an own computer
// (a contact at ∞), answers the owner's other agents' approval requests in the owner's place, for the agents and the
// kinds of requests the owner chooses. The daemon decides whether an answer counts (only inside the owner's own
// computers, never the approver's own requests, no chains) and logs every answer with its reason.
//
// Naming an approver, widening what it answers or naming a stale one again shows the red warning first, at the moment
// of choosing (D-UI-20, D-UI-30), then asks for one touch (Touch ID) or the password: it widens who decides. Narrowing
// and Off send `approver_narrow` / `approver_remove` with neither (D-84). The dialog says before Save which of the two
// the change is.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/approvers.dart';
import '../../state/messages.dart';
import '../../state/touch_id.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/touch_id_text.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';

/// Whose requests [agent] (on own computer [contact]) answers, and Off.
Future<void> showApproverDialog(BuildContext context, {required String agent, String? contact}) =>
    showXDialog<void>(context, (_) => ApproverDialog(agent: agent, contact: contact));

/// "volna", or "volna on Mac mini" for an agent of an own computer.
String approverName(AppLocalizations l, String agent, String? device) =>
    device == null ? agent : l.approverOnDevice(agent, device);

/// An `answerable_by` label (`volna`, `volna@Mac mini`) in words.
String approverLabelName(AppLocalizations l, String label) {
  final (agent, device) = splitApproverLabel(label);
  return approverName(l, agent, device);
}

/// A kind of request, as a choice ("Files it sends").
String approverKindLabel(AppLocalizations l, String kind) => switch (kind) {
      'send_message' => l.approverKindSend,
      'share_file' => l.approverKindShare,
      'request_file' => l.approverKindRequest,
      'accept_file' => l.approverKindAccept,
      _ => kind,
    };

/// A kind of request inside a sentence ("files it sends").
String approverKindShort(AppLocalizations l, String kind) => switch (kind) {
      'send_message' => l.approverKindSendShort,
      'share_file' => l.approverKindShareShort,
      'request_file' => l.approverKindRequestShort,
      'accept_file' => l.approverKindAcceptShort,
      _ => kind,
    };

/// "all your agents · every kind", "builder · messages, file requests".
String approverScope(AppLocalizations l, List<String>? agents, List<String>? kinds) => l.approverScope(
      agents == null ? l.approverAgentsAll : agents.join(', '),
      kinds == null
          ? l.approverKindsAll
          : [for (final k in delegableKinds) if (kinds.contains(k)) approverKindShort(l, k)].join(', '),
    );

/// The warning before an agent is named or widened, red at the moment of choosing (D-UI-30). `true`: accepted.
Future<bool> confirmApproverWarning(BuildContext context, String who) async =>
    await showXDialog<bool>(
      context,
      (ctx) => XDialogShell(
        key: const Key('approver-warning'),
        title: ctx.l.approverWarnTitle(who),
        titleTag: const ExperimentalTag(),
        leading: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: XColors.danger.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(Icons.gpp_maybe_outlined, size: 18, color: XColors.danger),
        ),
        width: 520,
        actions: [
          OutlinedButton(
            key: const Key('approver-warning-cancel'),
            style: XButtons.secondary(),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonCancel),
          ),
          FilledButton(
            key: const Key('approver-warning-accept'),
            style: XButtons.destructiveFilled(),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.approverWarnAccept(who)),
          ),
        ],
        child: Text(ctx.l.approverWarnBody(who), style: XText.body),
      ),
    ) ??
    false;

/// `approver_set` with one touch or the password (the warning was accepted before). `(true, null)`: done;
/// `(false, null)`: the owner backed out; `(false, err)`: the daemon refused.
Future<(bool, Object?)> authorizeApprover(BuildContext context, ApproverSetRequest r) async {
  final m = AppScope.read(context);
  final l = context.l;
  final who = approverName(l, r.name, r.contact);
  String? note;
  if (m.touchIdReady) {
    final err = await m.setApproverWithTouchId(r, reason: l.touchIdReasonApprover(cutForPrompt(r.name)));
    if (err == null) return (true, null);
    if (TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) return (false, err);
    note = touchIdFallbackNote(l, m, err);
    if (!context.mounted) return (false, null);
  }
  final pw = await askOwnerPassword(
    context,
    note: note,
    action: l.approverSetAction(who),
    detail: approverScope(l, r.agents, r.kinds),
    cli: approverCli(r),
  );
  if (pw == null || !context.mounted) return (false, null);
  final err = await m.setApprover(r.withPassword(pw));
  return (err == null, err);
}

/// Name a stale approver again with its scope (its key there changed): the warning, then a touch or the password.
Future<Object?> nameApproverAgain(BuildContext context, ApproverInfo a) async {
  final who = approverName(context.l, a.agent, a.contact);
  if (!await confirmApproverWarning(context, who) || !context.mounted) return null;
  final (_, err) = await authorizeApprover(
      context, ApproverSetRequest(name: a.agent, contact: a.contact, agents: a.agents, kinds: a.kinds, password: ''));
  return err;
}

class ApproverDialog extends StatefulWidget {
  const ApproverDialog({super.key, required this.agent, this.contact});

  /// The approver: this computer's agent, or with [contact] that own computer's agent.
  final String agent;
  final String? contact;

  @override
  State<ApproverDialog> createState() => _ApproverDialogState();
}

class _ApproverDialogState extends State<ApproverDialog> {
  late bool _on;
  late bool _allAgents;
  late final Set<String> _agents;
  late final Set<String> _kinds;

  /// The warning was accepted in this dialog: a second Save (a mistyped password) does not show it again.
  bool _warned = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final cur = AppScope.read(context).approverOf(widget.agent, contact: widget.contact);
    _on = cur != null;
    _allAgents = cur?.agents == null;
    _agents = {...?cur?.agents};
    _kinds = {...(cur?.kinds ?? delegableKinds)};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshApprovers();
    });
  }

  /// What Save sends for the choices on screen; a String when they are incomplete.
  Object _change(BuildContext context) {
    final l = context.l;
    if (_on && !_allAgents && _agents.isEmpty) return l.approverNoAgents;
    if (_on && _kinds.isEmpty) return l.approverNoKinds;
    return approverChange(
      name: widget.agent,
      contact: widget.contact,
      current: AppScope.of(context).approverOf(widget.agent, contact: widget.contact),
      on: _on,
      agents: _allAgents ? null : [for (final a in _candidates(context)) if (_agents.contains(a)) a],
      kinds: normalKinds(_kinds),
    );
  }

  /// The agents whose requests it may answer: this computer's, without itself.
  List<String> _candidates(BuildContext context) => [
        for (final a in AppScope.of(context).agents)
          if (a.localModel == null && (widget.contact != null || a.name != widget.agent)) a.name,
        // A chosen agent that is gone stays listed, so narrowing does not drop it silently
        for (final n in _agents)
          if (!AppScope.of(context).agents.any((a) => a.name == n)) n,
      ];

  Future<void> _save() async {
    final change = _change(context);
    if (change is String) {
      setState(() => _error = change);
      return;
    }
    final m = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    Object? err;
    var done = true;
    switch (change) {
      case ApproverUnchanged():
        break;
      case ApproverOff(:final request):
        err = await m.removeApprover(request.name, contact: request.contact);
      case ApproverNarrow(:final request):
        err = await m.narrowApprover(request);
      case ApproverWiden(:final request):
        if (!_warned) {
          _warned = await confirmApproverWarning(context, approverName(context.l, widget.agent, widget.contact));
          if (!mounted) return;
        }
        if (!_warned) {
          done = false;
        } else {
          (done, err) = await authorizeApprover(context, request);
        }
    }
    if (!mounted) return;
    if (err == null && done) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _nameAgain(ApproverInfo a) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await nameApproverAgain(context, a);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final who = approverName(l, widget.agent, widget.contact);
    Widget shell(Widget child, List<Widget> actions) => XDialogShell(
          title: l.approverTitle(who),
          icon: Icons.how_to_reg_outlined,
          titleTag: const ExperimentalTag(key: Key('experimental-approver-dialog')),
          width: 600,
          actions: actions,
          child: child,
        );
    if (!m.approversSupported) {
      return shell(Text(l.approverNeedsNewer, key: const Key('approver-needs-newer'), style: XText.bodyDim),
          [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose))]);
    }
    final current = m.approverOf(widget.agent, contact: widget.contact);
    final change = _change(context);
    final candidates = _candidates(context);
    return shell(
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.approverAbout, style: XText.bodyDim),
        if (current != null && current.stale) ...[
          const SizedBox(height: 12),
          Container(
            key: const Key('approver-stale'),
            padding: const EdgeInsets.all(12),
            decoration: xPanel(
              fill: Color.alphaBlend(XColors.warn.withValues(alpha: 0.08), XColors.bg1),
              border: XColors.warn.withValues(alpha: 0.4),
              radius: XRadius.m,
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.key_off_outlined, size: 18, color: XColors.warn),
              const SizedBox(width: 8),
              Expanded(child: Text(l.approverStale(current.contact ?? ''), style: XText.body)),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('approver-name-again'),
                style: XButtons.secondary(),
                onPressed: _busy ? null : () => _nameAgain(current),
                child: Text(l.approverNameAgain),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        RadioGroup<bool>(
          groupValue: _on,
          onChanged: (v) => setState(() => _on = v ?? false),
          child: Column(children: [
            for (final (value, text) in [(false, l.approverOffOption), (true, l.approverOnOption(widget.agent))])
              InkWell(
                key: Key('approver-${value ? 'on' : 'off'}'),
                borderRadius: BorderRadius.circular(XRadius.m),
                onTap: () => setState(() => _on = value),
                child: Row(children: [
                  Radio<bool>(value: value),
                  const SizedBox(width: 4),
                  Expanded(child: Text(text, style: XText.body)),
                ]),
              ),
          ]),
        ),
        if (_on) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l.approverWhose, style: XText.label),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ChoiceChip(
                  key: const Key('approver-agents-all'),
                  label: Text(l.approverAllAgents),
                  selected: _allAgents,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _allAgents = true),
                ),
                ChoiceChip(
                  key: const Key('approver-agents-chosen'),
                  label: Text(l.approverChosenAgents),
                  selected: !_allAgents,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _allAgents = false),
                ),
              ]),
              if (!_allAgents) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final n in candidates)
                    FilterChip(
                      key: Key('approver-agent-$n'),
                      label: Text(n),
                      selected: _agents.contains(n),
                      onSelected: (v) => setState(() => v ? _agents.add(n) : _agents.remove(n)),
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              Text(l.approverWhich, style: XText.label),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in delegableKinds)
                  FilterChip(
                    key: Key('approver-kind-$k'),
                    label: Text(approverKindLabel(l, k)),
                    selected: _kinds.contains(k),
                    onSelected: (v) => setState(() => v ? _kinds.add(k) : _kinds.remove(k)),
                  ),
              ]),
              const SizedBox(height: 8),
              Text(l.approverStaysWithYou, style: XText.meta),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        // Which of the two Save is, before it is pressed: widening asks, narrowing does not.
        switch (change) {
          ApproverWiden() => _Note(Icons.key_outlined, l.approverWidenNote, key: const Key('approver-note-widen')),
          ApproverNarrow() || ApproverOff() =>
            _Note(Icons.lock_open_outlined, l.approverNarrowNote, key: const Key('approver-note-narrow')),
          _ => const SizedBox.shrink(),
        },
        if (_error case final e?) e is String ? ErrorLine(e) : ErrorLine(describeError(l, e), detail: errorDetail(e)),
      ]),
      [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('approver-save'),
          style: XButtons.primary(),
          onPressed: _busy ? null : _save,
          child: Text(l.approverSave),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 16, color: XColors.textDim),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.meta)),
      ]);
}
