// SPDX-License-Identifier: AGPL-3.0-only
// File requests (x-control/3, CONTROL §14): a part of requests.dart.

part of 'requests.dart';

/// Send a file to a contact (v3): [path] is an absolute path; a secret in the file → `approval_required`, retry with
/// [approvalId]. [to] / [toAgent] (v7, PG-19): who the offer is for; absent: no address, as before.
final class ShareFileRequest extends XRequest {
  const ShareFileRequest({required this.contact, required this.path, this.name, this.approvalId, this.to, this.toAgent});
  final String contact;
  final String path;
  final String? name;
  final String? approvalId;
  final String? to;
  final String? toAgent;
  @override
  String get cmd => 'share_file';
  @override
  Json get fields =>
      {'contact': contact, 'path': path, 'name': ?name, 'approval_id': ?approvalId, 'to': ?to, 'to_agent': ?toAgent};
}

/// Files in quarantine (v3); [all] also includes previously accepted ones.
final class FilesPendingRequest extends XRequest {
  const FilesPendingRequest({this.contact, this.all = false});
  final String? contact;
  final bool all;
  @override
  String get cmd => 'files_pending';
  @override
  Json get fields => {'contact': ?contact, 'all': all};
}

/// Safe preview of a file (v3).
final class FilePreviewRequest extends XRequest {
  const FilePreviewRequest(this.id);
  final String id;
  @override
  String get cmd => 'file_preview';
  @override
  Json get fields => {'id': id};
}

/// Accept a file (v3): [force] accepts a threat or an unchecked file (only with [password]); [allowSpecial] allows a
/// dotfile or an auto-executable name; [approvalId] is an approved approval request.
final class FileAcceptRequest extends XRequest {
  const FileAcceptRequest(this.id, {this.name, this.force = false, this.allowSpecial = false, this.approvalId, this.password});
  final String id;
  final String? name;
  final bool force;
  final bool allowSpecial;
  final String? approvalId;
  final String? password;
  @override
  String get cmd => 'file_accept';
  @override
  Json get fields => {
        'id': id,
        'name': ?name,
        if (force) 'force': true,
        if (allowSpecial) 'allow_special': true,
        'approval_id': ?approvalId,
        'password': ?password,
      };
  @override
  String toString() => 'XRequest::file_accept';
}

/// Withdraw a file this node sent that the contact has not answered yet (preview.5, owner only): [id] is the file ID
/// or the offer's message ID (8+ hex). An older daemon answers `unknown_command`; an answered or unknown file
/// `not_found`.
final class FileWithdrawRequest extends XRequest {
  const FileWithdrawRequest(this.id);
  final String id;
  @override
  String get cmd => 'file_withdraw';
  @override
  Json get fields => {'id': id};
}

/// Reject a file (v3): the record and the key are erased, and the contact gets a rejection receipt.
final class FileRejectRequest extends XRequest {
  const FileRejectRequest(this.id);
  final String id;
  @override
  String get cmd => 'file_reject';
  @override
  Json get fields => {'id': id};
}

/// Where files from an own computer at level 5 are saved (v7, D-130, CONTROL §14; owner only): for [contact], or for
/// one of its [agent]s (by its name on the link; it applies when the agent's key signed the offer). With [path] (an
/// existing folder in the owner's home, not hidden, not a system folder, not Antenna's) the password or an owner proof;
/// without it the folder is cleared, no password. Reply: [FileSaveDirsReply].
final class FileSaveDirRequest extends XRequest {
  const FileSaveDirRequest(this.contact, {this.agent, this.path, this.password});
  final String contact;
  final String? agent;
  final String? path;
  final String? password;
  @override
  String get cmd => 'file_save_dir';
  @override
  Json get fields => {'contact': contact, 'agent': ?agent, 'path': ?path, 'password': ?password};
  @override
  String toString() => 'XRequest::file_save_dir';
}

/// Let programs or installers from an own computer at level 5 through without waiting (v7, D-130; owner only):
/// [entries] are `executables`, `installers` or an extension such as `.dmg`. The password or an owner proof every
/// time. Reply: [FileAllowReply].
final class FileAllowRequest extends XRequest {
  const FileAllowRequest(this.contact, this.entries, {this.password});
  final String contact;
  final List<String> entries;
  final String? password;
  @override
  String get cmd => 'file_allow';
  @override
  Json get fields => {'contact': contact, 'entries': entries, 'password': ?password};
  @override
  String toString() => 'XRequest::file_allow';
}

/// Take [entries] off the allowlist (all of them when `null`); no password. Reply: [FileAllowReply].
final class FileDisallowRequest extends XRequest {
  const FileDisallowRequest(this.contact, {this.entries});
  final String contact;
  final List<String>? entries;
  @override
  String get cmd => 'file_disallow';
  @override
  Json get fields => {'contact': contact, 'entries': ?entries};
}
