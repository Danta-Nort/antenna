// SPDX-License-Identifier: AGPL-3.0-only
// The time left of an approval request in words (state/format.dart `expiresIn`). The maintainer read "08:35" in the
// corner of a request from another own computer as the time of day (it was 21:53 there). Every approval card now says
// "Expires in 8 min": the cards here (the conversation, the list) and the cards of another computer's requests in My
// devices and the agent map's "Approve on …".

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/format.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_touch_id.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

/// A clock-like `08:35` or `1:05:00` anywhere in [s].
final _clock = RegExp(r'\b\d{1,2}:\d\d\b');

void main() {
  test('the time left in words, never as a clock', () {
    expect(expiresIn(en, const Duration(minutes: 8, seconds: 35)), 'Expires in 8 min');
    expect(expiresIn(en, const Duration(hours: 1, minutes: 5)), 'Expires in 1 h 5 min');
    expect(expiresIn(en, const Duration(seconds: 35)), 'Expires in 35 s');
    expect(expiresIn(en, Duration.zero), 'Expired');
    expect(expiresIn(en, const Duration(seconds: -3)), 'Expired');
    expect(expiresIn(ru, const Duration(minutes: 8, seconds: 35)), ru.approvalsExpiresIn(ru.durationMinutes(8)));
    for (final d in [const Duration(minutes: 8, seconds: 35), const Duration(hours: 2), const Duration(seconds: 9)]) {
      expect(expiresIn(en, d), isNot(matches(_clock)));
    }
  });

  testWidgets('a request on another own computer says "Expires in 9 min", not 09:00', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..devicesEnabled = true;
    final h = FakeTouchId(system: true);
    h.preset(h.dirFor(d.socketPath), d.ownerKeys);
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, touchId: h);
    await m.connect();
    d.devicesState = demoDevices(touchKeyId: d.ownerKeys.keys.values.firstOrNull?.keyId ?? '');
    await m.refreshDevices();
    t.view.physicalSize = const Size(1440, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('nav-devices')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('device-request-k2ab9c1d')), findsOneWidget);
    final shown = [
      for (final id in ['k2ab9c1d', 'p7xq2m4n']) t.widget<Text>(find.byKey(Key('device-request-expires-$id'))).data!,
    ];
    expect(shown, isNotEmpty);
    for (final s in shown) {
      expect(s, startsWith('Expires in '));
      expect(s, isNot(matches(_clock)));
    }
    expect(shown, contains(en.approvalsExpiresIn(en.durationMinutes(9))));
  });

  testWidgets('the cards of requests here say the same', (t) async {
    final a = ApprovalInfo(
      id: 'ap-time',
      state: 'pending',
      requester: 'claude',
      contact: jordan.label,
      contactTrust: jordan.trust,
      action: 'share_file',
      target: jordan.label,
      reasons: const ['secret:private_key'],
      grants: const Grants(read: 'local file /tmp/build.log', write: '-', commands: '-', send: 'file build.log'),
      quote: '/tmp/build.log → build.log',
      fingerprint: 'f',
      createdMs: ms(fixedNow),
      expiresMs: ms(fixedNow.add(const Duration(minutes: 8, seconds: 35))),
      linkId: jordan.linkId,
      targetLinkId: jordan.linkId,
    );
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: [a]);
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    final pill = find.byKey(const Key('approval-expires-ap-time'));
    expect(pill, findsWidgets);
    expect(t.widget<Text>(pill.first).data, 'Expires in 8 min');
    expect(find.text('08:35 left'), findsNothing);
  });
}
