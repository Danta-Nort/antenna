// SPDX-License-Identifier: AGPL-3.0-only
// The window's control client forced through the window bridge (D-135, CONTROL §34) on Linux and macOS: a REAL
// `antennad` and the REAL `antenna window-bridge` next to it. Everything the window needs at once goes over one bridge
// process: init, the held owner session, a subscription, a request that changes trust, and its event on the
// subscription; then the bridge is killed and the next call starts another; a daemon that is not there comes back as
// XDaemonUnreachable with the CLI's reason. On Windows the same client goes through the pipe (the window's Windows
// runner, by hand); this harness starts daemons on unix sockets.
//
// Run: ANTENNAD_BIN=<path to antennad, with antenna beside it> nice -n 10 flutter test test/protocol/live_bridge_test.dart
@Tags(['live'])
@TestOn('!windows')
library;

import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

void main() {
  final antennad = findXd();
  final cli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final missing = antennad == null
      ? noXdReason
      : !File(cli!).existsSync()
          ? 'antenna not found beside antennad: build it (`cargo build -p antenna-cli`)'
          : null;

  test('one bridge carries a held session, a subscription and requests at once', () async {
    final root = await tempRoot();
    final node = XdNode('alice', root, antennad!);
    await node.start();
    final mux = BridgeMux.process(cli!, arguments: ['--socket', node.socket]);
    final c = XControlClient(node.socket, bridge: mux);
    try {
      final h = await c.hello();
      expect(h.role, 'owner', reason: 'the bridge passes the window\'s hello through; the daemon checks it');
      expect(h.proto, controlProto);
      expect((await c.status()).state, DaemonState.uninitialized);
      expect(await c.init(node.password), DaemonState.unlocked);
      // The held session and the subscription are long-lived connections through the same bridge.
      final session = await openOwnerSession(c, node.password);
      expect((await c.hello()).session, 'held');
      final sub = Events(c.subscribe());
      expect((await sub.next<Subscribed>()).role, 'owner');
      final calls = await Future.wait([c.status(), c.contacts(), c.status()]);
      expect((calls.first as StatusReply).state, DaemonState.unlocked);
      expect(calls[1], isEmpty);
      final added = await c.agentAdd('helper', localLevel: 3, password: node.password);
      expect(added.token, startsWith('xat_'));
      await sub.next<AgentEvent>((e) => e.name == 'helper' && e.change == 'added');
      // A daemon error passes through as the daemon said it.
      await expectLater(
        c.agentAdd('other', localLevel: 3, password: 'not-the-password'),
        throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword)),
      );
      expect(mux.starts, 1, reason: 'one bridge process for every connection');

      // The bridge dies: its connections fail as unreachable, and the next call starts another bridge.
      final first = mux.channel! as ProcessBridgeChannel;
      final subEnded = sub.dialog.result.then<Object?>((_) => null, onError: (Object e) => e);
      expect(Process.killPid(first.pid, ProcessSignal.sigkill), isTrue);
      expect(await subEnded, isA<XDaemonUnreachable>());
      c.sessionToken = null;
      await openOwnerSession(c, node.password);
      expect((await c.status()).state, DaemonState.unlocked);
      expect(mux.starts, 2);
      expect((mux.channel! as ProcessBridgeChannel).pid, isNot(first.pid));
      await session.cancel();
    } finally {
      await mux.dispose();
      await node.stop();
      await root.delete(recursive: true);
    }
  }, skip: missing ?? false);

  test('no daemon there: XDaemonUnreachable with the CLI\'s reason, and the bridge goes on', () async {
    final root = await tempRoot();
    final socket = '${root.path}/missing.sock';
    final mux = BridgeMux.process(cli!, arguments: ['--socket', socket]);
    final c = XControlClient(socket, bridge: mux);
    try {
      for (var i = 0; i < 2; i++) {
        await expectLater(
          c.hello(),
          throwsA(isA<XDaemonUnreachable>()
              .having((e) => e.message, 'message', allOf(contains('cannot connect to antennad'), contains(socket)))
              .having((e) => e.socketPath, 'socketPath', socket)),
        );
      }
      expect(mux.starts, 1);
    } finally {
      await mux.dispose();
      await root.delete(recursive: true);
    }
  }, skip: missing ?? false);
}
