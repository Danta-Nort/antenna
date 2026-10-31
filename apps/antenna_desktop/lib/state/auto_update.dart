// SPDX-License-Identifier: AGPL-3.0-only
// "Install signed updates by itself" (x-control/7, D-103, CONTROL §23), as the window shows it. The daemon holds the
// setting and does all the work: it verifies a release with the keys pinned in it, stages it, waits until agents are
// idle and installs it; the window reads `update_auto_status`, re-reads it on every `update_auto` event, and sends the
// owner's choices (on and off with the password, "Install now", "Later"). A daemon older than v7 has none of it: the
// window says so instead of showing a switch that would do nothing.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

/// The version in the daemon's banner (`antennad 0.1.0-preview.7 (e142081)` → `0.1.0-preview.7`), or `null`.
String? daemonVersionOf(String? banner) {
  if (banner == null) return null;
  final m = RegExp(r'(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)').firstMatch(banner);
  return m?.group(1);
}

/// SemVer 2.0 precedence of two versions (`0.1.0-preview.9` < `0.1.0-preview.10` < `0.1.0`); `null` when either is
/// not a version. Build metadata does not count.
int? compareVersions(String a, String b) {
  final re = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');
  final x = re.firstMatch(a), y = re.firstMatch(b);
  if (x == null || y == null) return null;
  for (var i = 1; i <= 3; i++) {
    final c = int.parse(x.group(i)!).compareTo(int.parse(y.group(i)!));
    if (c != 0) return c;
  }
  final px = x.group(4), py = y.group(4);
  if (px == null || py == null) return px == py ? 0 : (px == null ? 1 : -1);
  final ix = px.split('.'), iy = py.split('.');
  for (var i = 0; i < ix.length && i < iy.length; i++) {
    final nx = int.tryParse(ix[i]), ny = int.tryParse(iy[i]);
    final c = nx != null && ny != null
        ? nx.compareTo(ny)
        : (nx != null ? -1 : (ny != null ? 1 : ix[i].compareTo(iy[i])));
    if (c != 0) return c;
  }
  return ix.length.compareTo(iy.length);
}

mixin AutoUpdateMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  void safeNotify();

  /// The daemon's control protocol version (`hello_ok.proto`): the commands exist from 7 on.
  int get daemonProto;

  /// The setting and what the daemon did (`null`: not read yet, or the daemon is older than v7).
  UpdateAutoInfo? updateAuto;

  bool _autoWorks = true;

  /// The daemon has the commands: it speaks x-control/7 and has not answered one as unknown. An older daemon is
  /// never sent them.
  bool get updateAutoAvailable => daemonProto >= 7 && _autoWorks;

  /// The last `update_auto` event (for the notice while an install is coming).
  UpdateAutoEvent? lastUpdateAutoEvent;

  /// A v7 daemon that has not built the command yet (`not_implemented`), or one that does not know it.
  bool _isOld(XControlException e) => e.code == XErrorCode.unknownCommand || e.code == XErrorCode.notImplemented;

  /// Read the setting (after sign-in, on each `update_auto` event, when Settings opens).
  Future<void> refreshUpdateAuto() async {
    if (daemonProto < 7) {
      updateAuto = null;
      return;
    }
    try {
      updateAuto = await daemon.updateAutoStatus();
      _autoWorks = true;
    } on XControlException catch (e) {
      if (_isOld(e)) {
        _autoWorks = false;
        updateAuto = null;
      }
    } on XClientException {
      return;
    }
    safeNotify();
  }

  /// Turn "Install signed updates by itself" on (the owner password: the daemon opens the root key with it, D-103) or
  /// off (the password or one touch, D-131). Returns the error or `null`.
  Future<Object?> setUpdateAuto({required bool enabled, required OwnerAuth auth}) =>
      _do(() => ownerOp(auth, (d, pw) => d.updateAutoSet(enabled: enabled, password: pw)));

  /// Install the staged release now (the daemon's checks are the same). Returns the error or `null`. With [auth] (the
  /// password) when the daemon keeps no keys for the restart (the setting is off, D-137), so the new version comes up
  /// unlocked.
  Future<Object?> updateAutoNow({OwnerAuth? auth}) => auth == null
      ? _do(daemon.updateAutoNow)
      : _do(() => ownerOp(auth, (d, pw) => d.updateAutoNow(password: pw)));

  /// Postpone the staged release by an hour. Returns the error or `null`.
  Future<Object?> updateAutoLater() => _do(daemon.updateAutoLater);

  Future<Object?> _do(Future<UpdateAutoInfo> Function() op) async {
    try {
      updateAuto = await op();
      safeNotify();
      return null;
    } on XControlException catch (e) {
      if (_isOld(e)) {
        _autoWorks = false;
        safeNotify();
      }
      return e;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// The `update_auto` event: remember it and read the whole picture again.
  void onUpdateAutoEvent(UpdateAutoEvent e) {
    lastUpdateAutoEvent = e;
    safeNotify();
    unawaited(refreshUpdateAuto());
  }

  void clearUpdateAuto() {
    updateAuto = null;
    lastUpdateAutoEvent = null;
  }
}
