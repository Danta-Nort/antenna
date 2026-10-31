// SPDX-License-Identifier: AGPL-3.0-only
// The agents' questions (x-control/7, CONTROL §29, D-118): a part of requests.dart. Owner commands only: an agent
// connection has none of them. A v7 daemon from before them answers `unknown_command`, and the window shows no
// questions then.

part of 'requests.dart';

/// The agents' open questions, or all of them with [all].
final class EscalationsRequest extends XRequest {
  const EscalationsRequest({this.all = false});
  final bool all;
  @override
  String get cmd => 'escalations';
  @override
  Json get fields => {if (all) 'all': true};
}

/// Answer a question ([answer]) or set it aside ([dismiss]); an owner session is enough.
final class EscalationAnswerRequest extends XRequest {
  const EscalationAnswerRequest({required this.id, this.answer, this.dismiss = false});
  final String id;
  final String? answer;
  final bool dismiss;
  @override
  String get cmd => 'escalation_answer';
  @override
  Json get fields => {'id': id, 'answer': ?answer, if (dismiss) 'dismiss': true};
}

/// Where an agent's questions go: [to] a contact, or `null` for the owner. Owner password.
final class AgentEscalateRequest extends XRequest {
  const AgentEscalateRequest({required this.name, required this.password, this.to});
  final String name;
  final String? to;
  final String password;
  @override
  String get cmd => 'agent_escalate';
  @override
  Json get fields => {'name': name, 'to': to, 'password': password};
}
