// SPDX-License-Identifier: AGPL-3.0-only
// "Connect an agent" against REAL `antennad` and `antenna`: the owner issues a token from the window (agent_add with
// the password), and the screen's ready-made snippets actually work: the script agent from the "Any script" tab gets a
// message and replies, and `antenna mcp` from the Claude Code config answers initialize and tools/list.
// Run: ANTENNAD_BIN=<path to antennad> flutter test test/protocol/live_agent_test.dart (`antenna` next to `antennad`).
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_snippets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Matcher _code(String c) => isA<XControlException>().having((e) => e.code, 'code', c);

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final hasJq = Process.runSync('sh', ['-c', 'command -v jq']).exitCode == 0;

  test('agent token from the window + snippets work against real daemons', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    Process? script;
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      // Link alice ↔ bob (owner A types the code as read out by B).
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 3,
        label: 'alice',
        connectTimeoutMs: 5000,
        password: bob.password,
      )));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;

      // The "Connect an agent" screen: the label is required, plus the owner password.
      await expectLater(
        a.agentAdd('jarvis', localLevel: 5, password: 'wrong-password'),
        throwsA(_code(XErrorCode.wrongPassword)),
      );
      // Label 5 (projects and memory): replying to a level 3 contact needs the owner's approval (no write down).
      final jarvis = await a.agentAdd('jarvis', localLevel: 5, password: alice.password, links: ['bob']);
      expect(jarvis.token, startsWith('xat_'));
      final send5 = await Process.run(xCli!, ['--json', 'send', 'bob', 'hello from jarvis'],
          environment: {'ANTENNA_AGENT_TOKEN': jarvis.token, 'ANTENNA_SOCKET': alice.socket});
      expect(send5.exitCode, 77, reason: '${send5.stdout}');
      expect('${send5.stdout}', contains('approval_required'));
      final pending = (await a.approvals()).approvals.single;
      expect(pending.reasons.join(), contains('no_write_down'));
      print('AGENT level 5 → contact level 3: exit ${send5.exitCode}, approval ${pending.id} (${pending.reasons})');

      // Label 3 (shared materials): it replies to a level 3 contact on its own.
      final added = await a.agentAdd('helper', localLevel: 3, password: alice.password, links: ['bob']);
      final list = await a.agents();
      expect(list.map((x) => x.name), containsAll(['jarvis', 'helper']));
      expect(list.firstWhere((x) => x.name == 'helper').links, ['bob']);
      print('AGENT: tokens issued, agents=${list.map((x) => '${x.name}:${x.localLevel}').toList()}');

      final snippets = {
        for (final s in agentSnippets(l10nFor('en'), name: 'helper', token: added.token, xPath: xCli, socket: alice.socket))
          s.id: s,
      };

      // "Any script": run exactly this text; B writes, and the agent replies.
      if (hasJq) {
        script = await Process.start('bash', ['-c', snippets['script']!.text]);
        unawaited(script.stdout.drain<void>());
        unawaited(script.stderr.transform(utf8.decoder).forEach((l) => print('script: $l')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final sub = Events(b.subscribe());
        await sub.next<Subscribed>();
        // Since x-control/6 an agent reads only what is addressed to it by name, or to everyone when its owner allows
        // that (CONTROL §20). `helper` has not written yet, so bob cannot name it: he writes to everyone, and alice
        // lets `helper` read messages to everyone.
        final hello = await a.hello();
        if (controlVersion(hello.proto) >= 6) {
          await a.agentSet('helper', everyone: true, password: alice.password);
          await b.send('alice', 'hello, agent!', address: const MessageAddress.everyone());
        } else {
          await b.send('alice', 'hello, agent!');
        }
        // v2: the agent's read leaves a receipt in the shared history; B sees it as a message event (kind receipt).
        final receipt = await sub.next<MessageEvent>((e) => e.message.isReceipt, const Duration(seconds: 20));
        print('RECEIPT at B: actor=${receipt.message.receipt?.actor} action=${receipt.message.receipt?.action} '
            'decision=${receipt.message.receipt?.decision} source=${receipt.message.receipt?.source}');
        expect(receipt.message.receipt?.actor, 'helper');
        final reply = await sub.next<MessageEvent>(
          (e) => !e.message.outgoing && !e.message.isReceipt,
          const Duration(seconds: 20),
        );
        print('SCRIPT AGENT: replied "${reply.message.text}"');
        expect(reply.message.text, 'received: 13 characters');
        await sub.close();
        script.kill();
        await script.exitCode;
        script = null;
      } else {
        print('SCRIPT AGENT: skipped (no jq)');
      }

      // Claude Code: `antenna mcp` with the token from the config answers initialize and tools/list. Through bash (not exec),
      // so that bash becomes the binding anchor instead of the test process (otherwise the daemon would also treat the
      // owner's window as an agent).
      final mcp = await Process.start(
        'bash',
        ['-c', '"\$X" mcp; exit \$?'],
        environment: {'X': xCli, 'ANTENNA_AGENT_TOKEN': added.token, 'ANTENNA_SOCKET': alice.socket},
      );
      final lines = StreamIterator(mcp.stdout.transform(utf8.decoder).transform(const LineSplitter()));
      unawaited(mcp.stderr.drain<void>());
      void rpc(Map<String, Object?> m) => mcp.stdin.writeln(jsonEncode(m));
      rpc({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'antenna-desktop-test', 'version': '0'},
        },
      });
      expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      final init = jsonDecode(lines.current) as Map<String, Object?>;
      expect(init['result'], isNotNull, reason: lines.current);
      rpc({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      rpc({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
      expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      final tools = ((jsonDecode(lines.current) as Map<String, Object?>)['result']! as Map<String, Object?>)['tools']!
          as List<Object?>;
      final names = [for (final t in tools) (t! as Map<String, Object?>)['name']];
      print('MCP: initialize ok, tools=$names');
      expect(names, containsAll(['list_contacts', 'send_message', 'read_inbox', 'wait_for_message']));
      expect(names, isNot(contains('trust')), reason: 'no owner commands in MCP (SPEC §9)');
      await mcp.stdin.close();
      mcp.kill();
      await mcp.exitCode;

      // Revoke the token.
      await a.agentRemove('jarvis', alice.password);
      await a.agentRemove('helper', alice.password);
      expect(await a.agents(), isEmpty);
    } finally {
      script?.kill();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !File('${File(antennad).parent.path}/antenna').existsSync() ? noXdReason : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
