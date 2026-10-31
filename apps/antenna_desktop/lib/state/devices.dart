// SPDX-License-Identifier: AGPL-3.0-only
// My devices (x-control/7, CONTROL §27, D-106; experimental): the owner's own computers (contacts at ∞) as the daemon
// learned them over their links: name, OS, version and updates, health, agents, pending approval requests; answering
// those requests from here; which keys answer approvals; a lost computer; "Lend this computer to my teams".
//
// The window owns none of it: everything comes from `devices` and the `device` event. Approving a request of another
// computer is that computer's decision on a proof made here: with Touch ID the Secure Enclave key signs the other
// computer's one-time challenge and the exact request text (the D-102 message, built by the Runner), and this daemon
// passes the proof on; with the password, this daemon checks it and signs with its own device key. The other computer
// accepts only keys its owner confirmed there. A daemon older than these commands gets none of them.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/touch_id.dart';
import '../protocol/x_control.dart';
import 'owner_auth.dart';

/// How a request of another computer can be approved from here: by the keys that computer says it accepts.
enum DeviceApproveWay {
  /// One touch: the window's Touch ID key is accepted there and Touch ID is usable now.
  touchId,

  /// The password typed here: this computer's device key is accepted there.
  password,
}

mixin DevicesMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  HelloOk? get hello;
  void safeNotify();
  TouchIdHost get touchIdHost;
  String get touchIdDir;
  OwnerKeyRecord? get ownerKeyRecord;
  bool get touchIdReady;
  Future<void> refreshContacts();

  /// A link was removed with its history: the window's preview copies of what it sent there go too.
  void forgetSentPreviews(String linkId);

  /// The daemon stopped answering in the middle of a command.
  void daemonFailed(Object e);

  /// A `devices` reply was read: its pending requests may be news (approval_alerts.dart).
  void scanApprovalAlerts();

  /// `devices`; `null` until it answered (or with an older daemon).
  DevicesReply? devices;

  /// The last `devices` failed.
  Object? devicesError;

  /// A v7 daemon refused `devices` as an unknown command: one built before own devices.
  bool devicesAbsent = false;

  Timer? _devicesDebounce;

  /// The daemon speaks x-control/7 and knows own devices.
  bool get devicesSupported => controlVersion(hello?.proto) >= 7 && !devicesAbsent;

  /// The owner's other computers.
  List<DeviceInfo> get ownDevices => devices?.devices ?? const [];

  /// Pending approval requests on all own devices (the navigation's counter).
  int get devicesPending => ownDevices.fold(0, (a, d) => a + d.pending);

  Future<void> refreshDevices() async {
    if (controlVersion(hello?.proto) < 7) return;
    try {
      final r = devices = expectReply<DevicesReply>(await daemon.call(const DevicesRequest()));
      devicesError = null;
      devicesAbsent = false;
      onDevicesRead(r);
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) {
        devicesAbsent = true;
      } else {
        devicesError = e;
      }
    } on XClientException catch (e) {
      devicesError = e;
      if (e is XDaemonUnreachable) daemonFailed(e);
    }
    scanApprovalAlerts();
    safeNotify();
  }

  /// What the window does with a fresh `devices` besides showing it (Code mode: an approver here hears of a request
  /// it may answer on another own computer, code_wake.dart).
  @protected
  void onDevicesRead(DevicesReply r) {}

  /// A `device` event: read `devices` again (events come in bursts when a status arrives with several changes).
  void onDeviceEvent(DeviceEvent e) {
    _devicesDebounce?.cancel();
    _devicesDebounce = Timer(const Duration(milliseconds: 300), () => unawaited(refreshDevices()));
  }

  void clearDevices() {
    _devicesDebounce?.cancel();
    devices = null;
    devicesError = null;
  }

  /// The ways [d] accepts an approval from here, best first.
  List<DeviceApproveWay> approveWays(DeviceInfo d) {
    final self = devices?.self;
    final rec = ownerKeyRecord;
    return [
      if (touchIdReady && rec != null && d.acceptsMine.contains(rec.keyId)) DeviceApproveWay.touchId,
      if (self?.passwordKey case final k? when d.acceptsMine.contains(k.keyId)) DeviceApproveWay.password,
    ];
  }

  Future<Object?> _run(Future<void> Function() op) async {
    try {
      await op();
      return null;
    } on TouchIdException catch (e) {
      return e;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
      return e;
    } finally {
      unawaited(refreshDevices());
    }
  }

  /// Approve [a] of [d] with one touch: the other computer's challenge first (so nothing is signed for a request it
  /// would refuse anyway), then the Secure Enclave key signs that challenge with the exact text, which names the link,
  /// the request and the fingerprint shown here. [reason] is the Touch ID sheet's text.
  Future<Object?> deviceApproveWithTouchId(DeviceInfo d, DeviceApproval a, {required String reason}) => _run(() async {
        final rec = ownerKeyRecord;
        if (rec == null || !touchIdReady) throw const TouchIdException(TouchIdFailure.unavailable);
        final ch = expectReply<DeviceChallengeReply>(await daemon.call(DeviceChallengeRequest(d.contact)));
        final text = remoteApproveText(linkId: ch.linkId, id: a.id, fingerprint: a.fingerprint);
        final sig = await touchIdHost.sign(dir: touchIdDir, nonce: ch.nonce, request: text, reason: reason);
        expectReply<DeviceDecidedReply>(await daemon.call(
            DeviceApproveRequest(contact: d.contact, request: text, nonce: ch.nonce, keyId: rec.keyId, sig: sig)));
      });

  /// Approve [a] of [d] with this computer's password or one touch here (the daemon checks it and signs with its
  /// device key, D-131): for a computer that accepts this one's device key but not its Touch ID key.
  Future<Object?> deviceApproveWithPassword(DeviceInfo d, DeviceApproval a, OwnerAuth auth) => _run(() async {
        await ownerOp(
            auth,
            (x, pw) async => expectReply<DeviceDecidedReply>(await x.call(DeviceDecideRequest(
                contact: d.contact, id: a.id, approve: true, fingerprint: a.fingerprint, password: pw))));
      });

  /// Deny [a] of [d]: no password, no proof (a refusal only takes something away, D-84).
  Future<Object?> deviceDeny(DeviceInfo d, DeviceApproval a) => _run(() async {
        expectReply<DeviceDecidedReply>(
            await daemon.call(DeviceDecideRequest(contact: d.contact, id: a.id, approve: false)));
      });

  /// Accept approvals from [keyIds] of [d] (all it offers when empty), with the password or one touch.
  Future<Object?> deviceConfirmKeys(DeviceInfo d, List<String> keyIds, OwnerAuth auth) => _run(() async {
        devices = await ownerOp(
            auth,
            (x, pw) async => expectReply<DevicesReply>(
                await x.call(DeviceKeysConfirmRequest(contact: d.contact, keyIds: keyIds, password: pw))));
      });

  /// Stop accepting approvals from [d]'s keys ([keyIds], all when empty). No password.
  Future<Object?> deviceForgetKeys(DeviceInfo d, {List<String> keyIds = const []}) => _run(() async {
        devices = expectReply<DevicesReply>(
            await daemon.call(DeviceKeysRemoveRequest(contact: d.contact, keyIds: keyIds)));
      });

  /// "Lend this computer to my teams": on with the password or one touch, off without.
  Future<Object?> setLend(bool on, {OwnerAuth? auth}) => _run(() async {
        devices = on && auth != null
            ? await ownerOp(
                auth,
                (x, pw) async =>
                    expectReply<DevicesReply>(await x.call(DeviceLendSetRequest(enabled: true, password: pw))))
            : expectReply<DevicesReply>(await daemon.call(DeviceLendSetRequest(enabled: on)));
      });

  /// "Revoke this computer": the other own devices are told, then the link is revoked here.
  Future<Object?> deviceRevoke(DeviceInfo d, OwnerAuth auth, {bool deleteHistory = false}) => _run(() async {
        await ownerOp(
            auth,
            (x, pw) async => expectReply<RevokedReply>(
                await x.call(DeviceRevokeRequest(contact: d.contact, password: pw, deleteHistory: deleteHistory))));
        if (deleteHistory) forgetSentPreviews(d.linkId);
        await refreshContacts();
      });

  /// Clear "reported as lost" on [d] (its keys stay removed).
  Future<Object?> deviceDismissLost(DeviceInfo d) => _run(() async {
        devices = expectReply<DevicesReply>(await daemon.call(DeviceLostDismissRequest(d.contact)));
      });
}
