// SPDX-License-Identifier: AGPL-3.0-only
// State of the pairing dialogs on top of XDialog (SPEC §6, docs/CONTROL.md §6). The owner makes the decisions: the
// code is typed by hand on B, and confirmation on A comes only after a spoken "it matches" (items 8–9). The UI never
// confirms anything by itself. An invite lives in the daemon until its TTL (Q-7): closing the window does not burn
// it; that is what "Cancel invite" is for.
//
// Confirmation on A (CONTROL §6, PROTOCOL §15, F-4): the owner TYPES the code they read out and the other person
// confirmed; the window never fills in the displayed code itself (that would be confirmation without verification).
// x-control/2: the code goes as `input confirm {yes, code}` over the follow connection (the password was already
// checked at `invite`); a wrong code yields an `input_rejected` event and the invite stays alive (D-UI-4, revised for
// v2).
//
// D-95 (x-control/6): when the daemon says `confirm_without_code` (B entered the code correctly and no other invite
// of this node showed a code meanwhile, so "it matches" can only be about this invite), the owner's one click is the
// confirmation: `input confirm {yes}` without a code. It is still the owner's explicit action; the window never sends
// it by itself and never fills in a code. If the daemon refuses it (`code_required`: another invite showed a code at
// the same time; `bad_request`: a daemon older than D-95), the code field comes back.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../protocol/x_control.dart';
import 'messages.dart';

enum InvitePhase {
  /// Request sent, waiting for the link.
  creating,

  /// The link is ready, waiting for B to connect.
  waitingPeer,

  /// The sides exchanged keys: A has the code, B enters it on their side.
  codeShown,

  /// B entered the correct code: owner A confirms with one click when the daemon offers it (D-95), otherwise by
  /// entering the code that was confirmed to them.
  needConfirm,

  /// The daemon accepted the code; the link is being activated.
  confirming,
  linked,
  failed,
}

/// Invite (side A).
class InviteSession extends ChangeNotifier {
  InviteSession(this._dialog, {required this.trust, required this.ttl, this.label}) {
    _sub = _dialog.events.listen(_onEvent);
    _dialog.result.then(_onLinked, onError: _onError);
  }

  final XDialog _dialog;
  late final StreamSubscription<XEvent> _sub;
  final int trust;
  final Duration ttl;
  final String? label;

  InvitePhase phase = InvitePhase.creating;

  /// Error of the last confirmation attempt (wrong code, password); the invite stays alive.
  Object? confirmError;

  /// D-95: the daemon accepts "yes" without the code (`need_input confirm` with `confirm_without_code`).
  bool confirmWithoutCode = false;

  /// Why the code field came back after a "yes" without the code: [XErrorCode.codeRequired] (another invite showed a
  /// code at the same time) or [XErrorCode.badRequest] (a daemon older than D-95). `null`: not refused.
  String? codeFallback;

  /// The last "yes" went without a code (its refusal brings the code field back rather than an error).
  bool _sentWithoutCode = false;

  /// The confirmation is one button rather than the code field.
  bool get confirmByButton => confirmWithoutCode && codeFallback == null;
  /// v5: the web address https://antenna.contact/#…, for people and the QR code (an older daemon sends x://pair#…).
  String? link;

  /// v5: antenna://pair#…, for "open in the app" and 0.1.0-preview.1 nodes.
  String? linkApp;
  DateTime? expiresAt;
  String? netMode;
  String? sas;
  String? sasEmoji;
  String? inviteId;
  bool peerEnteredCode = false;
  final List<AttemptFailed> attempts = [];
  LinkedReply? linked;
  Object? error;
  bool _disposed = false;

  bool get finished => phase == InvitePhase.linked || phase == InvitePhase.failed;

  void _onEvent(XEvent e) {
    switch (e) {
      case InviteCreated():
        link = e.link;
        linkApp = e.linkApp;
        expiresAt = DateTime.fromMillisecondsSinceEpoch(e.expiresMs);
        netMode = e.netMode;
        inviteId = e.id;
        phase = InvitePhase.waitingPeer;
      case SasEvent():
        sas = e.code;
        sasEmoji = e.emoji;
        phase = InvitePhase.codeShown;
      case PeerEnteredCode():
        peerEnteredCode = true;
      case NeedInput(isConfirm: true, :final confirmWithoutCode):
        this.confirmWithoutCode = confirmWithoutCode;
        phase = InvitePhase.needConfirm;
      case InputRejected(what: 'confirm', :final code, :final message):
        if (_sentWithoutCode && (code == XErrorCode.codeRequired || code == XErrorCode.badRequest)) {
          // The daemon wants the code after all: the code field, with the reason, instead of an error.
          codeFallback = code;
          confirmError = null;
        } else {
          // Wrong or empty code: the invite stays alive and the owner enters it again.
          confirmError = XControlException(code, message);
        }
        _sentWithoutCode = false;
        if (phase == InvitePhase.confirming) phase = InvitePhase.needConfirm;
      case AttemptFailed():
        attempts.add(e);
        // Failed attempt: the daemon put the invite back into waiting and erased the code.
        sas = null;
        sasEmoji = null;
        phase = InvitePhase.waitingPeer;
      default:
        break;
    }
    _notify();
  }

