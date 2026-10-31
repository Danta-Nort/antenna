// SPDX-License-Identifier: AGPL-3.0-only
// Installing an update from files: the CLI verifies the release (`antenna update --from … --dry-run`), the dialog
// shows what it found, and "Install and restart" hands the owner password to `antenna update --from … --yes
// --password-stdin`. The window shows only what the CLI says; it checks no signatures itself.

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';

import '../../host/updater.dart';
import '../../l10n/l10n.dart';
import '../../state/format.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../files/file_card.dart' show fileSizeLabel;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';

/// Picking the release manifest or its folder through the system dialog. Replaced in tests (`flutter test` has no
/// plugins).
abstract class UpdatePicker {
  /// [confirm] is the label of the system dialog's button.
  Future<String?> manifest(String confirm);
  Future<String?> folder(String confirm);

  static UpdatePicker instance = _SystemPicker();
}

class _SystemPicker implements UpdatePicker {
  @override
  Future<String?> manifest(String confirm) async => (await fs.openFile(
        acceptedTypeGroups: const [
          fs.XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
        confirmButtonText: confirm,
      ))
          ?.path;

  @override
  Future<String?> folder(String confirm) => fs.getDirectoryPath(confirmButtonText: confirm);
}

/// An `antenna update` failure in the window's language.
String describeUpdateError(AppLocalizations l, Object e) => switch (e) {
      UpdateException(code: UpdateErrorCode.noReleaseKey) => l.updateErrNoReleaseKey,
      UpdateException(code: UpdateErrorCode.badSignature) => l.updateErrBadSignature,
      UpdateException(code: UpdateErrorCode.badManifest) => l.updateErrBadManifest,
      UpdateException(code: UpdateErrorCode.notNewer) => l.updateErrNotNewer,
      UpdateException(code: UpdateErrorCode.wrongPlatform) => l.updateErrWrongPlatform,
      UpdateException(code: UpdateErrorCode.assetMissing) => l.updateErrAssetMissing,
      UpdateException(code: UpdateErrorCode.hashMismatch) => l.updateErrHashMismatch,
      UpdateException(code: UpdateErrorCode.unsupportedInstall) => l.updateErrUnsupportedInstall,
      UpdateException(code: UpdateErrorCode.daemonUnavailable) => l.updateErrDaemonUnavailable,
      UpdateException(code: UpdateErrorCode.locked) => l.errLocked,
      UpdateException(code: UpdateErrorCode.wrongPassword) => l.errWrongOwnerPassword,
      UpdateException(code: UpdateErrorCode.loginRequired) => l.errLoginRequired,
      UpdateException(code: UpdateErrorCode.installFailed) => l.updateErrInstallFailed,
      UpdateException(code: UpdateErrorCode.rollbackUnavailable) => l.updateErrRollbackUnavailable,
      UpdateException(code: UpdateErrorCode.noUpdateUrl) => l.updateErrNoUpdateUrl,
      UpdateException(code: UpdateErrorCode.fetchFailed) => l.updateErrFetchFailed,
      UpdateException(code: UpdateErrorCode.updateInProgress) => l.updateErrInProgress,
      UpdateException(code: UpdateErrorCode.timeout) => l.updateErrTimeout,
      UpdateException(code: UpdateErrorCode.noResult) => l.updateErrNoResult,
      UpdateException(code: UpdateErrorCode.startFailed) => l.updateErrStart,
      UpdateException(:final code) => l.updateErrOther(code),
      _ => l.updateErrOther('$e'),
    };

/// The CLI's own English message, shown under the localized one.
String? updateErrorDetail(Object e) => e is UpdateException && e.message.isNotEmpty ? e.message : null;

/// How the signature checked out, with its color.
(String, Color) signatureLook(AppLocalizations l, UpdateSignature s) {
  final id = s.keyIds.isEmpty ? '?' : shortKeyId(s.keyIds.first);
  if (!s.valid) return (l.updateNotSigned, XColors.danger);
  if (s.testKey) return (l.updateSignedByTest(id), XColors.warn);
  return (l.updateSignedBy(id), XColors.ok);
}

/// Pick the manifest ([folder] false) or the folder with the release, then open the update dialog.
Future<void> pickAndVerifyUpdate(BuildContext context, {required bool folder}) async {
  final confirm = context.l.updateChooserConfirm;
  final p = UpdatePicker.instance;
  final path = folder ? await p.folder(confirm) : await p.manifest(confirm);
  if (path == null || !context.mounted) return;
  await showUpdateDialog(context, [path]);
}

/// The update dialog for the release at [paths] (a folder, or the manifest).
Future<void> showUpdateDialog(BuildContext context, List<String> paths) =>
    showXDialog<void>(context, (_) => UpdateDialog(paths: paths));

enum _Stage { verifying, ready, installing, installed }

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.paths});
  final List<String> paths;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  _Stage _stage = _Stage.verifying;
  UpdateVerification? _v;
  UpdateInstalled? _done;
  Object? _error;

  AntennaUpdater? get _updater => AppScope.read(context).updater;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _verify());
  }

  Future<void> _verify() async {
    final u = _updater;
    if (u == null) return;
    try {
      final v = await u.verify(widget.paths);
      if (mounted) setState(() => _v = v);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _stage = _Stage.ready);
    }
  }

  Future<void> _install() async {
    final u = _updater;
    final v = _v;
    if (u == null || v == null) return;
    final l = context.l;
    final m = AppScope.read(context);
    // With Touch ID on, the CLI asks for one touch itself (D-131); when it does not go through, the password.
    if (m.touchIdReady) {
      setState(() {
        _stage = _Stage.installing;
        _error = null;
      });
      try {
        final r = await u.install(widget.paths, null);
        if (mounted) {
          setState(() {
            _done = r;
            _stage = _Stage.installed;
          });
        }
        return;
      } on UpdateException catch (e) {
        if (!mounted) return;
        setState(() => _stage = _Stage.ready);
        if (!_touchFellBack(e)) {
          setState(() => _error = e);
          return;
        }
      }
    }
    if (!mounted) return;
    final pw = await askOwnerPassword(
      context,
      action: l.updateInstallAction(v.release.version),
      detail: l.updateInstallDetail,
      cli: 'antenna update --from ${widget.paths.join(' ')} --yes',
    );
    if (pw == null || !mounted) return;
    setState(() {
      _stage = _Stage.installing;
      _error = null;
    });
    try {
      // On macOS the CLI quits this window before it answers; the window comes back after the update.
      final r = await u.install(widget.paths, pw);
      if (mounted) {
        setState(() {
          _done = r;
          _stage = _Stage.installed;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _stage = _Stage.ready;
        });
      }
    }
  }

  /// The CLI's touch did not go through (cancelled, unavailable, the password due…): it asks for the password then, and
  /// without a terminal says so (`bad_request` naming `--password-stdin`), or the daemon refused the proof.
  static bool _touchFellBack(UpdateException e) =>
      (e.code == 'bad_request' && e.message.contains('--password-stdin')) ||
      const {'password_required', 'proof_invalid', 'challenge_invalid', 'owner_key_unknown', 'owner_key_refused'}
          .contains(e.code);

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = _v;
    final installing = _stage == _Stage.installing;
    return PopScope(
      // The install runs: the dialog stays until the CLI answers (or quits the window).
      canPop: !installing,
      child: XDialogShell(
        key: const Key('update-dialog'),
        title: l.updateDialogTitle,
        icon: Icons.system_update_alt_rounded,
        width: 620,
        onClose: installing ? () {} : null,
        actions: [
          if (_stage == _Stage.installed)
            FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(l.commonClose))
          else ...[
            TextButton(
              onPressed: installing ? null : () => Navigator.of(context).maybePop(),
              child: Text(l.commonCancel),
            ),
            FilledButton.icon(
              key: const Key('update-install'),
              onPressed: _stage == _Stage.ready && (v?.installable ?? false) ? _install : null,
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              label: Text(l.updateInstallButton),
            ),
          ],
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_updater == null) Text(l.updateNoCli, style: XText.bodyDim),
          if (_stage == _Stage.verifying && _updater != null) _Busy(l.updateVerifying),
          if (v != null) _Verified(v),
          if (_stage == _Stage.installing) ...[
            const SizedBox(height: 16),
            _Busy(l.updateInstalling, key: const Key('update-installing')),
            const SizedBox(height: 8),
            Text(l.updateInstallingNote, style: XText.bodyDim),
          ],
          if (_done case final d?) ...[
            const SizedBox(height: 16),
            Text(
              l.updateInstalled(d.to.version),
              key: const Key('update-installed'),
              style: XText.body.copyWith(color: XColors.ok),
            ),
            if (d.log != null) ...[const SizedBox(height: 4), Text(l.updateLog(d.log!), style: XText.monoSmall)],
          ],
          if (_error case final e?) ErrorLine(describeUpdateError(l, e), key: const Key('update-error'), detail: updateErrorDetail(e)),
        ]),
      ),
    );
  }
}

