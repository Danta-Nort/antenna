// SPDX-License-Identifier: AGPL-3.0-only
// The "E2E · PQ" badge is built only from facts the daemon read from the rustls and libsignal state
// (`antenna contacts --json`), not from what "should be" according to the code: facts come from state.

import '../l10n/app_localizations.dart';
import '../protocol/x_control.dart';

/// The hybrid TLS 1.3 group (X25519 + ML-KEM-768, RFC 10024).
const hybridGroup = 'X25519MLKEM768';

final class PqFacts {
  PqFacts(this.c);

  final ContactInfo c;

  /// The transport negotiated the hybrid at pairing and (if there was one) on the latest connection.
  bool get tlsHybrid =>
      c.transport.pairingKxGroup == hybridGroup && (c.transport.lastKxGroup ?? hybridGroup) == hybridGroup;

  /// libsignal session version 4: PQXDH + SPQR.
  bool get sessionV4 => c.e2e.sessionVersion == 4;

  /// SPQR has finished negotiation.
  bool get spqrComplete => c.e2e.pqRatchet?.startsWith('NegotiationComplete') ?? false;

  bool get hasE2e => c.e2e.sessionVersion != null;

  /// Post-quantum protection is confirmed by facts in both the transport and the session.
  bool get pq => tlsHybrid && sessionV4;

  /// Badge label.
  String badge(AppLocalizations l) {
    if (!hasE2e) return l.factsBadgeNoData;
    if (pq && spqrComplete) return 'E2E · PQ';
    if (pq) return l.factsBadgeSpqrNegotiating;
    return 'E2E';
  }

  /// Fact rows (the badge tooltip and the contact card): labels in the window's language, values as is.
  List<(String, String)> lines(AppLocalizations l) => [
        (l.factsTlsPairing, c.transport.pairingKxGroup.isEmpty ? '—' : c.transport.pairingKxGroup),
        (l.factsTlsConnection, c.transport.lastKxGroup ?? l.factsNotYet),
        (l.factsSession, c.e2e.sessionVersion == null ? '—' : 'v${c.e2e.sessionVersion}${sessionV4 ? ' · PQXDH + SPQR' : ''}'),
        ('SPQR', c.e2e.pqRatchet ?? '—'),
        (
          l.factsIncoming,
          c.e2e.lastRxVersion == null
              ? l.factsNotYet
              : 'v${c.e2e.lastRxVersion}${c.e2e.lastRxPqLen == null ? '' : ' · SPQR ${c.e2e.lastRxPqLen} B'}'
        ),
      ];
}

/// What the one "Secure" indicator of the conversation header says (reference v3), from the same facts as the
/// details it opens: the session's E2E facts and the history verification state. A history problem wins, since it
/// blocks sending and has its banner; without session facts nothing is claimed.
enum SecureState {
  /// End-to-end and post-quantum ([PqFacts.pq]: the hybrid TLS group and a v4 session) are reported, and the history
  /// is not in doubt.
  secure,

  /// An end-to-end session is reported, post-quantum protection is not (an older session or a classic TLS group).
  encrypted,

  /// The daemon reports no session facts yet (nothing is claimed).
  unconfirmed,

  /// The two copies of the history differ.
  mismatch,

  /// A rollback was found on either side: a rekey is needed.
  rekey;

  static SecureState of(ContactInfo c) {
    final h = c.history;
    if (h != null && h.mismatch) return SecureState.mismatch;
    if (h != null && (h.rolledBack || h.peerRolledBack)) return SecureState.rekey;
    final f = PqFacts(c);
    if (!f.hasE2e) return SecureState.unconfirmed;
    return f.pq ? SecureState.secure : SecureState.encrypted;
  }
}
