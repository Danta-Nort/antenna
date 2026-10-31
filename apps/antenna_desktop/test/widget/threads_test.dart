// SPDX-License-Identifier: AGPL-3.0-only
// x-control/6 in the window on the fake daemon, a v6 daemon like preview.7's (CONTROL §20, D-UI-18, D-UI-32): a link's
// messages split into chats by the counterpart on the contact's side, which the window groups itself from the history
// it loaded (rows of the chat list since D-UI-32), with topic and my-agent filters; the composer's recipient and topic
// default to the open chat and travel in `send`; every author is named (me, my agent, the contact, the contact's agent);
// unread counts per chat and `mark_read` of exactly that chat's IDs; several approvals with one password, a failed one
// reported alone, denying without a password, "Approve all from this agent"; an agent's "messages to everyone" switch;
// and a daemon older than v6 (no addresses sent, chats by `via_agent`, approvals one by one). Chats listed by a v7
// daemon: `chats_test.dart`.

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/widgets/badges.dart' show QuietUnreadDot;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

FakeDaemon _team({int proto = 6}) {
  final d = FakeDaemon(
    contacts: [jordanTeam, emily, buildBot, ryan, rachel],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
  )..protoVersion = proto;
  d.topicMap[jordanTeam.linkId] = teamTopics();
  return d;
}

/// The IDs of history messages by their `seq` in [teamHistory].
String idOf(int seq) => teamHistory().firstWhere((m) => m.seq == seq).id;

List<int> visibleSeqs(AppModel m, String link) => [for (final e in m.visibleChat(link)) if (e.seq != null) e.seq!];

const backend = ThreadKey.agent('claude-backend');
const designBot = ThreadKey.agent('design-bot');

/// The chat list's rows of Jordan's link.
Key row(ThreadKey k) => k.isPerson ? Key('contact-$jordanName') : Key('chat-$jordanName-${k.id}');

Future<void> _send(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer')), text);
  await t.tap(find.byKey(const Key('send')));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _pick(WidgetTester t, String menu, String item) async {
  await t.tap(find.byKey(Key(menu)));
  // The menu grows in over several frames before its items settle where they can be tapped.
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(item)).last);
  await t.pumpAndSettle();
}

