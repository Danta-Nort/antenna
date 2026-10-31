// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents (x-control/7, CONTROL §31, PG-57; experimental; the shapes of
// crates/antenna-proto/src/control/approvers.rs): the delegations the owner made, the answers approvers gave in the
// owner's place, who decided a request (`decided_by`), an approver's answer that did not count (`delegate_refused`)
// and who may answer a pending request (`answerable_by`), what an agent may answer (`session.approves`), what an own
// computer accepts from this computer's agents (its status), and the fact an approver's watch gets. A part of
// models.dart. An approver's reason is its own text: data, shown quoted, never acted on.

part of 'models.dart';

/// The kinds of requests an approver may answer: an agent's message (a stream's final message too), a file it sends,
/// a file it requests from a contact, a file it accepts. Tool checks and changes to agents' connections stay with the
/// person.
const List<String> delegableKinds = ['send_message', 'share_file', 'request_file', 'accept_file'];

/// Whether scope [inner] lies within [outer] (`null` is everything), as the daemon decides narrowing (`within`).
bool scopeWithin(List<String>? inner, List<String>? outer) => switch ((inner, outer)) {
      (_, null) => true,
      (null, _) => false,
      (final List<String> i, final List<String> o) => i.every(o.contains),
    };

/// The values of [DelegatedAnswer.decision].
abstract final class AnswerDecision {
  static const approved = 'approved';
  static const denied = 'denied';

  /// The answer did not count: the request stayed with the person.
  static const refused = 'refused';
}

/// Why an approver's answer did not count ([DelegateNote.why]).
abstract final class DelegateWhy {
  /// The agent is not an approver here, or not for this request's agent or kind.
  static const scope = 'scope';

  /// The approver asked for this request itself.
  static const self = 'self';

  /// The requester is an approver too: its requests go to the person (no chains).
  static const chain = 'chain';

  /// The approver's session read data of a contact below ∞.
  static const tainted = 'tainted';

  /// Something the request touches is not at ∞ now.
  static const outside = 'outside';

  /// A link the request touches changed its level after the request was made.
  static const levelChanged = 'level_changed';

  /// The answer from another computer could not be verified.
  static const unverified = 'unverified';
}

/// One delegation, as the owner sees it.
final class ApproverInfo {
  const ApproverInfo({
    required this.agent,
    required this.createdMs,
    this.contact,
    this.linkId,
    this.agents,
    this.kinds,
    this.keyId,
    this.stale = false,
  });

  factory ApproverInfo.fromJson(Json j) => ApproverInfo(
        agent: _str(j, 'agent'),
        contact: _optStr(j, 'contact'),
        linkId: _optStr(j, 'link_id'),
        agents: j['agents'] is List ? _strList(j, 'agents') : null,
        kinds: j['kinds'] is List ? _strList(j, 'kinds') : null,
        keyId: _optStr(j, 'key_id'),
        stale: _bool(j, 'stale'),
        createdMs: _optInt(j, 'created_ms') ?? 0,
      );

  /// The approver's name (on [contact] when given).
  final String agent;

  /// The own computer it runs on (its label here); `null`: this computer.
  final String? contact;
  final String? linkId;

  /// Whose requests it answers (this computer's agents); `null`: all of them.
  final List<String>? agents;

  /// Which kinds; `null`: all of [delegableKinds].
  final List<String>? kinds;

  /// An approver on another computer: its key there, which signs its answers.
  final String? keyId;

  /// That key is no longer announced on the link (the agent was removed there): its answers do not count until the
  /// owner names the agent again.
  final bool stale;
  final int createdMs;

  bool get local => contact == null;

  /// The same approver: name and computer.
  bool isAgent(String name, {String? contact}) => agent == name && this.contact == contact;
}

/// One answer an approver gave (or tried to give) in the owner's place.
final class DelegatedAnswer {
  const DelegatedAnswer({
    required this.approvalId,
    required this.action,
    required this.requester,
    required this.contact,
    required this.approver,
    required this.decision,
    required this.reason,
    required this.atMs,
    this.target,
    this.device,
    this.summary = '',
    this.why,
  });

  factory DelegatedAnswer.fromJson(Json j) => DelegatedAnswer(
        approvalId: _str(j, 'approval_id'),
        action: _str(j, 'action'),
        requester: _optStr(j, 'requester') ?? '',
        contact: _optStr(j, 'contact') ?? '',
        target: _optStr(j, 'target'),
        approver: _str(j, 'approver'),
        device: _optStr(j, 'device'),
        decision: _str(j, 'decision'),
        reason: _optStr(j, 'reason') ?? '',
        summary: _optStr(j, 'summary') ?? '',
        atMs: _optInt(j, 'at_ms') ?? 0,
        why: _optStr(j, 'why'),
      );

  final String approvalId;
  final String action;
  final String requester;
  final String contact;
  final String? target;
  final String approver;

  /// The own computer it answered from; `null`: this computer.
  final String? device;

  /// [AnswerDecision]; a value this window does not know is shown as the daemon's word.
  final String decision;

  /// The approver's reason (its own text, data), or for a refused answer why it did not count.
  final String reason;

