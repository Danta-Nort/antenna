// SPDX-License-Identifier: AGPL-3.0-only
// Trust levels of SPEC §9 as reference text for the owner. Rights are enforced by the daemon, not by the UI (SPEC §9):
// these are only labels; where the daemon reports a level's rights in structured form (`Rights`, slice 2 onwards),
// those are shown instead. Texts are in the window's language (lib/l10n, keys trust*).

import '../l10n/app_localizations.dart';

/// Description of a trust level (SPEC §9, table).
final class TrustLevel {
  const TrustLevel._(this.level);

  final int level;

  static const all = <TrustLevel>[TrustLevel._(1), TrustLevel._(2), TrustLevel._(3), TrustLevel._(4), TrustLevel._(5)];

  static TrustLevel of(int level) => all[level.clamp(1, 5) - 1];

  /// Level name: Observer / Acquaintance / Colleague / Partner / Self.
  String name(AppLocalizations l) => switch (level) {
        1 => l.trust1Name,
        2 => l.trust2Name,
        3 => l.trust3Name,
        4 => l.trust4Name,
        _ => l.trust5Name,
      };

  String messages(AppLocalizations l) => level == 1 ? l.trust1Messages : l.trustMessagesText;

  String files(AppLocalizations l) => switch (level) {
        1 => l.trustNone,
        2 => l.trust2Files,
        3 => l.trust3Files,
        4 => l.trust4Files,
        _ => l.trust5Files,
      };

  String tasks(AppLocalizations l) => switch (level) {
        1 => l.trust1Tasks,
        2 => l.trust2Tasks,
        3 => l.trust3Tasks,
        4 => l.trust4Tasks,
        _ => l.trust5Tasks,
      };

  String commands(AppLocalizations l) => switch (level) {
        1 || 2 || 3 => l.trustNone,
        4 => l.trust4Commands,
        _ => l.trust5Commands,
      };

  String limit(AppLocalizations l) => switch (level) {
        1 => l.trustLimitMessages(10),
        2 => l.trustLimitMessagesData(30, '100 MB'),
        3 => l.trustLimitMessagesData(60, '1 GB'),
        4 => l.trustLimitMessagesData(120, '10 GB'),
        _ => l.trust5Limit,
      };

  /// Default network mode for a level (SPEC §4): 1–2 relay only, 3–5 direct.
  static String defaultNetMode(int level) => level <= 2 ? 'relay_only' : 'direct';

  /// Presence (online status) is shared only with levels 3+ (SPEC §4, Q-8).
  static bool presenceAllowed(int level) => level >= 3;
}

/// Level 5 reads as the symbol ∞ "My computer" everywhere the window shows a trust level (D-UI-30): a display
/// choice only — the protocol, the CLI and the daemon keep the number 5 (SPEC §9, D-99, D-100 unchanged).
String trustGlyph(int level) => level == 5 ? '∞' : '$level';

/// Label of a link's network mode.
String netModeLabel(AppLocalizations l, String mode) => switch (mode) {
      'relay_only' => l.netRelayOnly,
      'direct' => l.netDirect,
      'tor' => 'Tor',
      _ => mode,
    };

/// What this mode means for IP privacy (SPEC §4, table).
String netModeHint(AppLocalizations l, String mode) => switch (mode) {
      'relay_only' => l.netRelayOnlyHint,
      'direct' => l.netDirectHint,
      _ => '',
    };
