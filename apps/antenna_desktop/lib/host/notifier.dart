// SPDX-License-Identifier: AGPL-3.0-only
// System notifications (D-84): "an agent is waiting for your approval" while the window is not in focus. No plugin
// and no native code:
// - Linux: the freedesktop notification service (`org.freedesktop.Notifications.Notify` on the session bus) through
//   the pure-Dart `dbus` package, which the app already ships (desktop_drop uses it). Every desktop that shows
//   notifications (GNOME, KDE, XFCE, …) implements this interface. No session bus or no service: nothing is shown.
// - macOS: `osascript`, `display notification` (Standard Additions; the app already uses osascript, D-58). The texts
//   go in as script arguments (`on run argv`), never into the script text, so nothing needs escaping.
// The window still has the card in the conversation and the counter, so a notification that cannot be shown is not
// an error. The notification carries no request text: only the agent's name, the contact's label (both the owner's
// own) and the action (SPEC §11: a notification, not content; it may show on a locked screen).

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'cli_install.dart' show CliCommandRunner, runWithTimeout;

/// Shows a system notification (replaced in tests).
abstract interface class SystemNotifier {
  /// Show [title] and [body]. Never throws.
  Future<void> show({required String title, required String body});
}

/// The desktop entry and icon name of the app (Linux packaging, `install-desktop-entry.sh`).
const String linuxAppId = 'io.github.danta_nort.antenna';

/// The notifier for this OS; `null` where there is none (neither Linux nor macOS).
SystemNotifier? systemNotifierFor(Map<String, String> env) {
  if (Platform.isLinux) return FreedesktopNotifier(busAddress: env['DBUS_SESSION_BUS_ADDRESS']);
  if (Platform.isMacOS) return MacosNotifier();
  return null;
}

/// A single line without control characters, at most 200 characters: the texts are short facts, not content.
String notificationText(String s) {
  final t = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();
  return t.length > 200 ? '${t.substring(0, 199)}…' : t;
}

/// Linux: `org.freedesktop.Notifications.Notify` on the session bus.
final class FreedesktopNotifier implements SystemNotifier {
  FreedesktopNotifier({this.busAddress});

  /// `DBUS_SESSION_BUS_ADDRESS`; `null`: the package's default (`/run/user/<uid>/bus`).
  final String? busAddress;

  /// How the last attempt ended (tests, diagnostics).
  String? lastResult;

  /// The arguments of `Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout)`.
  static List<DBusValue> notifyArgs({required String title, required String body}) => [
        const DBusString('Antenna'),
        const DBusUint32(0),
        const DBusString(linuxAppId),
        DBusString(notificationText(title)),
        DBusString(notificationText(body)),
        DBusArray.string(const []),
        // The desktop ties the notification to the app's menu entry (its name and icon).
        DBusDict.stringVariant({'desktop-entry': const DBusString(linuxAppId)}),
        const DBusInt32(10000),
      ];

  @override
  Future<void> show({required String title, required String body}) async {
    final address = busAddress;
    final DBusClient client;
    try {
      client = address == null || address.isEmpty
          ? DBusClient.session(introspectable: false)
          : DBusClient(DBusAddress(address), introspectable: false);
    } catch (e) {
      lastResult = 'no session bus: $e';
      return;
    }
    try {
      final r = await DBusRemoteObject(
        client,
        name: 'org.freedesktop.Notifications',
        path: DBusObjectPath('/org/freedesktop/Notifications'),
      )
          .callMethod('org.freedesktop.Notifications', 'Notify', notifyArgs(title: title, body: body),
              replySignature: DBusSignature('u'))
          .timeout(const Duration(seconds: 5));
      lastResult = 'shown: id ${r.returnValues.first.asUint32()}';
    } catch (e) {
      lastResult = 'not shown: $e';
    } finally {
      unawaited(client.close().catchError((_) {}));
    }
  }
}

/// macOS: `osascript -e 'display notification …'`.
final class MacosNotifier implements SystemNotifier {
  MacosNotifier({CliCommandRunner? run}) : _run = run ?? runWithTimeout;

  final CliCommandRunner _run;

  /// How the last attempt ended (tests, diagnostics).
  String? lastResult;

  /// The command: the script reads both texts from its arguments.
  static (String, List<String>) command({required String title, required String body}) => (
        '/usr/bin/osascript',
        [
          '-e', 'on run argv',
          '-e', 'display notification (item 2 of argv) with title (item 1 of argv)',
          '-e', 'end run',
          // The title comes first and is ours ("Antenna: …"), so no argument can be taken for an option.
          notificationText(title), notificationText(body),
        ],
      );

  @override
  Future<void> show({required String title, required String body}) async {
    final (exe, args) = command(title: title, body: body);
    try {
      final r = await _run(exe, args, timeout: const Duration(seconds: 5));
      lastResult = 'exit ${r.exitCode}${r.exitCode == 0 ? '' : ': ${r.stderr}'}';
    } catch (e) {
      lastResult = 'not shown: $e';
    }
  }
}
