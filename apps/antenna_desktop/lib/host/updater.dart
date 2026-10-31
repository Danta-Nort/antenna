// SPDX-License-Identifier: AGPL-3.0-only
// Updates from the window: a client of `antenna update`, the CLI inside the app. Pure Dart (dart:io), no Flutter.
//
// The window never checks signatures or hashes itself: the CLI verifies the signed release manifest against the
// release key pinned in this build, checks the asset hashes and installs; the window shows what it says. With `--json`
// the CLI prints one JSON object on stdout (human progress goes to stderr); an error is
// `{"ok":false,"error":"<code>","message":"<English text>",…}` with a non-zero exit code. Nothing is reported as signed
// unless the CLI said `signature.valid == true`.
//
// Installing quits the window itself on macOS (the CLI stops the daemon, swaps the app, restarts the daemon and
// relaunches the window), so the install process is started detached with stdio: it survives the window's exit. The
// owner password goes only to the CLI's stdin, never into its arguments (visible to every process of the user) or its
// environment.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cli_install.dart' show CliCommandRunner, runWithTimeout;

/// Starts the install process detached from the window, with stdin/stdout/stderr connected (replaced in tests).
typedef DetachedStarter = Future<Process> Function(String exe, List<String> args);

Future<Process> startDetachedWithStdio(String exe, List<String> args) =>
    Process.start(exe, args, mode: ProcessStartMode.detachedWithStdio);

/// Error codes of `antenna update` (the `error` field), plus the window's own ones at the end.
abstract final class UpdateErrorCode {
  static const noReleaseKey = 'no_release_key';
  static const badSignature = 'bad_signature';
  static const badManifest = 'bad_manifest';
  static const notNewer = 'not_newer';
  static const wrongPlatform = 'wrong_platform';
  static const assetMissing = 'asset_missing';
  static const hashMismatch = 'hash_mismatch';
  static const unsupportedInstall = 'unsupported_install';
  static const daemonUnavailable = 'daemon_unavailable';
  static const locked = 'locked';
  static const wrongPassword = 'wrong_password';
  static const loginRequired = 'login_required';
  static const installFailed = 'install_failed';
  static const rollbackUnavailable = 'rollback_unavailable';
  static const noUpdateUrl = 'no_update_url';
  static const fetchFailed = 'fetch_failed';
  static const updateInProgress = 'update_in_progress';

  /// The CLI printed no JSON result (a CLI without `update`, a crash, a killed process); the message is its stderr.
  static const noResult = 'no_result';

  /// The CLI did not answer in time.
  static const timeout = 'timeout';

  /// The CLI could not be started.
  static const startFailed = 'start_failed';
}

/// An `antenna update` failure: the code (the UI turns it into text in the window's language) and the CLI's own
/// English message, shown as details.
final class UpdateException implements Exception {
  const UpdateException(this.code, [this.message = '']);
  final String code;
  final String message;

  @override
  String toString() => 'UpdateException($code${message.isEmpty ? '' : ': $message'})';
}

/// A JSON object from the CLI.
typedef UpdateJson = Map<String, Object?>;

UpdateJson _obj(UpdateJson j, String k) => j[k] is Map ? (j[k]! as Map).cast<String, Object?>() : const {};
UpdateJson? _optObj(UpdateJson j, String k) => j[k] is Map ? (j[k]! as Map).cast<String, Object?>() : null;
String _str(UpdateJson j, String k) => j[k] is String ? j[k]! as String : '';
String? _optStr(UpdateJson j, String k) => j[k] is String ? j[k]! as String : null;
int _int(UpdateJson j, String k) => j[k] is int ? j[k]! as int : 0;
List<Object?> _list(UpdateJson j, String k) => j[k] is List ? j[k]! as List<Object?> : const [];
List<String> _strs(UpdateJson j, String k) => [for (final x in _list(j, k)) if (x is String) x];

