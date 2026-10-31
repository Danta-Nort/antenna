// SPDX-License-Identifier: AGPL-3.0-only
// Approval requests (SPEC §9, CONTROL §8, §20): the request as the daemon shows it, the replies to approve / deny and
// their batch forms, the subscription event of a request changing state, and what became of an approved request
// (`approval_resolved`, x-control/6: the daemon finishes an agent's approved action itself and reports the outcome).

part of 'models.dart';

/// Structured view of the rights in an approval request (SPEC §9).
final class Grants {
  const Grants({required this.read, required this.write, required this.commands, required this.send});

  factory Grants.fromJson(Json j) => Grants(
        read: _optStr(j, 'read') ?? '',
        write: _optStr(j, 'write') ?? '',
        commands: _optStr(j, 'commands') ?? '',
        send: _optStr(j, 'send') ?? '',
      );

  final String read;
  final String write;
  final String commands;
  final String send;
}

/// An approval request: rights as structure, text only as a quote (SPEC §9, protection against UI injection).
final class ApprovalInfo {
  const ApprovalInfo({
    required this.id,
    required this.state,
    this.quiet = false,
    required this.requester,
    required this.contact,
    required this.contactTrust,
    required this.action,
    this.target,
    this.reasons = const [],
    required this.grants,
    required this.quote,
    required this.fingerprint,
    required this.createdMs,
    required this.expiresMs,
    this.linkId,
    this.targetLinkId,
    this.completes = false,
    this.decidedBy,
    this.delegateRefused,
    this.answerableBy = const [],
  });

  factory ApprovalInfo.fromJson(Json j) => ApprovalInfo(
        id: _str(j, 'id'),
        state: _str(j, 'state'),
        quiet: _bool(j, 'quiet'),
        requester: _str(j, 'requester'),
        contact: _str(j, 'contact'),
        contactTrust: _int(j, 'contact_trust'),
        action: _str(j, 'action'),
        target: _optStr(j, 'target'),
        reasons: _strList(j, 'reasons'),
        grants: Grants.fromJson(_obj(j, 'grants')),
        quote: _optStr(j, 'quote') ?? '',
        fingerprint: _str(j, 'fingerprint'),
        createdMs: _int(j, 'created_ms'),
        expiresMs: _int(j, 'expires_ms'),
        linkId: _optStr(j, 'link_id'),
        targetLinkId: _optStr(j, 'target_link_id'),
        completes: _bool(j, 'completes'),
        decidedBy: DecidedBy.parse(j['decided_by']),
        delegateRefused: DelegateNote.parse(j['delegate_refused']),
        answerableBy: _strList(j, 'answerable_by'),
      );

  final String id;

  /// `pending` / `approved` / `denied` / `used` / `expired`. A pending request that runs out of time closes by
  /// itself: the daemon sends the `approval` event with `expired` (D-84).
  final String state;
  final bool quiet;

  /// Agent name or `owner`.
  final String requester;
  final String contact;
  final int contactTrust;

  /// `send_message`, `check:exec`, `share_file`…
  final String action;
  final String? target;
  final List<String> reasons;
  final Grants grants;

  /// Request text: display ONLY as a quote.
  final String quote;
  final String fingerprint;
  final int createdMs;
  final int expiresMs;

  /// The link of [contact] and of [target] (D-84): where the window shows the request. `null` from older daemons:
  /// the labels are matched instead.
  final String? linkId;
  final String? targetLinkId;

  /// x-control/6: after the owner approves, the daemon itself carries out exactly the approved action (an agent's
  /// send, file share or accept, file request, a stream's final message) and reports it with `approval_resolved`;
  /// nobody has to tell the agent to repeat it. `false` from older daemons, and for a check the agent acts on itself.
  final bool completes;

  /// v7 (CONTROL §31): an approver agent decided this request in the owner's place: who, from which own computer,
  /// and its reason (the agent's words, shown quoted). `null`: the owner decided, or an older daemon.
  final DecidedBy? decidedBy;

  /// v7: the latest answer of an agent that did not count; the request waits for the owner, who is told why.
  final DelegateNote? delegateRefused;

  /// v7: the approvers that may answer this pending request now: `volna`, or `volna@<own computer>`.
  final List<String> answerableBy;

  bool get pending => state == 'pending';

  /// Asked by an agent, not by the owner's own command.
  bool get byAgent => requester != 'owner';
}

final class ApprovalsReply extends Reply {
  const ApprovalsReply(this.approvals, {this.hiddenQuiet = 0});
  final List<ApprovalInfo> approvals;

