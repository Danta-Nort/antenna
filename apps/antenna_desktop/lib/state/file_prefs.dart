// SPDX-License-Identifier: AGPL-3.0-only
// An own computer's file settings in the window (D-130, D-UI-46): where its files and its agents' files are saved, and
// which of its programs and installers are saved without waiting. The daemon keeps both and checks every rule (level
// 5 only, a folder in the owner's home, the password or one touch to set); the window shows `contacts[].save_dirs`
// and `contacts[].file_allow` and asks again after a change.

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

/// An allowlist entry for all programs (ELF, Mach-O, PE).
const allowExecutables = 'executables';

/// An allowlist entry for all installers and disk images.
const allowInstallers = 'installers';

/// An extension the allowlist takes: a dot and 1–16 letters or digits (`.dmg`), as the daemon checks it.
final allowExtension = RegExp(r'^\.[A-Za-z0-9]{1,16}$');

mixin FilePrefsMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  Future<void> refreshContacts();

  /// Where files from [c] (or from its [agent]) are saved: the folder set for them, else `null` (the agent's falls
  /// back to the contact's, the contact's to the link's `shared/`).
  String? saveDirOf(ContactInfo c, {String? agent}) {
    for (final d in c.saveDirs) {
      if (d.agent == agent) return d.path;
    }
    return null;
  }

  /// Save files from [c] (or [agent]) into [path]. The daemon's error, or `null`.
  Future<Object?> setSaveDir(ContactInfo c, String path, {String? agent, required OwnerAuth auth}) =>
      _change(() => ownerOp(auth, (d, pw) => d.fileSaveDir(c.label, agent: agent, path: path, password: pw)));

  /// Back to the default folder (no password). The daemon's error, or `null`.
  Future<Object?> clearSaveDir(ContactInfo c, {String? agent}) =>
      _change(() => daemon.fileSaveDir(c.label, agent: agent));

  /// Let [entries] from [c] through without waiting. The daemon's error, or `null`.
  Future<Object?> allowFiles(ContactInfo c, List<String> entries, {required OwnerAuth auth}) =>
      _change(() => ownerOp(auth, (d, pw) => d.fileAllow(c.label, entries, password: pw)));

  /// Take [entries] off [c]'s allowlist (no password). The daemon's error, or `null`.
  Future<Object?> disallowFiles(ContactInfo c, List<String> entries) =>
      _change(() => daemon.fileDisallow(c.label, entries: entries));

  Future<Object?> _change(Future<Object?> Function() op) async {
    try {
      await op();
    } on XClientException catch (e) {
      return e;
    }
    await refreshContacts();
    return null;
  }
}
