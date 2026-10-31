// SPDX-License-Identifier: AGPL-3.0-only
// Touch ID for owner commands (D-102, CONTROL §22, experimental): the window's owner key for this daemon, and the
// commands it signs. One touch is one command or one listed batch: the window asks the daemon for a one-time
// challenge, the Secure Enclave key signs it with the exact text of the request (an approval's ID and the fingerprint
// the owner was shown, every item of a batch), and the daemon verifies the proof itself (SPEC §9). Unlocking takes the
// unlock slot's key, opened by the same touch that then signs the sign-in.
//
// The password always stays reachable: it enrolls the key, and the window falls back to it when Touch ID is cancelled
// or unavailable, when the daemon wants the password this time (14 days since the last one, three failed proofs), when
// the key is gone from the daemon, and after a fingerprint change (the key is dead; the owner turns Touch ID on again).
// Every Touch ID prompt starts from a click of the owner's; nothing here shows one by itself.
// Offered only on macOS with Touch ID and only with a daemon that speaks x-control/7.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../host/touch_id.dart';
import '../protocol/x_control.dart';
import 'app_model.dart' show Phase;
import 'owner_auth.dart';

/// Why the daemon asked for the password instead of a proof, as far as the window can tell.
enum PasswordReason {
  /// 14 days since the password was last used.
  due,

  /// Three failed proofs in a row.
  failedAttempts,

  /// The window never saw when the password is due.
  unknown,
}

/// What a screen does after a Touch ID attempt that did not go through.
enum TouchIdFallback {
  /// Not a Touch ID matter: show the error (an expired request, a wrong fingerprint, the daemon unreachable…).
  none,

  /// The owner cancelled the prompt: the password field, nothing else to say.
  cancelled,

  /// Touch ID cannot be used now (no sensor, the lid closed, locked after failed touches): the password.
  unavailable,

  /// The daemon wants the password this time ([TouchIdMixin.passwordReason] says why).
  passwordRequired,

  /// The key is gone from the daemon: Touch ID is off here now; the password.
  keyGone,

  /// The unlock slot did not open (it was changed): unlocking takes the password from now on; signing still works.
  slotInvalid,

  /// Fingerprints changed since Touch ID was turned on: the password now, and turn it on again in Settings.
  fingerprintsChanged,
}

/// The label of this Mac's key in the daemon's list (`antenna`'s owner key list): an identifier, not a sentence;
/// 1–64 bytes of printable ASCII.
String ownerKeyLabel([String? host]) {
  final h = (host ?? Platform.localHostname).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  final label = 'touchid@${h.isEmpty ? 'mac' : h}';
  return label.length > 64 ? label.substring(0, 64) : label;
}

