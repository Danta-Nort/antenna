// SPDX-License-Identifier: AGPL-3.0-only
// The words of My devices: what another computer said about itself (its OS, version, updates, health, agents, keys)
// turned into lines. Everything it said is its word and plain text; codes the window does not know are shown as
// they came.

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../approvals/approval_card.dart' show actionLabel;
import '../security/touch_id_text.dart' show cutForPrompt;

/// "macOS 27.0 · aarch64", "Ubuntu 26.04 LTS · x86_64": the release when known, else the OS name.
String deviceSystem(String os, String osVersion, String arch) {
  final name = osVersion.isNotEmpty
      ? osVersion
      : switch (os) {
          'macos' => 'macOS',
          'linux' => 'Linux',
          _ => os,
        };
  return arch.isEmpty ? name : '$name · $arch';
}

/// The daemon's version without the build commit: `antennad 0.2.0 (abc1234)` → `0.2.0`.
String deviceVersion(String v) => v.replaceFirst(RegExp(r'^antennad\s+'), '').replaceFirst(RegExp(r'\s*\(.*\)$'), '');

/// Memory in whole gigabytes, or a dash.
String deviceMemory(int bytes) => bytes <= 0 ? '—' : '${(bytes / (1 << 30)).round()} GB';

/// What a computer said about its updates, in one line.
String deviceUpdateLine(AppLocalizations l, DeviceUpdate u, DateTime now) {
  final parts = <String>[u.auto ? l.devicesUpdatesAuto : l.devicesUpdatesManual];
  if (u.staged case final v?) {
    parts.add(u.stagedState == 'installing' ? l.devicesUpdateInstalling(v) : l.devicesUpdateStaged(v));
  } else if (u.last case final v?) {
    final when = u.lastAtMs == null ? '' : shortStamp(l, DateTime.fromMillisecondsSinceEpoch(u.lastAtMs!), now);
    switch (u.lastResult) {
      case 'installed':
        parts.add(l.devicesUpdateLastInstalled(v, when));
      case 'failed':
        parts.add(l.devicesUpdateLastFailed(v, when));
    }
  }
  return parts.join(' · ');
}

/// One health fact in words.
String deviceHealthLine(AppLocalizations l, DeviceHealth h) => switch (h.code) {
      'relay_unreachable' => l.devicesHealthRelayUnreachable(h.count ?? 1),
      'relay_disabled' => l.devicesHealthRelayDisabled,
      'token_bound_elsewhere' => l.devicesHealthTokenBound(h.count ?? 1),
      'update_failed' => l.devicesHealthUpdateFailed,
      final c => c,
    };

/// An agent's state there.
String deviceAgentState(AppLocalizations l, DeviceAgent a) => switch (a.state) {
      'connected' => l.devicesAgentConnected,
      'local' => l.devicesAgentLocal,
      _ => l.devicesAgentIdle,
    };

/// A key's kind in words ("Touch ID", "the password there"); [here]: a key of this computer ("the password here").
String deviceKeyKind(AppLocalizations l, DeviceKeyInfo k, {bool here = false}) =>
    k.touchId ? l.devicesKeyTouchId : (here ? l.devicesKeyPasswordHere : l.devicesKeyPassword);

/// Several keys in words, kinds only (the labels are in the tooltip); [here]: this computer's keys.
String deviceKeys(AppLocalizations l, List<DeviceKeyInfo> keys, {bool here = false}) =>
    keys.map((k) => deviceKeyKind(l, k, here: here)).join(', ');

/// The Touch ID sheet's reason for approving [a] of [device] ("approve on mac-mini: Send a message").
String deviceTouchReason(AppLocalizations l, String device, DeviceApproval a) =>
    l.devicesTouchReason(cutForPrompt(device), cutForPrompt(actionLabel(l, a.action)));
