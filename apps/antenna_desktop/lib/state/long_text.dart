// SPDX-License-Identifier: AGPL-3.0-only
// Text longer than one message holds. The daemon takes at most 64 KiB of UTF-8 per message (`link::MAX_TEXT`) and
// refuses more with `text_too_long` (CONTROL §10; an older daemon said `bad_request`). As in any messenger, such text
// goes as a file: the window writes it into a `.txt` in its staging folder (`OutgoingStaging`, the folder a pasted
// image goes to) and shares it in the same chat, so the file has the chat's address (the open chat's agent, PG-19).
// The composer counts the bytes near the limit and turns Send into "Send as a file" over it; a bubble the daemon
// refused as too long offers the same.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../host/outgoing_staging.dart';
import '../protocol/x_control.dart';
import 'app_model.dart' show ChatEntry, ChatThread;
import 'files.dart';

/// The most text one message holds, in bytes of UTF-8.
const maxMessageBytes = 64 * 1024;

/// From here on the composer shows how much of a message the text takes.
const messageCounterFrom = maxMessageBytes * 4 ~/ 5;

/// The length of [s] in UTF-8, without encoding it (the composer asks on every keystroke).
int utf8Length(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length && (s.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      n += 4;
      i++;
    } else {
      n += 3;
    }
  }
  return n;
}

/// [text] does not fit in one message.
bool textTooLong(String text) => utf8Length(text) > maxMessageBytes;

/// The daemon refused [e] because its text is too long: `text_too_long`, or `bad_request` from a daemon before it for a
/// text over the limit.
bool refusedAsTooLong(ChatEntry e) =>
    e.error == XErrorCode.textTooLong || (e.error == XErrorCode.badRequest && textTooLong(e.text));

/// The file's name: the first line's words (letters, digits, `.`, `-`, `_`) joined by `-`, at most 48 characters, or
/// `message-2026-10-06-215300.txt` when the first line has none. The contact sees it and an agent types it.
String textFileName(String text, DateTime at) {
  final first = text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  var base = first
      .replaceAll(RegExp(r'[^\p{L}\p{N}._\- ]', unicode: true), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join('-')
      .replaceAll(RegExp(r'^[.\-]+'), '');
  if (base.length > 48) base = base.substring(0, 48).replaceAll(RegExp(r'[.\-_]+$'), '');
  if (base.isEmpty) {
    String two(int n) => n.toString().padLeft(2, '0');
    base = 'message-${at.year}-${two(at.month)}-${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }
  return '$base.txt';
}

/// How a text sent as a file went.
enum TextFileResult {
  /// The daemon has the file.
  sent,

  /// The file is in the composer with the daemon's refusal (or the approval it needs), as any file there.
  held,

  /// The window could not write the file (no staging folder).
  notWritten,
}

mixin LongTextMixin on ChangeNotifier {
  Map<String, ChatThread> get chats;
  DateTime now();
  void safeNotify();
  StagedAttachment stageAttachment(String linkId, StagedFile file);
  Future<bool> sendStaged(String linkId, {StagedAttachment? only});

  /// Send [text] into [linkId]'s chat as a `.txt` file. [failed]: the bubble the daemon refused as too long, replaced
  /// by the file once it went.
  Future<TextFileResult> sendTextAsFile(String linkId, String text, {ChatEntry? failed}) async {
    final s = OutgoingStaging.instance?.stageBytes(utf8.encode(text), textFileName(text, now()));
    if (s == null) return TextFileResult.notWritten;
    final a = stageAttachment(linkId, s);
    final sent = await sendStaged(linkId, only: a);
    if (sent && failed != null) {
      chats[linkId]?.entries.remove(failed);
      safeNotify();
    }
    return sent ? TextFileResult.sent : TextFileResult.held;
  }
}
