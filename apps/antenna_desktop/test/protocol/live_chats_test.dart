// SPDX-License-Identifier: AGPL-3.0-only
// Chats per agent (x-control/7, CONTROL §26, D-113, D-UI-32) against REAL daemons: the owner's Mac and a server with
// two agent sessions, each with its own token and "messages to everyone" off. The window lists each session as its
// own chat from the daemon, opens one by its own page, writes to that session only, and reads it by chat; each session
// reads only what is addressed to it; the owner's local name, notifications and archive are kept by the Mac's daemon,
// reach the window's subscription when another client changes them, and never reach the server.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live --concurrency=1 test/protocol/live_chats_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> untilAsync(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  // A daemon from before chats has no `antenna chats`.
  var hasChats = false;
  if (xCli != null && File(xCli).existsSync()) {
    final help = Process.runSync(xCli, ['--help'], environment: ownerCliEnv(), includeParentEnvironment: false);
    hasChats = '${help.stdout}'.contains('chats');
  }

  test('each agent session is its own chat in the window; settings stay on the Mac', () async {
    final root = await tempRoot();
    final mac = XdNode('mac', root, antennad!);
    final server = XdNode('server', root, antennad);
    await Future.wait([mac.start(), server.start()]);
    final a = XControlClient(mac.socket);
    final b = XControlClient(server.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: mac.socket, factsEvery: const Duration(seconds: 1));
    try {
      await a.init(mac.password);
      await b.init(server.password);
      await openOwnerSession(a, mac.password);
      await openOwnerSession(b, server.password);

      // The link: the server is the owner's own computer (∞), a common setup.
      final inv = Events(a.open(InviteRequest(trust: 5, ttlSecs: 120, label: 'server', password: mac.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 5,
        label: 'mac',
        connectTimeoutMs: 5000,
        password: server.password,
      )));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      final link = (await a.contacts()).single.linkId;

      // Two sessions on the server, each its own agent; each says hello.
      final dev = await b.agentAdd('antenna-dev', localLevel: 0, password: server.password, links: ['mac'], everyone: false);
      final volna = await b.agentAdd('volna-dev', localLevel: 0, password: server.password, links: ['mac'], everyone: false);
      Future<ProcessResult> asAgent(AgentAddedReply who, List<String> args) => Process.run(xCli!, ['--json', ...args],
          environment: {'ANTENNA_AGENT_TOKEN': who.token, 'ANTENNA_SOCKET': server.socket});
      for (final (who, text) in [(dev, 'antenna-dev is here'), (volna, 'volna-dev is here')]) {
        final r = await asAgent(who, ['send', 'mac', text, '--wait', '3s']);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      }
      await untilAsync(() async => (await a.contacts()).single.agents.length == 2, what: 'the mac learns both');

      // The window: the chats come from the daemon, one per session.
      await m.connect();
      expect(await m.login(mac.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      expect(m.chatsSupported, isTrue);
      expect(m.agentChatsOf(link).toSet(), {const ThreadKey.agent('antenna-dev'), const ThreadKey.agent('volna-dev')});
      // The window opened the chat with the latest message (volna-dev's hello) and read it, by chat only.
      expect(m.openThreadOf(link), const ThreadKey.agent('volna-dev'));
      await untilAsync(() async => (await a.contacts()).single.unread == 1, what: 'only that chat read');
      expect(m.chatUnread(link, const ThreadKey.agent('antenna-dev')), 1);
      expect(m.chatUnread(link, const ThreadKey.agent('volna-dev')), 0);

      // Open antenna-dev's chat: its own page, read by chat; write to it.
      await m.select(link, chat: const ThreadKey.agent('antenna-dev'));
      expect([for (final e in m.visibleChat(link)) e.text], ['antenna-dev is here']);
      await untilAsync(() async => (await a.contacts()).single.unread == 0, what: 'that chat read too');
      await m.send('antenna-dev, please build preview.8');
      final sent = (await a.history(link, chat: const ChatRef.agent('antenna-dev'))).messages;
      expect(sent.last.text, 'antenna-dev, please build preview.8');
      expect((sent.last.to, sent.last.toAgent), ('agent', 'antenna-dev'));

      // Each session reads only its own (the daemon's rule, D-91): volna-dev never sees antenna-dev's task.
      await untilAsync(() async {
        final r = await asAgent(dev, ['inbox', '--wait', '--timeout', '1s']);
        return '${r.stdout}'.contains('please build preview.8');
      }, what: 'antenna-dev reads its task');
      final other = await asAgent(volna, ['inbox']);
      expect(other.exitCode, 0, reason: '${other.stderr}');
      expect('${other.stdout}', isNot(contains('preview.8')));
      final otherHistory = await asAgent(volna, ['history', 'mac', '--limit', '100']);
      expect('${otherHistory.stdout}', isNot(contains('preview.8')));
      print('PRIVACY: volna-dev read ${jsonDecode('${other.stdout}'.trim().split('\n').last)['messages']}');

      // A reply lands in its chat; a message of the other session is counted in the other chat.
      expect((await asAgent(dev, ['send', 'mac', 'preview.8 builds', '--wait', '3s'])).exitCode, 0);
      expect((await asAgent(volna, ['send', 'mac', 'Volna release checked', '--wait', '3s'])).exitCode, 0);
      await until(() => m.chatUnread(link, const ThreadKey.agent('volna-dev')) == 1, what: 'volna-dev counted');
      await until(() => m.visibleChat(link).any((e) => e.text == 'preview.8 builds'), what: 'the reply on screen');
      expect(m.chatUnread(link, const ThreadKey.agent('antenna-dev')), 0, reason: 'read on screen');

      // Local settings: the window names a chat; another client sees it, the server never does.
      expect(await m.renameChat(link, const ThreadKey.agent('antenna-dev'), 'Antenna development'), isNull);
      expect(await m.setChatNotify(link, const ThreadKey.agent('volna-dev'), ChatNotify.off), isNull);
      final listed = await a.chats(contact: link);
      final named = listed.firstWhere((c) => c.agent == 'antenna-dev');
      expect((named.name, named.saved), ('Antenna development', true));
      expect(listed.firstWhere((c) => c.agent == 'volna-dev').notify, ChatNotify.off);
      final serverSide = jsonEncode([
        for (final h in (await b.history((await b.contacts()).single.linkId, limit: 500)).messages) h.text,
        for (final c in await b.chats()) c.name,
      ]);
      expect(serverSide, isNot(contains('Antenna development')));

      // Another client's change reaches the window's subscription (the `chat` event).
      await a.chatSet(link, agent: 'volna-dev', name: 'Volna development');
      await until(() => m.chatName(link, const ThreadKey.agent('volna-dev')) == 'Volna development',
          what: 'the chat event');
      // Archive: hidden until something new; the person chat is the contact itself.
      expect(await m.archiveChat(link, const ThreadKey.agent('volna-dev'), archived: true), isNull);
      expect(m.agentChatsOf(link), [const ThreadKey.agent('antenna-dev')]);
      expect((await m.archiveChat(link, ThreadKey.person, archived: true)), isA<XControlException>());
      expect((await asAgent(volna, ['send', 'mac', 'one more thing', '--wait', '3s'])).exitCode, 0);
      await until(() => m.agentChatsOf(link).length == 2, what: 'a new message brings the chat back');
      print('CHATS: ${[for (final c in await a.chats(contact: link)) '${c.agent ?? 'person'}:${c.unread}:${c.name}']}');

      // A name nobody there has (the server's node answers, `no-agent/0`): the window says so instead of
      // "delivered", with the names one can address.
      await m.select(link, chat: const ThreadKey.agent('chatgpt'));
      await m.send('chatgpt, please draw three avatars');
      final sentNoAgent = m.visibleChat(link).last;
      expect(sentNoAgent.noAgent, isTrue, reason: 'the server has no agent chatgpt');
      expect(sentNoAgent.delivery, Delivery.delivered, reason: 'the node has it; its owner can read it');
      final hist = (await a.history(link, chat: const ChatRef.agent('chatgpt'))).messages;
      expect(hist.single.noAgent, isTrue);
      print('NO AGENT: ${hist.single.text} → no agent named chatgpt');
    } finally {
      m.dispose();
      await Future.wait([mac.stop(), server.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null ? noXdReason : (!hasChats ? 'needs antennad/antenna with chats (x-control/7, `antenna chats`)' : false),
      timeout: const Timeout(Duration(minutes: 3)));
}
