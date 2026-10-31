// SPDX-License-Identifier: AGPL-3.0-only
// Profile pictures (x-control/7, CONTROL §28): the owner's own picture and their agents', and each contact's, as the
// daemon lists them (`pictures`, kept current by `picture` events). The window draws a drawn picture from its own
// assets by id (`assets/avatars/sets.json`; an id it does not know is initials) and a photo only from the daemon's
// rebuilt bytes (`picture_photo`, fetched once per id): never a file path and never bytes the window read itself, so
// what a contact sent is never decoded here before the daemon's sandbox rebuilt it. A contact's photo the daemon
// withheld (trust level 1, a refused image, no sandbox here) is initials. A daemon without pictures (older than this
// version) answers `unknown_command`: nobody has a picture and the picker says a newer daemon is needed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../protocol/x_control.dart';

/// An animal of a drawn set.
@immutable
final class PictureAnimalInfo {
  const PictureAnimalInfo(this.id, this.name);

  /// `fox`, `snow-leopard`.
  final String id;

  /// The English name (the window shows `pictureAnimal` in the current language).
  final String name;
}

/// A drawn set of the bundled manifest.
@immutable
final class PictureSetInfo {
  const PictureSetInfo(this.id, this.name, this.animals, {this.cover});
  final String id;
  final String name;
  final List<PictureAnimalInfo> animals;

  /// The set's icon for the picker's tabs (`cover-128.webp`, transparent), when the set has one.
  final String? cover;

  /// The asset of [cover].
  String? get coverAsset => cover == null ? null : 'assets/avatars/$id/$cover';
}

/// The drawn sets bundled with the window (`assets/avatars/sets.json`, made by `tools/avatars.py`).
final class PictureCatalog {
  const PictureCatalog(this.sets);

  factory PictureCatalog.fromJson(Object? json) {
    final sets = <PictureSetInfo>[];
    if (json is Map && json['sets'] is List) {
      for (final s in json['sets'] as List) {
        if (s is! Map || s['id'] is! String || s['animals'] is! List) continue;
        final animals = [
          for (final a in s['animals'] as List)
            if (a is Map && a['id'] is String) PictureAnimalInfo(a['id'] as String, (a['name'] as String?) ?? ''),
        ];
        final cover = s['cover'];
        sets.add(PictureSetInfo(s['id'] as String, (s['name'] as String?) ?? '', animals,
            cover: cover is String && RegExp(r'^[a-z0-9-]+\.webp$').hasMatch(cover) ? cover : null));
      }
    }
    return PictureCatalog(sets);
  }

  static const manifest = 'assets/avatars/sets.json';

  /// The catalog once loaded (it never changes while the window runs).
  static PictureCatalog? loaded;
  static Future<PictureCatalog>? _loading;

  /// Load the manifest once; an unreadable one is an empty catalog (no drawn pictures, initials everywhere).
  static Future<PictureCatalog> load([AssetBundle? bundle]) {
    final done = loaded;
    if (done != null) return Future.value(done);
    return _loading ??= () async {
      try {
        final c = PictureCatalog.fromJson(jsonDecode(await (bundle ?? rootBundle).loadString(manifest)));
        return loaded = c;
      } on Object catch (e) {
        debugPrint('pictures: the manifest: $e');
        _loading = null;
        return const PictureCatalog([]);
      }
    }();
  }

  final List<PictureSetInfo> sets;

  /// [id] (`set1/fox`) is a picture of this catalog.
  bool knows(String id) {
    final parts = id.split('/');
    if (parts.length != 2) return false;
    for (final s in sets) {
      if (s.id == parts[0]) return s.animals.any((a) => a.id == parts[1]);
    }
    return false;
  }
}

/// What a picture is drawn from, once the window may draw it.
sealed class ShownPicture {
  const ShownPicture();
}

/// A drawn picture of the bundled catalog.
final class DrawnPicture extends ShownPicture {
  const DrawnPicture(this.id);

  /// `set1/fox`: always one the catalog knows.
  final String id;

  /// The asset for a picture drawn [size] logical pixels wide: the 128 px file up to 64 px, the 512 px one above.
  String assetFor(double size) => 'assets/avatars/$id-${size <= 64 ? 128 : 512}.webp';

  @override
  bool operator ==(Object other) => other is DrawnPicture && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A photo: the daemon's rebuilt bytes (`picture_photo`), nothing else.
final class PhotoPicture extends ShownPicture {
  const PhotoPicture(this.id, this.bytes);
  final String id;
  final Uint8List bytes;

  @override
  bool operator ==(Object other) => other is PhotoPicture && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

mixin PicturesMixin on ChangeNotifier {
  XDaemon get daemon;

  /// The `hello_ok.proto` version (`x-control/7` → 7).
  int get daemonProto;
  List<ContactInfo> get contacts;
  void safeNotify();
  void daemonFailed(Object e);

  /// The daemon has pictures (`pictures` answered since unlocking); otherwise nobody has one and nothing can be set.
  bool picturesSupported = false;

  /// A v7 daemon from before pictures said `unknown_command`: not asked again until the next daemon.
  bool _picturesRefused = false;

  /// The daemon's list: the owner's own pictures, then each contact's.
  List<PictureEntry> pictureEntries = const [];

  /// The bundled drawn sets; `null` until loaded.
  PictureCatalog? pictureCatalog = PictureCatalog.loaded;

  /// Rebuilt photos by id, fetched once each; ids asked for since the last list (a failed one waits for the next).
  final Map<String, Uint8List> _photos = {};
  final Set<String> _photosAsked = {};

  /// Ask the daemon for the pictures. `false` when it has none to give (an older daemon).
  Future<bool> refreshPictures() async {
    // An unreadable manifest is asked again next time rather than kept as an empty catalog
    if (pictureCatalog == null) {
      final c = await PictureCatalog.load();
      if (c.sets.isNotEmpty) pictureCatalog = c;
    }
    if (daemonProto < 7 || _picturesRefused) return false;
    try {
      final list = await daemon.pictures();
      picturesSupported = true;
      _setEntries(list);
      return true;
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) {
        _picturesRefused = true;
        picturesSupported = false;
        pictureEntries = const [];
        safeNotify();
        return false;
      }
      if (e.code == XErrorCode.loginRequired || e.code == XErrorCode.locked) daemonFailed(e);
      return false;
    } on XClientException catch (e) {
      daemonFailed(e);
      return false;
    }
  }

