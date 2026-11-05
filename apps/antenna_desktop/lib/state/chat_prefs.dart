// SPDX-License-Identifier: AGPL-3.0-only
// Local "phone book" settings for a contact's agent chats, kept on this computer only and never sent — unlike the
// local name, notifications and archive of D-113, which live in the daemon's own database because they are the
// daemon's local-settings store. There is no such store for these two, so they follow the window's own local-settings
// pattern instead (`appearance.dart`, `window.json`): a small JSON file next to it, `chat_prefs.json`.
//
// - **A stable order** (field feedback 2026-10-06): a list that reordered itself by the latest message made it hard to keep
//   track of which agent chat was which. The order a contact's agent chats are shown in is
//   the order they first appeared, drag-reorderable, saved here; a **Pin** stays on top in the order it was pinned.
//   Activity still shows (the unread badge, the time), it just does not move the row.
// - **A local picture** for a contact's agent (D-UI-32's agent chats, D-115's pictures): a phone book entry on top of
//   what the agent's own owner announced. The photo path reuses the window's own decode → crop → re-encode pipeline
//   (`photo_crop.dart`), the same one already used before a picture ever reaches the daemon (D-UI-35): nothing of the
//   chosen file's bytes or metadata is kept, only a 512 × 512 PNG this window drew itself, saved next to this file.
// - **"Notify about messages between agents"** (D-UI-44, off by default): a chat's own opt-in, kept here next to its
//   stable order and its picture, for the same reason — it is this computer's own display choice, not something the
//   daemon or the contact needs to know.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';

/// One contact's local chat preferences.
@immutable
class LinkChatPrefs {
  const LinkChatPrefs(
      {this.order = const [], this.pinned = const [], this.pictures = const {}, this.notifyAgents = const {}});

  /// Agent names, the order their chats are shown in when not pinned: first seen, then as dragged.
  final List<String> order;

  /// Agent names that are pinned, most recently pinned first.
  final List<String> pinned;

  /// A local picture override per agent name.
  final Map<String, ChatPictureOverride> pictures;

  /// Agent names whose chat notifies about agent-to-agent traffic too (off by default, D-UI-44).
  final Set<String> notifyAgents;

  bool get isEmpty => order.isEmpty && pinned.isEmpty && pictures.isEmpty && notifyAgents.isEmpty;

  LinkChatPrefs copyWith(
          {List<String>? order,
          List<String>? pinned,
          Map<String, ChatPictureOverride>? pictures,
          Set<String>? notifyAgents}) =>
      LinkChatPrefs(
        order: order ?? this.order,
        pinned: pinned ?? this.pinned,
        pictures: pictures ?? this.pictures,
        notifyAgents: notifyAgents ?? this.notifyAgents,
      );

  factory LinkChatPrefs.fromJson(Object? j) {
    if (j is! Map) return const LinkChatPrefs();
    final order = j['order'];
    final pinned = j['pinned'];
    final pictures = j['pictures'];
    final notifyAgents = j['notify_agents'];
    final pictureMap = <String, ChatPictureOverride>{};
    if (pictures is Map) {
      for (final e in pictures.entries) {
        final p = ChatPictureOverride.fromJson(e.value);
        if (e.key is String && p != null) pictureMap['${e.key}'] = p;
      }
    }
    return LinkChatPrefs(
      order: order is List ? [for (final a in order) if (a is String) a] : const [],
      pinned: pinned is List ? [for (final a in pinned) if (a is String) a] : const [],
      pictures: pictureMap,
      notifyAgents: notifyAgents is List ? {for (final a in notifyAgents) if (a is String) a} : const {},
    );
  }

  Object toJson() => {
        if (order.isNotEmpty) 'order': order,
        if (pinned.isNotEmpty) 'pinned': pinned,
        if (pictures.isNotEmpty) 'pictures': {for (final e in pictures.entries) e.key: e.value.toJson()},
        if (notifyAgents.isNotEmpty) 'notify_agents': notifyAgents.toList(),
      };
}

/// A local picture set for a contact's agent: a drawn picture of the bundled catalog, or a photo this window already
/// rebuilt (the file name, inside this store's picture folder).
sealed class ChatPictureOverride {
  const ChatPictureOverride();

  static ChatPictureOverride? fromJson(Object? j) {
    if (j is! Map) return null;
    final drawn = j['drawn'];
    if (drawn is String) return ChatPictureDrawn(drawn);
    final photo = j['photo'];
    if (photo is String) return ChatPicturePhoto(photo);
    return null;
  }

  Object toJson();
}

/// `set2/owl`: drawn from the window's own bundled assets, exactly like any other drawn picture.
final class ChatPictureDrawn extends ChatPictureOverride {
  const ChatPictureDrawn(this.id);
  final String id;

