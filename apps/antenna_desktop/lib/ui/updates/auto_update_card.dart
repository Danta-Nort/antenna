// SPDX-License-Identifier: AGPL-3.0-only
// Settings → Updates → "Install signed updates by itself" (D-103, CONTROL §23): per computer, off by default, the
// owner password both ways (the daemon checks it), experimental (D-94). Under the switch: what the daemon staged,
// what it did last and the versions it will not try again by itself. Everything shown comes from
// `update_auto_status`; the window decides nothing about a release.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../settings/settings_page.dart' show SettingRow;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import 'ready_banner.dart' show describeAutoUpdateError;

class AutoUpdateSetting extends StatefulWidget {
  const AutoUpdateSetting({super.key});

  @override
  State<AutoUpdateSetting> createState() => _AutoUpdateSettingState();
}

class _AutoUpdateSettingState extends State<AutoUpdateSetting> {
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshUpdateAuto();
    });
  }

  Future<void> _set(bool on) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Turning it on takes the password itself (the daemon opens the root key with it, D-103); off takes a touch too.
    final (_, err) = await confirmOwner(
      context,
      action: on ? l.updateAutoOnAction : l.updateAutoOffAction,
      detail: on ? l.updateAutoOnDetail : l.updateAutoOffDetail,
      touch: !on,
      run: (auth) => m.setUpdateAuto(enabled: on, auth: auth),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final a = m.updateAuto;
    if (!m.updateAutoAvailable) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.updateAutoTitle, style: XText.title),
          const SizedBox(height: 4),
          Text(l.updateAutoOld, key: const Key('update-auto-old'), style: XText.bodyDim),
        ]),
      );
    }
    final on = a?.enabled ?? false;
    // Turning it on needs an installation that can replace itself; turning it off is always possible.
    final canToggle = a != null && !_busy && (on || a.supported);
    return Padding(
      key: const Key('update-auto'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingRow(
          id: 'update-auto',
          title: l.updateAutoTitle,
          help: l.updateAutoHelp,
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            // A mechanism of our own (D-94): the keys carried across the restart, the install without the owner.
            const ExperimentalTag(key: Key('experimental-update-auto')),
            const SizedBox(width: 8),
            Switch(key: const Key('update-auto-switch'), value: on, onChanged: canToggle ? _set : null),
          ]),
        ),
        if (a != null && !a.supported)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l.updateAutoUnsupported(a.unsupportedReason ?? ''),
              key: const Key('update-auto-unsupported'),
              style: XText.bodyDim.copyWith(color: XColors.warn),
            ),
          ),
        if (_error case final e?) ErrorLine(describeAutoUpdateError(l, e), key: const Key('update-auto-error')),
        if (a != null) ..._facts(l, a),
      ]),
    );
  }

  List<Widget> _facts(AppLocalizations l, UpdateAutoInfo a) {
    String when(int ms) => formatDateTime(l, DateTime.fromMillisecondsSinceEpoch(ms));
    final s = a.staged;
    final last = a.last;
    return [
      if (a.enabled || s != null || last != null || a.failed.isNotEmpty) const SizedBox(height: 8),
      if (s != null)
        FactRow(
          l.updateAutoFactStaged,
          switch (s.state) {
            'installing' => l.updateAutoStagedInstalling(s.version),
            'soon' when s.atMs != null => l.updateAutoStagedSoon(s.version, hhmm(DateTime.fromMillisecondsSinceEpoch(s.atMs!))),
            // With the setting off only the daily check stages a release, and it waits for the owner (D-137).
            _ when !a.enabled => l.updateAutoStagedWaiting(s.version),
            _ => s.source == 'url' || s.contact == null
                ? l.updateAutoStagedUrl(s.version)
                : l.updateAutoStagedFrom(s.version, s.contact!),
          },
          key: const Key('update-auto-staged'),
          valueColor: XColors.accent,
        ),
      if (last != null)
        FactRow(
          l.updateAutoFactLast,
          switch (last.result) {
            'installed' => last.unlocked == false
                ? l.updateAutoLastInstalledLocked(last.version, when(last.atMs))
                : l.updateAutoLastInstalled(last.version, when(last.atMs)),
            'failed' => l.updateAutoLastFailed(last.version, when(last.atMs), last.reason ?? ''),
            _ => l.updateAutoLastRefused(last.version, when(last.atMs), last.reason ?? ''),
          },
          key: const Key('update-auto-last'),
          valueColor: last.result == 'installed' ? XColors.ok : XColors.warn,
        ),
      if (a.failed.isNotEmpty)
        FactRow(l.updateAutoFactNoRetry, a.failed.join(', '), key: const Key('update-auto-failed'), valueColor: XColors.warn),
      if (a.url case final u?)
        FactRow(
          l.updateAutoFactUrl,
          a.lastCheckMs == null ? u : l.updateAutoUrlChecked(u, when(a.lastCheckMs!)),
        ),
    ];
  }
}
