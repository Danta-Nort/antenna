// SPDX-License-Identifier: AGPL-3.0-only
// Screen Recording on the window's side (lib/host/screen_permission.dart): what goes over `antenna/screen` to the macOS
// Runner (ScreenAccess.swift) and how its replies are read; a Runner without the channel is "could not check", never
// "missing"; Linux has no such permission. CoreGraphics itself is checked on a Mac.

import 'dart:io';

import 'package:antenna_desktop/host/screen_permission.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ChannelScreenPermission.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('preflight and request: a Bool from the Runner, nothing else sent', () async {
    final calls = <MethodCall>[];
    Object? reply = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
    final h = ChannelScreenPermission();
    expect(await h.check(), ScreenPermission.granted);
    reply = false;
    expect(await h.check(), ScreenPermission.missing);
    expect(await h.request(), ScreenPermission.missing);
    reply = 'yes';
    expect(await h.check(), ScreenPermission.unknown, reason: 'only a Bool is an answer');
    expect([for (final c in calls) (c.method, c.arguments)], [
      ('preflight', null),
      ('preflight', null),
      ('request', null),
      ('preflight', null),
    ]);
  });

  test('a Runner without the channel, or an error: could not check (the tool runs as before)', () async {
    expect(await ChannelScreenPermission().check(), ScreenPermission.unknown);
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'failed'));
    expect(await ChannelScreenPermission().request(), ScreenPermission.unknown);
  });

  test('no such permission off macOS', () async {
    expect(await const NoScreenPermission().check(), ScreenPermission.notApplicable);
    expect(await const NoScreenPermission().request(), ScreenPermission.notApplicable);
    expect(ChannelScreenPermission.forPlatform(), Platform.isMacOS ? isA<ChannelScreenPermission>() : isA<NoScreenPermission>());
  });
}
