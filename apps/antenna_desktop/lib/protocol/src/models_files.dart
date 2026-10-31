// SPDX-License-Identifier: AGPL-3.0-only
// File models (x-control/3, CONTROL §14): a part of models.dart, which holds the shared parsing helpers.

part of 'models.dart';

/// A finding of the file check.
final class FileFinding {
  const FileFinding({required this.code, required this.severity, required this.detail});

  factory FileFinding.fromJson(Json j) =>
      FileFinding(code: _str(j, 'code'), severity: _optStr(j, 'severity') ?? 'info', detail: _optStr(j, 'detail') ?? '');

  /// `eicar`, `archive_bomb`, `secret:private_key`, `pdf_javascript`…
  final String code;

  /// `info` / `warn` / `threat`.
  final String severity;

  /// The daemon's explanation (in English, without file contents).
  final String detail;
}

/// A file in quarantine or a sent file (`FileInfo`). [name] is **contact data** (the daemon has escaped invisible
/// and control characters): display it as plain text, without markup.
final class FileInfo {
  const FileInfo({
    required this.id,
    required this.contact,
    required this.linkId,
    required this.direction,
    required this.name,
    required this.size,
    required this.blake3,
    required this.state,
    required this.createdMs,
    this.senderMime = '',
    this.senderVerdict = '',
    this.verdict,
    this.mime,
    this.findings = const [],
    this.sandbox,
    this.dest,
    this.savedAs,
    this.savedPath,
    this.messageId,
    this.expiresMs,
    this.reason,
    this.withdrawal,
    this.duplicate = false,
    this.held,
    this.labels = const [],
    this.fileClass,
  });

  factory FileInfo.fromJson(Json j) => FileInfo(
        id: _str(j, 'id'),
        contact: _optStr(j, 'contact') ?? '',
        linkId: _optStr(j, 'link_id') ?? '',
        direction: _optStr(j, 'direction') ?? 'in',
        name: _optStr(j, 'name') ?? '',
        size: _optInt(j, 'size') ?? 0,
        blake3: _optStr(j, 'blake3') ?? '',
        senderMime: _optStr(j, 'sender_mime') ?? '',
        senderVerdict: _optStr(j, 'sender_verdict') ?? '',
        state: _str(j, 'state'),
        verdict: _optStr(j, 'verdict'),
        mime: _optStr(j, 'mime'),
        findings: [for (final f in _list(j, 'findings')) FileFinding.fromJson(f)],
        sandbox: _optStr(j, 'sandbox'),
        dest: _optStr(j, 'dest'),
        savedAs: _optStr(j, 'saved_as'),
        savedPath: _optStr(j, 'saved_path'),
        messageId: _optStr(j, 'message_id'),
        createdMs: _optInt(j, 'created_ms') ?? 0,
        expiresMs: _optInt(j, 'expires_ms'),
        reason: _optStr(j, 'reason'),
        withdrawal: _optStr(j, 'withdrawal'),
        duplicate: _bool(j, 'duplicate'),
        held: j['held'] is Map<String, Object?> ? FileHeld.fromJson(_obj(j, 'held')) : null,
        labels: _strList(j, 'labels'),
        fileClass: _optStr(j, 'class'),
      );

  /// 32 hex; commands accept the first 8+.
  final String id;
  final String contact;
  final String linkId;

  /// `in`: from the contact, `out`: to the contact.
  final String direction;
  final String name;
  final int size;
  final String blake3;

  /// What the sender claimed: a hint only; the receiver checks.
  final String senderMime;
  final String senderVerdict;

  /// `offered` (downloading) → `downloaded` → `checked` → `accepted` / `rejected`; `refused` means refused based on
  /// the manifest; `sent` means outgoing; `withdrawn` (preview.5): the sender withdrew it before it was accepted. A
  /// sent file's fate (D-129, from the contact's receipt): `accepted` (saved), `held` (it waits for the contact's
  /// owner), `blocked` (the contact's node refused it or its check holds it), `rejected` (the contact's owner or agent
  /// said no); [held] says why when the contact's node tells.
  final String state;

  /// `clean` / `suspicious` / `threat` / `failed` (after the check).
  final String? verdict;

  /// Type by signature (determined on our side).
  final String? mime;
  final List<FileFinding> findings;

  /// How the check worker was isolated (`landlock=… seccomp=… rlimits=…`).
  final String? sandbox;

  /// After acceptance: `inbox` / `shared` / `project` and the name in the folder.
  final String? dest;
  final String? savedAs;

  /// After acceptance: the absolute path of the file (`saved_path`), when the daemon reports it. The window uses it
  /// only to ask the CLI about a received release manifest.
  final String? savedPath;