/// What the CLI verified: version, channel, date, signature, the file and where it goes, its plan.
class _Verified extends StatelessWidget {
  const _Verified(this.v);
  final UpdateVerification v;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (sig, sigColor) = signatureLook(l, v.signature);
    final created = v.release.created;
    final install = v.install;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FactRow(l.updateFactVersion, v.release.version, valueColor: v.newer && v.signature.valid ? XColors.ok : null),
      FactRow(l.updateFactInstalled, v.current.label),
      if (v.release.channel.isNotEmpty) FactRow(l.updateFactChannel, v.release.channel),
      // The build date in UTC, as the manifest records it: the same date on every machine.
      if (created != null) FactRow(l.updateFactCreated, formatDate(l, created.toUtc())),
      FactRow(l.updateFactSignature, sig, valueColor: sigColor),
      if (v.asset case final a?) FactRow(l.updateFactFile, '${a.name} · ${fileSizeLabel(a.size)}'),
      if (install != null && install.supported && install.path != null) FactRow(l.updateFactTarget, install.path!),
      if (!v.newer)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l.updateNotNewer(v.current.version), style: XText.bodyDim.copyWith(color: XColors.warn)),
        ),
      if (install != null && !install.supported)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l.updateUnsupported(install.reason ?? ''), style: XText.bodyDim.copyWith(color: XColors.warn)),
        ),
      if (v.steps.isNotEmpty && v.installable) ...[
        const SizedBox(height: 16),
        Text(l.updatePlan, style: XText.label),
        const SizedBox(height: 4),
        // The CLI's plan, in its own words (English).
        for (final s in v.steps) Text('· $s', style: XText.monoSmall),
      ],
    ]);
  }
}

