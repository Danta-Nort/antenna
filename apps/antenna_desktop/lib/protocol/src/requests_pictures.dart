// SPDX-License-Identifier: AGPL-3.0-only
// Profile pictures (x-control/7, CONTROL §28): a part of requests.dart. Owner commands only: an agent connection has
// none of them. A v7 daemon from before pictures answers `unknown_command`, and the window then shows no picture
// actions and draws everybody as before.

part of 'requests.dart';

/// Every picture the window may draw: the owner's own, their agents', and each contact's.
final class PicturesRequest extends XRequest {
  const PicturesRequest();
  @override
  String get cmd => 'pictures';
  @override
  Json get fields => const {};
}

/// Set the picture of the owner, or of the owner's [agent]: exactly one of [drawn] (an id such as `set1/fox`),
/// [photo] (an absolute path the daemon reads, checks in its sandbox and rebuilds) or [remove]. The reply is the full
/// `pictures` list after the change.
final class PictureSetRequest extends XRequest {
  const PictureSetRequest({this.agent, this.drawn, this.photo, this.remove = false})
      : assert((drawn != null ? 1 : 0) + (photo != null ? 1 : 0) + (remove ? 1 : 0) == 1, 'one of drawn/photo/remove');
  final String? agent;
  final String? drawn;
  final String? photo;
  final bool remove;
  @override
  String get cmd => 'picture_set';
  @override
  Json get fields => {
        'agent': ?agent,
        'drawn': ?drawn,
        'photo': ?photo,
        if (remove) 'remove': true,
      };
}

/// A rebuilt photo's bytes by its id ([PictureEntry.photo]).
final class PicturePhotoRequest extends XRequest {
  const PicturePhotoRequest(this.id);
  final String id;
  @override
  String get cmd => 'picture_photo';
  @override
  Json get fields => {'id': id};
}
