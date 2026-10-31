// SPDX-License-Identifier: AGPL-3.0-only
// After the owner approves (x-control/6, CONTROL §8): a request the daemon finishes by itself (`completes`: an
// agent's send, file share or accept, file request, a stream's final message) does not leave the window at once. Its
// card says "Approved — Antenna is finishing it…" until the daemon reports the outcome (`approval_resolved`), the
// request is used up or closed (the `approval` event), or at the latest [ApprovalFinishMixin.finishFallback] after the
// approval (a daemon that sends no `approval_resolved`). A failure stays, with the daemon's reason, until the owner
// dismisses it. The daemon tells the agent; the window never asks the owner to tell the agent anything.
// Events and replies come in any order (the subscription may report the outcome before the `approve` reply): an
// outcome, once known, is never replaced by "finishing".

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';

/// The request concerns the conversation with [linkId]: the contact it is about or the recipient of what it would
/// send (D-84). An older daemon gives no link IDs, so the labels are matched ([label] is the link's label).
bool approvalConcerns(ApprovalInfo a, String linkId, String? label) =>
    a.linkId == linkId ||
    a.targetLinkId == linkId ||
    (a.linkId == null && label != null && (a.contact == label || a.target == label));

enum FinishState { finishing, failed }

/// An approved request the daemon is finishing, or failed to finish.
class ApprovalFinish {
  ApprovalFinish(this.approval, {this.state = FinishState.finishing, this.error, this.detailed = true});

  /// The request as the owner approved it (or, rebuilt from `approval_resolved`, its who, what and for whom).
  final ApprovalInfo approval;
  FinishState state;

  /// With [FinishState.failed]: the daemon's reason.
  XControlException? error;

  /// [approval] is the request the window showed (rights and quote included), not one rebuilt from the event.
  final bool detailed;

  bool get failed => state == FinishState.failed;
}

mixin ApprovalFinishMixin on ChangeNotifier {
  /// Notify the window (no error after dispose: daemon replies can arrive after the model is closed).
  void safeNotify();
  ContactInfo? contactById(String linkId);

  /// How long a "finishing" card waits for the outcome before it leaves by itself (an older daemon reports none).
  Duration get finishFallback => const Duration(seconds: 15);

  /// Approved requests the daemon is finishing, or failed to finish, by ID.
  final Map<String, ApprovalFinish> finishing = {};
  final Map<String, Timer> _finishTimers = {};

  /// Requests whose outcome is known (used, closed, resolved): a late reply or event does not bring them back.
  final Set<String> _settled = {};

  /// What the owner approved, kept briefly after the card left (`used` comes before `approval_resolved{failed}`).
  final Map<String, ApprovalInfo> _approvedRecently = {};

  static const _remember = 256;

  /// [a] was approved (the `approve` reply, a batch item, or the subscription's `approval` event). [shown] is the
  /// request as the window had it: an older reply may lack `completes`.
  void onApproved(ApprovalInfo a, {ApprovalInfo? shown}) {
    if (!(a.completes || (shown?.completes ?? false))) return;
    if (_settled.contains(a.id) || finishing.containsKey(a.id)) return;
    final info = shown ?? a;
    _keep(_approvedRecently, a.id, info);
    finishing[a.id] = ApprovalFinish(info);
    _finishTimers[a.id]?.cancel();
    _finishTimers[a.id] = Timer(finishFallback, () {
      _finishTimers.remove(a.id);
      if (finishing[a.id]?.failed ?? true) return;
      finishing.remove(a.id);
      _settle(a.id);
      safeNotify();
    });
  }

  /// The `approval` event says the request is used up, denied or expired: a "finishing" card leaves.
  void onApprovalClosed(ApprovalInfo a) {
    _settle(a.id);
    if (finishing[a.id]?.failed ?? true) return;
    finishing.remove(a.id);
    _finishTimers.remove(a.id)?.cancel();
  }

  /// The daemon reports what became of an approved request: done (the card leaves) or failed (it stays, with why).
  void onApprovalResolved(ApprovalResolvedEvent e) {
    _settle(e.id);
    _finishTimers.remove(e.id)?.cancel();
    if (!e.failed) {
      finishing.remove(e.id);
      return;
    }
    final known = finishing[e.id]?.approval ?? _approvedRecently[e.id];
    final error = e.error ?? XControlException(XErrorCode.internal, e.message);
    finishing[e.id] = known != null
        ? ApprovalFinish(known, state: FinishState.failed, error: error)
        : ApprovalFinish(_fromEvent(e), state: FinishState.failed, error: error, detailed: false);
  }

  /// The owner read the failure.
  void dismissFinished(String id) {
    if (finishing.remove(id) != null) safeNotify();
  }

  /// Cards to show in the conversation with [linkId]: agents' requests only, as for pending ones (the owner's own
  /// sends have their place in the bubble).
  List<ApprovalFinish> finishingFor(String linkId) {
    final label = contactById(linkId)?.label;
    return finishing.values.where((f) => f.approval.byAgent && approvalConcerns(f.approval, linkId, label)).toList()
      ..sort((a, b) => a.approval.createdMs.compareTo(b.approval.createdMs));
  }

  void clearFinishing() {
    for (final t in _finishTimers.values) {
      t.cancel();
    }
    _finishTimers.clear();
    finishing.clear();
    _settled.clear();
    _approvedRecently.clear();
  }

  void _settle(String id) {
    _settled.add(id);
    if (_settled.length > _remember) _settled.remove(_settled.first);
  }

  static void _keep(Map<String, ApprovalInfo> m, String id, ApprovalInfo a) {
    m[id] = a;
    if (m.length > _remember) m.remove(m.keys.first);
  }

  /// A failure for a request the window never showed (approved elsewhere, before the window started): who, what and
  /// for whom, from the event; no rights, no quote.
  static ApprovalInfo _fromEvent(ApprovalResolvedEvent e) => ApprovalInfo(
        id: e.id,
        state: 'approved',
        requester: e.requester,
        contact: e.contact,
        contactTrust: 0,
        action: e.action,
        target: e.target,
        grants: const Grants(read: '', write: '', commands: '', send: ''),
        quote: '',
        fingerprint: '',
        createdMs: e.atMs ?? 0,
        expiresMs: e.atMs ?? 0,
        linkId: e.linkId,
        targetLinkId: e.targetLinkId,
        completes: true,
        decidedBy: e.decidedBy,
      );
}
