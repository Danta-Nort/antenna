// SPDX-License-Identifier: AGPL-3.0-only
// Updates that install by themselves (x-control/7, D-103, CONTROL §23), the `updated` fact in `status`, the agent's own
// facts for the window that started it (`agent_watch`, `message_fact`), and the name check of a received file
// (`file_name_check`, CONTROL §14): a part of models.dart, which holds the shared parsing helpers.

part of 'models.dart';

/// A verified release the daemon will install when agents are idle (`staged`).
final class StagedUpdate {
  const StagedUpdate({
    required this.version,
    required this.source,
    required this.stagedMs,
    required this.state,
    this.contact,
    this.atMs,
  });

  factory StagedUpdate.fromJson(Json j) => StagedUpdate(
        version: _str(j, 'version'),
        source: _optStr(j, 'source') ?? '',
        contact: _optStr(j, 'contact'),
        stagedMs: _optInt(j, 'staged_ms') ?? 0,
        state: _optStr(j, 'state') ?? 'waiting',
        atMs: _optInt(j, 'at_ms'),
      );

  /// Release version (`0.1.0-preview.9`).
  final String version;

  /// `link` (release files from a level-5 contact) or `url` (the daily check).
  final String source;

  /// The contact's label, for `source: "link"`.
  final String? contact;
  final int stagedMs;

  /// `waiting` (for 10 minutes without agent activity), `soon` (installs at [atMs]), `installing`.
  final String state;

  /// With `soon`: when the install starts; with `waiting` after "Later": not before then.
  final int? atMs;
}

/// One automatic install, refusal or failure.
final class UpdateRecord {
  const UpdateRecord({
    required this.version,
    required this.result,
    required this.source,
    required this.atMs,
    this.reason,
    this.contact,
    this.from,
    this.unlocked,
  });

  factory UpdateRecord.fromJson(Json j) => UpdateRecord(
        version: _str(j, 'version'),
        result: _str(j, 'result'),
        reason: _optStr(j, 'reason'),
        source: _optStr(j, 'source') ?? '',
        contact: _optStr(j, 'contact'),
        from: _optStr(j, 'from'),
        unlocked: j['unlocked'] is bool ? j['unlocked']! as bool : null,
        atMs: _optInt(j, 'at_ms') ?? 0,
      );

  final String version;

  /// `installed`, `failed` (the old version runs), `refused` (did not verify, not for this computer).
  final String result;

  /// For `failed` and `refused`: `<code>: <text>` from the daemon (English).
  final String? reason;
  final String source;
  final String? contact;

  /// The version installed before (`installed`).
  final String? from;

  /// For `installed`: the keys came across the restart.
  final bool? unlocked;
  final int atMs;
}

/// `update_auto`: the setting of this computer and what the daemon did (reply to `update_auto_*`).
final class UpdateAutoInfo {
  const UpdateAutoInfo({
    required this.enabled,
    required this.supported,
    this.unsupportedReason,
    this.keysKept = false,
    this.url,
    this.lastCheckMs,
    this.staged,
    this.last,
    this.failed = const [],
    this.history = const [],
  });

  factory UpdateAutoInfo.fromJson(Json j) => UpdateAutoInfo(
        enabled: _bool(j, 'enabled'),
        supported: _bool(j, 'supported'),
        unsupportedReason: _optStr(j, 'unsupported_reason'),
        keysKept: _bool(j, 'keys_kept'),
        url: _optStr(j, 'url'),
        lastCheckMs: _optInt(j, 'last_check_ms'),
        staged: j['staged'] is Map<String, Object?> ? StagedUpdate.fromJson(_obj(j, 'staged')) : null,
        last: j['last'] is Map<String, Object?> ? UpdateRecord.fromJson(_obj(j, 'last')) : null,
        failed: _strList(j, 'failed'),
        history: [for (final r in _list(j, 'history')) UpdateRecord.fromJson(r)],
      );

  /// "Install signed updates by itself" is on for this computer (off by default).
  final bool enabled;

  /// This installation can replace itself; otherwise [unsupportedReason] says why (English, from the daemon).
  final bool supported;
  final String? unsupportedReason;

  /// The daemon holds the keys for the update's restart: the new version will come up unlocked.
  final bool keysKept;

  /// The update URL checked once a day, if one is configured.
  final String? url;
  final int? lastCheckMs;
  final StagedUpdate? staged;
  final UpdateRecord? last;

  /// Versions whose install failed here: never tried again by themselves.
  final List<String> failed;

  /// Recent records, newest first.
  final List<UpdateRecord> history;
}

final class UpdateAutoReply extends Reply {
  const UpdateAutoReply(this.info);
  final UpdateAutoInfo info;
}

/// The `update_auto` event (owner subscriptions of x-control/7): staged, soon, installing, refused, failed, postponed.
/// The window reads `update_auto_status` again for the whole picture.
final class UpdateAutoEvent extends XEvent {
  const UpdateAutoEvent({required this.state, required this.version, this.source = '', this.contact, this.atMs, this.reason});
  final String state;
  final String version;
  final String source;
  final String? contact;
  final int? atMs;
  final String? reason;
}

/// In `status` (x-control/7): this daemon process came up from an automatic update (D-103). Absent otherwise.
final class UpdatedInfo {
  const UpdatedInfo({required this.from, required this.to, required this.atMs, required this.unlocked});

  factory UpdatedInfo.fromJson(Json j) =>
      UpdatedInfo(from: _str(j, 'from'), to: _str(j, 'to'), atMs: _int(j, 'at_ms'), unlocked: _bool(j, 'unlocked'));

  /// The version before.
  final String from;

  /// The version now.
  final String to;

  /// When the new version came up (Unix ms).
  final int atMs;

  /// The keys came across the restart.
  final bool unlocked;
}

/// `file_name`: can a received file be accepted under this name (reply to `file_name_check`)?
final class FileNameCheck extends Reply {
  const FileNameCheck({required this.name, required this.state, this.suggestion, this.message});

  factory FileNameCheck.fromJson(Json j) => FileNameCheck(
        name: _optStr(j, 'name') ?? '',
        state: _str(j, 'state'),
        suggestion: _optStr(j, 'suggestion'),
        message: _optStr(j, 'message'),
      );

  /// The name as it would be saved (normalized), or the name given when it is `invalid`.
  final String name;

  /// `free`, `taken` (another file has this name, ignoring case), `same_file` (the same content is already there:
  /// accepting saves nothing new), `invalid` (the name breaks the naming rules). An unknown state counts as not free.
  final String state;

  /// With `taken`: a free name in the same folder (`report (2).pdf`).
  final String? suggestion;

  /// With `taken` and `invalid`: why (English, from the daemon).
  final String? message;

  bool get free => state == 'free';
  bool get taken => state == 'taken';
  bool get sameFile => state == 'same_file';
  bool get invalid => state == 'invalid';
}

/// `message_fact` (an agent's subscription, and `agent_watch` for the window that started the agent): an incoming
/// message the agent may read, without its text (SPEC §11). [contact] is the owner's label of the link.
final class MessageFactEvent extends XEvent {
  const MessageFactEvent({
    required this.contact,
    required this.id,
    required this.trust,
    required this.chars,
    this.receivedMs,
    this.urgent = false,
  });
  final String contact;
  final String id;
  final int trust;
  final int chars;
  final int? receivedMs;

  /// CONTROL §33: the owner's urgent message, honoured by the daemon (as `HistoryItem.urgent`).
  final bool urgent;
}
