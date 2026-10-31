// SPDX-License-Identifier: AGPL-3.0-only
// Approval requests must not run out unnoticed (D-84, D-114), on the fake daemon and a fake notifier: a new request
// on another own computer raises a system notification while the window is not in focus (the computer, who asks,
// the action, the time left); the requests already there when the window first looked do not; once per request, about
// two minutes before it runs out, a reminder (here and there), never again and nothing once it is decided or gone; no
// request text ever reaches a notification. The reminder's own timer runs in a model of its own at the end.

import 'package:antenna_desktop/host/notifier.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/approval_alerts.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

class _Notifier implements SystemNotifier {
  final shown = <(String, String)>[];
  @override
  Future<void> show({required String title, required String body}) async => shown.add((title, body));
}

const _secret = 'SECRET merger terms for Jordan';
const _mini = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

int _ms(DateTime t) => t.millisecondsSinceEpoch;

DeviceApproval _deviceRequest(String id, {required DateTime created, Duration ttl = const Duration(minutes: 10)}) =>
    DeviceApproval(
      id: id,
      action: 'send_message',
      requester: 'codex',
      contact: emilyName,
      contactTrust: 3,
      target: emilyName,
      reasons: const ['no_write_down'],
      quote: _secret,
      fingerprint: '9c41e07a3b5d0f12',
      createdMs: _ms(created),
      expiresMs: _ms(created.add(ttl)),
    );

