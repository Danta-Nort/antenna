// SPDX-License-Identifier: AGPL-3.0-only
// Collects dialog/subscription events for tests: wait for an event of a given type matching a condition.

import 'dart:async';

import 'package:antenna_desktop/protocol/x_control.dart';

class Events {
  Events(this.dialog) {
    _sub = dialog.events.listen((e) {
      for (final w in [..._waiters]) {
        if (w.$1(e)) {
          _waiters.remove(w);
          w.$2.complete(e);
          return;
        }
      }
      seen.add(e);
    });
  }

  final XDialog dialog;
  late final StreamSubscription<XEvent> _sub;

  /// Events nobody has taken yet.
  final seen = <XEvent>[];
  final _waiters = <(bool Function(XEvent), Completer<XEvent>)>[];

  /// The next event of type [T] (already received or still to come) that satisfies [where].
  Future<T> next<T extends XEvent>([bool Function(T)? where, Duration timeout = const Duration(seconds: 15)]) {
    bool test(XEvent e) => e is T && (where == null || where(e));
    for (final e in seen) {
      if (test(e)) {
        seen.remove(e);
        return Future.value(e as T);
      }
    }
    final c = Completer<XEvent>();
    _waiters.add((test, c));
    return c.future.timeout(timeout, onTimeout: () {
      throw TimeoutException('no ${T.toString()} event; seen: ${seen.map((e) => e.runtimeType).toList()}');
    }).then((e) => e as T);
  }

  Future<void> close() async {
    await dialog.cancel();
    await _sub.cancel();
  }
}

/// Open an owner session that holds the connection (v2, `login {hold}`) and put the token into the client.
Future<XDialog> openOwnerSession(XDaemon c, String password) async {
  final d = c.login(password);
  final ev = Events(d);
  final s = await ev.next<SessionEvent>();
  c.sessionToken = s.token;
  return d;
}
