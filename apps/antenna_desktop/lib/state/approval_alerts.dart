// SPDX-License-Identifier: AGPL-3.0-only
// Approval requests must not run out unnoticed (D-84, D-114). Besides a new request on this computer (the model's
// `newApprovals`), the window tells the owner about a new request waiting on one of their other computers (My
// devices: a device's status carries its pending requests, sent within about 2 s), and, once per request, about two
// minutes before it runs out, that it expires soon. The screen shows these only while the window is not looked at.
//
// An alert carries facts only (who asks, the action and its target, the computer, the time left), never the request
// text: a notification may show on a locked screen (SPEC §11). It has no field that could carry the text.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';

enum ApprovalAlertKind {
  /// A request not seen before.
  arrived,

  /// About [ApprovalAlertsMixin.remindBefore] is left, and it is still pending.
  expiresSoon,
}

/// What a notification about one request may say.
final class ApprovalAlert {
  const ApprovalAlert({
    required this.kind,
    required this.id,
    required this.requester,
    required this.action,
    this.target,
    this.device,
    this.left,
  });

  /// A request on this computer.
  factory ApprovalAlert.here(ApprovalInfo a, DateTime now, {ApprovalAlertKind kind = ApprovalAlertKind.arrived}) =>
      ApprovalAlert(
        kind: kind,
        id: a.id,
        requester: a.requester,
        action: a.action,
        target: a.target,
        left: a.expiresMs > 0 ? DateTime.fromMillisecondsSinceEpoch(a.expiresMs).difference(now) : null,
      );

  final ApprovalAlertKind kind;
  final String id;

  /// The agent that asks.
  final String requester;

  /// `send_message`, `share_file`… and what it is about (the contact's label, the recipient).
  final String action;
  final String? target;

  /// The own computer it waits on (its label here); `null`: this computer.
  final String? device;

  /// Time left until it expires; `null`: not known.
  final Duration? left;
}

/// One pending request as the alerts see it.
typedef _Pending = ({
  String key,
  String? device,
  String id,
  String requester,
  String action,
  String? target,
  DateTime? deadline,
});

mixin ApprovalAlertsMixin on ChangeNotifier {
  Map<String, ApprovalInfo> get approvals;
  DevicesReply? get devices;
  DateTime now();

  /// Background work runs (off in golden and widget tests: they call [scanApprovalAlerts] themselves).
  bool get live;

  /// The reminder comes when this much is left.
  static const remindBefore = Duration(minutes: 2);

  /// New requests on other own computers and reminders (here and there); the screen decides whether to show them.
  Stream<ApprovalAlert> get approvalAlerts => _alerts.stream;
  final _alerts = StreamController<ApprovalAlert>.broadcast();

  /// Every request seen (`here/<id>` or `<link>/<id>`) with its deadline, so one that leaves and comes back (a
  /// computer offline, then online again) is not news again.
  final _seen = <String, DateTime?>{};
  final _reminded = <String>{};

  /// The first `devices` reply was read: what it lists was there before this window looked, not news.
  bool _devicesRead = false;
  Timer? _reminderTimer;

  /// A request of another computer runs out at its own clock's `expires_ms`; how long that is from its status's
  /// `at_ms`, counted from when this computer received the status, is the time left here (no clocks compared).
  static DateTime? _deviceDeadline(DeviceInfo d, DeviceView s, DeviceApproval a, DateTime now) {
    if (a.expiresMs <= 0) return null;
    final from = s.atMs > 0 ? s.atMs : a.createdMs;
    final received = d.receivedMs == null ? now : DateTime.fromMillisecondsSinceEpoch(d.receivedMs!);
    return received.add(Duration(milliseconds: a.expiresMs - from));
  }

  List<_Pending> _pending(DateTime t) => [
        for (final a in approvals.values)
          if (a.pending && a.byAgent && !a.quiet)
            (
              key: 'here/${a.id}',
              device: null,
              id: a.id,
              requester: a.requester,
              action: a.action,
              target: a.target,
              deadline: a.expiresMs > 0 ? DateTime.fromMillisecondsSinceEpoch(a.expiresMs) : null,
            ),
        for (final d in devices?.devices ?? const <DeviceInfo>[])
          if (d.status case final s?)
            for (final a in s.approvals)
              if (a.byAgent)
                (
                  key: '${d.linkId}/${a.id}',
                  device: d.contact,
                  id: a.id,
                  requester: a.requester,
                  action: a.action,
                  target: a.target,
                  deadline: _deviceDeadline(d, s, a, t),
                ),
      ];

  ApprovalAlert _alert(ApprovalAlertKind kind, _Pending p, DateTime t) => ApprovalAlert(
        kind: kind,
        id: p.id,
        requester: p.requester,
        action: p.action,
        target: p.target,
        device: p.device,
        left: p.deadline?.difference(t),
      );

  /// Looks at the pending requests now: announces the new ones of other computers, reminds of the ones about to run
  /// out, and sets the timer for the next reminder. Called after each change of [approvals] and each `devices` read.
  void scanApprovalAlerts() {
    if (_alerts.isClosed) return;
    final t = now();
    final firstDevices = !_devicesRead && devices != null;
    if (devices != null) _devicesRead = true;
    final pending = _pending(t);
    for (final p in pending) {
      final left = p.deadline?.difference(t);
      if (!_seen.containsKey(p.key)) {
        _seen[p.key] = p.deadline;
        // Already short of time when first seen: the news says the time left, a reminder right after it would repeat
        // it.
        if (left == null || left <= remindBefore) _reminded.add(p.key);
        if (p.device != null && !firstDevices) _alerts.add(_alert(ApprovalAlertKind.arrived, p, t));
        continue;
      }
      _seen[p.key] = p.deadline;
      if (left != null && left > Duration.zero && left <= remindBefore && _reminded.add(p.key)) {
        _alerts.add(_alert(ApprovalAlertKind.expiresSoon, p, t));
      }
    }
    // Requests that ran out an hour ago are forgotten (their ids are not reused).
    _seen.removeWhere((k, d) {
      final gone = d != null && t.difference(d) > const Duration(hours: 1);
      if (gone) _reminded.remove(k);
      return gone;
    });
    _scheduleReminder(pending, t);
  }

  void _scheduleReminder(List<_Pending> pending, DateTime t) {
    _reminderTimer?.cancel();
    _reminderTimer = null;
    if (!live) return;
    Duration? next;
    for (final p in pending) {
      final d = p.deadline;
      if (d == null || _reminded.contains(p.key)) continue;
      final due = d.subtract(remindBefore).difference(t);
      if (next == null || due < next) next = due;
    }
    if (next == null) return;
    // At least a second; at most five minutes, so a clock that jumped (sleep) is caught up soon.
    final wait = next < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : (next > const Duration(minutes: 5) ? const Duration(minutes: 5) : next);
    _reminderTimer = Timer(wait, scanApprovalAlerts);
  }

  void disposeApprovalAlerts() {
    _reminderTimer?.cancel();
    _reminderTimer = null;
    unawaited(_alerts.close());
  }
}
