// SPDX-License-Identifier: AGPL-3.0-only
// Files in the window (x-control/3, CONTROL §14): quarantine of incoming files, owner decisions, sending. The daemon
// makes all decisions and stores everything; the window keeps in memory only the last known state
// (`files_pending --all` + `file` events), what is being sent right now (until the `share_file` reply), and the files
// waiting in the composer for Send (attached, dropped or pasted; nothing leaves before Send), per chat (drafts.dart):
// a file attached in one chat never goes out with Send in another.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../host/app_connect.dart';
import '../host/image_actions.dart';
import '../host/outgoing_staging.dart';
import '../host/sent_previews.dart';
import '../protocol/x_control.dart';
import 'drafts.dart';
import 'owner_auth.dart';
import 'threads.dart';

/// Where an accepted file goes, by trust level (CONTROL §14, "Who can do what"): 2 → `inbox/`, 3–4 → `shared/`,
/// 5 → the project folder; 1 has no files at all.
String? fileDestForLevel(int level) => switch (level) {
      2 => 'inbox',
      3 || 4 => 'shared',
      5 => 'project',
      _ => null,
    };

/// A send the daemon has not accepted yet: it hashes and encrypts the file before replying to `share_file`.
class OutgoingFile {
  OutgoingFile(
      {required this.localId,
      required this.linkId,
      required this.path,
      required this.at,
      this.staged = false,
      this.origin});

  final String localId;
  final String linkId;
  final String path;
  final DateTime at;

  /// [path] is the window's copy (`OutgoingStaging`): deleted once the daemon has it or the send is dismissed.
  final bool staged;

  /// Where the person's file was, when [path] is a copy of it.
  final String? origin;

  /// The daemon's secret scanner stopped the send: owner approval (password) is needed, then a retry with this ID.
  String? approvalId;

  /// The daemon error (code and message).
  Object? error;
  bool busy = true;

  String get name => path.split(RegExp(r'[/\\]')).last;
}

/// The card of an offer the daemon keeps no record of any more (the sender withdrew it and this node deleted its
/// copy, so `files_pending` no longer lists it), built from its history line, CONTROL §14:
/// `file: <name> (<size> bytes, <mime>, blake3 <16 hex>)`. `null` for any other text.
FileInfo? withdrawnOfferFrom(HistoryItem m) {
  final x = RegExp(r'^file: (.*) \((\d+) bytes, ([^,]*), blake3 ([0-9a-f]+)\)$', dotAll: true).firstMatch(m.text);
  final size = x == null ? null : int.tryParse(x[2]!);
  if (x == null || size == null) return null;
  return FileInfo(
    id: m.id,
    contact: '',
    linkId: '',
    direction: m.direction,
    name: x[1]!,
    size: size,
    blake3: x[4]!,
    senderMime: x[3]!,
    state: 'withdrawn',
    createdMs: m.ts,
    messageId: m.id,
  );
}

/// A sent file's fate from the contact's receipt about it (D-129): `accept_file` / `accepted` saved it; `check_file`
/// / `held` holds it for the contact's owner; `reject_file` / `denied` is the contact's node: its check holds it (a
/// threat waits there for its owner, kept 7 days) or its limits refused it, never a person's answer; `reject_file` /
/// `rejected` (or any other decision) is the contact's owner or agent saying no. `null`: not about a file's fate.
String? sentFileFate(ReceiptInfo r) => switch ((r.action, r.decision)) {
      ('accept_file', 'accepted' || 'allowed') => 'accepted',
      ('check_file', 'held') => 'held',
      ('reject_file', 'denied') => 'blocked',
      ('reject_file', _) => 'rejected',
      _ => null,
    };

/// How far a sent file has got: its state only moves forward, whatever order the receipts arrive in. A hold is not
/// a decision: the contact's owner may still accept a held file, or one its check blocked (a threat, with the
/// password), so `accepted` comes after both.
int sentFileRank(String state) => switch (state) {
      'held' => 1,
      'blocked' => 2,
      'rejected' => 3,
      'accepted' => 4,
      _ => 0,
    };

