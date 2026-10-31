// SPDX-License-Identifier: AGPL-3.0-only
// Signed Antenna releases among received files. An accepted file named like a release manifest is checked by the CLI
// (`antenna update --from <path> --manifest-only`), lazily and once per path; only a manifest the CLI reports with
// `signature.valid == true` counts. A file still in quarantine whose BLAKE3 (verified by the daemon on download)
// equals an asset hash of such a manifest is part of that signed release.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/updater.dart';
import '../protocol/x_control.dart';
import 'auto_update.dart' show compareVersions;

final _manifestName = RegExp(r'^antenna-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-manifest\.json$');

/// The version in a release manifest file name (`antenna-0.1.0-preview.3-manifest.json` → `0.1.0-preview.3`), or
/// `null` for any other name. Only a hint for what to ask the CLI: the version shown comes from the CLI.
String? releaseManifestVersion(String fileName) => _manifestName.firstMatch(fileName)?.group(1);

class ManifestChecks extends ChangeNotifier {
  ManifestChecks(this.updater);

  final AntennaUpdater updater;

  /// Path → the verified manifest, or `null` when the CLI did not confirm the signature (or failed).
  final Map<String, UpdateVerification?> _done = {};
  final Set<String> _running = {};
  bool _disposed = false;

  /// The verified manifest at [path]; `null` while it is being checked or when it is not a signed release. The first
  /// call starts the check.
  UpdateVerification? verified(String path) {
    if (_done.containsKey(path)) return _done[path];
    if (_running.add(path)) unawaited(_check(path));
    return null;
  }

  Future<void> _check(String path) async {
    UpdateVerification? v;
    try {
      final r = await updater.verify([path], manifestOnly: true);
      v = r.signature.valid ? r : null;
    } on Object {
      v = null;
    }
    _running.remove(path);
    _done[path] = v;
    if (!_disposed) notifyListeners();
  }

  /// A verified release that lists an asset with this BLAKE3.
  UpdateVerification? releaseWithAsset(String blake3) {
    final h = blake3.toLowerCase();
    if (h.isEmpty) return null;
    for (final v in _done.values) {
      if (v != null && v.assets.any((a) => a.blake3.toLowerCase() == h)) return v;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A release the owner can install now: the "ready to install" banner at the top of Files and in Settings → Updates.
final class ReadyRelease {
  const ReadyRelease.manifest(this.version, String this.manifestPath, {this.contact}) : staged = null;
  ReadyRelease.staged(StagedUpdate s)
      : staged = s,
        version = s.version,
        manifestPath = null,
        contact = s.contact;

  final String version;

  /// The accepted manifest in a link folder: installed with the normal flow (the dialog, the owner password).
  final String? manifestPath;

  /// Who sent the manifest (the owner's label).
  final String? contact;

  /// Staged by the daemon for the automatic install (`update_auto_now` installs it at once).
  final StagedUpdate? staged;
}

/// Accepted files that look like a release manifest, with the path the daemon saved them at.
Iterable<FileInfo> acceptedManifests(Iterable<FileInfo> files) => files.where((f) =>
    f.incoming &&
    f.state == 'accepted' &&
    f.savedPath != null &&
    releaseManifestVersion(f.savedPath!.split('/').last) != null);

/// The newest release that can be installed here, or `null`. Candidates: an accepted manifest the CLI verified
/// ([ManifestChecks.verified], started here if not yet) that is signed by a pinned key, newer than the installed
/// version, with this computer's file next to it and an installation that can be updated; and the release the daemon
/// staged for the automatic install. A release that is installed already or older is never offered: besides the
/// CLI's own "newer", the daemon's running version ([running]) is compared too (a manifest checked before an install
/// is older than what runs after it). On equal versions the staged one wins: one click, no password.
ReadyRelease? readyRelease({
  required Iterable<FileInfo> files,
  required ManifestChecks? checks,
  UpdateAutoInfo? auto,
  String? running,
}) {
  bool newerThanRunning(String v) => running == null || (compareVersions(v, running) ?? 0) > 0;
  ReadyRelease? best;
  String? bestVersion;
  void offer(ReadyRelease r, String v) {
    if (!newerThanRunning(v)) return;
    final c = bestVersion == null ? 1 : compareVersions(v, bestVersion!);
    if (c == null || c < 0) return;
    if (c == 0 && best?.staged != null) return;
    best = r;
    bestVersion = v;
  }

  if (checks != null) {
    for (final f in acceptedManifests(files)) {
      final v = checks.verified(f.savedPath!);
      if (v == null || !v.installable) continue;
      offer(ReadyRelease.manifest(v.release.version, f.savedPath!, contact: f.contact), v.release.version);
    }
  }
  if (auto?.staged case final s?) offer(ReadyRelease.staged(s), s.version);
  return best;
}