  /// The offer message in the link history.
  final String? messageId;
  final int createdMs;

  /// For a threat: when the record will be deleted.
  final int? expiresMs;

  /// For `refused`: `level_forbids_files`, `file_quota_exceeded`, `bad_manifest`.
  final String? reason;

  /// An outgoing `withdrawn` file (preview.5): `contact_notified` (the contact's node deleted its pending copy) or
  /// `contact_cannot_withdraw` (an older node: no longer served, but a copy it already downloaded stays there).
  final String? withdrawal;

  /// With `state: "accepted"` (preview.8): the same file (name ignoring case, size and BLAKE3) was already in the
  /// folder, so nothing new was saved; [savedAs] and [savedPath] name that file.
  final bool duplicate;

  /// v7 (D-128): a checked file from a level-5 contact the daemon could not save by itself, and why; it waits for
  /// the owner. A sent file `held` or `blocked` (D-129): the contact's node's reason and rules. An incoming checked
  /// file at levels 3–5 the own-computer rules hold (D-130): [FileHeld.holdsByRule].
  final FileHeld? held;

  /// v7 (D-130): finding codes of the check that did not hold the file (`active_content`, `polyglot_html`,
  /// `secret:api_key`): quiet labels, never a verdict.
  final List<String> labels;

  /// v7 (D-129, `class`): what the content is by the check: `code` (code and markup, all of it inspected; Antenna does
  /// not run it), `text`, `executable`, `installer`, `other`. Absent before the check and from an older daemon.
  final String? fileClass;

  /// Saved under another name than the contact's (`report (2).pdf`, D-128: another file had the name), as the
  /// daemon reports it.
  bool get renamed => savedAs != null && savedAs != name;

  /// A copy with a different state (an outgoing file updated by the contact's receipt; [savedAs]: the name the
  /// contact's node saved it under, when that is not the offered one; with [setHeld], [held] replaces the reason: why
  /// the contact's node holds or blocked it, `null` when its receipt gives none).
  FileInfo withState(String state, {String? withdrawal, String? savedAs, bool setHeld = false, FileHeld? held}) =>
      FileInfo(
        id: id,
        contact: contact,
        linkId: linkId,
        direction: direction,
        name: name,
        size: size,
        blake3: blake3,
        state: state,
        createdMs: createdMs,
        senderMime: senderMime,
        senderVerdict: senderVerdict,
        verdict: verdict,
        mime: mime,
        findings: findings,
        sandbox: sandbox,
        dest: dest,
        savedAs: savedAs ?? this.savedAs,
        savedPath: savedPath,
        messageId: messageId,
        expiresMs: expiresMs,
        reason: reason,
        withdrawal: withdrawal ?? this.withdrawal,
        duplicate: duplicate,
        held: setHeld ? held : this.held,
        labels: labels,
        fileClass: fileClass,
      );

  bool get incoming => direction != 'out';
  bool get decided => state == 'accepted' || state == 'rejected' || state == 'refused' || withdrawn;

  /// The sender withdrew it before the contact answered (preview.5).
  bool get withdrawn => state == 'withdrawn';

  /// Checked and awaiting the owner's decision.
  bool get awaitingDecision => incoming && state == 'checked';

  /// Can be accepted only with `force` and the owner password.
  bool get needsForce => verdict == 'threat' || verdict == 'failed';
}

/// Why the daemon did not save a level-5 file by itself (v7, D-128): the accept's error code and message. For a sent
/// file (D-129): why the contact's node holds or blocked it.
final class FileHeld {
  const FileHeld({required this.code, this.message = '', this.rules = const []});

  factory FileHeld.fromJson(Json j) =>
      FileHeld(code: _str(j, 'code'), message: _optStr(j, 'message') ?? '', rules: _strList(j, 'rules'));

  /// `file_name_taken`, `forbidden`, `internal`, … (CONTROL §10); for a sent file the contact's reason (`threat`,
  /// `executable`, `review`, `limit`, …).
  final String code;

  /// The daemon's explanation (in English, without the file's name or content).
  final String message;

  /// v7 (D-129): the check's rules that matched (finding codes), when the reason comes from the check.
  final List<String> rules;

  /// The reasons the own-computer rules hold an incoming checked file for the owner (D-129, D-130), as opposed to an
  /// accept's error code (D-128). Keeping such a file takes `force` and the owner password.
  static const ruleCodes = {'threat', 'executable', 'installer', 'uninspected', 'check_failed'};

  /// This hold comes from the rules (a program, an installer, an archive not opened whole, a threat, a failed check).
  bool get holdsByRule => ruleCodes.contains(code);
}