/// A file waiting in the composer for Send: the window's copy (`OutgoingStaging`), or the person's own file when it is
/// too large to copy. A send the daemon refused keeps it here, with the error or the approval it needs.
class StagedAttachment {
  StagedAttachment({required this.id, required this.file, this.size});

  /// A local ID (chip keys).
  final String id;
  final StagedFile file;

  /// Bytes, when known.
  final int? size;

  /// Being sent now (the daemon hashes and encrypts before it replies).
  bool busy = false;

  /// The daemon's error for the last send (code and message).
  Object? error;

  /// The secret scanner stopped the send: the owner approves (password), then a retry with this ID.
  String? approvalId;

  /// The name the contact sees: the file's own (a copy keeps it).
  String get name => file.path.split('/').last;

  /// An image the chip can show as a thumbnail (by its name; anything else gets an icon).
  bool get isImage => RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(name);
}

mixin FilesMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  /// The chat on screen for a link: files staged now wait in its draft.
  ThreadKey openThreadOf(String linkId);

  /// Opens files with their apps on this computer (`null` in tests that need none).
  AppLauncher? get appLauncher;

  /// Where [f] is on this computer, for Open, Show in Finder, Save as… and Copy path: a received file where the daemon
  /// saved it, a sent one where the person's own file was when this window sent it; `null` before the accept, for a
  /// file sent from a copy only (a pasted picture), or when the file is no longer there.
  String? localFileOf(FileInfo f) {
    final path = f.incoming ? (f.state == 'accepted' ? f.savedPath : null) : _sentOrigins[f.id];
    if (path == null) return null;
    try {
      return File(path).existsSync() ? path : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Open [path] with its app (the owner's click). `false` when the system refused.
  Future<bool> openLocalFile(String path) async => await appLauncher?.openFile(path) ?? false;

  /// Show [path] in Finder (or its folder in the file manager). `false` when the system refused.
  Future<bool> revealLocalFile(String path) => ImageActions.instance.reveal(path);

  /// The person's own file behind a file this window sent (file ID → path), never the window's staged copy (deleted
  /// after the send): what Open and Show in Finder use on a sent file's row. Kept for the session, like the window's
  /// other file state; a sent file's picture comes from its preview copy, not from here.
  final Map<String, String> _sentOrigins = {};

  void _rememberOrigin(String fileId, String? path) {
    if (path != null) _sentOrigins[fileId] = path;
  }

  /// Move a file waiting in the composer of the chat on screen from position [from] to position [to] (where it ends
  /// up): the order is the order of sending, so the album's order.
  void reorderStaged(String linkId, int from, int to) {
    final list = staged[draftKey(linkId, openThreadOf(linkId))];
    if (list == null || from < 0 || from >= list.length) return;
    final target = to.clamp(0, list.length - 1);
    if (target == from) return;
    list.insert(target, list.removeAt(from));
    _filesChanged();
  }

  /// Who a file sent on [linkId] now is for (PG-19): the open chat's counterpart when it is one of the contact's
  /// agents (or everyone, when the owner chose that), so only that agent sees the offer; in the person's chat no
  /// address, as before (every agent of the contact with the link sees it).
  ({String? to, String? toAgent}) fileAddressOf(String linkId);

  /// Notify the window (no error after dispose: daemon replies can arrive after the model is closed).
  void safeNotify();

  /// The last known state of files (ID → FileInfo).
  final Map<String, FileInfo> files = {};

  /// Sends awaiting the daemon's reply (local ID → send).
  final Map<String, OutgoingFile> outgoing = {};
  int _outSeq = 0;

  /// Files waiting in the composer for Send, per chat ([draftKey]), in the order they were added.
  final Map<String, List<StagedAttachment>> staged = {};
  int _stagedSeq = 0;

  /// Preview copies of sent images being made now (file ID → the job): the card waits for them instead of showing none.
  final Map<String, Future<void>> _previewJobs = {};

  /// Whether a sent file has a kept preview (file ID → answer), asked once per file and window session.
  final Map<String, bool> _previewKnown = {};

  /// A sent image shows the window's own preview copy (`SentPreviews`): it has one, or one is being made.
  bool hasSentPreview(FileInfo f) =>
      _previewJobs.containsKey(f.id) ||
      (_previewKnown[f.id] ??= SentPreviews.instance?.has(f.linkId, f.id) ?? false);

  /// The kept preview of a sent image (after the job making it, if one runs), or `null`.
  Future<Uint8List?> sentPreviewBytes(FileInfo f) async {
    final job = _previewJobs[f.id];
    if (job != null) await job;
    return await SentPreviews.instance?.read(f.linkId, f.id);
  }

  /// The bytes the daemon is about to read from [path], kept for the preview when the file is an image of a size the
  /// window decodes. Read before the send: the file may be gone a moment after it (a screenshot's temporary file).
  /// Read at once, as staging copies are (a screenshot is a few megabytes; the limit is 32 MiB).
  Uint8List? _bytesForPreview(String path) {
    RandomAccessFile? f;
    try {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) return null;
      f = File(path).openSync();
      final size = f.lengthSync();
      if (size == 0 || size > SentPreviews.maxInput || !looksLikeImage(f.readSync(16), name: path)) return null;
      f.setPositionSync(0);
      return f.readSync(size);
    } on FileSystemException {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  /// After the daemon accepted [f]: an image keeps its preview, made from [bytes] (what was sent).
  void _keepPreview(FileInfo f, Uint8List? bytes) {
    final store = SentPreviews.instance;
    if (bytes == null || store == null || !(f.mime ?? f.senderMime).startsWith('image/')) return;
    final job = store.keep(f.linkId, f.id, bytes).then((ok) {
      _previewKnown[f.id] = ok;
    });
    _previewJobs[f.id] = job;
    unawaited(job.whenComplete(() {
      _previewJobs.remove(f.id);
      _filesChanged();
    }));
  }

  /// A link was removed with its history: its preview copies go too.
  void forgetSentPreviews(String linkId) {
    SentPreviews.instance?.forgetLink(linkId);
    _previewKnown.removeWhere((id, _) => files[id]?.linkId == linkId || files[id] == null);
  }

  /// Offers a `withdraw_file` receipt refers to (message IDs), and the cards of those the daemon no longer lists.
  final Set<String> _withdrawnOffers = {};
  final Map<String, FileInfo> _withdrawnCards = {};

  /// The daemon supports files (x-control/3).
  bool filesSupported = true;

  /// The daemon can withdraw a sent file (preview.5): `false` after it answered `file_withdraw` with
  /// `unknown_command`, and the cards stop offering it.
  bool fileWithdrawSupported = true;

  void _filesChanged() => safeNotify();

  Future<void> refreshFiles() async {
    try {
      final list = await daemon.filesPending(all: true);
      files
        ..clear()
        ..addEntries(list.map((f) => MapEntry(f.id, f)));
      filesSupported = true;
    } on XControlException catch (e) {
      // A daemon older than x-control/3 lacks the command; the files section says so plainly.
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) filesSupported = false;
    } on XClientException {
      return;
    }
    _filesChanged();
  }

  /// The `file` event: a state change. The daemon does not store `refused`, so it is shown until the next reload.
  void onFileEvent(FileEvent e) {
    files[e.file.id] = e.file;
    // A file was saved into a folder: what the other cards were told about their names may have changed.
    if (e.file.state == 'accepted') _forgetNameChecks();
  }

  void _forgetNameChecks() {
    sameNameChecks.clear();
    _sameNameAsked.clear();
  }

  /// The contact's receipts for our files (`accept_file` / `reject_file` / `check_file`, signed by their node): after
  /// them the daemon forgets the transfer and sends no `file` event, so the state of a sent file is taken from the
  /// receipt ([sentFileFate]), moving only forward ([sentFileRank]). A `withdraw_file` receipt (preview.5) marks the
  /// file it refers to withdrawn: ours (our own receipt), or the contact's that was not accepted here (theirs).
  void applyFileReceipts(Iterable<HistoryItem> items) {
    for (final m in items) {
      final r = m.receipt;
      if (!m.isReceipt || r == null) continue;
      if (r.action == 'withdraw_file' && r.decision == 'withdrawn') {
        for (final ref in r.refs) {
          _withdrawnOffers.add(ref);
          for (final f in files.values.toList()) {
            if (f.messageId == ref && f.incoming != m.outgoing && f.state != 'accepted' && !f.withdrawn) {
              files[f.id] = f.withState('withdrawn');
            }
          }
        }
        continue;
      }
      if (m.outgoing) continue;
      final state = sentFileFate(r);
      if (state == null) continue;
      // D-128: the contact's node numbered the name because another file had it there.
      final number = state == 'accepted' ? r.nameNumber : null;
      // D-129: why the contact's node holds or blocked it (an older node does not say).
      final why = (state == 'held' || state == 'blocked') && r.why != null
          ? FileHeld(code: r.why!, rules: r.rules)
          : null;
      for (final ref in r.refs) {
        for (final f in files.values.toList()) {
          if (f.incoming || f.messageId != ref || f.withdrawn || f.state == 'refused') continue;
          if (sentFileRank(state) <= sentFileRank(f.state)) continue;
          files[f.id] = f.withState(state,
              savedAs: number == null ? null : numberedFileName(f.name, number),
              setHeld: state == 'held' || state == 'blocked',
              held: why);
        }
      }
    }
    // A withdrawn offer with no record left (the receiver after a reload; its receipt may have come on a newer page).
    for (final m in items) {
      if (m.kind == 'file' && _withdrawnOffers.contains(m.id) && fileByMessage(m.id) == null) {
        final card = withdrawnOfferFrom(m);
        if (card != null) _withdrawnCards[m.id] = card;
      }
    }
  }

  void clearFiles() {
    _sentOrigins.clear();
    files.clear();
    outgoing.values.forEach(_releaseCopy);
    outgoing.clear();
    for (final a in staged.values.expand((l) => l)) {
      _releaseStaged(a);
    }
    staged.clear();
    _withdrawnOffers.clear();
    _withdrawnCards.clear();
    _previewKnown.clear();
    _forgetNameChecks();
  }

  /// The files waiting in the composer of the chat on screen for [linkId].
  List<StagedAttachment> stagedOf(String linkId) => stagedIn(linkId, openThreadOf(linkId));

  /// The files waiting in the composer of the chat [t] of [linkId].
  List<StagedAttachment> stagedIn(String linkId, ThreadKey t) => staged[draftKey(linkId, t)] ?? const [];

  /// Add a file to the composer of the chat on screen for [linkId] (the paperclip, a drop, a pasted image). Nothing is
  /// sent before Send.
  StagedAttachment stageAttachment(String linkId, StagedFile file) {
    int? size;
    try {
      size = File(file.path).lengthSync();
    } on FileSystemException {
      size = null;
    }
    final a = StagedAttachment(id: 'att-${++_stagedSeq}', file: file, size: size);
    (staged[draftKey(linkId, openThreadOf(linkId))] ??= []).add(a);
    _filesChanged();
    return a;
  }

  /// Take a file out of the composer (its ✕): the window's copy is deleted.
  void unstage(String linkId, StagedAttachment a) {
    if (a.busy) return;
    final key = staged.keys.where((k) => staged[k]!.contains(a)).firstOrNull;
    if (key == null) return;
    final list = staged[key]!..remove(a);
    if (list.isEmpty) staged.remove(key);
    _releaseStaged(a);
    _filesChanged();
  }

  /// Send the composer's files for [linkId] in order, one `share_file` each ([only]: just that one, after its
  /// approval). A sent file leaves the composer and its copy is deleted; a refused one stays with its error or the
  /// approval it needs, and the others still go. `true` when every file it tried went (one added meanwhile waits for
  /// the next Send).
  Future<bool> sendStaged(String linkId, {StagedAttachment? only}) async {
    // The chat on screen now, and its address: another chat opened while the files go changes neither.
    final key = draftKey(linkId, openThreadOf(linkId));
    final addr = fileAddressOf(linkId);
    final list = staged[key];
    if (list == null) return true;
    var allSent = true;
    for (final a in List.of(list)) {
      if (a.busy || (only != null && a != only)) continue;
      a
        ..busy = true
        ..error = null;
      _filesChanged();
      try {
        final bytes = _bytesForPreview(a.file.path);
        final f =
            await daemon.shareFile(linkId, a.file.path, approvalId: a.approvalId, to: addr.to, toAgent: addr.toAgent);
        files[f.id] = f;
        _keepPreview(f, bytes);
        _rememberOrigin(f.id, a.file.origin ?? (a.file.owned ? null : a.file.path));
        list.remove(a);
        _releaseStaged(a);
      } on XControlException catch (e) {
        if (e.code == XErrorCode.approvalRequired && e.approval?['id'] is String) {
          a.approvalId = e.approval!['id']! as String;
        } else {
          a
            ..approvalId = null
            ..error = e;
        }
      } on XClientException catch (e) {
        a.error = e;
      }
      a.busy = false;
      if (list.contains(a)) allSent = false;
      _filesChanged();
    }
    if (list.isEmpty) staged.remove(key);
    return allSent;
  }

  void _releaseStaged(StagedAttachment a) {
    if (a.file.owned) OutgoingStaging.instance?.release(a.file.path);
  }

  /// Files of a link, newest first.
  List<FileInfo> filesOfLink(String linkId) =>
      files.values.where((f) => f.linkId == linkId).toList()..sort((a, b) => b.createdMs.compareTo(a.createdMs));

  /// All files, newest first.
  List<FileInfo> get allFiles => files.values.toList()..sort((a, b) => b.createdMs.compareTo(a.createdMs));

  /// Checked and awaiting the owner's decision.
  List<FileInfo> get filesAwaiting => allFiles.where((f) => f.awaitingDecision).toList();

  /// The file that arrived as history message [messageId].
  FileInfo? fileByMessage(String messageId) {
    for (final f in files.values) {
      if (f.messageId == messageId) return f;
    }
    return _withdrawnCards[messageId];
  }

  List<OutgoingFile> outgoingOf(String linkId) => outgoing.values.where((o) => o.linkId == linkId).toList();

  /// Send file [path] over link [linkId]. The daemon replies after hashing and encrypting the file. A [staged] path is
  /// the window's copy ([origin]: the person's file): it is deleted after that reply, and kept while the send waits
  /// for approval or a retry (an approval is bound to the path).
  Future<void> shareFile(String linkId, String path,
      {String? approvalId, OutgoingFile? retry, bool staged = false, String? origin}) async {
    final o = retry ??
        OutgoingFile(
            localId: 'out-${++_outSeq}',
            linkId: linkId,
            path: path,
            at: DateTime.now(),
            staged: staged,
            origin: origin);
    o
      ..busy = true
      ..error = null;
    outgoing[o.localId] = o;
    _filesChanged();
    try {
      final addr = fileAddressOf(linkId);
      final bytes = _bytesForPreview(path);
      final f = await daemon.shareFile(linkId, path, approvalId: approvalId, to: addr.to, toAgent: addr.toAgent);
      outgoing.remove(o.localId);
      _releaseCopy(o);
      files[f.id] = f;
      _keepPreview(f, bytes);
      _rememberOrigin(f.id, o.origin ?? (o.staged ? null : o.path));
    } on XControlException catch (e) {
      o.busy = false;
      if (e.code == XErrorCode.approvalRequired && e.approval?['id'] is String) {
        o.approvalId = e.approval!['id']! as String;
      } else {
        o.error = e;
      }
    } on XClientException catch (e) {
      o
        ..busy = false
        ..error = e;
    }
    _filesChanged();
  }

  void dismissOutgoing(String localId) {
    final o = outgoing.remove(localId);
    if (o != null) _releaseCopy(o);
    _filesChanged();
  }

  void _releaseCopy(OutgoingFile o) {
    if (o.staged) OutgoingStaging.instance?.release(o.path);
  }

  Future<FilePreviewReply> previewFile(String id) async {
    final r = await daemon.filePreview(id);
    files[r.file.id] = r.file;
    _filesChanged();
    return r;
  }

  /// The daemon's control protocol version (`hello_ok.proto`).
  int get daemonProto;

  bool _nameCheckWorks = true;

  /// The daemon checks a name before an accept (`file_name_check`, x-control/7); not an older daemon (it is never
  /// asked), nor one that answered the command as unknown: the rename dialog then learns that a name is taken only
  /// from the accept itself.
  bool get fileNameCheckSupported => daemonProto >= 7 && _nameCheckWorks;

  /// The daemon's answer for a file waiting for a decision, under the contact's name (ID → answer): its card says
  /// "Already in the folder: the same file" before the owner clicks. Asked once per file.
  final Map<String, FileNameCheck> sameNameChecks = {};
  final Set<String> _sameNameAsked = {};

  /// Can [id] be accepted under [name] (the contact's name when `null`)? `null`: the daemon cannot say (older than
  /// preview.8: [fileNameCheckSupported] turns off) or did not answer.
  Future<FileNameCheck?> checkFileName(String id, {String? name}) async {
    if (!fileNameCheckSupported) return null;
    try {
      return await daemon.fileNameCheck(id, name: name);
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.notImplemented) {
        _nameCheckWorks = false;
        _filesChanged();
      }
      return null;
    } on XClientException {
      return null;
    }
  }

  /// What the daemon says about [f]'s own name in the folder, for its card; the first call asks (once per file).
  FileNameCheck? sameNameCheck(FileInfo f) {
    if (!f.awaitingDecision || !fileNameCheckSupported) return null;
    if (_sameNameAsked.add(f.id)) {
      unawaited(checkFileName(f.id).then((r) {
        if (r == null) return;
        sameNameChecks[f.id] = r;
        _filesChanged();
      }));
    }
    return sameNameChecks[f.id];
  }

  /// Accept a file. Returns the daemon error or `null`. A forced accept takes the owner's [auth] (the password or one
  /// touch, D-131), or the bare [password].
  Future<Object?> acceptFile(String id,
      {String? name,
      bool force = false,
      bool allowSpecial = false,
      String? approvalId,
      String? password,
      OwnerAuth? auth}) async {
    try {
      final f = auth == null
          ? await daemon.fileAccept(id,
              name: name, force: force, allowSpecial: allowSpecial, approvalId: approvalId, password: password)
          : await ownerOp(
              auth,
              (d, pw) => d.fileAccept(id,
                  name: name, force: force, allowSpecial: allowSpecial, approvalId: approvalId, password: pw));
      files[f.id] = f;
      _forgetNameChecks();
      _filesChanged();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Withdraw a sent file the contact has not answered (preview.5). Returns the daemon error or `null`; an older
  /// daemon (`unknown_command`) turns the offer off.
  Future<Object?> withdrawFile(FileInfo f) async {
    try {
      final w = await daemon.fileWithdraw(f.id);
      files[w.id] = w;
      _filesChanged();
      return null;
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand) {
        fileWithdrawSupported = false;
        _filesChanged();
      }
      return e;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Reject a file. Returns the daemon error or `null`.
  Future<Object?> rejectFile(String id) async {
    try {
      final f = await daemon.fileReject(id);
      files[f.id] = f;
      _filesChanged();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }
}