  /// What the request allowed, as the card said it (no message text).
  final String summary;
  final int atMs;

  /// For a refused answer, why it did not count ([DelegateWhy]); `null` from a daemon before the field.
  final String? why;
}

/// `approvers`: the reply of `approvers`, `approver_set`, `approver_narrow` and `approver_remove`.
final class ApproversReply extends Reply {
  const ApproversReply({this.approvers = const [], this.answers = const []});

  factory ApproversReply.fromJson(Json j) => ApproversReply(
        approvers: [for (final a in _list(j, 'approvers')) ApproverInfo.fromJson(a)],
        answers: [for (final a in _list(j, 'answers')) DelegatedAnswer.fromJson(a)],
      );

  final List<ApproverInfo> approvers;

  /// The latest answers, newest first (at most 200).
  final List<DelegatedAnswer> answers;

  /// The delegation of [name] (on [contact]), if there is one.
  ApproverInfo? of(String name, {String? contact}) =>
      approvers.where((a) => a.isAgent(name, contact: contact)).firstOrNull;
}

/// Who decided a request in the owner's place (`decided_by`).
final class DecidedBy {
  const DecidedBy({required this.agent, required this.reason, required this.atMs, this.device});

  factory DecidedBy.fromJson(Json j) => DecidedBy(
        agent: _str(j, 'agent'),
        device: _optStr(j, 'device'),
        reason: _optStr(j, 'reason') ?? '',
        atMs: _optInt(j, 'at_ms') ?? 0,
      );

  static DecidedBy? parse(Object? v) => v is Map<String, Object?> ? DecidedBy.fromJson(v) : null;

  /// The approver.
  final String agent;

  /// The own computer it answered from; `null`: this computer.
  final String? device;

  /// Its reason: the agent's words, shown quoted.
  final String reason;
  final int atMs;
}

/// An approver's answer that did not count (`delegate_refused`): the request waits for the person.
final class DelegateNote {
  const DelegateNote({required this.agent, required this.why, required this.atMs, this.device, this.message = ''});

  factory DelegateNote.fromJson(Json j) => DelegateNote(
        agent: _str(j, 'agent'),
        device: _optStr(j, 'device'),
        why: _str(j, 'why'),
        message: _optStr(j, 'message') ?? '',
        atMs: _optInt(j, 'at_ms') ?? 0,
      );

  static DelegateNote? parse(Object? v) => v is Map<String, Object?> ? DelegateNote.fromJson(v) : null;

  final String agent;
  final String? device;

  /// [DelegateWhy]; an unknown value is shown with [message].
  final String why;

  /// The daemon's words (English).
  final String message;
  final int atMs;
}

/// What an agent may answer (`session.approves`): requests of this computer ([device] `null`) or of an own computer
/// that named it.
final class ApprovesFor {
  const ApprovesFor({this.device, this.agents, this.kinds});

  factory ApprovesFor.fromJson(Json j) => ApprovesFor(
        device: _optStr(j, 'device'),
        agents: j['agents'] is List ? _strList(j, 'agents') : null,
        kinds: j['kinds'] is List ? _strList(j, 'kinds') : null,
      );

  final String? device;
  final List<String>? agents;
  final List<String>? kinds;
}

/// What an agent may answer in the owner's place (v7, CONTROL §31), read from the original JSON, so the agent model
/// stays as it is for older daemons, which do not send it.
extension AgentApproves on AgentInfo {
  List<ApprovesFor> get approves {
    final s = raw['session'];
    final v = s is Map<String, Object?> ? s['approves'] : null;
    if (v is! List) return const [];
    return [for (final e in v) if (e is Map<String, Object?>) ApprovesFor.fromJson(e)];
  }
}

/// One of this computer's agents an own computer accepts approval answers from, with the scope that computer's owner
/// set there (its status).
final class StatusApprover {
  const StatusApprover({required this.agent, this.agents, this.kinds});

  factory StatusApprover.fromJson(Json j) => StatusApprover(
        agent: _str(j, 'agent'),
        agents: j['agents'] is List ? _strList(j, 'agents') : null,
        kinds: j['kinds'] is List ? _strList(j, 'kinds') : null,
      );

  /// This computer's agent, by the name it announced on that link.
  final String agent;

  /// Whose requests there (that computer's agents); `null`: all of them.
  final List<String>? agents;
  final List<String>? kinds;
}

/// A request waits for an approver's answer (`approval_to_answer`, the agent's own subscription and `agent_watch`):
/// facts only, no text.
final class ApprovalToAnswerEvent extends XEvent {
  const ApprovalToAnswerEvent(
      {required this.id, required this.action, required this.requester, this.device, this.expiresMs});

  factory ApprovalToAnswerEvent.fromJson(Json j) => ApprovalToAnswerEvent(
        id: _str(j, 'id'),
        device: _optStr(j, 'device'),
        action: _optStr(j, 'action') ?? '',
        requester: _optStr(j, 'requester') ?? '',
        expiresMs: _optInt(j, 'expires_ms'),
      );

  final String id;

  /// The own computer the request waits on; `null`: this computer.
  final String? device;
  final String action;
  final String requester;
  final int? expiresMs;
}