/// The `n`-th name the daemon gives a received file whose name is taken (D-128, `n` ≥ 2): `<stem> (n).<ext>`, a
/// double extension such as `.tar.gz` kept whole, a dot file and a name without an extension numbered at the end.
/// The same rule as the daemon's `numbered_name`, so a receipt's `name_number` reads as the name the contact's
/// folder has (the daemon also shortens names near 255 bytes; such a name reads approximately here).
String numberedFileName(String name, int n) {
  final lower = name.toLowerCase();
  var ext = '';
  for (final e in const ['.tar.gz', '.tar.xz', '.tar.bz2', '.tar.zst']) {
    if (lower.endsWith(e) && lower.length > e.length) {
      ext = name.substring(name.length - e.length);
      break;
    }
  }
  if (ext.isEmpty) {
    final dot = name.lastIndexOf('.');
    if (dot > 0) ext = name.substring(dot);
  }
  final stem = name.substring(0, name.length - ext.length).replaceAll(RegExp(r'[ .]+$'), '');
  return '$stem ($n)$ext';
}

/// Safe preview: text is sanitized; images and PDF pages are PNGs the daemon rebuilt from pixels with its own encoder
/// (nothing from the original file).
final class FilePreview {
  const FilePreview({required this.kind, this.text, this.imagesPng = const [], this.truncated = false, this.notice});

  factory FilePreview.fromJson(Json j) {
    final raw = j['images_png_base64'];
    final images = <Uint8List>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is String) {
          try {
            images.add(base64.decode(e));
          } on FormatException {
            throw const XProtocolException('field "images_png_base64": bad base64');
          }
        }
      }
    }
    return FilePreview(
      kind: _optStr(j, 'kind') ?? 'none',
      text: _optStr(j, 'text'),
      imagesPng: images,
      truncated: _bool(j, 'truncated'),
      notice: _optStr(j, 'notice'),
    );
  }

  /// `image` / `pdf` / `document` / `text` / `archive` / `none`.
  final String kind;
  final String? text;
  final List<Uint8List> imagesPng;
  final bool truncated;
  final String? notice;
}

/// `file`: a single file (reply to `share_file`, `file_accept`, `file_reject`, `file_withdraw`).
final class FileReply extends Reply {
  const FileReply(this.file);
  final FileInfo file;
}

/// `files`: reply to `files_pending`.
final class FilesReply extends Reply {
  const FilesReply(this.files);
  final List<FileInfo> files;
}

/// `file_preview`: the preview is `null` if there is none (a threat, a type without preview, the check did not run).
final class FilePreviewReply extends Reply {
  const FilePreviewReply({required this.file, this.preview});
  final FileInfo file;
  final FilePreview? preview;
}

/// `file_requested`: reply to `request_file`.
final class FileRequestedReply extends Reply {
  const FileRequestedReply({required this.contact, required this.id, required this.status});
  final String contact;
  final String id;
  final String status;
}

/// The `file` event: a file changed state (sent, refused by manifest, downloaded, checked, accepted, rejected,
/// withdrawn).
final class FileEvent extends XEvent {
  const FileEvent({required this.contact, required this.linkId, required this.file});
  final String contact;
  final String linkId;
  final FileInfo file;
}

/// A save folder for files from an own computer (v7, D-130): the contact's own ([agent] `null`) or one of its agents'.
final class SaveDir {
  const SaveDir({this.agent, required this.path});

  factory SaveDir.fromJson(Json j) => SaveDir(agent: _optStr(j, 'agent'), path: _str(j, 'path'));

  final String? agent;

  /// The folder, symlinks resolved when it was set.
  final String path;
}

/// `file_save_dir`: the contact's save folders after the change.
final class FileSaveDirsReply extends Reply {
  const FileSaveDirsReply({required this.contact, required this.linkId, this.dirs = const []});

  factory FileSaveDirsReply.fromJson(Json j) => FileSaveDirsReply(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        dirs: [for (final d in _list(j, 'dirs')) SaveDir.fromJson(d)],
      );

  final String contact;
  final String linkId;
  final List<SaveDir> dirs;
}

/// `file_allow` / `file_disallow`: the contact's allowlist after the change.
final class FileAllowReply extends Reply {
  const FileAllowReply({required this.contact, required this.linkId, this.entries = const []});

  factory FileAllowReply.fromJson(Json j) =>
      FileAllowReply(contact: _str(j, 'contact'), linkId: _str(j, 'link_id'), entries: _strList(j, 'entries'));

  final String contact;
  final String linkId;
  final List<String> entries;
}
