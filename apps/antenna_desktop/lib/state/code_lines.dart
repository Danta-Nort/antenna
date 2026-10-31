// SPDX-License-Identifier: AGPL-3.0-only
// The lines the window itself may put into an agent's terminal (D-UI-23, D-UI-25): an [AllowedLine] exists only for
// the phrases built into the app, a contact's label or a version sanitized into one of them, and the path of a
// screenshot the window took itself. A contact can at most cause a line; it never chooses or adds text.

import 'dart:convert';

import '../host/screenshot.dart';
import 'code_mode.dart' show AgentRun;

/// A line the window may put into an agent's terminal: only those built into the app.
final class AllowedLine {
  const AllowedLine._(this.text, {this.paste = false});

  /// What is typed (Enter follows separately, [AgentRun.typeLine]) or pasted.
  final String text;

  /// Pasted as one bracketed paste, without Enter (a screenshot's path: Claude Code attaches the image).
  final bool paste;

  /// The wake line when the sender cannot be named (several contacts, or a label with nothing printable left).
  static const wakeAny = AllowedLine._('New Antenna messages: read your inbox and continue.');

  /// After the owner approved one of the agent's requests (D-100: the daemon has already carried it out).
  static const approved = AllowedLine._('Approved — continue.');

  /// After the owner answered or set aside one of the agent's questions (D-118): the answer is in its inbox.
  static const answered = AllowedLine._('Your question was answered: read your inbox and continue.');

  /// An approver agent (CONTROL §31, PG-57): a request waits for its answer in the owner's place. The same words as
  /// `antenna session`'s waker; the request's text is never typed (the agent reads it with `approvals_to_answer`).
  static const toAnswer =
      AllowedLine._('An approval request waits for your answer: read approvals_to_answer and answer it.');

  /// Quick replies (owner clicks only).
  static const checkChat = AllowedLine._('Check the Antenna chat: read your inbox and continue.');
  static const goAhead = AllowedLine._('Yes, go ahead.');

  /// An urgent message (CONTROL §33) when the sender cannot be named. The same words as `antenna session`'s waker.
  static const urgentAny = AllowedLine._('Urgent Antenna message: read your inbox now.');

  /// The urgent line naming the own computer by the owner's own local label, sanitized like [wakeFrom]'s. The same
  /// words as `antenna session`'s waker.
  static AllowedLine urgentFrom(String localLabel) {
    final label = sanitizeContactLabel(localLabel);
    return label.isEmpty ? urgentAny : AllowedLine._('Urgent Antenna message from $label: read your inbox now.');
  }

  /// The wake line naming the contact by the owner's own local label, sanitized.
  static AllowedLine wakeFrom(String localLabel) {
    final label = sanitizeContactLabel(localLabel);
    return label.isEmpty ? wakeAny : AllowedLine._('New Antenna messages from $label: read your inbox and continue.');
  }

  /// A team's lead: somebody else changed one of the team's tasks (a worker submitted or asks something, the owner
  /// reviewed or applied). The team's name is the daemon's (`[a-z0-9-]`), sanitized like a label all the same.
  static AllowedLine teamTasks(String team) {
    final name = sanitizeContactLabel(team);
    return AllowedLine._(name.isEmpty
        ? 'Your Antenna team has news: check task_list and continue.'
        : 'Your Antenna team $name has news: check task_list and continue.');
  }

  /// After an automatic update restarted the agent in its session (D-103): the new version as the daemon reports it
  /// (`status.updated.to`), sanitized ([sanitizeVersion]); without a printable version, the line names none.
  static AllowedLine updated(String version) {
    final v = sanitizeVersion(version);
    return AllowedLine._(v.isEmpty
        ? 'Antenna was updated: read your inbox and continue.'
        : 'Antenna was updated to $v: read your inbox and continue.');
  }

  /// A screenshot the window took itself ([WindowScreenshot] exists only for a file the window wrote and checked in
  /// its own folder), pasted as its path; `null` when the path has characters a terminal paste could misread.
  static AllowedLine? screenshot(WindowScreenshot shot) => shot.pasteable ? AllowedLine._(shot.path, paste: true) : null;

  /// The Stop hook's answer that continues the turn with this line (host/code_hooks.dart).
  String get stopContinuation => jsonEncode({'decision': 'block', 'reason': text});

  @override
  String toString() => text;
}

/// The longest label put into a wake line, in characters.
const maxWakeLabel = 40;

final _labelChar = RegExp(r"[\p{L}\p{M}\p{N} .\-_@'+&#()]", unicode: true);

/// A contact's label as it may appear in a typed line: letters, marks, digits, spaces and a few punctuation marks,
/// nothing else (no control characters, escapes, line breaks, format or bidi characters, no `:` or `/`), runs of
/// spaces collapsed, at most [maxWakeLabel] characters.
String sanitizeContactLabel(String label) {
  final kept = StringBuffer();
  for (final r in label.runes) {
    final c = String.fromCharCode(r);
    kept.write(_labelChar.hasMatch(c) ? c : ' ');
  }
  final s = kept.toString().replaceAll(RegExp(' +'), ' ').trim();
  final runes = s.runes.toList();
  return runes.length <= maxWakeLabel ? s : String.fromCharCodes(runes.take(maxWakeLabel)).trimRight();
}

/// The longest version put into the update line, in characters.
const maxLineVersion = 40;

/// A version as it may appear in a typed line: SemVer characters only (digits, ASCII letters, `.`, `-`, `+`), at most
/// [maxLineVersion]; anything else is dropped. The version comes from the daemon, but the line goes into a terminal.
String sanitizeVersion(String version) {
  final kept = version.replaceAll(RegExp(r'[^0-9A-Za-z.+-]'), '');
  return kept.length <= maxLineVersion ? kept : kept.substring(0, maxLineVersion);
}

/// The quick replies under a Code mode terminal. The labels are translated; the typed text stays English.
enum QuickReply {
  approved,
  checkChat,
  goAhead,

  /// Escape for Claude Code and Codex (their "esc to interrupt"); Ctrl+C for an own command. Types nothing.
  stop;

  /// What a click types (`null`: [stop]).
  AllowedLine? get line => switch (this) {
        approved => AllowedLine.approved,
        checkChat => AllowedLine.checkChat,
        goAhead => AllowedLine.goAhead,
        stop => null,
      };
}
