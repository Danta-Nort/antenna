// SPDX-License-Identifier: AGPL-3.0-only
// A resident agent's session in the window (PG-23; x-control/6, CONTROL §21, D-93): its state and counters on the
// wake rule's card, the owner's own words to it (`wake_say`, the answer streams into the dialog), and the session
// commands: compact, stop, reset (with the password). The daemon keeps the session; the window only shows and asks.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';

/// The state of a resident session: label and color.
(String, Color) residentStateLook(AppLocalizations l, String state) => switch (state) {
      ResidentState.idle => (l.residentStateIdle, XColors.ok),
      ResidentState.busy => (l.residentStateBusy, XColors.accent),
      ResidentState.failed => (l.residentStateFailed, XColors.danger),
      _ => (l.residentStateSleeping, XColors.textDim),
    };

/// The session part of a resident rule's card.
class ResidentBlock extends StatelessWidget {
  const ResidentBlock(this.r, {super.key});
  final WakeRuleInfo r;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = r.resident!;
    final (state, color) = residentStateLook(l, s.state);
    final facts = <String>[
      if (s.started) l.residentCounters(s.turns, s.ownerTurns, s.starts) else l.residentNoSession,
      if (s.started) l.residentTokens(s.contextTokens, s.inputTokens, s.outputTokens, s.cacheReadTokens),
      if (s.costMicroUsd case final c?) l.residentCost((c / 1e6).toStringAsFixed(2)),
      if (s.compactions > 0) l.residentCompactions(s.compactions),
    ];
    Future<void> act(ResidentAction a) async {
      final err = await AppScope.read(context).residentSession(r.linkId, a);
      if (err != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
      }
    }

    return Column(
      key: Key('resident-${r.contact}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.forum_outlined, size: 16, color: XColors.agent),
          const SizedBox(width: XSpace.s),
          Text(l.residentLabel, style: XText.label.copyWith(color: XColors.text)),
          const SizedBox(width: 8),
          Container(
            key: Key('resident-state-${r.contact}'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Color.alphaBlend(color.withValues(alpha: 0.12), XColors.bg1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(state, style: XText.meta.copyWith(color: color, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: XSpace.s),
        Text(facts.join(' · '), key: Key('resident-facts-${r.contact}'), style: XText.meta),
        if (s.ceiling case final c?) ...[
          const SizedBox(height: 4),
          Text(l.residentCeiling(c), style: XText.meta.copyWith(color: XColors.warn)),
        ],
        if (s.parked) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.lock_outline, size: 13, color: XColors.textMute),
            const SizedBox(width: 4),
            Flexible(child: Text(l.residentParked, key: Key('resident-parked-${r.contact}'), style: XText.meta)),
          ]),
        ],
        const SizedBox(height: XSpace.s),
        Wrap(spacing: 8, children: [
          TextButton.icon(
            key: Key('resident-talk-${r.contact}'),
            onPressed: () => showResidentTalk(context, r.linkId),
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: Text(l.residentTalk),
          ),
          TextButton.icon(
            key: Key('resident-compact-${r.contact}'),
            onPressed: s.started ? () => act(ResidentAction.compact) : null,
            icon: const Icon(Icons.compress, size: 16),
            label: Text(l.residentCompact),
          ),
          TextButton.icon(
            key: Key('resident-stop-${r.contact}'),
            onPressed: s.state == ResidentState.sleeping ? null : () => act(ResidentAction.stop),
            icon: const Icon(Icons.bedtime_outlined, size: 16),
            label: Text(l.residentStop),
          ),
          TextButton.icon(
            key: Key('resident-reset-${r.contact}'),
            style: XButtons.destructive(),
            onPressed: s.started ? () => showResidentReset(context, r) : null,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: Text(l.residentReset),
          ),
        ]),
      ],
    );
  }
}

/// The owner's own words to [linkId]'s resident agent; the answer streams in.
Future<void> showResidentTalk(BuildContext context, String linkId) =>
    showXDialog<void>(context, (_) => _TalkDialog(linkId: linkId));