class _Busy extends StatelessWidget {
  const _Busy(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: XColors.accent)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.bodyDim)),
      ]);
}

/// On an accepted file that looks like a release manifest: once the CLI confirms its signature, "Signed Antenna
/// update `version` (verified)" and "Install" (the folder of the manifest goes to `--from`).
class UpdateManifestNotice extends StatelessWidget {
  const UpdateManifestNotice({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final checks = AppScope.of(context).manifestChecks;
    if (checks == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: checks,
      builder: (context, _) {
        final v = checks.verified(path);
        if (v == null || !v.signature.valid) return const SizedBox.shrink();
        final l = context.l;
        final ver = v.release.version;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(key: const Key('update-file-notice'), children: [
            Icon(Icons.verified_outlined, size: 15, color: XColors.ok),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                v.newer ? l.updateFileVerified(ver) : l.updateFileVerifiedNotNewer(ver),
                style: XText.meta.copyWith(color: XColors.ok),
              ),
            ),
            if (v.newer)
              TextButton(
                key: const Key('update-file-install'),
                // The manifest itself, not its folder: a link folder can hold other releases too. The CLI finds the
                // signature and the file for this installation next to it.
                onPressed: () => showUpdateDialog(context, [path]),
                child: Text(l.updateFileInstall),
              ),
          ]),
        );
      },
    );
  }
}

/// On a file in quarantine whose content hash (checked by the daemon on download) is an asset of a verified release
/// manifest.
class UpdateAssetNotice extends StatelessWidget {
  const UpdateAssetNotice({super.key, required this.blake3});
  final String blake3;

  @override
  Widget build(BuildContext context) {
    final checks = AppScope.of(context).manifestChecks;
    if (checks == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: checks,
      builder: (context, _) {
        final v = checks.releaseWithAsset(blake3);
        if (v == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(key: const Key('update-asset-notice'), children: [
            Icon(Icons.verified_outlined, size: 15, color: XColors.ok),
            const SizedBox(width: 8),
            Expanded(
              child: Text(context.l.updateFilePart(v.release.version), style: XText.meta.copyWith(color: XColors.ok)),
            ),
          ]),
        );
      },
    );
  }
}
