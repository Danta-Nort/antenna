// SPDX-License-Identifier: AGPL-3.0-only
// The view that sends one owner command with a proof (D-131): a typed request goes out through `callWithProof` with
// the exact text the prover signed and its password fields empty; a second request through the same view is refused
// before anything is signed (one touch is one command); a prover that fails turns into XProofException and nothing
// reaches the daemon.

import 'package:antenna_desktop/host/touch_id.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_owner_keys.dart';
import '../support/fixtures.dart';

void main() {
  late FakeDaemon d;
  late String keyId;
  final signed = <String>[];

  Future<OwnerProof> prove(String req) async {
    signed.add(req);
    final ch = await d.ownerChallenge();
    final key = d.ownerKeys.keys[keyId]!;
    return OwnerProof(keyId: keyId, nonce: ch.nonce, sig: fakeSig(key.publicKey, ch.nonce, req));
  }

  setUp(() {
    d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..protoVersion = 7;
    keyId = d.ownerKeys.add('BTest', 'touchid@mac', unlock: false).key.keyId;
    signed.clear();
  });

  test('one typed request goes out with a proof over its exact text', () async {
    final p = ProvingDaemon(d, prove);
    final c = await p.trust(emily.linkId, 2, '');
    expect(c.trust, 2);
    expect(d.proven, ['trust']);
    expect(signed.single, '{"cmd":"trust","contact":"${emily.linkId}","level":2,"password":""}');
    expect(d.ownerKeys.lines.single.$1, signed.single, reason: 'the daemon got the text that was signed');
  });

  /// Negative control (seen failing): the `_used` check removed from `ProvingDaemon._once`.
  test('a second request through the same view is refused before anything is signed', () async {
    final p = ProvingDaemon(d, prove);
    await p.agentRemove('claude', '');
    await expectLater(p.trust(emily.linkId, 2, ''), throwsA(isA<XProtocolException>()));
    expect(signed, hasLength(1));
    expect(d.proven, ['agent_remove']);
  });

  test('a prover that fails is XProofException, and nothing reaches the daemon', () async {
    final p = ProvingDaemon(d, (_) async => throw const TouchIdException(TouchIdFailure.cancelled));
    final e = await p.trust(emily.linkId, 2, '').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<XProofException>());
    expect((e! as XProofException).cause, isA<TouchIdException>());
    expect(d.calls, isNot(contains('trust')));
    expect(d.proven, isEmpty);
  });

  test('a client error of the prover stays itself (the daemon wants the password)', () async {
    d.ownerKeys.needPassword = true;
    final p = ProvingDaemon(d, prove);
    await expectLater(
        p.trust(emily.linkId, 2, ''),
        throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.passwordRequired)));
  });
}