void main() {
  final link = jordanTeam.linkId;

  testWidgets('chats: the person and each agent of the contact; an agent chat defaults to "With me" (D-UI-44)',
      (t) async {
    final m = await _model(_team());
    await m.select(link);
    await _app(t, m);
    // The latest message is from claude-backend: its chat opens.
    expect(m.openThreadOf(link), backend);
    expect(m.agentChatsOf(link), [backend, designBot]);
    expect(find.byKey(const Key('thread-bar')), findsOneWidget);
    expect(find.byKey(row(designBot)), findsOneWidget);
    expect(find.text('Morning! Can we talk about the release tomorrow?'), findsNothing, reason: 'Jordan himself is in his own thread');

    // Default: "With me" — only what the owner in person exchanged with claude-backend, not what it exchanged with
    // the owner's own agents (builder, chatgpt).
    expect(m.filterOf(link), const WithMeFilter());
    expect(visibleSeqs(m, link), [56, 58]);
    expect(find.text('Build 412 fails on auth::refresh. Can you rerun the flaky test with logs?'), findsNothing,
        reason: 'negative control: agent-to-agent traffic is hidden by the default filter');

    await t.tap(find.byKey(const Key('thread-filter-between-agents')));
    await t.pump(const Duration(milliseconds: 300));
    expect(visibleSeqs(m, link), [52, 53, 54, 55], reason: 'what claude-backend exchanged with builder and chatgpt');

    await t.tap(find.byKey(const Key('thread-filter-all')));
    await t.pump(const Duration(milliseconds: 300));
    expect(visibleSeqs(m, link), [52, 53, 54, 55, 56, 58]);

    // Topics moved into a secondary menu, still available.
    expect(find.byKey(const Key('thread-filter-mine-builder')), findsNothing, reason: 'per-agent chips are gone here');
    await t.tap(find.byKey(const Key('thread-filter-topics-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('thread-filter-${TopicFilter(topicAvatars).id}')));
    await t.pumpAndSettle();
    expect(visibleSeqs(m, link), [54, 55]);

    // Switching to design-bot's chat and back keeps each chat's own filter (remembered per chat, D-UI-44).
    await t.tap(find.byKey(row(designBot)));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.filterOf(link), const WithMeFilter(), reason: "design-bot's chat opens on its own default");
    await t.tap(find.byKey(row(backend)));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.filterOf(link), TopicFilter(topicAvatars), reason: "backend's chat kept the topic filter it had");

    await t.tap(find.byKey(row(ThreadKey.person)));
    await t.pump(const Duration(milliseconds: 300));
    expect(visibleSeqs(m, link), [50, 51]);
    expect(find.text('Morning! Can we talk about the release tomorrow?'), findsOneWidget);
    // The person chat has no topics or agents of mine: no filter bar, as before D-UI-44.
    expect(find.byKey(const Key('thread-filter-with-me')), findsNothing);
    expect(find.byKey(const Key('thread-bar')), findsNothing);
  });

  testWidgets('a conversation between two people has no thread bar and no address line', (t) async {
    final m = await _model(_team());
    await m.select(emily.linkId);
    await _app(t, m);
    expect(find.byKey(const Key('thread-bar')), findsNothing);
    expect(find.byKey(const Key('composer-to')), findsNothing);
    expect(find.byKey(const Key('composer-topic')), findsOneWidget, reason: 'a topic can still be started');
    expect(find.text(en.authorYou), findsNothing, reason: 'no labels between two people');
  });

  testWidgets('the recipient and topic follow the open chat, and send carries them', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await _app(t, m);
    // A chat with an agent writes to that agent: no choice of recipient there.
    expect(m.recipientOf(link), const Recipient.agent('claude-backend'));
    expect(find.byKey(const Key('composer-to')), findsNothing);

    await _send(t, 'Any news on the flaky test?');
    expect(d.sentAddresses.last, const MessageAddress.agent('claude-backend'));

    // A topic filter makes the topic the default for the next message (by its ID). Topics are a secondary menu in
    // an agent's chat (D-UI-44).
    await t.tap(find.byKey(const Key('thread-filter-topics-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('thread-filter-${TopicFilter(topicBuild).id}')));
    await t.pumpAndSettle();
    await _send(t, 'And keep the log, please.');
    expect(d.sentAddresses.last, MessageAddress.agent('claude-backend', topicId: topicBuild.id));
    expect(m.openThreadOf(link), backend, reason: 'the window stays in the chat it wrote in');

    // The person chat: the person, or everyone on Jordan's computer.
    await t.tap(find.byKey(row(ThreadKey.person)));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.recipientOf(link), Recipient.person);
    await t.tap(find.byKey(const Key('composer-to')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('to-agent-claude-backend')), findsNothing, reason: 'agents have chats of their own');
    expect(find.text(en.composerToEveryoneOn(jordanName)), findsWidgets);
    await t.tap(find.byKey(const Key('to-everyone')).last);
    await t.pumpAndSettle();
    await _send(t, 'Release at 16:00 for everyone.');
    expect(d.sentAddresses.last, const MessageAddress.everyone());
    expect(m.openThreadOf(link), ThreadKey.person);
    expect(find.text('Release at 16:00 for everyone.'), findsOneWidget);
    expect(find.text(en.authorTo(en.authorToEveryone)), findsWidgets, reason: 'the addressee is not the obvious one');

    // The choices stay for the next message until changed.
    await _send(t, 'And the notes will follow.');
    expect(d.sentAddresses.last, const MessageAddress.everyone());
    await _pick(t, 'composer-to', 'to-person');
    await _send(t, 'See you at 10.');
    expect(d.sentAddresses.last, const MessageAddress.person());
    // Another chat starts from its own counterpart again.
    await t.tap(find.byKey(row(designBot)));
    await t.pump(const Duration(milliseconds: 300));
    await _send(t, 'Thanks for the palette.');
    expect(d.sentAddresses.last, const MessageAddress.agent('design-bot'));
  });

  testWidgets('a new topic: the title goes with the first message, then the topic continues by ID', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await _app(t, m);
    await _pick(t, 'composer-topic', 'topic-new');
    await t.enterText(find.byKey(const Key('topic-title')), 'Logo');
    await t.tap(find.byKey(const Key('topic-start')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('composer-topic-chip')), findsOneWidget);
    expect(find.text(en.composerTopicNewTag), findsOneWidget);
    await _send(t, 'Can design-bot draw a logo too?');
    expect(d.sentAddresses.last, const MessageAddress.agent('claude-backend', topic: 'Logo'));
    final logo = d.topicMap[link]!.first;
    expect(logo.title, 'Logo');
    await _send(t, 'Monochrome, please.');
    expect(d.sentAddresses.last, MessageAddress.agent('claude-backend', topicId: logo.id));
    expect(m.topicOptions(link).map((x) => x.title), contains('Logo'));
  });

  testWidgets('authors: my agent, the contact, the contact\'s agent, the addressee; mine unsigned (en, ru)', (t) async {
    final m = await _model(_team());
    await m.select(link);
    await _app(t, m);
    // This test looks at the whole thread, not the default "With me" filter of D-UI-44.
    await t.tap(find.byKey(const Key('thread-filter-all')));
    await t.pump(const Duration(milliseconds: 300));
    // My own message carries neither a name nor a picture, as in any messenger; every other sender has both (D-UI-24).
    expect(find.text(en.authorYou), findsNothing);
    expect(find.byKey(Key('author-${idOf(56)}')), findsNothing);
    expect(find.byKey(Key('avatar-${idOf(56)}')), findsNothing);
    expect(find.byKey(Key('avatar-${idOf(52)}')), findsOneWidget, reason: 'builder, my agent');
    expect(find.byKey(Key('avatar-${idOf(53)}')), findsOneWidget, reason: "claude-backend, the contact's agent");
    expect(find.text('builder'), findsWidgets);
    expect(find.text(en.authorYourAgentTag), findsNWidgets(2), reason: 'builder and chatgpt are mine');
    expect(find.byKey(Key('author-to-${idOf(53)}')), findsOneWidget, reason: '→ builder: one of my agents was addressed');
    expect(find.byKey(Key('author-to-${idOf(58)}')), findsOneWidget, reason: '→ everyone');
    // My agent's bubble is not mine: it uses the agent tint, mine stays brand blue.
    await t.tap(find.byKey(row(ThreadKey.person)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(Key('author-${idOf(50)}')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('author-${idOf(50)}')), matching: find.text(jordanName)), findsOneWidget);

    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(row(backend)));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('thread-filter-all')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(ru.authorYou), findsNothing);
    expect(find.text(ru.authorYourAgentTag), findsNWidgets(2));
    expect(find.text(ru.authorTo(ru.authorToEveryone)), findsOneWidget);
    expect(find.text(ru.composerTo), findsNothing, reason: 'an agent chat has no choice of recipient');
  });

  testWidgets('unread per chat (a v6 daemon): opening a chat marks exactly its messages read', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await _app(t, m);
    // claude-backend opened: only its unread message was marked (a v6 daemon marks by message IDs; v7 marks by chat,
    // chats_test.dart).
    expect(d.markedIds[link], [idOf(58)]);
    expect(d.markedRead[link], 0);
    expect(m.contactById(link)!.unread, 2);
    expect(m.chatUnread(link, ThreadKey.person), 1);
    expect(m.chatUnread(link, designBot), 1);
    // design-bot's one unread message is addressed to my own agent chatgpt (D-UI-44): a quiet dot, not a number.
    expect(find.descendant(of: find.byKey(row(designBot)), matching: find.text('1')), findsNothing);
    expect(find.descendant(of: find.byKey(row(designBot)), matching: find.byType(QuietUnreadDot)), findsOneWidget);

    await t.tap(find.byKey(row(designBot)));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.markedIds[link], [idOf(57)]);
    expect(m.contactById(link)!.unread, 1);

    // A new message in another chat keeps its count; one in the open chat is read at once.
    m.handleEvent(MessageEvent(
      contact: jordanName,
      linkId: link,
      message: msg(60, false, 'Ping from Jordan.', ago(minutes: 1), to: 'person', unread: true),
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.chatUnread(link, ThreadKey.person), 2);
    expect(m.contactById(link)!.unread, 2);
    final inOpen = msg(61, false, 'One more color?', ago(minutes: 1), viaAgent: 'design-bot', to: 'agent', toAgent: 'chatgpt', unread: true);
    m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: inOpen));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.markedIds[link], [inOpen.id]);
  });

  testWidgets('the contact\'s node cannot address: the composer says so honestly', (t) async {
    final old = contact(jordanName, 23, peerKind: 'mixed', peerAddressing: false, agents: jordanTeam.agents);
    final d = FakeDaemon(contacts: [old, emily], history: {old.linkId: teamHistory()});
    final m = await _model(d);
    await m.select(old.linkId);
    await _app(t, m);
    expect(find.byKey(const Key('composer-old-node')), findsOneWidget);
    expect(find.text(en.composerOldNode(jordanName)), findsOneWidget);
  });

  group('batch approvals', () {
    List<ApprovalInfo> three(ContactInfo about) => [
          agentApproval('ap-1', about, fingerprint: 'f1f1f1f1', quote: 'one', minutesAgo: 3),
          agentApproval('ap-2', about, fingerprint: 'f2f2f2f2', quote: 'two', minutesAgo: 2),
          agentApproval('ap-3', about, fingerprint: 'f3f3f3f3', quote: 'three', minutesAgo: 1),
        ];

    testWidgets('approve selected: the password once, every ID with its fingerprint; a failed one alone', (t) async {
      final d = _team()
        ..approvalList = three(jordanTeam)
        ..expiredIds.add('ap-2');
      final m = await _model(d);
      await _app(t, m);
      unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('approvals-select-all')));
      await t.pump();
      expect(find.text(en.approvalsSelectedCount(3)), findsOneWidget);
      await t.tap(find.byKey(const Key('approve-selected')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('owner-password')), findsOneWidget);
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('owner-password')), findsNothing, reason: 'one password for all of them');
      final (items, pw) = d.approveManyCalls.single;
      expect([for (final i in items) (i.id, i.fingerprint)],
          [('ap-1', 'f1f1f1f1'), ('ap-2', 'f2f2f2f2'), ('ap-3', 'f3f3f3f3')]);
      expect(pw, d.password);
      expect(d.calls.where((c) => c == 'approve'), isEmpty);
      expect(m.approvals, isEmpty, reason: 'two approved, the expired one closed');
      expect(find.byKey(const Key('approvals-failed-ap-2')), findsOneWidget);
      expect(find.byKey(const Key('approvals-failed-ap-1')), findsNothing);
      expect(find.textContaining(en.errApprovalExpired), findsOneWidget);
    });

    testWidgets('a changed request fails alone; a wrong password approves nothing', (t) async {
      final requests = three(jordanTeam);
      final d = _team()..approvalList = requests;
      final m = await _model(d);
      await _app(t, m);
      // What the owner saw for ap-3 is not what the daemon has now.
      final seen = [requests[0], requests[1], agentApproval('ap-3', jordanTeam, fingerprint: '00000000')];
      var (results, err) = await m.approveMany(seen, 'wrong');
      expect(err, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      expect(m.approvals.length, 3);
      (results, err) = await m.approveMany(seen, d.password);
      expect(err, isNull);
      expect([for (final r in results) r.ok], [true, true, false]);
      expect(results.last.error!.code, XErrorCode.approvalMismatch);
      expect(m.approvals.keys, ['ap-3']);
    });

    testWidgets('deny selected sends no password', (t) async {
      final d = _team()..approvalList = three(jordanTeam);
      final m = await _model(d);
      await _app(t, m);
      unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('select-ap-1')));
      await t.ensureVisible(find.byKey(const Key('select-ap-3')));
      await t.pump();
      await t.tap(find.byKey(const Key('select-ap-3')));
      await t.pump();
      await t.ensureVisible(find.byKey(const Key('deny-selected')));
      await t.pump();
      await t.tap(find.byKey(const Key('deny-selected')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('owner-password')), findsNothing);
      expect(d.denyManyCalls.single.$1, ['ap-1', 'ap-3']);
      expect(d.passwords.keys, isNot(contains('deny_many')));
      expect(m.approvals.keys, ['ap-2']);
      expect(find.byKey(const Key('approvals-batch')), findsNothing, reason: 'one request left: no selection needed');
    });

    testWidgets('in the conversation: "Approve all from this agent" with one password', (t) async {
      final d = _team()
        ..approvalList = [
          ...three(emily),
          agentApproval('ap-x', emily, requester: 'chatgpt', fingerprint: 'c0c0c0c0'),
        ];
      final m = await _model(d);
      await m.select(emily.linkId);
      await _app(t, m);
      expect(find.byKey(const Key('approve-all-builder')), findsOneWidget, reason: 'on the agent\'s last card only');
      expect(find.byKey(const Key('approve-all-chatgpt')), findsNothing, reason: 'one request: nothing to batch');
      expect(find.text(en.approvalsApproveAllFromAgent(3)), findsOneWidget);
      await t.tap(find.byKey(const Key('approve-all-builder')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text(en.approvalsApproveAllAction(3, 'builder')), findsOneWidget);
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect([for (final i in d.approveManyCalls.single.$1) i.id], ['ap-1', 'ap-2', 'ap-3']);
      expect(m.approvals.keys, ['ap-x']);
    });
  });

  testWidgets('agents: "Sees messages to everyone" on asks the password, off does not', (t) async {
    final d = _team()
      ..agentList = [
        AgentInfo(name: 'builder', createdMs: 0, localLevel: 4, everyone: false),
        AgentInfo(name: 'chatgpt', createdMs: 0, localLevel: 0, everyone: true),
      ];
    final m = await _model(d);
    await _app(t, m);
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.agentEveryone), findsNWidgets(2));
    await t.tap(find.byKey(const Key('agent-everyone-builder')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.agentSetCalls.last, ('builder', true, d.password));
    expect(m.agents.firstWhere((a) => a.name == 'builder').everyone, isTrue);
    await t.tap(find.byKey(const Key('agent-everyone-chatgpt')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsNothing, reason: 'narrowing what an agent reads needs no password');
    expect(d.agentSetCalls.last, ('chatgpt', false, null));
  });

  group('a daemon older than v6', () {
    testWidgets('no address is sent, chats follow via_agent, nothing per message is marked', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..protoVersion = 5;
      final m = await _model(d);
      expect(m.addressing, isFalse);
      expect(m.chatsSupported, isFalse);
      await m.select(jordan.linkId);
      await _app(t, m);
      // Jordan's agent writes in its own chat even without addresses; the person chat holds the rest.
      expect(m.agentChatsOf(jordan.linkId), [const ThreadKey.agent('claude-backend')]);
      expect(m.openThreadOf(jordan.linkId), const ThreadKey.agent('claude-backend'));
      expect(d.markedIds, isEmpty);
      expect(d.markedRead[jordan.linkId], 24, reason: 'marked up to the last incoming message, as before');
      expect(find.byKey(const Key('composer-to')), findsNothing);
      expect(find.byKey(const Key('composer-topic')), findsNothing);
      expect(d.calls, isNot(contains('topics')));
      expect(d.calls, isNot(contains('chats')));
      await t.tap(find.byKey(Key('contact-$jordanName')));
      await t.pump(const Duration(milliseconds: 300));
      await _send(t, 'Thanks, Jordan.');
      expect(d.sentAddresses.last, isNull, reason: 'a v5 daemon rejects unknown fields');
      expect(find.text('Thanks, Jordan.'), findsOneWidget);
    });

    testWidgets('several approvals: one password typed, `approve` per request; deny per request', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
        ..protoVersion = 5
        ..approvalList = [
          agentApproval('ap-1', jordan, fingerprint: 'f1f1f1f1'),
          agentApproval('ap-2', jordan, fingerprint: 'f2f2f2f2'),
          agentApproval('ap-3', jordan, fingerprint: 'f3f3f3f3'),
          agentApproval('ap-4', jordan, fingerprint: 'f4f4f4f4'),
        ]
        ..expiredIds.add('ap-2');
      final m = await _model(d);
      await _app(t, m);
      unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('select-ap-1')));
      await t.tap(find.byKey(const Key('select-ap-2')));
      await t.pump();
      await t.tap(find.byKey(const Key('approve-selected')));
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.calls, isNot(contains('approve_many')));
      expect(d.approveIds, ['ap-1', 'ap-2']);
      expect(find.byKey(const Key('approvals-failed-ap-2')), findsOneWidget);
      expect(m.approvals.keys.toSet(), {'ap-3', 'ap-4'});
      await t.tap(find.byKey(const Key('approvals-select-all')));
      await t.pump();
      await t.tap(find.byKey(const Key('deny-selected')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.calls, isNot(contains('deny_many')));
      expect(d.calls.where((c) => c == 'deny').length, 2);
      expect(m.approvals, isEmpty);
    });

    test('a wrong password stops the one-by-one approvals at the first request', () async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
        ..protoVersion = 5
        ..approvalList = [agentApproval('ap-1', jordan), agentApproval('ap-2', jordan)];
      final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
      await m.connect();
      final (results, err) = await m.approveMany(m.approvals.values.toList(), 'wrong');
      expect(results, isEmpty);
      expect(err, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      expect(d.calls.where((c) => c == 'approve').length, 1, reason: 'no more wrong attempts than one');
      m.dispose();
    });
  });
}
