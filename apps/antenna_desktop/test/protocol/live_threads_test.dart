// SPDX-License-Identifier: AGPL-3.0-only
// Addressing, topics, threads and batch approvals (x-control/6, CONTROL §20, D-UI-18) against REAL daemons: two nodes
// linked; the contact's agent announces itself by writing; the window addresses a message to that agent and another
// to the person with a topic, and the history items carry `to` / `to_agent` / `topic` on both nodes; the contact's
// agent reads only what is addressed to it; showing one thread marks exactly its messages read; `approve_many`
// approves two requests with one password, and `deny_many` denies two without one (also without an owner session).
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live --concurrency=1 test/protocol/live_threads_test.dart
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
  // A daemon older than v6 refuses the x-control/6 hello; the test is about v6.
  var speaksV6 = false;
  if (xCli != null && File(xCli).existsSync()) {
    final help = Process.runSync(xCli, ['send', '--help']);
    speaksV6 = '${help.stdout}'.contains('--to-agent');
  }

  test('addressing, topics, unread per thread and batch approvals between two real nodes', () async {
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
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      final hello = await a.hello();
      print('HELLO: ${hello.daemon} speaks ${hello.proto}');
      expect(hello.proto, controlProto, reason: 'the daemon accepts x-control/6');

      // The link.
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
      final link = (await a.contacts()).single.linkId;

      // Bob's agent `lead` (reads only what is addressed to it) announces itself by writing to alice.
      final lead = await b.agentAdd('lead', localLevel: 0, password: bob.password, links: ['alice']);
      Future<ProcessResult> asLead(List<String> args) => Process.run(xCli!, ['--json', ...args],
          environment: {'ANTENNA_AGENT_TOKEN': lead.token, 'ANTENNA_SOCKET': bob.socket});
      final hi = await asLead(['send', 'alice', 'lead here: I take the build tasks', '--wait', '3s']);
      expect(hi.exitCode, 0, reason: '${hi.stdout}${hi.stderr}');
      await untilAsync(() async => (await a.contacts()).single.agents.any((x) => x.name == 'lead'),
          what: 'alice learns bob\'s agent');
      final bobContact = (await a.contacts()).single;
      print('CONTACT: peer_kind ${bobContact.peerKind}, agents ${bobContact.agents.map((x) => x.name)}, '
          'peer_addressing ${bobContact.peerAddressing}');
      expect(bobContact.peerAddressing, isTrue);

      // The window: signed in, subscribed, the link open.
      await m.connect();
      expect(await m.login(alice.password), isNull);
      expect(m.addressing, isTrue);
      await until(() => m.subscribed, what: 'subscription');
      await m.select(link);
      // The daemon lists the chats (x-control/7, CONTROL §26): bob's agent is its own chat.
      expect(m.chatsSupported, isTrue);
      expect(m.agentChatsOf(link), [const ThreadKey.agent('lead')]);

      // To bob's agent, then to bob himself with a topic.
      await m.openThread(link, const ThreadKey.agent('lead'));
      expect(m.recipientOf(link), const Recipient.agent('lead'));
      await m.send('lead, please rerun build 412');
      await m.openThread(link, ThreadKey.person);
      m.setTopicChoice(link, const TopicChoice.create('Avatars'));
      await m.send('Bob, which avatar sizes do you need?');

      final mine = (await a.history(link)).messages.where((x) => x.outgoing).toList();
      final toLead = mine.firstWhere((x) => x.text.startsWith('lead, please'));
      final toBob = mine.firstWhere((x) => x.text.startsWith('Bob, which'));
      print('ALICE HISTORY: to lead → to ${toLead.to}/${toLead.toAgent}; to Bob → to ${toBob.to}, topic ${toBob.topic?.title}');
      expect((toLead.to, toLead.toAgent), ('agent', 'lead'));
      expect((toBob.to, toBob.topic?.title), ('person', 'Avatars'));
      expect(toBob.topic!.id, hasLength(32));
      final topics = await a.topics(link);
      expect(topics.topics.map((t) => t.title), contains('Avatars'));

      // Bob's node got the same addresses (the contact's node understands addressing).
      final bobLink = (await b.contacts()).single.linkId;
      await untilAsync(() async => (await b.history(bobLink)).messages.where((x) => !x.outgoing).length >= 2,
          what: 'bob receives both');
      final got = (await b.history(bobLink)).messages.where((x) => !x.outgoing).toList();
      final gotLead = got.firstWhere((x) => x.text.startsWith('lead, please'));
      final gotBob = got.firstWhere((x) => x.text.startsWith('Bob, which'));
      print('BOB HISTORY: ${gotLead.to}/${gotLead.toAgent}, ${gotBob.to} topic ${gotBob.topic?.title}');
      expect((gotLead.to, gotLead.toAgent), ('agent', 'lead'));
      expect((gotBob.to, gotBob.topic?.title), ('person', 'Avatars'));

      // What the agent reads: only the message addressed to it by name.
      final inbox = await asLead(['inbox']);
      expect(inbox.exitCode, 0, reason: '${inbox.stderr}');
      print('LEAD INBOX: ${'${inbox.stdout}'.trim()}');
      expect('${inbox.stdout}', contains('lead, please rerun build 412'));
      expect('${inbox.stdout}', isNot(contains('Bob, which avatar sizes')));

      // Unread per thread: Bob and his agent each write; the window shows lead's thread and marks only that one.
      await m.openThread(link, const ThreadKey.agent('lead'));
      await b.send('alice', 'Bob here: 64, 128 and 256 px.');
      final reply = await asLead(['send', 'alice', 'build 412 rerun: green', '--wait', '3s']);
      expect(reply.exitCode, 0, reason: '${reply.stdout}${reply.stderr}');
      await until(() => m.chatOf(link).any((e) => e.text == 'build 412 rerun: green'), what: 'lead\'s reply');
      await until(() => m.chatOf(link).any((e) => e.text == 'Bob here: 64, 128 and 256 px.'), what: 'Bob\'s reply');
      await untilAsync(() async => (await a.contacts()).single.unread == 1, what: 'one unread left (Bob\'s)');
      expect(m.chatUnread(link, ThreadKey.person), 1);
      expect(m.chatUnread(link, const ThreadKey.agent('lead')), 0);
      await m.openThread(link, ThreadKey.person);
      await untilAsync(() async => (await a.contacts()).single.unread == 0, what: 'all read');
      print('UNREAD: per chat, the contact went 1 → 0');

      // Batch approvals: my agent's two sends need approval (its data label 5 is above the contact's level 3).
      final jarvis = await a.agentAdd('jarvis', localLevel: 5, password: alice.password, links: ['bob']);
      Future<String> jarvisAsks(String text) async {
        final r = await Process.run(xCli!, ['--json', 'send', 'bob', text, '--wait', '0'],
            environment: {'ANTENNA_AGENT_TOKEN': jarvis.token, 'ANTENNA_SOCKET': alice.socket});
        expect(r.exitCode, 77, reason: '${r.stdout}');
        return RegExp(r'"id":"([a-z0-9]+)"').firstMatch('${r.stdout}')!.group(1)!;
      }

      final one = await jarvisAsks('project summary, part 1');
      final two = await jarvisAsks('project summary, part 2');
      await until(() => m.approvals.containsKey(one) && m.approvals.containsKey(two), what: 'two pending');
      final (approved, err) = await m.approveMany([m.approvals[one]!, m.approvals[two]!], alice.password);
      expect(err, isNull);
      expect([for (final r in approved) (r.id, r.approval?.state)], [(one, 'approved'), (two, 'approved')]);
      expect(m.approvals.containsKey(one) || m.approvals.containsKey(two), isFalse);
      print('APPROVE_MANY: ${approved.length} approved with one password');

      // Two more: beyond three requests about one contact in 10 minutes they are "quiet" (SPEC §9: no event, listed
      // only with `approvals --all`), so they are denied by ID, as `antenna deny <id> <id>` does.
      final three = await jarvisAsks('project summary, part 3');
      final four = await jarvisAsks('project summary, part 4');
      // Without a password, and even from a connection without an owner session.
      final noSession = XControlClient(alice.socket);
      expect((await noSession.hello()).session, 'none');
      final denied = await noSession.denyMany([three, four]);
      expect([for (final r in denied) (r.id, r.approval?.state)], [(three, 'denied'), (four, 'denied')]);
      final left = await a.approvals(all: true);
      expect(left.approvals.where((x) => x.id == three || x.id == four).map((x) => x.state).toSet(), {'denied'});
      print('DENY_MANY: ${jsonEncode([for (final r in denied) r.id])} denied without a password or session');
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : (!speaksV6 ? 'needs antennad/antenna with addressing (x-control/6: `antenna send --to-agent`)' : false),
      timeout: const Timeout(Duration(minutes: 3)));
}
