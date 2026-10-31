// SPDX-License-Identifier: AGPL-3.0-only
// One question of an agent for the owner (D-118, PG-18), with the approval requests: who asks and when, the question
// quoted as the agent's own words (it may carry what the agent read from contacts, and the card says whose messages
// it had read when it asked), a field for the answer, Answer and Set aside. The answer is the owner's word to the
// agent; the question itself is only shown, never acted on.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_logo.dart' show knownAgentBrand;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';

class QuestionCard extends StatefulWidget {
  const QuestionCard(this.q, {super.key});
  final EscalationInfo q;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _answer = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _decide({required bool dismiss}) async {
    final m = AppScope.read(context);
    if (!dismiss && _answer.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = dismiss ? await m.dismissQuestion(widget.q.id) : await m.answerQuestion(widget.q.id, _answer.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.q;
    final l = context.l;
    final m = AppScope.of(context);
    final asked = DateTime.fromMillisecondsSinceEpoch(q.createdMs);
    return Container(
      key: Key('question-${q.id}'),
      padding: const EdgeInsets.all(16),
      decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XAvatar(q.agent, size: 44, agent: true, brand: knownAgentBrand(m, q.agent)),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  q.team == null ? l.questionAsks(q.agent) : l.questionAsksTeam(q.agent, q.team!),
                  style: XText.title),
            ),
          ),
          Text(shortStamp(l, asked, m.now()), style: XText.meta),
        ]),
        const SizedBox(height: 12),
        // The agent's words, quoted: data for the owner, never an instruction to the window
        Container(
          key: Key('question-text-${q.id}'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: XColors.bg1,
            border: Border(left: BorderSide(color: XColors.lineStrong, width: 3)),
          ),
          child: SelectableText(q.question, style: XText.body),
        ),
        const SizedBox(height: XSpace.s),
        Text(l.questionQuoted, style: XText.meta),
        if (q.readFrom.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            l.questionReadFrom(q.agent, [for (final r in q.readFrom) l.questionReadContact(r.contact, r.level)].join(', ')),
            key: Key('question-read-${q.id}'),
            style: XText.meta.copyWith(color: XColors.warn),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: Key('question-answer-${q.id}'),
          controller: _answer,
          enabled: !_busy,
          minLines: 1,
          maxLines: 5,
          maxLength: 4000,
          decoration: InputDecoration(hintText: l.questionAnswerHint, counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          TextButton(
            key: Key('question-dismiss-${q.id}'),
            onPressed: _busy ? null : () => unawaited(_decide(dismiss: true)),
            child: Text(l.questionDismiss),
          ),
          FilledButton(
            key: Key('question-send-${q.id}'),
            style: XButtons.primary(),
            onPressed: _busy || _answer.text.trim().isEmpty ? null : () => unawaited(_decide(dismiss: false)),
            child: Text(l.questionAnswer),
          ),
        ]),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
