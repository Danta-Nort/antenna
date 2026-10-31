// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's own devices (x-control/7, CONTROL §27): what the other computers said, set by the test; the
// challenges it issues for a remote approval and the check of what the window sends back, in the order of
// PROTOCOL §24 (the challenge, the exact text naming the link, the request and its fingerprint, a key the other
// computer accepts, the signature). The fake's "signature" is [fakeSig], as for local proofs: a test sees that the
// window signed exactly what it sent, with the challenge it was given. The real check is in the live test.

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fake_owner_keys.dart';
import 'fixtures.dart' show fixedNow;

const _gib = 1024 * 1024 * 1024;

/// A Mac mini with an agent and two requests waiting (one with a secret, so its text stays there), and a Linux server
/// with a problem: the demo of the My devices frames.
DevicesReply demoDevices(
    {String touchKeyId = '', bool lostServer = false, bool acceptsMine = true, bool stopAgents = false}) {
  final now = fixedNow.millisecondsSinceEpoch;
  return DevicesReply(
      self: ThisDevice(
        name: 'Mayas-MacBook-Pro',
        os: 'macos',
        osVersion: 'macOS 27.0',
        arch: 'aarch64',
        version: 'antennad 0.2.0 (1c63cc92d7bf)',
        keys: [
          if (touchKeyId.isNotEmpty) DeviceKeyInfo(keyId: touchKeyId, label: 'touchid@Mayas-MacBook-Pro', kind: 'touch_id'),
          const DeviceKeyInfo(keyId: 'a1b2c3d4e5f60718', label: 'password', kind: 'password'),
        ],
      ),
      devices: [
        DeviceInfo(
          contact: 'Mac mini',
          linkId: 'aa' * 32,
          presence: 'online',
          supported: true,
          stopAgents: stopAgents,
          receivedMs: now,
          confirmed: [
            DeviceKeyInfo(keyId: '0c85b46888e6a061', label: 'touchid@Mac-mini', kind: 'touch_id', confirmedMs: now - 86400000),
            DeviceKeyInfo(keyId: '70d36db450c34855', label: 'password', kind: 'password', confirmedMs: now - 86400000),
          ],
          acceptsMine: acceptsMine ? [if (touchKeyId.isNotEmpty) touchKeyId, 'a1b2c3d4e5f60718'] : const [],
          status: DeviceView(
            atMs: now,
            name: 'Mac-mini',
            os: 'macos',
            osVersion: 'macOS 27.0',
            arch: 'aarch64',
            memoryBytes: 64 * _gib,
            version: 'antennad 0.2.0 (1c63cc92d7bf)',
            update: DeviceUpdate(auto: true, last: '0.2.0', lastResult: 'installed', lastAtMs: now - 3 * 3600000),
            agents: [
              DeviceAgent(name: 'codex', app: 'codex', state: 'connected', lastSeenMs: now - 60000),
              DeviceAgent(name: 'helper', app: 'local', state: 'local'),
            ],
            approvals: [
              DeviceApproval(
                id: 'k2ab9c1d',
                action: 'send_message',
                requester: 'codex',
                contact: 'Emily Carter',
                contactTrust: 3,
                target: 'Emily Carter',
                reasons: ['no_write_down'],
                quote: 'The refactor of the payments module is ready for review: 14 files, all tests pass.',
                fingerprint: '9c41e07a3b5d0f12',
                createdMs: now - 60000,
                expiresMs: now + 540000,
                completes: true,
              ),
              DeviceApproval(
                id: 'p7xq2m4n',
                action: 'send_message',
                requester: 'codex',
                contact: 'Diego Alvarez',
                contactTrust: 3,
                target: 'Diego Alvarez',
                reasons: ['secret:password'],
                quoteWithheld: true,
                fingerprint: '3b5d0f129c41e07a',
                createdMs: now - 30000,
                expiresMs: now + 570000,
                completes: true,
              ),
            ],
            pendingApprovals: 2,
          ),
        ),
        DeviceInfo(
          contact: 'build server',
          linkId: 'bb' * 32,
          presence: lostServer ? 'offline' : 'online',
          supported: true,
          receivedMs: now - 120000,
          offered: const [DeviceKeyInfo(keyId: '5e1f0a2b3c4d5e6f', label: 'password', kind: 'password')],
          lostBy: lostServer ? LostReport(contact: 'Mac mini', atMs: now - 600000) : null,
          status: DeviceView(
            atMs: now - 120000,
            name: 'ci-01',
            os: 'linux',
            osVersion: 'Ubuntu 26.04 LTS',
            arch: 'x86_64',
            memoryBytes: 128 * _gib,
            version: 'antennad 0.2.0 (1c63cc92d7bf)',
            update: DeviceUpdate(auto: true, staged: '0.2.1', stagedState: 'waiting'),
            health: [DeviceHealth(code: 'relay_unreachable', severity: 'warning', count: 2)],
            agents: [DeviceAgent(name: 'runner', app: 'claude', state: 'idle')],
            lend: true,
          ),
        ),
      ],
    );
}


