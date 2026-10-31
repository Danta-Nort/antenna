// SPDX-License-Identifier: AGPL-3.0-only
// The agents' questions (x-control/7, CONTROL §29, D-118; crates/antenna-proto/src/control/escalations.rs): a part of
// models.dart. An agent asks a question it cannot decide; the owner sees it as a card and answers or sets it aside.
// The question is the agent's own text, which may carry what it read from contacts: the window shows it quoted, as
// data, with what the agent had read when it asked.

part of 'models.dart';

/// A question's state (`EscalationInfo.state`).
abstract final class EscalationState {
  static const open = 'open';
  static const answered = 'answered';
  static const dismissed = 'dismissed';

  /// Sent to the supervisor contact as the agent's message.
  static const sent = 'sent';
}

/// What the agent had read when it asked (its taint): a contact and the trust level then.
final class EscalationRead {
  const EscalationRead(this.contact, this.level);
  final String contact;
  final int level;
}

/// One question of an agent.
final class EscalationInfo {
  const EscalationInfo({
    required this.id,
    required this.agent,
    required this.to,
    required this.question,
    required this.state,
    required this.createdMs,
    this.answer,
    this.answeredMs,
    this.team,
    this.readFrom = const [],
  });

  factory EscalationInfo.fromJson(Json j) => EscalationInfo(
        id: _str(j, 'id'),
        agent: _str(j, 'agent'),
        to: _optStr(j, 'to') ?? 'owner',
        question: _str(j, 'question'),
        state: _str(j, 'state'),
        createdMs: _int(j, 'created_ms'),
        answer: _optStr(j, 'answer'),
        answeredMs: _optInt(j, 'answered_ms'),
        team: _optStr(j, 'team'),
        readFrom: [
          for (final r in j['read_from'] is List ? _list(j, 'read_from') : const <Json>[])
            EscalationRead(_str(r, 'contact'), _optInt(r, 'level') ?? 0),
        ],
      );

  final String id;
  final String agent;

  /// `owner`, or the supervisor contact's label.
  final String to;

  /// The agent's own words: data for the owner.
  final String question;
  final String state;
  final int createdMs;
  final String? answer;
  final int? answeredMs;

  /// The team the agent works in (D-111): a worker's team, or a team it leads.
  final String? team;
  final List<EscalationRead> readFrom;

  bool get open => state == EscalationState.open;
}

/// The owner's questions from agents (v7, `escalations`).
final class EscalationsReply extends Reply {
  const EscalationsReply(this.escalations);
  final List<EscalationInfo> escalations;
}

/// One question (v7: `escalation_answer`).
final class EscalationReply extends Reply {
  const EscalationReply(this.escalation);
  final EscalationInfo escalation;
}

/// A question was asked, answered or set aside (v7; owner subscriptions get every change).
final class EscalationEvent extends XEvent {
  const EscalationEvent(this.escalation);
  final EscalationInfo escalation;
}
