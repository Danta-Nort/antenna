// SPDX-License-Identifier: AGPL-3.0-only
// A proof on the wire (x-control/7, CONTROL §22.2) against a stand-in daemon on a real unix socket: the line of a
// request with a proof is `{"req":<R>,"proof":{key_id, nonce, sig}}` with exactly the bytes R the signer was given,
// for a one-reply command and for a dialog (`login {password: "", hold: true}`); the signer runs before the connection
// opens; the owner-key commands (the enroll challenge too) and the changed `unlock` / `approve` go out as §22.1
// describes them.

// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A v7 daemon that keeps every line as raw bytes.
class _StandIn {
  final lines = <List<int>>[];
  final hellos = <String>[];
  late final Directory dir;
  late final ServerSocket server;

  String get path => '${dir.path}/antennad.sock';

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('antenna-v7-');
    server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    server.listen((s) {
      final buf = <int>[];
      s.listen((chunk) {
        buf.addAll(chunk);
        while (true) {
          final nl = buf.indexOf(10);
          if (nl < 0) break;
          final raw = buf.sublist(0, nl);
          buf.removeRange(0, nl + 1);
          _line(s, raw);
        }
      });
    });
  }

  void _line(Socket s, List<int> raw) {
    final j = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
    if (j['hello'] case final Map<String, Object?> h) {
      hellos.add(h['proto']! as String);
      s.write('${jsonEncode({
        'hello_ok': {
          'daemon': 'antennad 0.1.2 (test)',
          'protocol': 'x/1',
          'state': 'unlocked',
          'role': 'owner',
          'proto': h['proto'],
          'session': 'none',
        },
      })}\n');
      return;
    }
    lines.add(raw);
    final r = j['req']! as Map<String, Object?>;
    final ok = switch (r['cmd']) {
      'owner_challenge' => {'type': 'owner_challenge', 'nonce': 'ab' * 32, 'expires_ms': 9, 'password_due_ms': 10},
      'approve' => {
          'type': 'approval',
          'id': r['id'],
          'state': 'approved',
          'requester': 'builder',
          'contact': 'bob',
          'contact_trust': 3,
          'action': 'send_message',
          'grants': <String, Object?>{},
          'fingerprint': r['fingerprint'],
          'created_ms': 1,
          'expires_ms': 2,
        },
      'owner_key_add' => {
          'type': 'owner_key_added',
          'key': {'key_id': '01b3e9c533123cb8', 'label': r['label'], 'created_ms': 1, 'unlock': true},
          'slot_key': base64.encode(List.filled(32, 7)),
        },
      'owner_keys' || 'owner_key_list' => {
          'type': 'owner_keys',
          'keys': [
            {'key_id': '01b3e9c533123cb8', 'label': 'touchid@mac', 'created_ms': 1, 'last_used_ms': 5, 'unlock': true},
          ],
          'password_due_ms': 1792409600000,
          'test_key': true,
        },
      'owner_key_remove' => {'type': 'done', 'state': 'removed'},
      'unlock' => {'type': 'done', 'state': 'unlocked'},
      'login' => null,
      final c => throw StateError('unexpected $c'),
    };
    if (ok == null) {
      s.write('${jsonEncode({
        'event': {'kind': 'session', 'token': 'xos_test', 'mode': 'held'},
      })}\n');
    } else {
      s.write('${jsonEncode({'ok': ok})}\n');
    }
  }

  Future<void> stop() async {
    await server.close();
    await dir.delete(recursive: true);
  }
}

