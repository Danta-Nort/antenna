// SPDX-License-Identifier: AGPL-3.0-only
// My devices (x-control/7, CONTROL §27, D-106; experimental) against REAL daemons: the Mac mini and the laptop are each
// other's own computers (∞ both ways), Bob is the mini's contact at level 3. The laptop's window (AppModel) answers the
// mini's approval requests: with one touch (the published test key in software in place of the Secure Enclave, signed
// by `openssl` over the mini's challenge and the exact text the window built), with the laptop's password (its daemon's
// device key), and a denial with neither; the mini's daemon checks each against the keys its owner confirmed for the
// laptop, and carries the approved message to Bob. Then "Lend this computer to my teams" on the laptop reaches the
// mini.
// Run: ANTENNAD_BIN=<path to a debug antennad> nice -n 10 flutter test --tags live test/protocol/live_devices_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/soft_owner_key.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Pair [a] (inviting) and [b] at [trust] both ways.
Future<void> _pair(XControlClient a, XdNode an, XControlClient b, XdNode bn, int trust) async {
  final inv = Events(a.open(InviteRequest(trust: trust, ttlSecs: 120, label: bn.name, password: an.password)));
  final created = await inv.next<InviteCreated>();
  final join = Events(b.open(JoinRequest(
    link: created.link,
    trust: trust,
    label: an.name,
    connectTimeoutMs: 5000,
    password: bn.password,
  )));
  final sas = await inv.next<SasEvent>();
  await join.next<NeedInput>((e) => e.isSasCode);
  join.dialog.input(SasCodeInput(sas.code));
  await inv.next<NeedInput>((e) => e.isConfirm);
  inv.dialog.input(ConfirmInput(true, code: sas.code));
  await join.dialog.result;
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final haveOpenssl = hasOpenssl();
  final skip = antennad == null ? noXdReason : (!haveOpenssl ? 'openssl not found: it signs with the test key' : false);

  Future<String> agentAsks(String socket, String token, String text) async {
    final r = await Process.run(xCli!, ['--json', 'send', 'bob', text, '--wait', '0'],
        environment: {'ANTENNA_AGENT_TOKEN': token, 'ANTENNA_SOCKET': socket});
    expect(r.exitCode, 77, reason: '${r.stdout}${r.stderr}');
    return RegExp(r'"id":"([a-z0-9]+)"').firstMatch('${r.stdout}')!.group(1)!;
  }

  test('the laptop answers the mini\'s requests: one touch, the password there, a denial; lending travels', () async {
    final root = await tempRoot();
    final mini = XdNode('mini', root, antennad!);
    final lap = XdNode('lap', root, antennad, env: const {'ANTENNA_OWNER_TEST_KEY': '1'});
    final bob = XdNode('bob', root, antennad);
    await Future.wait([mini.start(), lap.start(), bob.start()]);
    final soft = SoftwareTouchId();
    AppModel? m;
    try {
      final c = XControlClient(mini.socket);
      final l = XControlClient(lap.socket);
      final b = XControlClient(bob.socket);
      await c.init(mini.password);
      await l.init(lap.password);
      await b.init(bob.password);
      await openOwnerSession(c, mini.password);
      await openOwnerSession(l, lap.password);
      await openOwnerSession(b, bob.password);
      await _pair(c, mini, l, lap, 5);
      await _pair(c, mini, b, bob, 3);
      final agent = await c.agentAdd('jarvis', localLevel: 5, password: mini.password, links: ['bob']);

      // The laptop's window, with Touch ID on (the test key enrolled with the password and a proof by itself)
      final w = AppModel(connector: XControlClient.new, socketPath: lap.socket, touchId: soft);
      m = w;
      await w.connect();
      expect(await w.login(lap.password), isNull);
      expect(await w.enrollTouchId(lap.password, reason: 'turn on Touch ID for Antenna'), isNull);
      expect(w.ownerKeyRecord?.keyId, testKeyId);

      // The mini's owner accepts the laptop's Touch ID key (once, with the password there)
      await _until(() async {
        final d = expectReply<DevicesReply>(await c.call(const DevicesRequest())).devices.single;
        return d.offered.any((k) => k.keyId == testKeyId);
      }, what: 'the laptop\'s Touch ID key offered to the mini');
      final confirmed = expectReply<DevicesReply>(await c.call(
          DeviceKeysConfirmRequest(contact: 'lap', keyIds: const [testKeyId], password: mini.password)));
      expect(confirmed.devices.single.confirmed.map((k) => k.keyId), [testKeyId]);

      // A request on the mini reaches the laptop's window, which approves it with one touch
      final one = await agentAsks(mini.socket, agent.token, 'the build report');
      DeviceInfo? dev;
      DeviceApproval? req;
      await _until(() async {
        await w.refreshDevices();
        dev = w.ownDevices.where((d) => d.contact == 'mini').firstOrNull;
        req = dev?.status?.approvals.where((a) => a.id == one).firstOrNull;
        return req != null && dev!.acceptsMine.contains(testKeyId);
      }, what: 'the request and the accepted key in the laptop\'s view');
      expect(w.approveWays(dev!).first.name, 'touchId');
      expect(await w.deviceApproveWithTouchId(dev!, req!, reason: 'approve on mini: send a message'), isNull);
      expect(soft.signed.last, remoteApproveText(linkId: dev!.linkId, id: one, fingerprint: req!.fingerprint),
          reason: 'the touch signed the exact text the mini checks');
      final st = expectReply<ApprovalsReply>(await c.call(const ApprovalsRequest(all: true)))
          .approvals
          .firstWhere((a) => a.id == one);
      expect(st.state, isNot('pending'));
      await _until(() async {
        final h = await b.history('mini', limit: 5);
        return h.messages.any((x) => x.text == 'the build report');
      }, what: 'the approved message at Bob');
      print('TOUCH: request $one approved from the laptop and delivered to Bob');

      // The password typed on the laptop: refused until the mini accepts the laptop's device key, then approved
      final two = await agentAsks(mini.socket, agent.token, 'the second report');
      await _until(() async {
        await w.refreshDevices();
        dev = w.ownDevices.firstWhere((d) => d.contact == 'mini');
        req = dev!.status?.approvals.where((a) => a.id == two).firstOrNull;
        return req != null;
      }, what: 'request two in the laptop\'s view');
      final refused = await w.deviceApproveWithPassword(dev!, req!, PasswordAuth(lap.password));
      expect(refused, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.ownerKeyUnknown));
      final passwordKey = w.devices!.self.passwordKey!.keyId;
      await c.call(DeviceKeysConfirmRequest(contact: 'lap', keyIds: [passwordKey], password: mini.password));
      expect(await w.deviceApproveWithPassword(dev!, req!, PasswordAuth(lap.password)), isNull);
      print('PASSWORD: request $two approved with the laptop\'s password');

      // A denial needs neither
      final three = await agentAsks(mini.socket, agent.token, 'the third report');
      await _until(() async {
        await w.refreshDevices();
        dev = w.ownDevices.firstWhere((d) => d.contact == 'mini');
        req = dev!.status?.approvals.where((a) => a.id == three).firstOrNull;
        return req != null;
      }, what: 'request three in the laptop\'s view');
      expect(await w.deviceDeny(dev!, req!), isNull);
      final denied = expectReply<ApprovalsReply>(await c.call(const ApprovalsRequest(all: true)))
          .approvals
          .firstWhere((a) => a.id == three);
      expect(denied.state, 'denied');

      // Lending this computer to teams: on with the password on the laptop; the mini sees it
      expect(await w.setLend(true, auth: PasswordAuth(lap.password)), isNull);
      expect(w.devices!.self.lend, isTrue);
      await _until(() async {
        final d = expectReply<DevicesReply>(await c.call(const DevicesRequest())).devices.single;
        return d.status?.lend ?? false;
      }, what: 'the mini sees the laptop lend itself');
    } finally {
      m?.dispose();
      await Future.wait([mini.stop(), lap.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
