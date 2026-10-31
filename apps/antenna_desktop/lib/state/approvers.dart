// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents in the window (x-control/7, CONTROL §31, PG-57; experimental): the owner names an agent of this
// computer, or an agent of an own computer (a contact at ∞), to answer other agents' approval requests in the owner's
// place, within a scope (whose requests, which kinds). The daemon decides whether an answer counts: only while
// everything the request touches stays on the owner's own computers, never for the approver's own requests, never in
// a chain; every answer is logged with the approver's name and its reason.
//
// The window owns none of it: the delegations and the latest answers come from `approvers`; who decided a request,
// whose answer did not count and who may answer come with the request itself (`decided_by`, `delegate_refused`,
// `answerable_by`). The only thing it keeps is the requests an approver decided while the window was open, so the
// owner sees each one in the conversation and in Approval requests until they dismiss it.
//
// Naming or widening an approver takes the owner password, or one touch (Touch ID) whose proof covers the exact
// request: it widens who decides. Narrowing and removing take neither (D-84). The screen shows the warning before it
// asks for either. An older daemon refuses the commands as unknown: the window then offers no approvers.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';

/// What a daemon built before approvers answers: its strict parser refuses the command.
bool approversUnknown(XControlException e) =>
    e.code == XErrorCode.unknownCommand || (e.code == XErrorCode.badRequest && e.message.contains('unknown variant'));

/// What the owner's choice in the approver dialog sends.
sealed class ApproverChange {
  const ApproverChange();
}

/// Nothing changes.
final class ApproverUnchanged extends ApproverChange {
  const ApproverUnchanged();
}

/// Name it, widen it, or name a stale one again: the warning, then the password or a proof.
final class ApproverWiden extends ApproverChange {
  const ApproverWiden(this.request);

  /// The request with an empty password: the screen fills it in (or sends it with a proof).
  final ApproverSetRequest request;
}

/// A scope within the one it has: no password.
final class ApproverNarrow extends ApproverChange {
  const ApproverNarrow(this.request);
  final ApproverNarrowRequest request;
}

/// Off: no password.
final class ApproverOff extends ApproverChange {
  const ApproverOff(this.request);
  final ApproverRemoveRequest request;
}

/// [kinds] as the daemon wants it: every delegable kind is `null` (all, also those added later), otherwise the chosen
/// ones in the protocol's order.
List<String>? normalKinds(Iterable<String> kinds) {
  final set = kinds.toSet();
  if (delegableKinds.every(set.contains)) return null;
  return [for (final k in delegableKinds) if (set.contains(k)) k];
}

bool _sameScope(List<String>? a, List<String>? b) =>
    (a == null && b == null) || (a != null && b != null && setEquals(a.toSet(), b.toSet()));

/// What turning approver [name] (on [contact]) [on] with scope [agents] / [kinds] (`null`: all) sends, given its
/// [current] delegation: a new one, a wider one, or a stale one named again asks for the password; a narrower one and
/// Off do not (making things safer never needs it, D-84).
ApproverChange approverChange({
  required String name,
  String? contact,
  required ApproverInfo? current,
  required bool on,
  List<String>? agents,
  List<String>? kinds,
}) {
  if (!on) {
    return current == null ? const ApproverUnchanged() : ApproverOff(ApproverRemoveRequest(name: name, contact: contact));
  }
  final widen =
      ApproverWiden(ApproverSetRequest(name: name, contact: contact, agents: agents, kinds: kinds, password: ''));
  if (current == null || current.stale) return widen;
  if (_sameScope(agents, current.agents) && _sameScope(kinds, current.kinds)) return const ApproverUnchanged();
  if (scopeWithin(agents, current.agents) && scopeWithin(kinds, current.kinds)) {
    return ApproverNarrow(ApproverNarrowRequest(name: name, contact: contact, agents: agents, kinds: kinds));
  }
  return widen;
}

/// `volna@Mac mini` (`answerable_by`) → (`volna`, `Mac mini`); `volna` → (`volna`, `null`). An agent's name has no
/// `@`; a computer's label may.
(String, String?) splitApproverLabel(String label) {
  final i = label.indexOf('@');
  return i <= 0 ? (label, null) : (label.substring(0, i), label.substring(i + 1));
}

/// The terminal command for the same change (shown under the password field).
String approverCli(ApproverSetRequest r) => [
      'antenna approver set ${r.name}',
      if (r.contact != null) '--on "${r.contact}"',
      if (r.agents != null) '--agents ${r.agents!.join(',')}',
      if (r.kinds != null) '--kinds ${r.kinds!.join(',')}',
    ].join(' ');

