// SPDX-License-Identifier: AGPL-3.0-only
// Invite links that open the app (`antenna://pair#…`):
// - macOS: the scheme is in Info.plist (CFBundleURLTypes); the system hands the link to the app, AppDelegate queues
//   it, and the window collects it over the `antenna/links` channel (`takePending`, nudged by `linksAvailable`);
// - Linux: a .desktop file with `x-scheme-handler/antenna` launches `antenna-desktop <link>`; if a window is already
//   open, the new process passes the link to it over a unix socket in `$XDG_RUNTIME_DIR` and exits.
// The window only pre-fills the link in "Join": a person still enters the verification code, and the owner the
// password.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/invite_link.dart';

/// Links that reached the app; the main screen takes them and opens "Join".
class IncomingLinks extends ChangeNotifier {
  IncomingLinks._();
  static final instance = IncomingLinks._();

  final List<String> _pending = [];

  /// Accept a link in any form (`antenna://`, `x://`, `https://antenna.contact/#…`); anything else is ignored.
  void add(String raw) {
    final l = normalizeInviteLink(raw);
    if (l == null) return;
    _pending.add(l);
    notifyListeners();
  }

  /// The next link (removed from the queue).
  String? take() => _pending.isEmpty ? null : _pending.removeAt(0);

  bool get hasPending => _pending.isNotEmpty;

  @visibleForTesting
  void clear() => _pending.clear();

  static const _channel = MethodChannel('antenna/links');

  /// macOS: collect the links the system launched the app with, and listen for new ones.
  Future<void> attachMacos() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'linksAvailable') await _pullMacos();
      return null;
    });
    await _pullMacos();
  }

  Future<void> _pullMacos() async {
    try {
      final links = await _channel.invokeListMethod<String>('takePending') ?? const [];
      links.forEach(add);
    } on MissingPluginException {
      // A build without the handler (tests, an old Runner): no links from the system.
    } on PlatformException catch (e) {
      debugPrint('antenna/links: $e');
    }
  }
}

/// Linux: one window instance per user session receives links. The path is `$XDG_RUNTIME_DIR/antenna-window.sock`
/// (a 0700 directory owned by this user only); without XDG_RUNTIME_DIR there is no forwarding and each window is on
/// its own.
class LinkRelay {
  LinkRelay._(this.path, this._server);
  final String path;
  final ServerSocket _server;

  static String? pathFor(Map<String, String> env) {
    // Windows: never a unix socket (D-135), so no forwarding there.
    if (Platform.isWindows) return null;
    final dir = env['XDG_RUNTIME_DIR'];
    if (dir == null || dir.isEmpty || !Directory(dir).existsSync()) return null;
    return '$dir/antenna-window.sock';
  }

  /// Pass a link to an already open window. `true` means the window received it.
  static Future<bool> forward(String path, String link) async {
    try {
      final s = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0,
          timeout: const Duration(milliseconds: 500));
      s.add(utf8.encode('$link\n'));
      await s.flush();
      final ack = await utf8.decoder.bind(s).join().timeout(const Duration(seconds: 2), onTimeout: () => '');
      s.destroy();
      return ack.trim() == 'ok';
    } on Object {
      return false;
    }
  }

  /// Become the window that links are forwarded to. A socket left over from a crashed window is replaced.
  static Future<LinkRelay?> serve(String path, void Function(String link) onLink) async {
    final addr = InternetAddress(path, type: InternetAddressType.unix);
    ServerSocket server;
    try {
      server = await ServerSocket.bind(addr, 0);
    } on SocketException {
      // Taken: if a live window answers, it is not us; if the file is stale, remove it and take over.
      if (await _alive(path)) return null;
      try {
        File(path).deleteSync();
        server = await ServerSocket.bind(addr, 0);
      } on Object {
        return null;
      }
    }
    try {
      Process.runSync('chmod', ['600', path]);
    } on Object {
      // The XDG_RUNTIME_DIR directory is 0700 anyway.
    }
    server.listen((c) {
      final buf = StringBuffer();
      c.cast<List<int>>().transform(utf8.decoder).listen(
        (chunk) {
          buf.write(chunk);
          if (buf.length > 8192) c.destroy();
          if (buf.toString().contains('\n')) {
            final line = buf.toString().split('\n').first.trim();
            if (looksLikeInviteLink(line)) {
              onLink(line);
              c.add(utf8.encode('ok\n'));
            } else {
              c.add(utf8.encode('no\n'));
            }
            unawaited(c.flush().then((_) => c.close()));
          }
        },
        onError: (_) => c.destroy(),
        cancelOnError: true,
      );
    });
    return LinkRelay._(path, server);
  }

  static Future<bool> _alive(String path) async {
    try {
      final s = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> close() async {
    await _server.close();
    try {
      File(path).deleteSync();
    } on Object {
      // Already gone.
    }
  }
}