/// The `req` value of a raw line, from its `{` to its matching `}` (strings and escapes skipped), as the daemon finds it.
List<int> _reqBytes(List<int> line) {
  const prefix = '{"req":';
  expect(utf8.decode(line.sublist(0, prefix.length)), prefix);
  var depth = 0;
  var inString = false;
  for (var i = prefix.length; i < line.length; i++) {
    final c = line[i];
    if (inString) {
      if (c == 0x5c) {
        i++;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) inString = true;
    if (c == 0x7b) depth++;
    if (c == 0x7d && --depth == 0) return line.sublist(prefix.length, i + 1);
  }
  throw StateError('no req value');
}

void main() {
  late _StandIn d;
  setUp(() async {
    d = _StandIn();
    await d.start();
  });
  tearDown(() => d.stop());

  /// Signs nothing: records the text it was given and answers with a fixed proof.
  ProofSource signer(List<String> signed, {List<String>? order}) => (req) async {
        order?.add('sign');
        signed.add(req);
        return OwnerProof(keyId: '01b3e9c533123cb8', nonce: 'ab' * 32, sig: 'c2lnbmF0dXJl');
      };

  /// Negative control (seen failing, this test and the next): `callWithProof` wrote the line from the request
  /// re-encoded canonically (keys sorted) instead of the signed text; the line's `req` bytes were then not the signed
  /// bytes.
  test('a one-reply command: the line carries exactly the signed bytes, and only req and proof', () async {
    final c = XControlClient(d.path);
    final signed = <String>[];
    // Non-ASCII and characters JSON may escape: the signed text and the line must not disagree about any of them.
    const label = 'touchid@Émilie’s Mac — "test" \\ \u0007';
    final reply = await c.callWithProof(
      const OwnerKeyAddRequest(publicKey: 'BPcp…', label: label, password: 'pw', unlock: true),
      signer(signed),
    );
    expect(reply, isA<OwnerKeyAddedReply>().having((r) => r.key.keyId, 'key', '01b3e9c533123cb8'));
    expect(signed, hasLength(1));
    final line = d.lines.single;
    expect(_reqBytes(line), utf8.encode(signed.single), reason: 'the daemon hashes these bytes: they are the signed ones');
    final j = jsonDecode(utf8.decode(line)) as Map<String, Object?>;
    expect(j.keys, ['req', 'proof']);
    expect(j['proof'], {'key_id': '01b3e9c533123cb8', 'nonce': 'ab' * 32, 'sig': 'c2lnbmF0dXJl'});
    expect(j['req'], {
      'cmd': 'owner_key_add',
      'public_key': 'BPcp…',
      'label': label,
      'unlock': true,
      'password': 'pw',
    });
    expect((reply as OwnerKeyAddedReply).toString(), isNot(contains(reply.slotKey!)), reason: 'the slot key is a secret');
  });

  test('approve with a proof: the password is empty and the fingerprint the owner saw is signed', () async {
    final c = XControlClient(d.path);
    final signed = <String>[];
    final reply = await c.callWithProof(
      const ApproveRequest(id: 'k2ab9c1d', password: '', fingerprint: '9c41e07a3b5d0f12'),
      signer(signed),
    );
    expect(reply, isA<ApprovalReply>());
    expect(jsonDecode(signed.single), {'cmd': 'approve', 'id': 'k2ab9c1d', 'password': '', 'fingerprint': '9c41e07a3b5d0f12'});
    expect(_reqBytes(d.lines.single), utf8.encode(signed.single));
  });

  test('a dialog with a proof: login {password: "", hold: true} opens the session; the signer runs first', () async {
    final c = XControlClient(d.path);
    final signed = <String>[];
    final order = <String>[];
    final dialog = c.openWithProof(const LoginRequest(''), signer(signed, order: order));
    final ev = await dialog.events.first;
    expect(ev, isA<SessionEvent>().having((e) => e.token, 'token', 'xos_test'));
    expect(jsonDecode(signed.single), {'cmd': 'login', 'password': '', 'hold': true});
    expect(_reqBytes(d.lines.single), utf8.encode(signed.single));
    expect(order, ['sign']);
    expect(d.hellos, hasLength(1), reason: 'one connection, opened after the signature');
    await dialog.cancel();
  });

  test('a signer that fails sends nothing: no connection, the error is the result', () async {
    final c = XControlClient(d.path);
    final dialog = c.openWithProof(const LoginRequest(''), (_) async => throw StateError('cancelled'));
    await expectLater(dialog.result, throwsA(isA<StateError>()));
    await expectLater(c.callWithProof(const ApproveRequest(id: 'k2', password: ''), (_) async => throw StateError('x')),
        throwsA(isA<StateError>()));
    expect(d.lines, isEmpty);
    expect(d.hellos, isEmpty, reason: 'nothing reaches the daemon without a proof');
  });

  test('§22.1 on the wire: owner_challenge, owner_key_list, owner_key_remove, unlock by slot', () async {
    final c = XControlClient(d.path);
    final ch = await c.ownerChallenge();
    expect((ch.nonce, ch.expiresMs, ch.passwordDueMs), ('ab' * 32, 9, 10));
    await c.ownerChallenge(enroll: true);
    final list = await c.ownerKeyList();
    expect(list.keys.single.keyId, '01b3e9c533123cb8');
    expect((list.keys.single.unlock, list.keys.single.lastUsedMs, list.testKey), (true, 5, true));
    await c.ownerKeyRemove('01b3e9c533123cb8');
    expect(await c.unlockWithSlot('01b3e9c533123cb8', 'AAAA'), DaemonState.unlocked);
    final sent = [for (final l in d.lines) (jsonDecode(utf8.decode(l)) as Map<String, Object?>)['req']];
    expect(sent, [
      {'cmd': 'owner_challenge'},
      {'cmd': 'owner_challenge', 'enroll': true},
      {'cmd': 'owner_key_list'},
      {'cmd': 'owner_key_remove', 'key_id': '01b3e9c533123cb8'},
      {'cmd': 'unlock', 'password': '', 'key_id': '01b3e9c533123cb8', 'slot_key': 'AAAA'},
    ]);
    expect(d.hellos.toSet(), {'x-control/7'});
    expect(const UnlockRequest('pw').toJson(), {'cmd': 'unlock', 'password': 'pw'}, reason: 'the password path unchanged');
    expect(const ApproveRequest(id: 'k2', password: 'pw').toJson(), {'cmd': 'approve', 'id': 'k2', 'password': 'pw'},
        reason: 'no fingerprint for an older daemon on the password path');
    expect('${const OwnerProof(keyId: 'k', nonce: 'n', sig: 'SECRETSIG')}', isNot(contains('SECRETSIG')));
  });
}