/// The first 8 hex of a key ID: how the window names a release key.
String shortKeyId(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// A build of Antenna: `current`, `previous`, `from`, `to`.
final class UpdateBuild {
  const UpdateBuild({required this.version, this.commit = ''});
  factory UpdateBuild.fromJson(UpdateJson j) => UpdateBuild(version: _str(j, 'version'), commit: _str(j, 'commit'));
  final String version;
  final String commit;

  /// `0.1.0-preview.2 (47cb9fa68c07)`.
  String get label => commit.isEmpty ? version : '$version ($commit)';
}

/// How this copy of Antenna is installed (`install`).
enum UpdateInstallKind {
  /// `Antenna.app` on macOS.
  macosApp,

  /// Binaries in a directory (the Linux archive).
  binDir,

  /// The CLI cannot update this installation: `reason` says why.
  unsupported,
}

final class UpdateTarget {
  const UpdateTarget({required this.kind, this.path, this.reason});
  factory UpdateTarget.fromJson(UpdateJson j) => UpdateTarget(
        kind: switch (_str(j, 'kind')) {
          'macos_app' => UpdateInstallKind.macosApp,
          'bin_dir' => UpdateInstallKind.binDir,
          _ => UpdateInstallKind.unsupported,
        },
        path: _optStr(j, 'path'),
        reason: _optStr(j, 'reason'),
      );
  final UpdateInstallKind kind;
  final String? path;

  /// For `unsupported`: an English sentence from the CLI.
  final String? reason;

  bool get supported => kind != UpdateInstallKind.unsupported;
}

/// Release keys pinned in this build (`keys`).
final class UpdateKeys {
  const UpdateKeys({required this.pinned, this.ids = const [], this.testKey = false});
  factory UpdateKeys.fromJson(UpdateJson j) =>
      UpdateKeys(pinned: _int(j, 'pinned'), ids: _strs(j, 'ids'), testKey: j['test_key'] == true);
  final int pinned;
  final List<String> ids;

  /// The pinned key is a development test key.
  final bool testKey;
}

/// `antenna update --json`.
final class UpdateStatus {
  const UpdateStatus({
    required this.current,
    required this.install,
    required this.keys,
    this.previous,
    this.updateUrl,
    this.log,
  });

  factory UpdateStatus.fromJson(UpdateJson j) => UpdateStatus(
        current: UpdateBuild.fromJson(_obj(j, 'current')),
        install: UpdateTarget.fromJson(_obj(j, 'install')),
        previous: switch (_optObj(j, 'previous')) { final p? => UpdateBuild.fromJson(p), null => null },
        keys: UpdateKeys.fromJson(_obj(j, 'keys')),
        updateUrl: _optStr(j, 'update_url'),
        log: _optStr(j, 'log'),
      );

  final UpdateBuild current;
  final UpdateTarget install;

  /// What a rollback would return to; `null` when there is nothing.
  final UpdateBuild? previous;
  final UpdateKeys keys;

  /// `null` when no update URL is configured (then there is nothing to check online).
  final String? updateUrl;
  final String? log;
}

/// The release a manifest describes (`update`).
final class UpdateRelease {
  const UpdateRelease({required this.version, this.channel = '', this.commit = '', this.created, this.manifest});
  factory UpdateRelease.fromJson(UpdateJson j) => UpdateRelease(
        version: _str(j, 'version'),
        channel: _str(j, 'channel'),
        commit: _str(j, 'commit'),
        created: DateTime.tryParse(_str(j, 'created')),
        manifest: _optStr(j, 'manifest'),
      );
  final String version;
  final String channel;
  final String commit;
  final DateTime? created;
  final String? manifest;
}

/// The manifest signature as the CLI checked it (`signature`).
final class UpdateSignature {
  const UpdateSignature({required this.valid, this.keyIds = const [], this.testKey = false});
  factory UpdateSignature.fromJson(UpdateJson j) =>
      UpdateSignature(valid: j['valid'] == true, keyIds: _strs(j, 'key_ids'), testKey: j['test_key'] == true);

  /// Strictly the JSON `true`: anything else is "not verified".
  final bool valid;
  final List<String> keyIds;
  final bool testKey;
}

/// A release file listed in the manifest (`assets[]`, `asset`).
final class UpdateAsset {
  const UpdateAsset({
    required this.name,
    this.os = '',
    this.arch = '',
    this.kind = '',
    this.size = 0,
    this.sha256 = '',
    this.blake3 = '',
    this.path,
    this.url,
  });
  factory UpdateAsset.fromJson(UpdateJson j) => UpdateAsset(
        name: _str(j, 'name'),
        os: _str(j, 'os'),
        arch: _str(j, 'arch'),
        kind: _str(j, 'kind'),
        size: _int(j, 'size'),
        sha256: _str(j, 'sha256'),
        blake3: _str(j, 'blake3'),
        path: _optStr(j, 'path'),
        url: _optStr(j, 'url'),
      );
  final String name;
  final String os;
  final String arch;
  final String kind;
  final int size;
  final String sha256;
  final String blake3;

  /// The local file (`verify`).
  final String? path;

  /// Where to download it (`check`).
  final String? url;
}

/// `verify` (`--dry-run` / `--manifest-only`) and `check`: what the manifest says and what the CLI found.
final class UpdateVerification {
  const UpdateVerification({
    required this.action,
    required this.current,
    required this.release,
    required this.newer,
    required this.signature,
    this.assets = const [],
    this.asset,
    this.install,
    this.steps = const [],
    this.log,
    this.url,
  });

  factory UpdateVerification.fromJson(UpdateJson j) => UpdateVerification(
        action: _str(j, 'action'),
        current: UpdateBuild.fromJson(_obj(j, 'current')),
        release: UpdateRelease.fromJson(_obj(j, 'update')),
        newer: j['newer'] == true,
        signature: UpdateSignature.fromJson(_obj(j, 'signature')),
        assets: [for (final a in _list(j, 'assets')) if (a is Map) UpdateAsset.fromJson(a.cast<String, Object?>())],
        asset: switch (_optObj(j, 'asset')) { final a? => UpdateAsset.fromJson(a), null => null },
        install: switch (_optObj(j, 'install')) { final i? => UpdateTarget.fromJson(i), null => null },
        steps: _strs(j, 'steps'),
        log: _optStr(j, 'log'),
        url: _optStr(j, 'url'),
      );

  /// `verify` or `check`.
  final String action;
  final UpdateBuild current;
  final UpdateRelease release;
  final bool newer;
  final UpdateSignature signature;
  final List<UpdateAsset> assets;

  /// The file for this computer; `null` when it was not found (`--manifest-only`) or not offered (`check`).
  final UpdateAsset? asset;
  final UpdateTarget? install;

  /// The CLI's plan, in English.
  final List<String> steps;
  final String? log;

  /// `check`: the manifest URL.
  final String? url;

  /// Signed by a pinned key, newer, the file for this computer found, and the installation can be updated.
  bool get installable => signature.valid && newer && asset != null && (install?.supported ?? false);
}

/// `install`: what was replaced with what.
final class UpdateInstalled {
  const UpdateInstalled({
    required this.from,
    required this.to,
    this.daemonRestarted = false,
    this.appRelaunched = false,
    this.keysLocked = true,
    this.log,
  });

  factory UpdateInstalled.fromJson(UpdateJson j) => UpdateInstalled(
        from: UpdateBuild.fromJson(_obj(j, 'from')),
        to: UpdateBuild.fromJson(_obj(j, 'to')),
        daemonRestarted: _obj(j, 'daemon')['restarted'] == true,
        appRelaunched: _obj(j, 'app')['relaunched'] == true,
        keysLocked: j['keys_locked'] != false,
        log: _optStr(j, 'log'),
      );

  final UpdateBuild from;
  final UpdateBuild to;
  final bool daemonRestarted;
  final bool appRelaunched;

  /// The daemon was restarted, so the keys are locked until the owner unlocks them.
  final bool keysLocked;
  final String? log;
}

/// The JSON object the CLI printed: the whole stdout or, failing that, its last line that is an object.
UpdateJson? _decode(String out) {
  Object? tryJson(String s) {
    try {
      return json.decode(s);
    } on FormatException {
      return null;
    }
  }

  var j = tryJson(out.trim());
  if (j is! Map) {
    final lines = out.split('\n').map((s) => s.trim()).where((s) => s.startsWith('{')).toList();
    j = lines.isEmpty ? null : tryJson(lines.last);
  }
  return j is Map ? j.cast<String, Object?>() : null;
}

/// The last lines of stderr: the reason when there is no JSON (for example, a CLI that has no `update` yet).
String _tail(String err) {
  final lines = err.trim().split('\n').where((s) => s.trim().isNotEmpty).toList();
  return lines.skip(lines.length > 3 ? lines.length - 3 : 0).join('\n');
}

/// The CLI result: the JSON object when `ok` is `true`, otherwise an [UpdateException] with the CLI's code.
/// [exitCode] is `null` for the detached install, which has none.
UpdateJson _result(String out, String err, int? exitCode) {
  final j = _decode(out);
  if (j == null) {
    throw UpdateException(
      exitCode == -1 ? UpdateErrorCode.timeout : UpdateErrorCode.noResult,
      _tail(err).isEmpty && exitCode != null ? 'exit $exitCode' : _tail(err),
    );
  }
  if (j['ok'] != true) {
    final code = _str(j, 'error');
    throw UpdateException(code.isEmpty ? UpdateErrorCode.noResult : code, _str(j, 'message'));
  }
  if (exitCode != null && exitCode != 0) throw UpdateException(UpdateErrorCode.noResult, 'exit $exitCode');
  return j;
}

/// `antenna update` from the window. [cliPath] is the CLI inside the app (`CoreBinaries.cli`).
final class AntennaUpdater {
  AntennaUpdater({
    required this.cliPath,
    CliCommandRunner? runner,
    DetachedStarter? starter,
    this.timeout = const Duration(minutes: 2),
    this.installTimeout = const Duration(minutes: 15),
  })  : _runner = runner ?? runWithTimeout,
        _starter = starter ?? startDetachedWithStdio;

  final String cliPath;
  final CliCommandRunner _runner;
  final DetachedStarter _starter;

  /// For status, verify and check (hashing a ~50 MB disk image, fetching a manifest).
  final Duration timeout;

  /// How long the window waits for the install's result; the install itself is not stopped.
  final Duration installTimeout;

  static List<String> statusArgs() => const ['update', '--json'];

  static List<String> verifyArgs(List<String> paths, {bool manifestOnly = false}) =>
      ['update', '--from', ...paths, manifestOnly ? '--manifest-only' : '--dry-run', '--json'];

  static List<String> checkArgs() => const ['update', '--check', '--json'];

  /// [touchId]: the CLI asks for Touch ID itself (D-131, CONTROL §22.7) instead of reading the password from stdin.
  static List<String> installArgs(List<String> paths, {bool touchId = false}) =>
      ['update', '--from', ...paths, '--yes', touchId ? '--touch-id' : '--password-stdin', '--json'];

  Future<UpdateJson> _run(List<String> args) async {
    final ProcessResult r;
    try {
      r = await _runner(cliPath, args, timeout: timeout);
    } on ProcessException catch (e) {
      throw UpdateException(UpdateErrorCode.startFailed, e.message);
    }
    return _result('${r.stdout}', '${r.stderr}', r.exitCode);
  }

  /// What is installed, how, the pinned release keys, the update URL.
  Future<UpdateStatus> status() async => UpdateStatus.fromJson(await _run(statusArgs()));

  /// Verify a release without installing: [paths] is a folder or the manifest, its `.sig` and the asset. With
  /// [manifestOnly], only the manifest signature is checked (the asset may be missing, and a version that is not
  /// newer is not an error).
  Future<UpdateVerification> verify(List<String> paths, {bool manifestOnly = false}) async =>
      UpdateVerification.fromJson(await _run(verifyArgs(paths, manifestOnly: manifestOnly)));

  /// Fetch and verify the manifest from the configured update URL.
  Future<UpdateVerification> check() async => UpdateVerification.fromJson(await _run(checkArgs()));

  /// Install the release at [paths]. The CLI reads [password] from stdin; with none, it asks for Touch ID itself
  /// (`--touch-id`, D-131) and fails, asking for the password, when the touch does not go through. On macOS it quits
  /// this window before it finishes; if it fails before that, the error comes back here.
  Future<UpdateInstalled> install(List<String> paths, String? password) async {
    final Process p;
    try {
      p = await _starter(cliPath, installArgs(paths, touchId: password == null));
    } on ProcessException catch (e) {
      throw UpdateException(UpdateErrorCode.startFailed, e.message);
    }
    const text = Utf8Decoder(allowMalformed: true);
    final out = p.stdout.transform(text).join();
    // stderr is drained so that the CLI never blocks on a full pipe.
    final err = p.stderr.transform(text).join();
    // The CLI may exit before reading stdin (a bad argument): the broken pipe is not the error to show, its JSON is.
    unawaited(p.stdin.done.then((_) {}, onError: (Object _) {}));
    try {
      if (password != null) p.stdin.add(utf8.encode('$password\n'));
      await p.stdin.flush();
      await p.stdin.close();
    } on Object {
      // See above.
    }
    final String o;
    try {
      o = await out.timeout(installTimeout);
    } on TimeoutException {
      throw const UpdateException(UpdateErrorCode.timeout);
    }
    final e = await err.timeout(const Duration(seconds: 2), onTimeout: () => '');
    // A detached process has no exit code: the JSON on stdout is the result.
    return UpdateInstalled.fromJson(_result(o, e, null));
  }
}
