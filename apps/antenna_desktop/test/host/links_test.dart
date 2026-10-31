// SPDX-License-Identifier: AGPL-3.0-only
// Invite links that open the app: parsing every link form (x://, antenna://, the website page), handing a link to an
// already open window (Linux, unix socket), "Join" with the link filled in.

import 'dart:io';

import 'package:antenna_desktop/host/links.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/invite_link.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

void main() {
  final body = demoLink.substring('x://pair#'.length);

  group('normalizeInviteLink', () {
    test('x:// and antenna:// pass through (daemon accepts both)', () {
      expect(normalizeInviteLink(demoLink), demoLink);
      expect(normalizeInviteLink('  antenna://pair#$body\n'), 'antenna://pair#$body');
    });
    test('the site handler page: https://antenna.contact/#<body> or #<full link>', () {
      expect(normalizeInviteLink('https://antenna.contact/#$body'), 'x://pair#$body');
      expect(normalizeInviteLink('https://www.antenna.contact#$body'), 'x://pair#$body');
      expect(normalizeInviteLink('antenna.contact/#$body'), 'x://pair#$body');
      expect(normalizeInviteLink('https://antenna.contact/#$demoLink'), demoLink);
      expect(normalizeInviteLink('https://antenna.contact/#antenna://pair#$body'), 'antenna://pair#$body');
      expect(normalizeInviteLink('https://antenna.contact/#${Uri.encodeComponent(demoLink)}'), demoLink);
    });
    test('a link wrapped by a messenger (spaces, line breaks) still parses', () {
      final wrapped = '${demoLink.substring(0, 40)}\n  ${demoLink.substring(40)}';
      expect(normalizeInviteLink(wrapped), demoLink);
    });
    test('not an invite → null', () {
      expect(normalizeInviteLink(''), isNull);
      expect(normalizeInviteLink('https://antenna.contact/#beta'), isNull);
      expect(normalizeInviteLink('https://evil.example/#$body'), isNull, reason: 'only our site');
      expect(normalizeInviteLink('x://join#$body'), isNull);
      expect(normalizeInviteLink('antenna://pair#'), isNull);
      expect(normalizeInviteLink('hello'), isNull);
    });
  });

  test('Linux: a second window forwards the link to the first and exits', () async {
    final dir = await Directory('/tmp').createTemp('alink-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/antenna-window.sock';
    expect(LinkRelay.pathFor({'XDG_RUNTIME_DIR': dir.path}), path);
    expect(LinkRelay.pathFor({}), isNull);
    expect(await LinkRelay.forward(path, demoLink), isFalse, reason: 'nobody listens yet');
    final got = <String>[];
    final relay = await LinkRelay.serve(path, got.add);
    expect(relay, isNotNull);
    expect(await LinkRelay.serve(path, got.add), isNull, reason: 'one window owns the socket');
    expect(await LinkRelay.forward(path, demoLink), isTrue);
    expect(await LinkRelay.forward(path, 'rm -rf /'), isFalse, reason: 'only invite links are accepted');
    expect(got, [demoLink]);
    await relay!.close();
    // A socket left by a crashed window (the file remains): the next window takes it over.
    final stale = await LinkRelay.serve(path, got.add);
    expect(stale, isNotNull);
    await stale!.close();
  }, skip: Platform.isWindows ? 'no unix socket on Windows (D-135)' : false);

  testWidgets('a link that arrived while keys were locked opens «Join» with it after unlock', (t) async {
    final d = FakeDaemon(state: DaemonState.locked, contacts: demoContacts(), history: demoHistory());
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(IncomingLinks.instance.clear);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 300));
    IncomingLinks.instance.add('https://antenna.contact/#$body');
    await t.pump();
    expect(find.byType(JoinDialog), findsNothing, reason: 'gate screen: the link waits');
    await t.enterText(find.byKey(const Key('password')), d.password);
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(JoinDialog), findsOneWidget);
    final field = t.widget<TextField>(find.byKey(const Key('join-link')));
    expect(field.controller!.text, 'x://pair#$body');
    // A person still types the code: joining starts only from the button, with the password.
    expect(d.dialogs.where((x) => x.request is JoinRequest), isEmpty);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('join-start')));
    await t.pump(const Duration(milliseconds: 300));
    expect((d.dialogs.lastWhere((x) => x.request is JoinRequest).request as JoinRequest).link, 'x://pair#$body');
  });
}
