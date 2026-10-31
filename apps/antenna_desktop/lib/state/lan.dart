// SPDX-License-Identifier: AGPL-3.0-only
// LAN via mDNS (x-control/5, CONTROL §18): nodes on the same local network find each other without internet. Off by
// default; the owner turns it on with the password. Only links at level 3+. The window takes the network state and
// addresses only from `lan_status`.

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

mixin LanMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  /// Notify the window (no error after dispose).
  void safeNotify();

  /// The last known state (`null` if not asked yet or the daemon is older than v5).
  LanReply? lan;

  /// The daemon supports LAN (x-control/5).
  bool lanSupported = true;

  Future<void> refreshLan() async {
    try {
      lan = await daemon.lanStatus();
      lanSupported = true;
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) lanSupported = false;
    } on XClientException {
      return;
    }
    safeNotify();
  }

  /// Turn on (owner password) or off. Returns the daemon error or `null`.
  Future<Object?> setLan({required bool enabled, OwnerAuth? auth}) async {
    try {
      lan = enabled && auth != null
          ? await ownerOp(auth, (d, pw) => d.lanSet(enabled: true, password: pw))
          : await daemon.lanSet(enabled: enabled);
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }
}
