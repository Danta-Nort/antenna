// SPDX-License-Identifier: AGPL-3.0-only
// App state (AppModel) on top of a REAL daemon: unlock, links, history, sending, receiving through the subscription,
// trust level change with the password, an external `antenna lock` → the window returns to the password screen.
// Run: ANTENNAD_BIN=<path to antennad> flutter test test/protocol/live_model_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 15), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final antennad = findXd();

  test('AppModel over two real daemons', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(b, bob.password); // B is a CLI client with its own session
      await a.lock();

      // Window: daemon locked → password screen; a wrong password gives an error, the right one the home screen.
      await m.connect();
      expect(m.phase, Phase.locked);
      expect(m.hello?.role, 'owner');
      final wrong = await m.unlock('nope-nope-nope');
      expect(wrong, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      expect(await m.unlock(alice.password), isNull);
      expect(m.phase, Phase.unlocked);
      expect((await m.daemon.hello()).session, 'held', reason: 'one password: keys and the window session');
      a.sessionToken = m.daemon.sessionToken; // same process, same session
      await until(() => m.subscribed, what: 'subscription');
      expect(m.contacts, isEmpty);

      // The link is created from the window (A) and from the CLI client (B).
      final inv = m.startInvite(trust: 3, ttl: const Duration(minutes: 2), label: 'bob', auth: PasswordAuth(alice.password));
      await until(() => inv.link != null, what: 'invite link');
      final join = Events(b.open(JoinRequest(
        link: inv.link!,
        trust: 3,
        label: 'alice',
        connectTimeoutMs: 5000,
        password: bob.password,
      )));
      await join.next<NeedInput>((e) => e.isSasCode);
      await until(() => inv.sas != null, what: 'sas');
      join.dialog.input(SasCodeInput(inv.sas!));
      final dictated = inv.sas!; // what owner A dictated and B typed in and read back
      await until(() => inv.phase.name == 'needConfirm', what: 'needs confirm');
      inv.confirmWithCode('');
      expect(inv.confirmError, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.badRequest));
      // A wrong code: the daemon answers with an input_rejected event; the invite stays alive (no second password).
      final wrongCode = ((int.parse(dictated) + 1) % 1000000).toString().padLeft(6, '0');
      inv.confirmWithCode(wrongCode);
      await until(() => inv.confirmError != null && inv.phase.name == 'needConfirm', what: 'input_rejected');
      expect(inv.confirmError, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.sasMismatch));
      inv.confirmWithCode(dictated);
      await join.dialog.result;
      await until(() => m.selected?.label == 'bob', what: 'contact selected after linking');
      print('MODEL: linked, contact ${m.selected!.label}, invite phase ${inv.phase.name}');

      // Sending from the window: a "sending" entry → delivered (the send response and subscription events in any order).
      await m.send('hello from the window');
      final out = m.chatOf(m.selectedLinkId!).last;
      expect(out.outgoing, isTrue);
      await until(() => out.delivery == Delivery.delivered, what: 'delivered');
      expect(m.chatOf(m.selectedLinkId!).where((e) => e.text == 'hello from the window').length, 1, reason: 'no duplicates');

      // Receiving: B writes, and the window gets a subscription event without polling the inbox.
      final sw = Stopwatch()..start();
      await b.send('alice', 'reply from the CLI');
      await until(() => m.chatOf(m.selectedLinkId!).any((e) => e.text == 'reply from the CLI'), what: 'incoming');
      print('MODEL: B send → window shows it in ${sw.elapsedMilliseconds} ms');
      // v2: the window marked it read (mark_read); for the owner this is shared state, so `antenna inbox` no longer shows it.
      final swRead = Stopwatch()..start();
      while ((await a.contacts()).single.unread != 0) {
        expect(swRead.elapsed, lessThan(const Duration(seconds: 10)), reason: 'mark_read from the window');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await a.inbox(), isEmpty, reason: 'the window marked it read for the owner (mark_read)');

      // The window restarted while the daemon kept running: keys are unlocked, but the new window has no session → "Sign in".
      final m2 = AppModel(connector: XControlClient.new, socketPath: alice.socket, live: false);
      await m2.connect();
      expect(m2.phase, Phase.loginRequired);
      expect(await m2.login('wrong-password'), isA<XControlException>());
      expect(await m2.login(alice.password), isNull);
      expect(m2.phase, Phase.unlocked);
      expect([for (final e in m2.chatOf(m2.selectedLinkId!)) e.text], ['hello from the window', 'reply from the CLI']);
      print('MODEL: restarted window → login_required → login → history back');
      m2.dispose();

      // Trust level: only with the password; the contact event updates the list.
      expect(await m.setTrust(m.selectedLinkId!, 4, const PasswordAuth('wrong-password')), isNotNull);
      expect(await m.setTrust(m.selectedLinkId!, 4, PasswordAuth(alice.password)), isNull);
      expect(m.selected!.trust, 4);
      expect(m.presenceOf(m.selected!), isTrue);

      // An external antenna lock: the subscription closes with locked → the window is on the password screen.
      await a.lock();
      await until(() => m.phase == Phase.locked, what: 'locked phase');
      print('MODEL: external antenna lock → phase ${m.phase.name}');
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));

  test('unreachable daemon → phase unreachable', () async {
    final m = AppModel(connector: XControlClient.new, socketPath: '/tmp/no-such-antennad.sock', live: false);
    await m.connect();
    expect(m.phase, Phase.unreachable);
    expect(m.lastError, isA<XDaemonUnreachable>());
    m.dispose();
    expect(File('/tmp/no-such-antennad.sock').existsSync(), isFalse);
  });
}