/// The Mac mini as it last said, with [requests] pending; its clock runs [skew] ahead of this one's (only the
/// difference within its own clock counts).
DevicesReply _devices(List<DeviceApproval> requests, {required DateTime received, Duration skew = Duration.zero}) =>
    DevicesReply(
      self: const ThisDevice(name: 'Mayas-MacBook-Pro', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
      devices: [
        DeviceInfo(
          contact: 'Mac mini',
          linkId: _mini,
          presence: 'online',
          supported: true,
          receivedMs: _ms(received),
          status: DeviceView(
            atMs: _ms(received.add(skew)),
            name: 'Mac-mini',
            os: 'macos',
            arch: 'aarch64',
            version: 'antennad 0.2.0',
            approvals: requests,
            pendingApprovals: requests.length,
          ),
        ),
      ],
    );

ApprovalInfo _here(String id,
        {required DateTime created, Duration ttl = const Duration(minutes: 10), String state = 'pending'}) =>
    ApprovalInfo(
      id: id,
      state: state,
      requester: 'claude',
      contact: jordanName,
      contactTrust: 3,
      action: 'share_file',
      target: jordanName,
      grants: const Grants(read: 'local file /tmp/plan.txt', write: '-', commands: '-', send: 'file plan.txt'),
      quote: _secret,
      fingerprint: '5e11c0aa',
      createdMs: _ms(created),
      expiresMs: _ms(created.add(ttl)),
    );

/// The notification body: who asks and what, here (`claude` shares a file with Jordan) or on the Mac mini (`codex`
/// sends Emily a message), and the minutes left.
String _body(String where, int minutes) {
  final body = where == 'device'
      ? en.notifyApprovalBody('codex', '${en.actionSendMessage} → $emilyName')
      : en.notifyApprovalBody('claude', '${en.actionShareFile} → $jordanName');
  return '$body · ${en.notifyApprovalLeft(minutes)}';
}

void main() {
  late DateTime clock;
  late FakeDaemon d;
  late AppModel m;
  late _Notifier notifier;

  /// The window after sign-in, which reads [devices] first: what is pending there then is not news.
  Future<void> app(WidgetTester t, {List<DeviceApproval> devices = const []}) async {
    clock = fixedNow;
    d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..devicesEnabled = true
      ..devicesState = _devices(devices, received: fixedNow);
    m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => clock);
    await m.connect();
    notifier = _Notifier();
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, notifier: notifier));
    await t.pump(const Duration(milliseconds: 300));
  }

  void away(WidgetTester t) => t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  void back(WidgetTester t) => t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

  testWidgets('a new request on another own computer: the computer, who asks, the action, the time left; not the text',
      (t) async {
    // What was there when the window first looked is not news (as with the requests here).
    await app(t, devices: [_deviceRequest('old-1', created: fixedNow)]);
    expect(m.ownDevices.single.status!.approvals.single.id, 'old-1');
    away(t);
    await m.refreshDevices();
    await t.pump();
    expect(notifier.shown, isEmpty);

    // A minute later its status brings a new one; that computer's clock is 3 hours off, which does not matter.
    clock = clock.add(const Duration(minutes: 1));
    final created = clock.add(const Duration(hours: 3));
    d.devicesState = _devices([
      _deviceRequest('old-1', created: fixedNow.add(const Duration(hours: 3))),
      _deviceRequest('new-2', created: created.subtract(const Duration(minutes: 1))),
    ], received: clock, skew: const Duration(hours: 3));
    await m.refreshDevices();
    await t.pump();
    expect(notifier.shown, [(en.notifyDeviceApprovalTitle('Mac mini'), _body('device', 9))]);
    expect(notifier.shown.every((n) => !'${n.$1} ${n.$2}'.contains('SECRET')), isTrue, reason: 'never the text');

    // The same status again, or the computer gone offline and back: not news again.
    await m.refreshDevices();
    d.devicesState = _devices(const [], received: clock);
    await m.refreshDevices();
    d.devicesState = _devices([_deviceRequest('new-2', created: clock)], received: clock);
    await m.refreshDevices();
    await t.pump();
    expect(notifier.shown, hasLength(1));

    // In focus: My devices' counter is enough.
    back(t);
    d.devicesState = _devices([_deviceRequest('new-3', created: clock)], received: clock);
    await m.refreshDevices();
    await t.pump();
    expect(notifier.shown, hasLength(1));
    away(t);
    back(t);
  });

  testWidgets('one reminder per request about two minutes before it runs out, here and on another computer', (t) async {
    await app(t, devices: [_deviceRequest('dev-1', created: fixedNow, ttl: const Duration(minutes: 9))]);
    away(t);
    // A request here: its news says the time left.
    m.handleEvent(ApprovalEvent(_here('here-1', created: clock)));
    // One here that the owner denies before its reminder, and one already short of time.
    m.handleEvent(ApprovalEvent(_here('here-2', created: clock, ttl: const Duration(minutes: 5))));
    m.handleEvent(ApprovalEvent(_here('here-3', created: clock, ttl: const Duration(seconds: 90))));
    await t.pump();
    expect(notifier.shown, [
      (en.notifyApprovalTitle, _body('here', 10)),
      (en.notifyApprovalTitle, _body('here', 5)),
      (en.notifyApprovalTitle, _body('here', 2)),
    ]);
    notifier.shown.clear();
    m.handleEvent(ApprovalEvent(_here('here-2', created: clock, ttl: const Duration(minutes: 5), state: 'denied')));

    // Seven minutes on: the Mac mini's request has two minutes left.
    clock = clock.add(const Duration(minutes: 7));
    m.scanApprovalAlerts();
    await t.pump();
    expect(notifier.shown, [(en.notifyDeviceApprovalSoonTitle('Mac mini'), _body('device', 2))]);

    // A minute more: the one here; the Mac mini's is not repeated, the denied one and the short one never come.
    clock = clock.add(const Duration(minutes: 1));
    m.scanApprovalAlerts();
    m.scanApprovalAlerts();
    await t.pump();
    expect(notifier.shown, [
      (en.notifyDeviceApprovalSoonTitle('Mac mini'), _body('device', 2)),
      (en.notifyApprovalSoonTitle, _body('here', 2)),
    ]);
    expect(notifier.shown.every((n) => !'${n.$1} ${n.$2}'.contains('SECRET')), isTrue, reason: 'never the text');

    // Decided or run out: nothing more, however long the window waits.
    m.handleEvent(ApprovalEvent(_here('here-1', created: fixedNow, state: 'approved')));
    clock = clock.add(const Duration(minutes: 30));
    m.scanApprovalAlerts();
    await t.pump();
    expect(notifier.shown, hasLength(2));
    back(t);
  });

  testWidgets('a reminder that comes while the window is in focus is not shown, nor later', (t) async {
    await app(t);
    m.handleEvent(ApprovalEvent(_here('here-1', created: clock)));
    clock = clock.add(const Duration(minutes: 8, seconds: 30));
    m.scanApprovalAlerts();
    await t.pump();
    expect(notifier.shown, isEmpty, reason: 'the card shows its countdown');
    away(t);
    clock = clock.add(const Duration(seconds: 30));
    m.scanApprovalAlerts();
    await t.pump();
    expect(notifier.shown, isEmpty);
    back(t);
  });

  testWidgets('the reminder\'s timer: set for two minutes before the end, it fires once', (t) async {
    final r = _Requests();
    addTearDown(r.disposeApprovalAlerts);
    final alerts = <ApprovalAlert>[];
    r.approvalAlerts.listen(alerts.add);
    r.approvals['here-1'] = _here('here-1', created: fixedNow, ttl: const Duration(minutes: 3));
    r.scanApprovalAlerts();
    // The clock moves with the timer.
    r.clock = fixedNow.add(const Duration(seconds: 50));
    await t.pump(const Duration(seconds: 50));
    expect(alerts, isEmpty);
    r.clock = fixedNow.add(const Duration(minutes: 1));
    await t.pump(const Duration(seconds: 10));
    expect(alerts.map((a) => (a.kind, a.id, a.left)),
        [(ApprovalAlertKind.expiresSoon, 'here-1', const Duration(minutes: 2))]);
    r.clock = fixedNow.add(const Duration(minutes: 2));
    await t.pump(const Duration(minutes: 1));
    expect(alerts, hasLength(1));
  });

  testWidgets('a request far off: the timer looks again within five minutes, then reminds', (t) async {
    final r = _Requests();
    addTearDown(r.disposeApprovalAlerts);
    final alerts = <ApprovalAlert>[];
    r.approvalAlerts.listen(alerts.add);
    r.approvals['here-1'] = _here('here-1', created: fixedNow);
    r.scanApprovalAlerts();
    r.clock = fixedNow.add(const Duration(minutes: 5));
    await t.pump(const Duration(minutes: 5));
    expect(alerts, isEmpty);
    r.clock = fixedNow.add(const Duration(minutes: 8));
    await t.pump(const Duration(minutes: 3));
    expect(alerts.map((a) => a.id), ['here-1']);
  });
}

/// The alerts alone, with background work on (the window's model runs them with `live`).
class _Requests extends ChangeNotifier with ApprovalAlertsMixin {
  @override
  final Map<String, ApprovalInfo> approvals = {};
  @override
  DevicesReply? devices;
  @override
  bool get live => true;
  DateTime clock = fixedNow;
  @override
  DateTime now() => clock;
}