  @override
  Object toJson() => {'drawn': id};

  @override
  bool operator ==(Object other) => other is ChatPictureDrawn && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// A photo this window rebuilt itself (decode, crop, re-encode with no metadata) and saved as `file`, inside this
/// store's own picture folder; never a path outside it, never the chosen file's own bytes.
final class ChatPicturePhoto extends ChatPictureOverride {
  const ChatPicturePhoto(this.file);
  final String file;

  @override
  Object toJson() => {'photo': file};

  @override
  bool operator ==(Object other) => other is ChatPicturePhoto && other.file == file;
  @override
  int get hashCode => file.hashCode;
}

/// Backs [ChatPrefsMixin]: the settings file (`chat_prefs.json`) and the folder of rebuilt photos next to it, in the
/// same directory as `window.json` (`appearance.dart`).
class ChatPrefsStore {
  ChatPrefsStore(this.path, this.picturesDir);

  /// `chat_prefs.json`.
  final String path;

  /// Where a photo override's rebuilt PNG lives (created on first use).
  final String picturesDir;

  static ChatPrefsStore? forEnv(Map<String, String> env, {bool? macos}) {
    final home = env['HOME'] ?? '';
    if (home.isEmpty) return null;
    final String base;
    if (macos ?? Platform.isMacOS) {
      base = '$home/Library/Application Support/Antenna';
    } else {
      final xdg = env['XDG_CONFIG_HOME'];
      base = (xdg != null && xdg.startsWith('/')) ? '$xdg/antenna' : '$home/.config/antenna';
    }
    return ChatPrefsStore('$base/chat_prefs.json', '$base/chat_pictures');
  }

  /// The saved preferences by link ID; a missing or corrupt file is empty (nothing of a contact's own picture is
  /// lost: it is announced again by the daemon, this is only the local override on top of it).
  Map<String, LinkChatPrefs> load() {
    Object? j;
    try {
      j = json.decode(File(path).readAsStringSync());
    } on Object {
      return {};
    }
    if (j is! Map) return {};
    return {
      for (final e in j.entries)
        if (e.key is String) '${e.key}': LinkChatPrefs.fromJson(e.value),
    };
  }

  void save(Map<String, LinkChatPrefs> links) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      final body = {for (final e in links.entries) if (!e.value.isEmpty) e.key: e.value.toJson()};
      tmp.writeAsStringSync(json.encode(body));
      tmp.renameSync(path);
    } on Object catch (e) {
      debugPrint('chat_prefs.json: $e');
    }
  }

  /// Write a photo override's rebuilt bytes under a name derived from the link and the agent; returns the file name
  /// (relative to [picturesDir]) to keep in [LinkChatPrefs.pictures]. `null` if the folder could not be written.
  String? writePhoto(String linkId, String agent, List<int> png) {
    try {
      final dir = Directory(picturesDir)..createSync(recursive: true);
      final name = '${_fileSafe(linkId)}-${_fileSafe(agent)}.png';
      File('${dir.path}/$name').writeAsBytesSync(png, flush: true);
      return name;
    } on Object catch (e) {
      debugPrint('chat_prefs photo: $e');
      return null;
    }
  }

  Uint8List? readPhoto(String file) {
    try {
      return File('$picturesDir/$file').readAsBytesSync();
    } on Object {
      return null;
    }
  }

  void deletePhoto(String file) {
    try {
      final f = File('$picturesDir/$file');
      if (f.existsSync()) f.deleteSync();
    } on Object catch (e) {
      debugPrint('chat_prefs photo: $e');
    }
  }

  /// A link ID (hex) or an agent name as one path segment: nothing from either ever has `/` or `..`, but this stays
  /// safe even if that changes.
  static String _fileSafe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// The contact's agent chats mixin uses: a stable order, pins, and local picture overrides. A part of `AppModel`.
