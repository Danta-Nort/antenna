// SPDX-License-Identifier: AGPL-3.0-only
// macOS Screen Recording for the screenshot tool (D-UI-27, D-UI-41): the real state of the permission, read before the
// window runs `screencapture -i`, so a missing permission gets the window's own explanation instead of macOS's question
// over the tool and a picture of the desktop. The Runner side is macos/Runner/ScreenAccess.swift (`antenna/screen`).
//
// macOS keeps the grant with the app's designated requirement (Apple TN3127). The app is ad-hoc signed, so that
// requirement is its cdhash, which every build changes: after an update the switch in System Settings can stay on for
// the previous build while this one has no access. CoreGraphics also caches a "no" for the life of the process, so a
// grant made while the window runs shows only after a restart. Linux has no such permission ([NoScreenPermission]): the
// tools there run as before.

import 'dart:io';

import 'package:flutter/services.dart';

/// The pane of System Settings with the switch (Privacy & Security → Screen & System Audio Recording).
const screenRecordingSettingsUrl = 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture';

/// Whether this build of the window may capture the screen.
enum ScreenPermission {
  /// Allowed for this build.
  granted,

  /// Not allowed for this build: never asked, denied, or allowed for an earlier build only.
  missing,

  /// This system has no such permission (Linux).
  notApplicable,

  /// The check could not run (a Runner without the channel): the tool runs as it did before the check existed.
  unknown,
}

/// The Runner's Screen Recording calls.
abstract interface class ScreenPermissionHost {
  /// The state now, without any prompt (`CGPreflightScreenCaptureAccess`).
  Future<ScreenPermission> check();

  /// Ask macOS (`CGRequestScreenCaptureAccess`): its own question at most once per build, and the app is put into the
  /// list in System Settings. Returns at once with the state now.
  Future<ScreenPermission> request();
}

/// The macOS Runner over `antenna/screen`.
final class ChannelScreenPermission implements ScreenPermissionHost {
  ChannelScreenPermission({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'antenna/screen';
  final MethodChannel _channel;

  /// The macOS host, or [NoScreenPermission] elsewhere.
  static ScreenPermissionHost forPlatform() =>
      Platform.isMacOS ? ChannelScreenPermission() : const NoScreenPermission();

  Future<ScreenPermission> _call(String method) async {
    try {
      final r = await _channel.invokeMethod<Object?>(method);
      return switch (r) {
        true => ScreenPermission.granted,
        false => ScreenPermission.missing,
        _ => ScreenPermission.unknown,
      };
    } on MissingPluginException {
      return ScreenPermission.unknown;
    } on PlatformException {
      return ScreenPermission.unknown;
    }
  }

  @override
  Future<ScreenPermission> check() => _call('preflight');

  @override
  Future<ScreenPermission> request() => _call('request');
}

/// No Screen Recording permission on this system (Linux, and tests that do not model one).
final class NoScreenPermission implements ScreenPermissionHost {
  const NoScreenPermission();

  @override
  Future<ScreenPermission> check() async => ScreenPermission.notApplicable;

  @override
  Future<ScreenPermission> request() async => ScreenPermission.notApplicable;
}