mixin ApproversMixin on ChangeNotifier {
  XDaemon get daemon;
  HelloOk? get hello;
  void safeNotify();
  void daemonFailed(Object e);
  ContactInfo? contactById(String linkId);

  /// One owner command signed with one touch ([TouchIdMixin]); the reply or the error.
  Future<(Reply?, Object?)> callWithTouchId(XRequest request, {required String reason});

  /// The last `approvers`; `null` until it answered (or with an older daemon).
  ApproversReply? approvers;

  /// The daemon refused an approver command as unknown: one built before approvers.
  bool approversAbsent = false;

  /// Requests an approver decided while the window was open, by ID, oldest first; each stays until the owner dismisses
  /// it (at most [_keepDecided]).
  final Map<String, ApprovalInfo> decidedByApprovers = {};
  static const _keepDecided = 50;
  Timer? _approversSoon;

  /// The daemon speaks x-control/7 and has not refused approvers.
  bool get approversSupported => controlVersion(hello?.proto) >= 7 && !approversAbsent;

  /// The daemon answered `approvers`: the window offers naming approvers (nothing drawn that does nothing).
  bool get approversKnown => approversSupported && approvers != null;

  /// The delegation of [name] (on [contact]).
  ApproverInfo? approverOf(String name, {String? contact}) => approvers?.of(name, contact: contact);

  Future<void> refreshApprovers() async {
    if (!approversSupported) return;
    try {
      approvers = expectReply<ApproversReply>(await daemon.call(const ApproversRequest()));
    } on XControlException catch (e) {
      if (approversUnknown(e)) {
        approversAbsent = true;
        approvers = null;
      }
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
    }
    safeNotify();
  }

  Future<Object?> _approverCall(Future<Reply> Function() op) async {
    try {
      approvers = expectReply<ApproversReply>(await op());
      return null;
    } on XControlException catch (e) {
      if (approversUnknown(e)) approversAbsent = true;
      return e;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
      return e;
    } finally {
      safeNotify();
    }
  }

  /// `approver_set` with the owner password in [r]; the error or `null`.
  Future<Object?> setApprover(ApproverSetRequest r) => _approverCall(() => daemon.call(r));

  /// `approver_set` with one touch: the proof covers exactly this request (its password field is empty). A Touch ID
  /// matter comes back as the error, and the screen asks for the password instead.
  Future<Object?> setApproverWithTouchId(ApproverSetRequest r, {required String reason}) async {
    final (reply, err) = await callWithTouchId(r.withPassword(''), reason: reason);
    if (err != null) return err;
    return _approverCall(() async => reply!);
  }

  /// `approver_narrow`: no password.
  Future<Object?> narrowApprover(ApproverNarrowRequest r) => _approverCall(() => daemon.call(r));

  /// `approver_remove`: no password.
  Future<Object?> removeApprover(String name, {String? contact}) =>
      _approverCall(() => daemon.call(ApproverRemoveRequest(name: name, contact: contact)));

  /// The subscription's `approval` event: a request an approver decided stays on screen until the owner dismisses it;
  /// an answer that did not count, or a decision, changes the list of answers (read again when the window has it).
  void onApprovalForApprovers(ApprovalInfo a) {
    // The decision itself (approved, denied); a later `used` of the same request changes nothing the owner reads
    if (a.decidedBy != null &&
        !a.pending &&
        (a.state == 'approved' || a.state == 'denied' || !decidedByApprovers.containsKey(a.id))) {
      decidedByApprovers
        ..remove(a.id)
        ..[a.id] = a;
      while (decidedByApprovers.length > _keepDecided) {
        decidedByApprovers.remove(decidedByApprovers.keys.first);
      }
    }
    if ((a.decidedBy != null || a.delegateRefused != null) && approvers != null) {
      _approversSoon?.cancel();
      _approversSoon = Timer(const Duration(milliseconds: 300), () => unawaited(refreshApprovers()));
    }
  }

  /// Approvers changed from another client (the CLI, another window): the `agent` event with `approver`, or the
  /// `device` event with `approvers` for an own computer's agent. Read them again when the window has them.
  void onApproversChanged() {
    if (approvers == null) return;
    _approversSoon?.cancel();
    _approversSoon = Timer(const Duration(milliseconds: 300), () => unawaited(refreshApprovers()));
  }

  /// The owner read it.
  void dismissDecided(String id) {
    if (decidedByApprovers.remove(id) != null) safeNotify();
  }

  /// Decided by approvers, about the conversation with [linkId] (the contact or the recipient), oldest first.
  List<ApprovalInfo> decidedFor(String linkId) {
    final label = contactById(linkId)?.label;
    return [
      for (final a in decidedByApprovers.values)
        if (a.byAgent &&
            (a.linkId == linkId ||
                a.targetLinkId == linkId ||
                (a.linkId == null && label != null && (a.contact == label || a.target == label))))
          a,
    ];
  }

  void clearApprovers() {
    _approversSoon?.cancel();
    approvers = null;
    approversAbsent = false;
    decidedByApprovers.clear();
  }
}