mixin ChatPrefsMixin on ChangeNotifier {
  void safeNotify();
  List<ContactInfo> get contacts;

  /// `null`: no settings file (no home directory, as in some tests), so nothing is remembered across runs.
  ChatPrefsStore? chatPrefsStore;

  final Map<String, LinkChatPrefs> _chatPrefs = {};
  bool _chatPrefsLoaded = false;
  final Map<String, Uint8List> _chatPhotoBytes = {};

  void _ensureLoaded() {
    if (_chatPrefsLoaded) return;
    _chatPrefsLoaded = true;
    final s = chatPrefsStore;
    if (s != null) _chatPrefs.addAll(s.load());
  }

  LinkChatPrefs _prefsOf(String linkId) {
    _ensureLoaded();
    return _chatPrefs[linkId] ?? const LinkChatPrefs();
  }

  void _save() => chatPrefsStore?.save(_chatPrefs);

  /// The stable order of [linkId]'s agent chats: first-seen order. Any name in [present] not seen before is appended
  /// once (the order a new chat is first shown in) and saved; later calls with the same names change nothing.
  List<String> chatOrderOf(String linkId, Iterable<String> present) {
    final p = _prefsOf(linkId);
    final grown = [...p.order, for (final a in present) if (!p.order.contains(a)) a];
    if (!listEquals(grown, p.order)) {
      _chatPrefs[linkId] = p.copyWith(order: grown);
      _save();
    }
    return grown;
  }

  /// The owner dragged [linkId]'s agent chats into [order] (every chat it currently has, in the new order).
  void reorderChats(String linkId, List<String> order) {
    final p = _prefsOf(linkId);
    if (listEquals(order, p.order)) return;
    _chatPrefs[linkId] = p.copyWith(order: order);
    _save();
    safeNotify();
  }

  /// Pinned agent names of [linkId], most recently pinned first.
  List<String> pinnedChatsOf(String linkId) => _prefsOf(linkId).pinned;

  bool isChatPinned(String linkId, String agent) => pinnedChatsOf(linkId).contains(agent);

  /// Pin or unpin a chat with [agent]: pinning moves it to the top of the pinned chats, as in other messengers.
  void setChatPinned(String linkId, String agent, bool pinned) {
    final p = _prefsOf(linkId);
    final list = [...p.pinned]..remove(agent);
    if (pinned) list.insert(0, agent);
    if (listEquals(list, p.pinned)) return;
    _chatPrefs[linkId] = p.copyWith(pinned: list);
    _save();
    safeNotify();
  }

  /// The local picture override for [linkId]'s agent [agent]; `null` keeps the contact's own picture working.
  ChatPictureOverride? chatPictureOverride(String linkId, String agent) => _prefsOf(linkId).pictures[agent];

  /// The same, by the contact's label (a bubble or the map names the contact by label, not always by its link ID).
  ChatPictureOverride? chatPictureOverrideByLabel(String label, String agent) {
    for (final c in contacts) {
      if (c.label == label) return chatPictureOverride(c.linkId, agent);
    }
    return null;
  }

  void setChatPictureDrawn(String linkId, String agent, String drawnId) {
    final p = _prefsOf(linkId);
    final old = p.pictures[agent];
    if (old is ChatPicturePhoto) chatPrefsStore?.deletePhoto(old.file);
    _chatPrefs[linkId] = p.copyWith(pictures: {...p.pictures, agent: ChatPictureDrawn(drawnId)});
    _save();
    safeNotify();
  }

  /// [png]: this window's own rebuild (decode, crop to a square, re-encode, no metadata), never the chosen file.
  void setChatPicturePhoto(String linkId, String agent, List<int> png) {
    final s = chatPrefsStore;
    if (s == null) return;
    final file = s.writePhoto(linkId, agent, png);
    if (file == null) return;
    final p = _prefsOf(linkId);
    final old = p.pictures[agent];
    if (old is ChatPicturePhoto && old.file != file) s.deletePhoto(old.file);
    _chatPhotoBytes.remove(file);
    _chatPrefs[linkId] = p.copyWith(pictures: {...p.pictures, agent: ChatPicturePhoto(file)});
    _save();
    safeNotify();
  }

  /// "Reset to theirs": the override is gone, the contact's own picture (if any) shows again.
  void removeChatPictureOverride(String linkId, String agent) {
    final p = _prefsOf(linkId);
    final old = p.pictures[agent];
    if (old == null) return;
    if (old is ChatPicturePhoto) {
      chatPrefsStore?.deletePhoto(old.file);
      _chatPhotoBytes.remove(old.file);
    }
    final pictures = {...p.pictures}..remove(agent);
    _chatPrefs[linkId] = p.copyWith(pictures: pictures);
    _save();
    safeNotify();
  }

  /// Whether [linkId]'s chat with [agent] notifies about what it exchanges with the owner's own agents too (off by
  /// default: "a person does not care what the AIs discuss among themselves").
  bool notifyAgentsOn(String linkId, String agent) => _prefsOf(linkId).notifyAgents.contains(agent);

  void setNotifyAgentsOn(String linkId, String agent, bool on) {
    final p = _prefsOf(linkId);
    final set = {...p.notifyAgents};
    final changed = on ? set.add(agent) : set.remove(agent);
    if (!changed) return;
    _chatPrefs[linkId] = p.copyWith(notifyAgents: set);
    _save();
    safeNotify();
  }

  /// The bytes of a photo override, read once and cached.
  Uint8List? chatPhotoBytes(String file) {
    final cached = _chatPhotoBytes[file];
    if (cached != null) return cached;
    final bytes = chatPrefsStore?.readPhoto(file);
    if (bytes != null) _chatPhotoBytes[file] = bytes;
    return bytes;
  }
}
