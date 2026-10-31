// SPDX-License-Identifier: AGPL-3.0-only
// "Antenna <version> is ready to install": one banner at the top of Files and in Settings → Updates whenever a release
// newer than the installed one can be installed (state/updates.dart, [readyRelease]): an accepted manifest in a link
// folder that the CLI verified, with this computer's file next to it (Install: the usual dialog and the owner
// password), or the release the daemon staged for the automatic install (Install now: `update_auto_now`, the daemon's
// checks are the same) or, with the setting off, staged by the daily check (Install: `update_auto_now` with the
// password, D-137). The release files' own cards keep their buttons; the banner only finds the release for the
// owner, wherever its files are in the list.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/auto_update.dart' show daemonVersionOf;
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/updates.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import 'update_dialog.dart';

class UpdateReadyBanner extends StatefulWidget {
  const UpdateReadyBanner({super.key, this.margin = const EdgeInsets.only(bottom: 16)});
  final EdgeInsetsGeometry margin;

  @override
  State<UpdateReadyBanner> createState() => _UpdateReadyBannerState();
}

class _UpdateReadyBannerState extends State<UpdateReadyBanner> {
  bool _busy = false;
  Object? _error;

  Future<void> _run(Future<Object?> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await op();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  /// Install now when the daemon keeps no keys for the restart: the password prompt (never a touch: the daemon opens
  /// the root key with the password, D-137). Returns the error or `null` (also when the owner cancels).
  Future<Object?> _installWithPassword(String version) async {
    final m = AppScope.read(context);
    final l = context.l;
    final (_, err) = await confirmOwner(
      context,
      action: l.updateReadyNowAction(version),
      detail: l.updateReadyNowDetail,
      touch: false,
      run: (auth) => m.updateAutoNow(auth: auth),
    );
    return err;
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final checks = m.manifestChecks;
    Widget body() {
      final r = readyRelease(
        files: m.allFiles,
        checks: checks,
        auto: m.updateAuto,
        running: daemonVersionOf(m.status?.daemon),
      );
      if (r == null) return const SizedBox.shrink();
      return _banner(context, r);
    }

    return checks == null ? body() : ListenableBuilder(listenable: checks, builder: (_, _) => body());
  }

  Widget _banner(BuildContext context, ReadyRelease r) {
    final m = AppScope.read(context);
    final l = context.l;
    final s = r.staged;
    final String note;
    final List<Widget> actions;
    if (s != null && s.state == 'installing') {
      note = l.updateReadyInstalling;
      actions = const [];
    } else if (s != null) {
      final at = s.atMs;
      // With the setting off the daily check only stages the release (D-137): it waits for the owner, and Install
      // takes the password so that the keys stay unlocked across the restart.
      final byItself = m.updateAuto?.enabled ?? false;
      final keysKept = m.updateAuto?.keysKept ?? false;
      note = !byItself
          ? l.updateReadyChecked
          : s.state == 'soon' && at != null
              ? l.updateReadySoon(hhmm(DateTime.fromMillisecondsSinceEpoch(at)))
              : l.updateReadyByItself;
      actions = [
        if (s.state == 'soon')
          TextButton(
            key: const Key('update-ready-later'),
            onPressed: _busy ? null : () => _run(m.updateAutoLater),
            child: Text(l.updateReadyLater),
          ),
        FilledButton(
          key: const Key('update-ready-now'),
          onPressed: _busy ? null : () => _run(keysKept ? m.updateAutoNow : () => _installWithPassword(r.version)),
          child: Text(byItself ? l.updateReadyNow : l.updateReadyInstall),
        ),
      ];
    } else {
      note = r.contact == null || r.contact!.isEmpty ? l.updateReadySigned : l.updateReadyFrom(r.contact!);
      actions = [
        FilledButton(
          key: const Key('update-ready-install'),
          // The manifest itself, as on its card: the CLI finds the signature and this computer's file next to it.
          onPressed: () => showUpdateDialog(context, [r.manifestPath!]),
          child: Text(l.updateReadyInstall),
        ),
      ];
    }
    return Container(
      key: const Key('update-ready'),
      margin: widget.margin,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: XColors.accentSoft,
        borderRadius: BorderRadius.circular(XRadius.l),
        border: Border.all(color: XColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.system_update_alt_rounded, size: 20, color: XColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.updateReadyTitle(r.version), key: const Key('update-ready-title'), style: XText.title),
              const SizedBox(height: 2),
              Text(note, key: const Key('update-ready-note'), style: XText.meta.copyWith(color: XColors.textDim)),
            ]),
          ),
          if (_busy || (s != null && s.state == 'installing'))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: XColors.accent)),
            ),
          ...[
            for (final a in actions) ...[const SizedBox(width: 8), a],
          ],
        ]),
        if (_error case final e?)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 32),
            child: Text(
              describeAutoUpdateError(l, e),
              key: const Key('update-ready-error'),
              style: XText.meta.copyWith(color: XColors.danger),
            ),
          ),
      ]),
    );
  }
}

/// An `update_auto_*` error in the window's language.
String describeAutoUpdateError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.unsupportedInstall, :final message) => l.updateAutoErrUnsupported(message),
      XControlException(code: XErrorCode.updateInProgress) => l.updateErrInProgress,
      XControlException(code: XErrorCode.notFound) => l.updateAutoErrNothingStaged,
      _ => describeError(l, e),
    };
