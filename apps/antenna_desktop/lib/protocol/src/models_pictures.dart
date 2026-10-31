// SPDX-License-Identifier: AGPL-3.0-only
// Profile pictures (x-control/7, CONTROL §28; crates/antenna-proto/src/control/pictures.rs): a part of models.dart.
// The owner chooses a drawn picture or a photo for themselves and for each of their agents; contacts announce theirs.
// A photo reaches the window only as the daemon's rebuilt image (`picture_photo`), never the bytes the owner chose or
// a contact sent.

part of 'models.dart';

/// Why a contact's photo is not shown ([PictureEntry.withheld]): the window draws initials instead.
abstract final class PictureWithheld {
  /// The contact is at trust level 1, where no files are taken (SPEC §9).
  static const level = 'level';

  /// The photo did not pass the image check.
  static const refused = 'refused';

  /// This computer has no working check sandbox, so no photo from a contact is shown.
  static const unavailable = 'unavailable';
}

/// One picture the window may draw (`pictures`, `picture_set`, the `picture` event): whose it is and what it is.
/// Neither [drawn] nor [photo]: initials.
final class PictureEntry {
  const PictureEntry(
      {this.contact, this.linkId, this.agent, this.drawn, this.photo, this.withheld, this.updatedMs = 0});

  factory PictureEntry.fromJson(Json j) => PictureEntry(
        contact: _optStr(j, 'contact'),
        linkId: _optStr(j, 'link_id'),
        agent: _optStr(j, 'agent'),
        drawn: _optStr(j, 'drawn'),
        photo: _optStr(j, 'photo'),
        withheld: _optStr(j, 'withheld'),
        updatedMs: _optInt(j, 'updated_ms') ?? 0,
      );

  /// The contact's label; `null` for this node's own pictures (the owner's and the owner's agents').
  final String? contact;

  /// The contact's link (hex); `null` for this node's own pictures.
  final String? linkId;

  /// An agent: one of the owner's (own pictures) or one the contact announced; `null` for the person.
  final String? agent;

  /// A drawn picture by id (`set1/fox`): drawn from the window's own assets; an id it does not know is initials.
  final String? drawn;

  /// A photo the daemon rebuilt: its id (16 hex); `picture_photo` returns the bytes.
  final String? photo;

  /// A contact's photo that is not shown, and why ([PictureWithheld]).
  final String? withheld;

  /// When the picture was chosen (own) or received, Unix ms.
  final int updatedMs;

  /// One of this node's own pictures (the owner's, or one of the owner's agents').
  bool get own => linkId == null;

  /// The same person or agent as [other] (the key an event replaces).
  bool sameOwner(PictureEntry other) => other.linkId == linkId && other.agent == agent;

  /// The same entry in the protocol's shape (the fake daemon, tests).
  Json toJson() => {
        'contact': ?contact,
        'link_id': ?linkId,
        'agent': ?agent,
        'drawn': ?drawn,
        'photo': ?photo,
        'withheld': ?withheld,
        'updated_ms': updatedMs,
      };

  @override
  String toString() =>
      'PictureEntry(${linkId == null ? 'own' : 'contact'}, ${agent == null ? 'person' : 'agent'}, '
      '${drawn ?? (photo != null ? 'photo' : withheld ?? 'initials')})';
}

/// `pictures`, and the reply to `picture_set` (the full list after the change): the owner's own pictures first, then
/// each contact's.
final class PicturesReply extends Reply {
  const PicturesReply(this.pictures);

  factory PicturesReply.fromJson(Json j) =>
      PicturesReply([for (final p in _list(j, 'pictures')) PictureEntry.fromJson(p)]);

  final List<PictureEntry> pictures;
}

/// `picture_photo`: the daemon's rebuilt photo (a JPEG it encoded from pixels).
final class PicturePhotoReply extends Reply {
  const PicturePhotoReply({required this.id, required this.mime, required this.data});

  factory PicturePhotoReply.fromJson(Json j) {
    final Uint8List data;
    try {
      data = base64.decode(_str(j, 'data_base64'));
    } on FormatException {
      throw const XProtocolException('field "data_base64": bad base64');
    }
    return PicturePhotoReply(id: _str(j, 'id'), mime: _optStr(j, 'mime') ?? 'image/jpeg', data: data);
  }

  final String id;
  final String mime;
  final Uint8List data;

  @override
  String toString() => 'PicturePhotoReply($id, $mime, ${data.length} bytes)';
}

/// A picture changed (the owner's in another window or the CLI, or one a contact announced): the entry as it is now.
final class PictureEvent extends XEvent {
  const PictureEvent(this.entry);
  final PictureEntry entry;
}