/// The window's owner key for the daemon of [socketPath], its state, and the commands it signs.
mixin TouchIdMixin on ChangeNotifier {
  XDaemon get daemon;
  HelloOk? get hello;
  String get socketPath;
  Phase get phase;
  TouchIdHost get touchIdHost;
  DateTime now();
  void safeNotify();

  /// One approval request decided by [op] (the model's bookkeeping: the list, the finishing card, the agent's line).
  Future<Object?> decideApproval(String id, Future<ApprovalInfo> Function() op);

  /// Results of a batch applied to the list.
  void applyApprovalResults(List<ApprovalResult> results);

  /// [op] changes the keys' state; then [session] opens the window's owner session, and the window enters.
  Future<Object?> keyOpWith(Future<DaemonState> Function() op, XDialog Function() session);

  /// After a way in failed halfway (the keys opened, the session did not): show the daemon's state.
  Future<void> recheckKeys();

  /// The daemon stopped answering in the middle of a command.
  void daemonFailed(Object e);

  /// What this Mac can do now, and the state of the key blobs for this daemon.
  TouchIdStatus touchIdStatus = TouchIdStatus.none;

  /// Which owner key the daemon enrolled for this window and daemon; `null`: Touch ID is off.
  OwnerKeyRecord? ownerKeyRecord;

  /// Touch ID failed as unavailable or locked out during this run: the password until the next status check.
  bool touchIdPaused = false;

  /// The fingerprints changed since Touch ID was turned on: the key is dead; the owner turns it on again.
  bool touchIdFingerprintsChanged = false;

  /// The daemon's list of owner keys (Settings).
  OwnerKeysReply? ownerKeys;

  /// When the daemon asks for the password next (from `owner_challenge` or `owner_key_list`).
  int? passwordDueMs;

  /// Enrolling or turning off is in progress.
  bool touchIdBusy = false;

  /// The last Touch ID attempt on the sign-in screen that did not go through (the screen may change under it).
  Object? touchIdGateError;

  /// The window has not been in yet in this run: its first gate (keys locked, or no session) opens the Touch ID sheet
  /// by itself, once, as soon as Touch ID is ready (D-131: opening the app is the owner's own action). Spent when the
  /// gate used it or the window got in any other way; a gate after "Lock keys" waits for a click.
  bool touchIdAtStart = true;

  String get touchIdDir => touchIdHost.dirFor(socketPath);

  /// The daemon speaks x-control/7 (owner keys).
  bool get touchIdProtocol => controlVersion(hello?.proto) >= 7;

  /// The Settings line is shown: macOS with Touch ID, a daemon with owner keys.
  bool get touchIdOffered =>
      touchIdHost.supported &&
      touchIdProtocol &&
      (touchIdStatus.available || ownerKeyRecord != null || touchIdFingerprintsChanged);

  /// Touch ID is turned on for this daemon and its key is alive.
  bool get touchIdOn => ownerKeyRecord != null && touchIdStatus.enrolled && !touchIdFingerprintsChanged;

  /// "Approve with Touch ID" and "Sign in with Touch ID" are offered.
  bool get touchIdReady =>
      touchIdHost.supported && touchIdProtocol && touchIdOn && touchIdStatus.available && !touchIdPaused;

  /// "Unlock with Touch ID" is offered: an unlock slot was sealed here.
  bool get touchIdUnlockReady => touchIdReady && (ownerKeyRecord?.unlock ?? false) && touchIdStatus.hpke;

  /// Why the password is asked this time.
  PasswordReason passwordReason() {
    final due = passwordDueMs;
    if (due == null) return PasswordReason.unknown;
    return now().millisecondsSinceEpoch >= due ? PasswordReason.due : PasswordReason.failedAttempts;
  }

  /// What a screen does with [err] from a Touch ID command.
  static TouchIdFallback fallbackFor(Object? err) => switch (err) {
        XProofException(:final cause) => fallbackFor(cause),
        TouchIdException(reason: TouchIdFailure.cancelled) => TouchIdFallback.cancelled,
        TouchIdException(reason: TouchIdFailure.keyInvalidated) => TouchIdFallback.fingerprintsChanged,
        TouchIdException() => TouchIdFallback.unavailable,
        XControlException(code: XErrorCode.passwordRequired) => TouchIdFallback.passwordRequired,
        XControlException(code: XErrorCode.ownerKeyUnknown || XErrorCode.ownerKeyRefused) => TouchIdFallback.keyGone,
        XControlException(code: XErrorCode.slotInvalid) => TouchIdFallback.slotInvalid,
        _ => TouchIdFallback.none,
      };

  /// Read the record and what this Mac can do now. Never shows a prompt.
  Future<void> refreshTouchId() async {
    if (!touchIdHost.supported) return;
    final dir = touchIdDir;
    try {
      final rec = await touchIdHost.readRecord(dir);
      final st = await touchIdHost.status(dir);
      touchIdStatus = st;
      touchIdPaused = false;
      ownerKeyRecord = rec;
      if (rec != null && st.domainChanged) touchIdFingerprintsChanged = true;
      if (rec != null && !st.enrolled) {
        // The record without its keys (the folder was cleaned): nothing can sign; Touch ID is off.
        await _forget(dir, rec, fromDaemon: true);
      }
    } on TouchIdException {
      touchIdStatus = TouchIdStatus.none;
    }
    safeNotify();
  }

  /// The daemon's owner keys and when the password is due (Settings; an owner session). A key the daemon no longer
  /// has is dropped here too.
  Future<void> refreshOwnerKeys() async {
    if (!touchIdHost.supported || !touchIdProtocol) return;
    try {
      final r = await daemon.ownerKeyList();
      ownerKeys = r;
      passwordDueMs = r.passwordDueMs;
      final rec = ownerKeyRecord;
      if (rec != null && !r.keys.any((k) => k.keyId == rec.keyId)) await _forget(touchIdDir, rec, fromDaemon: false);
    } on XClientException {
      // Settings shows the switch from the local state; the next command says what is wrong.
    }
    safeNotify();
  }

  /// Turn Touch ID on: create the Secure Enclave keys, enroll the signing key with [password] and a proof by that key
  /// (one touch, [reason] on the prompt), seal the unlock slot's key when this Mac has HPKE. A previous key of this
  /// window (dead after a fingerprint change, or still enrolled) is removed first. Returns the error or `null`.
  Future<Object?> enrollTouchId(String password, {required String reason, String? label}) async {
    touchIdBusy = true;
    safeNotify();
    final dir = touchIdDir;
    try {
      if (ownerKeyRecord case final old?) await _forget(dir, old, fromDaemon: true);
      final st = await touchIdHost.status(dir);
      touchIdStatus = st;
      if (!st.available) throw const TouchIdException(TouchIdFailure.unavailable);
      final keys = await touchIdHost.create(dir);
      // An enroll challenge: issued even when other proofs wait for the password (this request carries it).
      final ch = await daemon.ownerChallenge(enroll: true);
      final reply = expectReply<OwnerKeyAddedReply>(await daemon.callWithProof(
        OwnerKeyAddRequest(
            publicKey: keys.signingPublic, label: label ?? ownerKeyLabel(), password: password, unlock: st.hpke),
        (req) async => OwnerProof(
          keyId: keys.keyId,
          nonce: ch.nonce,
          sig: await touchIdHost.sign(dir: dir, nonce: ch.nonce, request: req, reason: reason),
        ),
      ));
      if (reply.key.keyId != keys.keyId) {
        // Fail closed: a key ID the window did not make is not this Secure Enclave key.
        unawaited(daemon.ownerKeyRemove(reply.key.keyId).catchError((Object _) {}));
        throw const XProtocolException('the daemon enrolled a different key ID');
      }
      var unlock = false;
      if (reply.slotKey case final slot?) {
        try {
          await touchIdHost.seal(dir: dir, slotKey: slot);
          unlock = true;
        } on TouchIdException {
          // The slot stays unopenable in the daemon (nobody holds its key); unlocking keeps the password.
        }
      }
      final rec = OwnerKeyRecord(keyId: keys.keyId, unlock: unlock);
      await touchIdHost.writeRecord(dir, rec);
      ownerKeyRecord = rec;
      touchIdFingerprintsChanged = false;
      touchIdPaused = false;
      touchIdStatus = await touchIdHost.status(dir);
      unawaited(refreshOwnerKeys());
      return null;
    } on TouchIdException catch (e) {
      await _discardUnenrolled(dir);
      return e;
    } on XClientException catch (e) {
      await _discardUnenrolled(dir);
      if (e is XDaemonUnreachable) daemonFailed(e);
      return e;
    } finally {
      touchIdBusy = false;
      safeNotify();
    }
  }

  /// Keys made for an enrollment that did not finish are useless: remove them.
  Future<void> _discardUnenrolled(String dir) async {
    if (ownerKeyRecord != null) return;
    try {
      await touchIdHost.delete(dir);
    } on TouchIdException {
      // Nothing was made.
    }
    touchIdStatus = await touchIdHost.status(dir).catchError((Object _) => touchIdStatus);
  }

  /// Turn Touch ID off: the daemon removes the key and its unlock slot (no password, D-84), and the local keys go.
  /// The local keys go even when the daemon cannot be reached (then the error is returned): off is off here.
  Future<Object?> disableTouchId() async {
    final rec = ownerKeyRecord;
    if (rec == null) return null;
    touchIdBusy = true;
    safeNotify();
    Object? err;
    try {
      await daemon.ownerKeyRemove(rec.keyId);
    } on XControlException catch (e) {
      if (e.code != XErrorCode.notFound) err = e;
    } on XClientException catch (e) {
      err = e;
    }
    await _forget(touchIdDir, rec, fromDaemon: false);
    touchIdFingerprintsChanged = false;
    touchIdBusy = false;
    unawaited(refreshOwnerKeys());
    safeNotify();
    return err;
  }

  Future<void> _forget(String dir, OwnerKeyRecord rec, {required bool fromDaemon}) async {
    if (fromDaemon) {
      try {
        await daemon.ownerKeyRemove(rec.keyId);
      } on XClientException {
        // Gone already, or the daemon cannot be reached: the key cannot sign without the local blob anyway.
      }
    }
    try {
      await touchIdHost.delete(dir);
    } on TouchIdException {
      // Nothing to delete.
    }
    if (ownerKeyRecord?.keyId == rec.keyId) ownerKeyRecord = null;
    touchIdStatus = await touchIdHost.status(dir).catchError((Object _) => touchIdStatus);
  }

  /// One command with a proof: the challenge first (so a daemon that wants the password says so before any Touch ID
  /// prompt), then [run] with the proof source that signs the request after one touch with [reason].
  Future<Object?> _withTouch(String reason, Future<Object?> Function(ProofSource prove) run, {bool reuse = false}) async {
    final rec = ownerKeyRecord;
    if (rec == null || !touchIdReady) return const TouchIdException(TouchIdFailure.unavailable);
    final dir = touchIdDir;
    final OwnerChallengeReply ch;
    try {
      ch = await daemon.ownerChallenge();
      passwordDueMs = ch.passwordDueMs;
    } on XClientException catch (e) {
      return _afterError(e);
    }
    Future<OwnerProof> prove(String req) async => OwnerProof(
          keyId: rec.keyId,
          nonce: ch.nonce,
          sig: await touchIdHost.sign(dir: dir, nonce: ch.nonce, request: req, reason: reason, reuse: reuse),
        );
    try {
      return _afterError(await run(prove));
    } on TouchIdException catch (e) {
      return _afterError(e);
    } on XClientException catch (e) {
      return _afterError(e);
    }
  }

  /// What a failed Touch ID command changes: the key gone from the daemon → off here; unavailable → the password for
  /// now; fingerprints changed → the key is dead.
  Object? _afterError(Object? err) {
    switch (fallbackFor(err)) {
      case TouchIdFallback.keyGone:
        final rec = ownerKeyRecord;
        if (rec != null) unawaited(_forget(touchIdDir, rec, fromDaemon: false).then((_) => safeNotify()));
      case TouchIdFallback.slotInvalid:
        final rec = ownerKeyRecord;
        if (rec != null) {
          ownerKeyRecord = OwnerKeyRecord(keyId: rec.keyId, unlock: false);
          unawaited(touchIdHost.writeRecord(touchIdDir, ownerKeyRecord!).catchError((Object _) {}));
        }
      case TouchIdFallback.unavailable:
        touchIdPaused = true;
      case TouchIdFallback.fingerprintsChanged:
        touchIdFingerprintsChanged = true;
      case TouchIdFallback.passwordRequired || TouchIdFallback.cancelled || TouchIdFallback.none:
        break;
    }
    if (err is XDaemonUnreachable) daemonFailed(err);
    if (err != null) safeNotify();
    return err;
  }

  /// The daemon to send one owner command with [auth] through, and the password to put in it (D-131): this daemon
  /// and the typed password, or, for one touch, a [ProvingDaemon] that signs exactly one request (its password fields
  /// empty, so `''`) after a fresh challenge; a daemon that wants the password says so before any prompt. For a
  /// dialog (invite, join) whose result comes later; one-reply commands use [ownerOp].
  (XDaemon, String) ownerDaemon(OwnerAuth auth) {
    switch (auth) {
      case PasswordAuth(:final password):
        return (daemon, password);
      case TouchAuth(:final reason):
        final rec = ownerKeyRecord;
        final dir = touchIdDir;
        return (
          ProvingDaemon(daemon, (req) async {
            // Checked again here: Touch ID may have been turned off or paused since the screen offered it.
            if (rec == null || !touchIdReady) throw const TouchIdException(TouchIdFailure.unavailable);
            final ch = await daemon.ownerChallenge();
            passwordDueMs = ch.passwordDueMs;
            return OwnerProof(
              keyId: rec.keyId,
              nonce: ch.nonce,
              sig: await touchIdHost.sign(dir: dir, nonce: ch.nonce, request: req, reason: reason),
            );
          }),
          '',
        );
    }
  }

  /// One owner command with [auth] (D-131): [op] makes exactly that command through the daemon and with the password
  /// [ownerDaemon] gives it; anything else [op] calls goes through [daemon] as usual. A Touch ID matter comes back as
  /// an [XClientException] ([XProofException] for the host's side) that [fallbackFor] reads, after the bookkeeping
  /// of a failed touch (the key gone, Touch ID paused, fingerprints changed).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op) async {
    final (d, pw) = ownerDaemon(auth);
    try {
      return await op(d, pw);
    } on XClientException catch (e) {
      if (auth is TouchAuth) _afterError(e);
      rethrow;
    }
  }

  /// [request] (an owner command that takes a proof, its password fields empty) signed with one touch with [reason]:
  /// the reply, or the error. A Touch ID matter ([fallbackFor]) means the screen asks for the password instead.
  Future<(Reply?, Object?)> callWithTouchId(XRequest request, {required String reason}) async {
    Reply? reply;
    final err = await _withTouch(reason, (prove) async {
      reply = await daemon.callWithProof(request, prove);
      return null;
    });
    return (err == null ? reply : null, err);
  }

  /// Approve [a] with one touch: the request carries its ID and the fingerprint the owner was shown, both signed.
  Future<Object?> approveWithTouchId(ApprovalInfo a, {required String reason}) => _withTouch(
        reason,
        (prove) => decideApproval(
          a.id,
          () async => expectReply<ApprovalReply>(await daemon.callWithProof(
            ApproveRequest(id: a.id, password: '', fingerprint: a.fingerprint),
            prove,
          )).approval,
        ),
      );

  /// Approve the listed [items] with one touch: one `approve_many` whose signed text names every request and its
  /// fingerprint; each request is still approved on its own and fails alone (D-92).
  Future<(List<ApprovalResult>, Object?)> approveManyWithTouchId(List<ApprovalInfo> items,
      {required String reason}) async {
    var results = <ApprovalResult>[];
    final err = await _withTouch(reason, (prove) async {
      final r = expectReply<ApprovalsDecidedReply>(await daemon.callWithProof(
        ApproveManyRequest(items: [for (final a in items) ApproveItem(a.id, fingerprint: a.fingerprint)], password: ''),
        prove,
      ));
      results = r.results;
      applyApprovalResults(results);
      return null;
    });
    return (results, err);
  }

  /// The keys are unlocked, the window has no session: one touch signs `login {hold}`.
  Future<Object?> signInWithTouchId({required String reason}) async {
    touchIdGateError = null;
    const login = LoginRequest('');
    final err = await _withTouch(reason, (prove) async {
      // The touch first, then the session: the window waits for the session event only briefly, and the owner may take
      // longer than that to touch the sensor. The dialog carries the text that was signed, unchanged.
      final req = requestText(login);
      final proof = await prove(req);
      return keyOpWith(
        () async => DaemonState.unlocked,
        () => daemon.openWithProof(
            login, (r) async => r == req ? proof : throw const XProtocolException('the sign-in request changed')),
      );
    });
    touchIdGateError = err;
    return err;
  }

  /// The keys are locked: one touch opens the unlock slot's key, the daemon unlocks with it, and the same touch signs
  /// the sign-in that follows (the Runner keeps that one context for exactly one signature, within 30 s).
  Future<Object?> unlockWithTouchId({required String reason}) async {
    touchIdGateError = null;
    final rec = ownerKeyRecord;
    if (rec == null || !touchIdUnlockReady) return touchIdGateError = const TouchIdException(TouchIdFailure.unavailable);
    final dir = touchIdDir;
    Object? err;
    try {
      final slot = await touchIdHost.openSlot(dir: dir, reason: reason);
      err = await keyOpWith(
        () => daemon.unlockWithSlot(rec.keyId, slot),
        () => daemon.openWithProof(const LoginRequest(''), (req) async {
          final ch = await daemon.ownerChallenge();
          passwordDueMs = ch.passwordDueMs;
          return OwnerProof(
            keyId: rec.keyId,
            nonce: ch.nonce,
            sig: await touchIdHost.sign(dir: dir, nonce: ch.nonce, request: req, reason: reason, reuse: true),
          );
        }),
      );
    } on TouchIdException catch (e) {
      err = e;
    } on XClientException catch (e) {
      err = e;
    }
    if (err != null) {
      // The slot may have opened the keys while the sign-in did not go through: show what the daemon says.
      await recheckKeys();
      _afterError(err);
    }
    touchIdGateError = err;
    safeNotify();
    return err;
  }
}