  /// How many "silent" requests (beyond 3 per 10 minutes) were not shown.
  final int hiddenQuiet;
}

final class ApprovalReply extends Reply {
  const ApprovalReply(this.approval);
  final ApprovalInfo approval;
}

/// One item of `approve_many` / `deny_many` (v6): the request as decided, or this item's own error.
final class ApprovalResult {
  const ApprovalResult({required this.id, this.approval, this.error});

  factory ApprovalResult.fromJson(Json j) {
    final e = j['error'];
    return ApprovalResult(
      id: _str(j, 'id'),
      approval: j['approval'] is Map<String, Object?> ? ApprovalInfo.fromJson(_obj(j, 'approval')) : null,
      error: e is Map<String, Object?>
          ? XControlException((e['code'] as String?) ?? XErrorCode.internal, (e['message'] as String?) ?? '')
          : null,
    );
  }

  final String id;
  final ApprovalInfo? approval;
  final XControlException? error;

  bool get ok => error == null && approval != null;
}

/// `approvals_decided` (v6): one result per item, in the order given.
final class ApprovalsDecidedReply extends Reply {
  const ApprovalsDecidedReply(this.results);
  final List<ApprovalResult> results;
}

/// An approval request was created, resolved or used up.
final class ApprovalEvent extends XEvent {
  const ApprovalEvent(this.approval);
  final ApprovalInfo approval;
}

/// x-control/6: what became of an approved (or closed) request, sent to the owner's subscriptions and to the requesting
/// agent's. `completed`: approved, and the daemon carried out the exact approved action ([result] is that action's
/// reply); `failed`: approved, but carrying it out failed ([error]); `approved`: approved, the action is the agent's
/// own (nothing for the daemon to finish); `denied`; `expired`. Older daemons never send it.
final class ApprovalResolvedEvent extends XEvent {
  const ApprovalResolvedEvent({
    required this.id,
    required this.state,
    this.action = '',
    this.requester = '',
    this.contact = '',
    this.linkId,
    this.target,
    this.targetLinkId,
    this.result,
    this.error,
    this.message = '',
    this.atMs,
    this.decidedBy,
  });

  factory ApprovalResolvedEvent.fromJson(Json j) {
    final e = j['error'];
    final r = j['result'];
    return ApprovalResolvedEvent(
      id: _str(j, 'id'),
      state: _str(j, 'state'),
      action: _optStr(j, 'action') ?? '',
      requester: _optStr(j, 'requester') ?? '',
      contact: _optStr(j, 'contact') ?? '',
      linkId: _optStr(j, 'link_id'),
      target: _optStr(j, 'target'),
      targetLinkId: _optStr(j, 'target_link_id'),
      result: r is Map<String, Object?> ? r : null,
      error: e is Map<String, Object?>
          ? XControlException((e['code'] as String?) ?? XErrorCode.internal, (e['message'] as String?) ?? '')
          : null,
      message: _optStr(j, 'message') ?? '',
      atMs: _optInt(j, 'at_ms'),
      decidedBy: DecidedBy.parse(j['decided_by']),
    );
  }

  final String id;

  /// `completed` / `failed` / `approved` / `denied` / `expired` (an unknown state is kept as is).
  final String state;

  /// `send_message`, `share_file`…
  final String action;

  /// Agent name or `owner`.
  final String requester;
  final String contact;
  final String? linkId;
  final String? target;
  final String? targetLinkId;

  /// With `completed`: the reply of the action the daemon carried out (`{"type":"sent",…}`, `{"type":"file",…}`,
  /// `{"type":"file_requested",…}`), as JSON.
  final Json? result;

  /// With `failed`: why carrying out the approved action failed.
  final XControlException? error;

  /// The daemon's summary for people (English).
  final String message;
  final int? atMs;

  /// v7 (CONTROL §31): an approver agent decided it in the owner's place.
  final DecidedBy? decidedBy;

  bool get completed => state == 'completed';
  bool get failed => state == 'failed';

  /// `type` of [result] (`sent`, `file`, `file_requested`…), or `null`.
  String? get resultType => switch (result?['type']) { final String t => t, _ => null };

  /// [result] as a typed reply when the window knows its type; `null` otherwise (it stays available as [result]).
  Reply? get resultReply {
    final r = result;
    if (r == null || r['type'] is! String) return null;
    try {
      final reply = Reply.fromJson(r);
      return reply is UnknownReply ? null : reply;
    } on XProtocolException {
      return null;
    }
  }
}