  void _onLinked(Reply r) {
    if (r is LinkedReply) {
      linked = r;
      phase = InvitePhase.linked;
    } else {
      error = XProtocolException('unexpected reply ${r.runtimeType}');
      phase = InvitePhase.failed;
    }
    _notify();
  }

  void _onError(Object e) {
    error = e;
    phase = InvitePhase.failed;
    _notify();
  }

  /// Confirmation by owner A: [code] is the code they TYPED themselves (6 digits, the same emoji, or animal names).
  void confirmWithCode(String code) {
    if (phase != InvitePhase.needConfirm) return;
    if (code.trim().isEmpty) {
      confirmError = const XControlException(XErrorCode.badRequest, 'no code entered');
      _notify();
      return;
    }
    confirmError = null;
    _sentWithoutCode = false;
    _dialog.input(ConfirmInput(true, code: code.trim()));
    phase = InvitePhase.confirming;
    _notify();
  }

  /// The owner's click on "The contact confirmed — codes match" (D-95): "yes" without a code, only when the daemon
  /// offered it. A refusal brings the code field back ([codeFallback]).
  void confirmMatch() {
    if (phase != InvitePhase.needConfirm || !confirmByButton) return;
    confirmError = null;
    _sentWithoutCode = true;
    _dialog.input(const ConfirmInput(true));
    phase = InvitePhase.confirming;
    _notify();
  }

  /// "Doesn't match" is a refusal: no link is created and the invite burns (no code or password needed).
  void reject() {
    if (phase != InvitePhase.needConfirm && phase != InvitePhase.codeShown) return;
    _dialog.input(const ConfirmInput(false));
    phase = InvitePhase.confirming;
    _notify();
  }

  String? confirmErrorText(AppLocalizations l) => confirmError == null ? null : describeConfirmError(l, confirmError!);

  /// Stop following in this window (the invite stays in the daemon until its TTL).
  Future<void> detach() => _dialog.cancel();

  String? errorText(AppLocalizations l) => error == null ? null : describeError(l, error!);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
    if (!finished) unawaited(_dialog.cancel());
    super.dispose();
  }
}

enum JoinPhase {
  /// Connecting to the invite.
  connecting,

  /// Need the code as read out by A.
  needCode,

  /// Code sent; waiting for A to confirm.
  verifying,
  linked,
  failed,
}

/// Join (side B).
class JoinSession extends ChangeNotifier {
  JoinSession(this._dialog, {required this.trust, this.label}) {
    _sub = _dialog.events.listen(_onEvent);
    _dialog.result.then(_onLinked, onError: _onError);
  }

  final XDialog _dialog;
  late final StreamSubscription<XEvent> _sub;
  final int trust;
  final String? label;

  JoinPhase phase = JoinPhase.connecting;
  String? waitingFor;
  LinkedReply? linked;
  Object? error;
  bool _disposed = false;

  bool get finished => phase == JoinPhase.linked || phase == JoinPhase.failed;

  void _onEvent(XEvent e) {
    switch (e) {
      case NeedInput(isSasCode: true):
        phase = JoinPhase.needCode;
      case Waiting(:final what):
        waitingFor = what;
      default:
        break;
    }
    _notify();
  }

  void _onLinked(Reply r) {
    if (r is LinkedReply) {
      linked = r;
      phase = JoinPhase.linked;
    } else {
      error = XProtocolException('unexpected reply ${r.runtimeType}');
      phase = JoinPhase.failed;
    }
    _notify();
  }

  void _onError(Object e) {
    error = e;
    phase = JoinPhase.failed;
    _notify();
  }

  /// The code owner B entered as read out by A: 6 digits, the same 6 emoji, or animal names.
  void submitCode(String code) {
    if (phase != JoinPhase.needCode) return;
    _dialog.input(SasCodeInput(code));
    phase = JoinPhase.verifying;
    _notify();
  }

  /// Refusal: closing the connection on B means no link is created.
  Future<void> cancel() => _dialog.cancel();

  String? errorText(AppLocalizations l) => error == null ? null : describeError(l, error!);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
    if (!finished) unawaited(_dialog.cancel());
    super.dispose();
  }
}