  /// Another daemon, locked keys: nothing is known any more.
  void clearPictures() {
    pictureEntries = const [];
    picturesSupported = false;
    _picturesRefused = false;
    _photos.clear();
    _photosAsked.clear();
  }

  /// A picture changed (the `picture` event): the entry replaces the one of the same person or agent. A contact's
  /// photo that has just arrived comes unchecked (`withheld: unavailable`): the daemon checks it in its sandbox on the
  /// next `pictures` (CONTROL §28), so the window asks for the list at once. Up to preview.8 it did not, and a
  /// contact's photo announced while the window was open stayed initials until the next unlock.
  void onPictureEvent(PictureEntry e) {
    if (!picturesSupported) return;
    _setEntries([for (final p in pictureEntries) if (!p.sameOwner(e)) p, e], fetchAll: false);
    if (!e.own && e.photo == null && e.withheld == PictureWithheld.unavailable) _askPictureCheck();
  }

  /// One `pictures` at a time for the photo checks; an event during it asks once more after it.
  Future<void>? _pictureCheck;
  bool _pictureCheckAgain = false;

  void _askPictureCheck() {
    if (_pictureCheck != null) {
      _pictureCheckAgain = true;
      return;
    }
    _pictureCheck = () async {
      do {
        _pictureCheckAgain = false;
        await refreshPictures();
      } while (_pictureCheckAgain);
      _pictureCheck = null;
    }();
  }

  void _setEntries(List<PictureEntry> list, {bool fetchAll = true}) {
    pictureEntries = List.unmodifiable(list);
    // A list asks again for a photo that failed before; an event only for one not asked yet
    if (fetchAll) _photosAsked.removeWhere((id) => !_photos.containsKey(id));
    for (final p in list) {
      final id = p.photo;
      if (id != null && p.withheld == null && !_photos.containsKey(id) && _photosAsked.add(id)) {
        unawaited(_fetchPhoto(id));
      }
    }
    safeNotify();
  }

  Future<void> _fetchPhoto(String id) async {
    try {
      final r = await daemon.picturePhoto(id);
      if (r.id != id || r.data.isEmpty) return;
      _photos[id] = r.data;
      safeNotify();
    } on XClientException catch (e) {
      debugPrint('pictures: photo $id: $e');
    }
  }

  /// What the window may draw for [e]: nothing for a withheld photo, an unknown drawn id, or a photo whose bytes have
  /// not come yet.
  ShownPicture? _shown(PictureEntry? e) {
    if (e == null || e.withheld != null) return null;
    final photo = e.photo;
    if (photo != null) {
      final bytes = _photos[photo];
      return bytes == null ? null : PhotoPicture(photo, bytes);
    }
    final drawn = e.drawn;
    if (drawn != null && (pictureCatalog?.knows(drawn) ?? false)) return DrawnPicture(drawn);
    return null;
  }

  /// The owner's own entry, or the entry of the owner's [agent].
  PictureEntry? ownPictureEntry({String? agent}) {
    for (final p in pictureEntries) {
      if (p.own && p.agent == agent) return p;
    }
    return null;
  }

  /// The owner's picture, or one of the owner's agents' ([agent]).
  ShownPicture? pictureOfMine({String? agent}) => _shown(ownPictureEntry(agent: agent));

  /// The picture of the contact of [linkId] in person, or of its [agent] (as the contact announced it).
  ShownPicture? pictureOfContact(String linkId, {String? agent}) {
    for (final p in pictureEntries) {
      if (p.linkId == linkId && p.agent == agent) return _shown(p);
    }
    return null;
  }

  /// The same by the contact's label (a bubble or an approval names the contact by label).
  ShownPicture? pictureOfContactLabel(String label, {String? agent}) {
    for (final c in contacts) {
      if (c.label == label) return pictureOfContact(c.linkId, agent: agent);
    }
    return null;
  }

  /// Why the contact's picture of [linkId] (in person, or its [agent]) is not shown ([PictureWithheld]); `null` when
  /// nothing was withheld (no picture was announced, or it shows). The card is the only place that says why instead of
  /// silently drawing initials (field feedback 2026-10-06: a check failure must never look the same as "no picture").
  String? pictureWithheldOf(String linkId, {String? agent}) {
    for (final p in pictureEntries) {
      if (p.linkId == linkId && p.agent == agent) return p.withheld;
    }
    return null;
  }

  /// Set the owner's picture, or one of the owner's agents' ([agent]): exactly one of [drawn], [photo] (a path the
  /// daemon reads) or [remove]. Throws the daemon's error ([XClientException]) for the picker to say in words.
  Future<void> setPicture({String? agent, String? drawn, String? photo, bool remove = false}) async {
    final list = await daemon.pictureSet(agent: agent, drawn: drawn, photo: photo, remove: remove);
    picturesSupported = true;
    _setEntries(list);
  }
}