/// What a test sets and reads.
mixin FakeDevices {
  int get protoVersion;
  String get password;

  /// A proof by an enrolled key was checked for the request being carried out (D-131): its password field is empty.
  bool get proofChecked;
  FakeOwnerKeys get ownerKeys;

  /// `false`: a v7 daemon built before own devices (`devices` is an unknown command).
  bool devicesEnabled = false;
  DevicesReply devicesState = const DevicesReply(
    self: ThisDevice(name: 'mac', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
    devices: [],
  );

  /// Every remote decision the window sent: (contact, request text or `<id> approve|deny`, how).
  final deviceDecisions = <(String, String, String)>[];

  /// The challenges this fake issued, per contact.
  final deviceNonces = <String, String>{};
  final deviceConfirms = <(String, List<String>)>[];
  final deviceRevokes = <String>[];
  final lendCalls = <(bool, String?)>[];

  /// The next remote decision fails with this error (the other computer's refusal).
  XControlException? deviceRefusal;
  var _n = 0;

  DeviceInfo _device(String contact) {
    final d = devicesState.devices.where((x) => x.contact == contact).firstOrNull;
    if (d == null) throw XControlException(XErrorCode.notFound, 'no contact $contact');
    return d;
  }

  void _removeRequest(String contact, String id) {
    devicesState = DevicesReply(self: devicesState.self, devices: [
      for (final d in devicesState.devices)
        if (d.contact != contact || d.status == null)
          d
        else
          DeviceInfo(
            contact: d.contact,
            linkId: d.linkId,
            presence: d.presence,
            supported: d.supported,
            receivedMs: d.receivedMs,
            confirmed: d.confirmed,
            offered: d.offered,
            acceptsMine: d.acceptsMine,
            lostBy: d.lostBy,
            status: DeviceView(
              atMs: d.status!.atMs,
              name: d.status!.name,
              os: d.status!.os,
              osVersion: d.status!.osVersion,
              arch: d.status!.arch,
              memoryBytes: d.status!.memoryBytes,
              version: d.status!.version,
              update: d.status!.update,
              health: d.status!.health,
              agents: d.status!.agents,
              approvals: [for (final a in d.status!.approvals) if (a.id != id) a],
              pendingApprovals: d.status!.pendingApprovals - 1,
              lend: d.status!.lend,
            ),
          ),
    ]);
  }

  void _pwCheck(String pw) {
    if (proofChecked) return;
    if (pw != password) throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
  }

  /// The device commands of [FakeDaemon.call].
  Reply devicesCall(XRequest r) {
    if (protoVersion < 7 || !devicesEnabled) {
      throw XControlException(XErrorCode.badRequest, 'bad message: unknown variant `${r.cmd}`');
    }
    switch (r) {
      case DevicesRequest():
        return devicesState;
      case DeviceChallengeRequest(:final contact):
        final d = _device(contact);
        final nonce = (++_n).toRadixString(16).padLeft(64, '0');
        deviceNonces[contact] = nonce;
        return DeviceChallengeReply(contact: contact, linkId: d.linkId, nonce: nonce, expiresMs: 60000);
      case DeviceApproveRequest(:final contact, :final request, :final nonce, :final keyId, :final sig):
        final d = _device(contact);
        if (deviceRefusal case final e?) {
          deviceRefusal = null;
          throw e;
        }
        if (deviceNonces.remove(contact) != nonce) {
          throw const XControlException(XErrorCode.challengeInvalid, 'the challenge expired or was used');
        }
        final id = d.status?.approvals.map((a) => a.id).firstWhere(
                  (i) => request ==
                      remoteApproveText(
                          linkId: d.linkId,
                          id: i,
                          fingerprint: d.status!.approvals.firstWhere((a) => a.id == i).fingerprint),
                  orElse: () => '',
                ) ??
            '';
        if (id.isEmpty) throw const XControlException(XErrorCode.proofInvalid, 'not a request of that computer');
        if (!d.acceptsMine.contains(keyId)) {
          throw const XControlException(XErrorCode.ownerKeyUnknown, 'the other computer has not confirmed this key');
        }
        final pub = ownerKeys.keys[keyId]?.publicKey;
        if (pub == null || sig != fakeSig(pub, nonce, request)) {
          throw const XControlException(XErrorCode.proofInvalid, 'the other computer did not accept the signature');
        }
        deviceDecisions.add((contact, request, 'touch_id'));
        _removeRequest(contact, id);
        return DeviceDecidedReply(contact: contact, id: id, state: 'approved');
      case DeviceDecideRequest(:final contact, :final id, :final approve, :final fingerprint, :final password):
        _device(contact);
        if (approve) _pwCheck(password ?? '');
        if (deviceRefusal case final e?) {
          deviceRefusal = null;
          throw e;
        }
        deviceDecisions.add((contact, '$id ${approve ? 'approve' : 'deny'} ${fingerprint ?? ''}'.trim(), 'password'));
        _removeRequest(contact, id);
        return DeviceDecidedReply(contact: contact, id: id, state: approve ? 'approved' : 'denied');
      case DeviceKeysConfirmRequest(:final contact, :final keyIds, :final password):
        _pwCheck(password);
        _device(contact);
        deviceConfirms.add((contact, keyIds));
        devicesState = DevicesReply(self: devicesState.self, devices: [
          for (final d in devicesState.devices)
            d.contact != contact
                ? d
                : DeviceInfo(
                    contact: d.contact,
                    linkId: d.linkId,
                    presence: d.presence,
                    supported: d.supported,
                    status: d.status,
                    receivedMs: d.receivedMs,
                    confirmed: [...d.confirmed, ...d.offered],
                    acceptsMine: d.acceptsMine,
                    lostBy: d.lostBy,
                  ),
        ]);
        return devicesState;
      case DeviceKeysRemoveRequest():
        return devicesState;
      case DeviceLendSetRequest(:final enabled, :final password):
        if (enabled) _pwCheck(password ?? '');
        lendCalls.add((enabled, password));
        final s = devicesState.self;
        devicesState = DevicesReply(
          self: ThisDevice(
              name: s.name, os: s.os, osVersion: s.osVersion, arch: s.arch, version: s.version, lend: enabled, keys: s.keys),
          devices: devicesState.devices,
        );
        return devicesState;
      case DeviceRevokeRequest(:final contact, :final password):
        _pwCheck(password);
        final d = _device(contact);
        deviceRevokes.add(contact);
        devicesState = DevicesReply(
          self: devicesState.self,
          devices: [for (final x in devicesState.devices) if (x.contact != contact) x],
        );
        return RevokedReply(contact: contact, linkId: d.linkId, historyDeleted: false);
      case DeviceLostDismissRequest():
        return devicesState;
      default:
        throw XControlException(XErrorCode.notImplemented, 'fake: ${r.cmd}');
    }
  }
}
