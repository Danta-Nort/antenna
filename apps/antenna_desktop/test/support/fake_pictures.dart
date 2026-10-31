// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's profile pictures (x-control/7, CONTROL §28). The list, the rebuilt photos and errors are set by
// the test; `picture_set {photo}` reads the file at the path the window sent, as the daemon does, and keeps a
// "rebuilt" image that is never the file's bytes. A fake older than v7, or a v7 fake without
// [FakePictures.picturesEnabled] (a daemon built before pictures), answers `unknown_command`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/protocol/x_control.dart';

/// An 8 × 8 grey JPEG: what the fake "rebuilds" a photo into unless the test says otherwise.
final Uint8List fakeRebuiltJpeg = base64.decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0o'
    'MCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgD'
    'ASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKB'
    'kaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZ'
    'mqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQF'
    'BgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5'
    'OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX'
    '2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwC3RRRXecJ//9k=');

mixin FakePictures {
  // From FakeDaemon.
  List<String> get calls;
  int get protoVersion;
  List<AgentInfo> get agentList;

  /// This daemon has profile pictures (with `protoVersion` 7). On by default: an empty list changes no frame.
  bool picturesEnabled = true;

  /// What `pictures` answers: the owner's own first, then each contact's.
  List<PictureEntry> pictureList = [];

  /// The rebuilt photos by id (`picture_photo`).
  final photoMap = <String, Uint8List>{};

  /// `picture_set` as the window sent it, and the bytes of each photo file as the daemon read them at the call.
  final pictureSetCalls = <PictureSetRequest>[];
  final photoFilesRead = <String, Uint8List>{};

  /// `picture_photo` ids in order.
  final picturePhotoCalls = <String>[];

  /// The next `picture_set` fails with this error (`picture_refused`, `sandbox_unavailable`, …).
  XControlException? pictureSetError;

  /// What the daemon makes of a photo file; by default [fakeRebuiltJpeg].
  Uint8List Function(Uint8List file)? rebuildPhoto;

  int _photoSeq = 0;

  void _v7pictures(String cmd) {
    calls.add(cmd);
    if (protoVersion < 7 || !picturesEnabled) {
      throw XControlException(XErrorCode.unknownCommand, 'unknown command "$cmd"');
    }
  }

  /// Put a rebuilt photo in and return its id (for the test's own entries).
  String addPhoto(Uint8List bytes) {
    final id = (0x1b2c3d4e5f600000 + (++_photoSeq)).toRadixString(16).padLeft(16, '0');
    photoMap[id] = bytes;
    return id;
  }

  Future<List<PictureEntry>> pictures() async {
    _v7pictures('pictures');
    return [...pictureList];
  }

  Future<List<PictureEntry>> pictureSet({String? agent, String? drawn, String? photo, bool remove = false}) async {
    _v7pictures('picture_set');
    pictureSetCalls.add(PictureSetRequest(agent: agent, drawn: drawn, photo: photo, remove: remove));
    final err = pictureSetError;
    if (err != null) {
      pictureSetError = null;
      throw err;
    }
    if (agent != null && !agentList.any((a) => a.name == agent)) {
      throw const XControlException(XErrorCode.notFound, 'no such agent');
    }
    if (drawn != null && !RegExp(r'^set[0-9]{1,3}/[a-z][a-z0-9-]{0,31}$').hasMatch(drawn)) {
      throw const XControlException(XErrorCode.badRequest, 'bad picture id');
    }
    String? photoId;
    if (photo != null) {
      if (!photo.startsWith('/')) throw const XControlException(XErrorCode.badRequest, 'photo: not an absolute path');
      final Uint8List file;
      try {
        file = File(photo).readAsBytesSync();
      } on FileSystemException {
        throw const XControlException(XErrorCode.notFound, 'photo: no such file');
      }
      photoFilesRead[photo] = file;
      photoId = addPhoto((rebuildPhoto ?? (_) => fakeRebuiltJpeg)(file));
    }
    pictureList.removeWhere((p) => p.own && p.agent == agent);
    if (!remove) {
      final e = PictureEntry(agent: agent, drawn: drawn, photo: photoId, updatedMs: 1000 + pictureSetCalls.length);
      // Own pictures first: the person, then the agents
      final at = agent == null ? 0 : pictureList.where((p) => p.own).length;
      pictureList.insert(at, e);
    }
    return [...pictureList];
  }

  Future<PicturePhotoReply> picturePhoto(String id) async {
    _v7pictures('picture_photo');
    picturePhotoCalls.add(id);
    final b = photoMap[id];
    if (b == null) throw const XControlException(XErrorCode.notFound, 'no such photo');
    return PicturePhotoReply(id: id, mime: 'image/jpeg', data: b);
  }
}