class _TalkDialog extends StatefulWidget {
  const _TalkDialog({required this.linkId});
  final String linkId;

  @override
  State<_TalkDialog> createState() => _TalkDialogState();
}

class _TalkDialogState extends State<_TalkDialog> {
  final _text = TextEditingController();
  bool _toContact = false;
  bool _interrupt = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    await AppScope.read(context).sayResident(widget.linkId, text, toContact: _toContact, interrupt: _interrupt);
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final r = m.wakeRuleOf(widget.linkId);
    final t = m.residentTalks[widget.linkId];
    final busy = t?.busy ?? false;
    final contact = r?.contact ?? '';
    final done = t?.done;
    return XDialogShell(
      title: l.residentTalkTitle(r?.agent ?? ''),
      icon: Icons.chat_bubble_outline,
      width: 600,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose)),
        FilledButton(
          key: const Key('resident-send'),
          style: XButtons.primary(),
          onPressed: busy ? null : _send,
          child: Text(l.residentSend),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.residentTalkAbout(contact), style: XText.bodyDim),
        if (t != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: XColors.accentFill, borderRadius: BorderRadius.circular(XRadius.bubble)),
              child: Text(t.text, style: XText.body.copyWith(color: XColors.onAccent)),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            key: const Key('resident-answer'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: XColors.bg2,
              borderRadius: BorderRadius.circular(XRadius.bubble),
              border: Border.all(color: busy ? XColors.agent.withValues(alpha: 0.55) : XColors.line),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (t.reply.isNotEmpty) SelectableText(t.reply, style: XText.body),
              if (busy) Text(t.activity ?? l.residentAnswering, style: XText.meta.copyWith(color: XColors.agent)),
              if (done != null && done.outcome == 'done' && t.toContact)
                Text(l.residentSentToContact(contact), style: XText.meta),
              if (done != null && done.outcome == 'interrupted')
                Text(l.residentInterrupted(done.detail), style: XText.meta.copyWith(color: XColors.warn)),
              if (done != null && done.outcome == 'failed')
                Text(l.residentFailed(done.detail), style: XText.meta.copyWith(color: XColors.danger)),
              if (t.error case final e?) ErrorLine(describeError(l, e), detail: errorDetail(e)),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('resident-text'),
          controller: _text,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(hintText: l.residentTalkHint),
        ),
        const SizedBox(height: 4),
        _CheckRow(
          key: const Key('resident-to-contact'),
          value: _toContact,
          onChanged: (v) => setState(() => _toContact = v),
          label: l.residentToContact(contact),
        ),
        if (r?.resident?.state == ResidentState.busy)
          _CheckRow(
            key: const Key('resident-interrupt'),
            value: _interrupt,
            onChanged: (v) => setState(() => _interrupt = v),
            label: l.residentInterrupt,
          ),
      ]),
    );
  }
}

/// A checkbox with its label (a `CheckboxListTile` paints under the dialog's decorated panel).
class _CheckRow extends StatelessWidget {
  const _CheckRow({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(XRadius.m),
        onTap: () => onChanged(!value),
        child: Row(children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: XText.body)),
        ]),
      );
}

/// A new session for [r]'s resident agent (the owner's password).
Future<void> showResidentReset(BuildContext context, WakeRuleInfo r) =>
    showXDialog<void>(context, (_) => _ResetDialog(r: r));

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({required this.r});
  final WakeRuleInfo r;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _auth = OwnerAuthController();
  Object? _error;
  bool _busy = false;

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await m.residentSession(widget.r.linkId, ResidentAction.reset,
        auth: _auth.auth(m, touchIdConfirmReason(l, l.residentResetTitle(widget.r.agent))));
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
    return XDialogShell(
      title: l.residentResetTitle(widget.r.agent),
      icon: Icons.restart_alt,
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('resident-reset-do'),
          style: XButtons.destructiveFilled(),
          onPressed: _busy ? null : _reset,
          child: Text(l.residentResetDo),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.residentResetAbout, style: XText.bodyDim),
        const SizedBox(height: 12),
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _reset()),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
