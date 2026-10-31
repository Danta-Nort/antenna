// SPDX-License-Identifier: AGPL-3.0-only
// One owner command with an owner proof in place of the password (v7, CONTROL §22.2, D-131): a view of a daemon
// whose typed calls go through [XDaemon.callWithProof] and [XDaemon.openWithProof] with one [ProofSource]. The view
// sends exactly one request: a second one through it is refused before anything is signed, so one touch never
// becomes two commands. Whatever the prover throws that is not a client error (a Touch ID prompt cancelled, Touch ID
// unavailable) comes back as [XProofException], so callers handle it with every other client error.

import 'daemon.dart';
import 'daemon_calls.dart';
import 'errors.dart';
import 'models.dart';
import 'requests.dart';

/// [inner] for one request signed by [prove]; its password fields go empty (the caller passes `''`).
final class ProvingDaemon with XDaemonCalls implements XDaemon {
  ProvingDaemon(this._inner, this._prove);

  final XDaemon _inner;
  final ProofSource _prove;
  bool _used = false;

  /// The one request was sent (or its proof was asked for).
  bool get used => _used;

  ProofSource _once() {
    if (_used) throw const XProtocolException('one owner proof signs one request');
    _used = true;
    return (req) async {
      try {
        return await _prove(req);
      } on XClientException {
        rethrow;
      } on Object catch (e) {
        throw XProofException(e);
      }
    };
  }

  @override
  Future<Reply> call(XRequest request) async => _inner.callWithProof(request, _once());

  @override
  XDialog open(XRequest request) => _inner.openWithProof(request, _once());

  @override
  Future<Reply> callWithProof(XRequest request, ProofSource prove) => _inner.callWithProof(request, prove);

  @override
  XDialog openWithProof(XRequest request, ProofSource prove) => _inner.openWithProof(request, prove);

  @override
  String get socketPath => _inner.socketPath;

  @override
  String? get sessionToken => _inner.sessionToken;

  @override
  set sessionToken(String? token) => _inner.sessionToken = token;

  @override
  Future<HelloOk> hello() => _inner.hello();
}
