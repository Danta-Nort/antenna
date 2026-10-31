// SPDX-License-Identifier: AGPL-3.0-only
// Chats per agent in the window (x-control/7, CONTROL §26, D-113, D-UI-32) on the fake daemon: each agent of a contact
// is its own row under the contact's row (the person chat), with its local name, its unread count and its menu; a
// chat's pages and its read mark are the daemon's by chat; rename, notifications and archive go to the daemon and stay
// local; a new agent becomes a row when it first writes, and the owner can start a chat with a known one; content-free
// notifications follow each chat's setting; a daemon from before chats (preview.7, x-control/6) still gets the rows,
// from the history the window loaded, without the settings.

import 'dart:io';

import 'package:antenna_desktop/host/notifier.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/chat_prefs.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/badges.dart' show QuietUnreadDot;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

class _Notifier implements SystemNotifier {
  final shown = <(String, String)>[];
  @override
  Future<void> show({required String title, required String body}) async => shown.add((title, body));
}

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, {SystemNotifier? notifier}) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, notifier: notifier));
  await t.pump(const Duration(milliseconds: 300));
}

final link = jordanTeam.linkId;
const backend = ThreadKey.agent('claude-backend');
const designBot = ThreadKey.agent('design-bot');

/// Jordan's link with its three chats, on a daemon that lists chats; claude-backend named "Payments API" here.
FakeDaemon _team({int proto = 7, bool named = true}) {
  final d = FakeDaemon(
    contacts: [jordanTeam, emily, buildBot],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
  )..protoVersion = proto;
  d.topicMap[jordanTeam.linkId] = teamTopics();
  if (named) {
    d.chatSettings[link] = {
      'claude-backend': ChatInfo(contact: jordanName, linkId: link, agent: 'claude-backend', name: 'Payments API', saved: true),
    };
  }
  return d;
}

Key row(ThreadKey k) => k.isPerson ? Key('contact-$jordanName') : Key('chat-$jordanName-${k.id}');
Finder _in(Key k, Finder f) => find.descendant(of: find.byKey(k), matching: f);
List<int> visibleSeqs(AppModel m) => [for (final e in m.visibleChat(link)) if (e.seq != null) e.seq!];
String idOf(int seq) => teamHistory().firstWhere((m) => m.seq == seq).id;

Future<void> _menu(WidgetTester t, ThreadKey k, String item) async {
  await t.tap(find.byKey(Key('chat-menu-$jordanName-${k.id}')).first);
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(item)).last);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the list: a row per agent under the contact, local names, unread per chat, the person chat', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);
    expect(m.chatsSupported, isTrue);
    expect(d.calls, contains('chats'));
    // Under Jordan's row (the person chat): one row per agent, the most recent first; the named one shows its name
    // and, quietly, whose agent it is.
    expect(find.byKey(row(ThreadKey.person)), findsOneWidget);
    expect(find.byKey(row(backend)), findsOneWidget);
    expect(find.byKey(row(designBot)), findsOneWidget);
    expect(t.getTopLeft(find.byKey(row(backend))).dy, greaterThan(t.getTopLeft(find.byKey(row(ThreadKey.person))).dy));
    expect(t.getTopLeft(find.byKey(row(backend))).dy, lessThan(t.getTopLeft(find.byKey(row(designBot))).dy));
    expect(t.getTopLeft(find.byKey(row(backend))).dx, greaterThan(t.getTopLeft(find.byKey(row(ThreadKey.person))).dx),
        reason: 'indented under the contact');
    expect(_in(row(backend), find.text('Payments API')), findsOneWidget);
    expect(_in(row(backend), find.text('claude-backend')), findsOneWidget);
    expect(_in(row(designBot), find.text('design-bot')), findsOneWidget);
    // The person chat is read now; each agent chat keeps its own count.
    expect(m.chatUnread(link, ThreadKey.person), 0);
    expect(_in(row(backend), find.text('1')), findsOneWidget, reason: "backend's unread is a broadcast, for me");
    // design-bot's one unread message is addressed to my own agent chatgpt (D-UI-44): a quiet dot, not a number.
    expect(_in(row(designBot), find.text('1')), findsNothing);
    expect(_in(row(designBot), find.byType(QuietUnreadDot)), findsOneWidget);
    expect(d.markedChats[link], (const ChatRef.person(), 51), reason: 'the daemon marked the person chat only');
    expect(d.historyChats, contains(const ChatRef.person()), reason: 'the chat\'s own page');
    expect(visibleSeqs(m), [50, 51]);
    expect(find.byKey(const Key('thread-bar')), findsNothing, reason: 'no thread chips any more');

    // An agent's chat: its own page, its own read mark, its name in the header with whose agent it is.
    await t.tap(find.byKey(row(backend)));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.openThreadOf(link), backend);
    expect(d.historyChats.last, const ChatRef.agent('claude-backend'));
    expect(d.markedChats[link], (const ChatRef.agent('claude-backend'), 58), reason: 'read in full, filter or not');
    // Opens on "With me" (D-UI-44): the other filters are `threads_test.dart`'s concern.
    expect(visibleSeqs(m), [56, 58]);
    expect(_in(const Key('chat-header-name'), find.text('Payments API')), findsOneWidget);
    expect(find.byKey(const Key('chat-header-agent')), findsOneWidget);
    expect(find.text(en.chatAgentTitle(jordanName, 'claude-backend')), findsWidgets);
    expect(_in(row(backend), find.text('1')), findsNothing);
    expect(m.contactById(link)!.unread, 1, reason: 'design-bot still waits');
    // Sending here addresses the agent; the window stays in its chat.
    await t.enterText(find.byKey(const Key('composer')), 'Any news?');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentAddresses.last, const MessageAddress.agent('claude-backend'));
    expect(m.openThreadOf(link), backend);
  });

  testWidgets('rename, notifications and archive from the chat menu; the person chat renames the contact', (t) async {
    final d = _team(named: false);
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);

    await _menu(t, designBot, 'chat-menu-rename');
    expect(find.text(en.chatRenameNote(jordanName)), findsOneWidget);
    await t.enterText(find.byKey(const Key('chat-rename-field')), '  Palette  ');
    await t.tap(find.byKey(const Key('chat-rename-ok')));
    await t.pumpAndSettle();
    final set = d.chatSetCalls.last;
    expect((set.agent, set.name, set.notify, set.archived), ('design-bot', 'Palette', null, null));
    expect(_in(row(designBot), find.text('Palette')), findsOneWidget);
    expect(m.chatName(link, designBot), 'Palette');

    // Notifications: "Only when it asks for me" by default for an agent, the owner picks Off.
    await t.tap(find.byKey(const Key('chat-menu-Jordan Lee-agent-design-bot')).first);
    await t.pumpAndSettle();
    expect(find.text(en.chatNotifyAsks), findsOneWidget);
    expect(_in(const Key('chat-menu-notify-asks'), find.byIcon(Icons.check_rounded)), findsOneWidget);
    await t.tap(find.byKey(const Key('chat-menu-notify-off')).last);
    await t.pumpAndSettle();
    expect(d.chatSetCalls.last.notify, ChatNotify.off);
    expect(_in(row(designBot), find.byIcon(Icons.notifications_off_outlined)), findsOneWidget);

    // Archive: the row goes into the folded Archived section, its history stays.
    await _menu(t, designBot, 'chat-menu-archive');
    expect(d.chatSetCalls.last.archived, isTrue);
    expect(find.byKey(row(designBot)), findsNothing);
    expect(find.text(en.chatsArchivedSection(1).toUpperCase()), findsOneWidget);
    await t.tap(find.byKey(const Key('chats-archived')));
    await t.pump(const Duration(milliseconds: 300));
    expect(_in(row(designBot), find.text('Palette')), findsOneWidget);
    await _menu(t, designBot, 'chat-menu-unarchive');
    expect(d.chatSetCalls.last.archived, isFalse);
    expect(find.byKey(const Key('chats-archived')), findsNothing);
    expect(find.byKey(row(designBot)), findsOneWidget);

    // Remove the name: the agent's own name again.
    await _menu(t, designBot, 'chat-menu-rename');
    await t.tap(find.byKey(const Key('chat-rename-reset')));
    await t.pumpAndSettle();
    expect(d.chatSetCalls.last.name, '');
    expect(_in(row(designBot), find.text('design-bot')), findsOneWidget);

    // The person chat: "Rename contact…" and no archive.
    await t.tap(find.byKey(const Key('chat-menu-Jordan Lee-person')).first);
    await t.pumpAndSettle();
    expect(find.text(en.chatMenuRenameContact), findsOneWidget);
    expect(find.byKey(const Key('chat-menu-archive')), findsNothing);
    expect(_in(const Key('chat-menu-notify-all'), find.byIcon(Icons.check_rounded)), findsOneWidget,
        reason: 'a person chat notifies of every message by default');
    await t.tap(find.byKey(const Key('chat-menu-rename')).last);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('rename-field')), findsOneWidget, reason: 'the contact\'s own rename dialog');
    await t.tap(find.text(en.commonCancel));
    await t.pumpAndSettle();

    // A change made in another window or the CLI arrives as a `chat` event.
    m.handleEvent(ChatEvent(ChatInfo(contact: jordanName, linkId: link, agent: 'design-bot', name: 'Design desk', saved: true)));
    await t.pump(const Duration(milliseconds: 300));
    expect(_in(row(designBot), find.text('Design desk')), findsOneWidget);
  });

  testWidgets('a new agent is a new chat when it first writes; "New chat" starts one with a known agent', (t) async {
    final withTester = contact(jordanName, 23,
        trust: 3, presence: 'online', role: 'joiner', unread: 3, peerKind: 'mixed', agents: [
      ...jordanTeam.agents,
      PeerAgent(name: 'tester', state: 'active', sinceMs: ms(ago(hours: 1))),
    ]);
    final d = FakeDaemon(contacts: [withTester, emily], history: {...demoHistory(), link: teamHistory()});
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);
    expect(find.byKey(row(const ThreadKey.agent('reviewer'))), findsNothing);

    final first = msg(70, false, 'Hi, I review the PRs now.', ago(minutes: 1), viaAgent: 'reviewer', to: 'person', unread: true);
    d.historyMap[link]!.add(first);
    m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: first));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(row(const ThreadKey.agent('reviewer'))), findsOneWidget);
    expect(m.chatUnread(link, const ThreadKey.agent('reviewer')), 1);
    expect(_in(row(const ThreadKey.agent('reviewer')), find.text('Hi, I review the PRs now.')), findsOneWidget);
    expect(m.chatUnread(link, ThreadKey.person), 0, reason: 'not counted in the person chat');

    // "New chat": the announced agent without a chat yet; starting it saves the chat at the daemon and opens it.
    await t.tap(find.byKey(const Key('new-chat')));
    await t.pumpAndSettle();
    expect(find.text(en.chatNewTitle), findsOneWidget);
    expect(find.text(en.chatNewStart), findsOneWidget, reason: 'only tester has no chat yet');
    await t.tap(find.byKey(const Key('new-chat-Jordan Lee-agent-tester')));
    await t.pumpAndSettle();
    expect((d.chatSetCalls.last.agent, d.chatSetCalls.last.name), ('tester', null));
    expect(m.openThreadOf(link), const ThreadKey.agent('tester'));
    expect(find.byKey(row(const ThreadKey.agent('tester'))), findsOneWidget);
    expect(find.byKey(const Key('thread-empty')), findsOneWidget);
    await t.enterText(find.byKey(const Key('composer')), 'Please run the suite.');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentAddresses.last, const MessageAddress.agent('tester'));
  });

  testWidgets('notifications follow each chat\'s setting and carry only the chat\'s name', (t) async {
    final notifier = _Notifier();
    final d = _team();
    d.chatSettings[link]!['design-bot'] =
        ChatInfo(contact: jordanName, linkId: link, agent: 'design-bot', notify: ChatNotify.off, notifySet: true, saved: true);
    final m = await _model(d);
    await m.select(emily.linkId);
    await _app(t, m, notifier: notifier);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    var seq = 80;
    Future<void> arrive(String text, {String? via, String to = 'person', String? toAgent}) async {
      final item = msg(seq++, false, text, ago(minutes: 1), viaAgent: via, to: to, toAgent: toAgent, unread: true);
      m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: item));
      await t.pump(const Duration(milliseconds: 50));
    }

    // The person chat: every message (the default "All messages").
    await arrive('SECRET dinner plans');
    expect(notifier.shown, [(en.notifyMessageTitle, en.notifyMessageBody(jordanName))]);
    expect(notifier.shown.single.$2, isNot(contains('SECRET')), reason: 'never the text');
    // claude-backend ("Only when it asks for me"): not its work with my agents, but what it writes to me.
    await arrive('build log for builder', via: 'claude-backend', to: 'agent', toAgent: 'builder');
    expect(notifier.shown, hasLength(1));
    await arrive('Maya, can you approve the deploy?', via: 'claude-backend');
    expect(notifier.shown.last, (en.notifyMessageTitle, en.notifyMessageBody('Payments API')),
        reason: 'the local name, not the text');
    // design-bot: off.
    await arrive('palette v2', via: 'design-bot');
    expect(notifier.shown, hasLength(2));
    // A burst in one chat: one notification.
    await arrive('and another thing');
    expect(notifier.shown, hasLength(2));
    // In focus the list's counts are enough.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await arrive('back', via: 'claude-backend');
    expect(notifier.shown, hasLength(2));
    // Russian.
    expect(ru.notifyMessageBody('Payments API'), contains('Payments API'));
  });

  testWidgets('agent-to-agent messages notify only when the chat opted in; a broadcast to everyone notifies (D-UI-44)',
      (t) async {
    final notifier = _Notifier();
    final m = await _model(_team());
    await m.select(emily.linkId);
    await _app(t, m, notifier: notifier);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    var seq = 90;
    Future<void> arrive(String text, {required String via, required String to, String? toAgent}) async {
      final item = msg(seq++, false, text, ago(minutes: 1), viaAgent: via, to: to, toAgent: toAgent, unread: true);
      m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: item));
      await t.pump(const Duration(milliseconds: 50));
    }

    // design-bot, "Only when it asks for me": what it tells my own agent chatgpt is not for me
    await arrive('palette for chatgpt', via: 'design-bot', to: 'agent', toAgent: 'chatgpt');
    expect(notifier.shown, isEmpty, reason: 'agent-to-agent traffic is quiet by default');
    expect(m.notifyAgentsOn(link, 'design-bot'), isFalse);

    // The chat opts in (its menu item): the same kind of message now notifies, with the chat's name only
    await t.tap(find.byKey(Key('chat-menu-$jordanName-${designBot.id}')).first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-menu-notify-agents')).last);
    await t.pumpAndSettle();
    expect(m.notifyAgentsOn(link, 'design-bot'), isTrue);
    await arrive('palette v2 for chatgpt', via: 'design-bot', to: 'agent', toAgent: 'chatgpt');
    expect(notifier.shown, [(en.notifyMessageTitle, en.notifyMessageBody(en.chatAgentTitle(jordanName, 'design-bot')))]);

    // A broadcast to everyone is for the person too: it notifies on "Only when it asks for me" (it did not before)
    await arrive('staging restarts at 15:00', via: 'claude-backend', to: 'everyone');
    expect(notifier.shown, hasLength(2));

    // The rule itself, past the once-per-10-seconds throttle: Off wins over the opt-in, and opting out is quiet again
    final between = ChatEntry.fromHistory(
        msg(99, false, 'late palette', ago(minutes: 1), viaAgent: 'design-bot', to: 'agent', toAgent: 'chatgpt'));
    expect(m.chatNotifies(link, between), isTrue);
    await m.setChatNotify(link, designBot, ChatNotify.off);
    expect(m.chatNotifies(link, between), isFalse, reason: 'a chat set to Off stays off');
    await m.setChatNotify(link, designBot, ChatNotify.asks);
    m.setNotifyAgentsOn(link, 'design-bot', false);
    expect(m.chatNotifies(link, between), isFalse, reason: 'opted out again');
  });

  testWidgets('a message to an agent the contact does not have says so, with the names one can address', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);
    // The owner starts a chat with a name nobody there has (as with "chatgpt" when the app's agent is "codex").
    d.historyMap[link]!.add(msg(71, false, 'chatgpt here?', ago(minutes: 1), viaAgent: 'chatgpt', to: 'person'));
    m.handleEvent(MessageEvent(
        contact: jordanName, linkId: link, message: d.historyMap[link]!.last));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(row(const ThreadKey.agent('chatgpt'))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('composer')), 'Please draw three avatars.');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    final sent = m.visibleChat(link).last;
    expect(sent.noAgent, isTrue);
    expect(find.byKey(Key('no-agent-${sent.id}')), findsOneWidget);
    expect(find.text('${en.bubbleNoAgent('chatgpt', jordanName)} ${en.bubbleNoAgentList('claude-backend, design-bot')}'),
        findsOneWidget);
    // An agent that is there: no such line.
    await t.tap(find.byKey(row(backend)));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('composer')), 'Any news?');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.visibleChat(link).last.noAgent, isFalse);
    // The answer can come later, as a status event: the same line.
    final later = msg(72, true, 'One more for design-bot.', ago(minutes: 1), to: 'agent', toAgent: 'design-bot');
    d.historyMap[link]!.add(later);
    m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: later));
    m.handleEvent(MessageStatusEvent(contact: jordanName, linkId: link, id: later.id, status: 'no_agent'));
    await t.tap(find.byKey(row(designBot)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(Key('no-agent-${later.id}')), findsOneWidget);
    // The receipt in the person chat reads in plain words.
    expect(en.receiptNoSuchAgent, 'no agent by that name');
  });

  test('a file sent in an agent\'s chat is for that agent only; in the person\'s chat it has no address (PG-19)',
      () async {
    final dir = Directory.systemTemp.createTempSync('pg19-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/build.log';
    File(path).writeAsStringSync('build 412: green');
    final d = _team();
    final m = await _model(d);
    await m.select(link);
    await m.openThread(link, backend);
    await m.shareFile(link, path);
    expect(d.shareAddresses.last, ('agent', 'claude-backend'));
    m.setRecipient(link, Recipient.everyone);
    await m.shareFile(link, path);
    expect(d.shareAddresses.last, ('everyone', null));
    await m.openThread(link, ThreadKey.person);
    await m.shareFile(link, path);
    expect(d.shareAddresses.last, (null, null), reason: 'the person: no address, as before');
    // A daemon before chats parses share_file strictly: no address at all
    final old = _team()..chatsEnabled = false;
    final m2 = await _model(old);
    await m2.select(link);
    await m2.openThread(link, backend);
    await m2.shareFile(link, path);
    expect(old.shareAddresses.last, (null, null));
  });

  testWidgets('filters and search reach chats by unread, the agent\'s and the local name', (t) async {
    final m = await _model(_team());
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(find.text(en.listFilterUnread).first);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(row(ThreadKey.person)), findsOneWidget);
    expect(find.byKey(row(backend)), findsOneWidget);
    expect(find.byKey(row(designBot)), findsOneWidget);
    await t.tap(find.byKey(row(designBot)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(row(designBot)), findsOneWidget, reason: 'read now, and still there while it is open');
    expect(m.chatUnread(link, designBot), 0);
    await t.tap(find.byKey(row(backend)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(row(designBot)), findsNothing, reason: 'read and closed: out of "Unread"');
    expect(find.byKey(row(backend)), findsOneWidget);
    await t.tap(find.text(en.listFilterAll).first);
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byType(TextField).first, 'payments');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(row(backend)), findsOneWidget);
    expect(find.byKey(row(designBot)), findsNothing);
    expect(find.byKey(row(ThreadKey.person)), findsOneWidget, reason: 'the contact\'s row stands above its chat');
    expect(find.byKey(Key('contact-$emilyName')), findsNothing);
  });

  testWidgets('counts read elsewhere and a lagged subscription ask the daemon for the chats again', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(emily.linkId);
    await _app(t, m);
    final before = d.calls.where((c) => c == 'chats').length;
    // `antenna inbox` read Jordan's messages: the contact's total no longer matches the chats.
    d.historyMap[link] = [for (final h in d.historyMap[link]!) h.withUnread(false)];
    d.contactList = [for (final c in d.contactList) c.linkId == link ? c.copyWith(unread: 0) : c];
    await m.refreshContacts();
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls.where((c) => c == 'chats').length, before + 1);
    expect(m.chatUnread(link, backend), 0);
    expect(_in(row(backend), find.text('1')), findsNothing);
    m.handleEvent(const Lagged(3));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls.where((c) => c == 'chats').length, before + 2);
  });

  testWidgets('a stable order (D-UI-43): a lower chat getting a new message does not move it', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);
    // Before: backend above design-bot (how the daemon first listed them; "first appeared" for a fresh window).
    final backendY = t.getTopLeft(find.byKey(row(backend))).dy;
    final designBotY = t.getTopLeft(find.byKey(row(designBot))).dy;
    expect(backendY, lessThan(designBotY));

    // design-bot, the lower chat, gets the newest message of the two: under the old "most recent first" rule this
    // would have put it on top; the order stays as it was (negative control: reverting `agentChatsOf` to sort by
    // `chatActivityMs` makes this assertion fail). Newer than backend's latest (4 minutes ago) but not newer than
    // Emily's (3 minutes ago), so the contact list's own, unrelated activity order (unaffected by this change) does
    // not also move Jordan's whole row and confound the measurement.
    final fresh = msg(90, false, 'Palette is ready.', fixedNow.subtract(const Duration(minutes: 3, seconds: 30)),
        viaAgent: 'design-bot', to: 'person', unread: true);
    d.historyMap[link]!.add(fresh);
    m.handleEvent(MessageEvent(contact: jordanName, linkId: link, message: fresh));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getTopLeft(find.byKey(row(backend))).dy, backendY, reason: 'stays where it was');
    expect(t.getTopLeft(find.byKey(row(designBot))).dy, designBotY, reason: 'activity does not move the row');
    // Activity still shows: the unread badge grew and the row still carries the new text, just not by moving.
    expect(m.chatUnread(link, designBot), 2);
    expect(_in(row(designBot), find.text('Palette is ready.')), findsOneWidget);
  });

  testWidgets('drag reorder is saved locally and outlives the window (D-UI-43)', (t) async {
    final tmp = Directory.systemTemp.createTempSync('chat_prefs_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = ChatPrefsStore('${tmp.path}/chat_prefs.json', '${tmp.path}/chat_pictures');
    final d = _team();
    final m1 = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, chatPrefs: store);
    await m1.connect();
    await m1.select(link, chat: ThreadKey.person);
    await _app(t, m1);
    expect(t.getTopLeft(find.byKey(row(backend))).dy, lessThan(t.getTopLeft(find.byKey(row(designBot))).dy));

    // The owner drags design-bot above claude-backend (the gesture itself is `_AgentChatBlock.onReorder`, tested as
    // the plain state change it makes).
    m1.reorderChats(link, const ['design-bot', 'claude-backend']);
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getTopLeft(find.byKey(row(designBot))).dy, lessThan(t.getTopLeft(find.byKey(row(backend))).dy),
        reason: 'the drag took effect at once');

    // A new window (a restart), same local settings file: the dragged order is still there, read fresh from disk.
    final d2 = _team();
    final m2 = AppModel(connector: (_) => d2, socketPath: d2.socketPath, live: false, clock: () => fixedNow, chatPrefs: store);
    await m2.connect();
    await m2.select(link, chat: ThreadKey.person);
    await _app(t, m2);
    expect(t.getTopLeft(find.byKey(row(designBot))).dy, lessThan(t.getTopLeft(find.byKey(row(backend))).dy),
        reason: 'negative control: a fresh store (no chatPrefs) falls back to the daemon\'s order, backend first');
  });

  testWidgets('Pin keeps a chat on top; Unpin returns it to its place (D-UI-43)', (t) async {
    final d = _team();
    final m = await _model(d);
    await m.select(link, chat: ThreadKey.person);
    await _app(t, m);
    expect(t.getTopLeft(find.byKey(row(backend))).dy, lessThan(t.getTopLeft(find.byKey(row(designBot))).dy));

    await _menu(t, designBot, 'chat-menu-pin');
    expect(m.isChatPinned(link, 'design-bot'), isTrue);
    expect(t.getTopLeft(find.byKey(row(designBot))).dy, lessThan(t.getTopLeft(find.byKey(row(backend))).dy),
        reason: 'pinned chats stay on top');

    await _menu(t, designBot, 'chat-menu-unpin');
    expect(m.isChatPinned(link, 'design-bot'), isFalse);
    expect(t.getTopLeft(find.byKey(row(backend))).dy, lessThan(t.getTopLeft(find.byKey(row(designBot))).dy),
        reason: 'negative control: unpinned, it goes back to its ordinary place, not staying on top');
  });

  group('migration and older daemons', () {
    testWidgets('a preview.7 daemon (x-control/6): the rows from the loaded history, no settings', (t) async {
      final d = _team(proto: 6, named: false);
      final m = await _model(d);
      await m.select(link, chat: ThreadKey.person);
      await _app(t, m);
      expect(m.chatsSupported, isFalse);
      expect(d.calls, isNot(contains('chats')));
      // The threads of preview.7 are rows now, with the counts of the history the window read.
      expect(find.byKey(row(backend)), findsOneWidget);
      expect(find.byKey(row(designBot)), findsOneWidget);
      // design-bot's one unread message is addressed to my own agent chatgpt (D-UI-44): a quiet dot, not a number.
      expect(_in(row(designBot), find.text('1')), findsNothing);
      expect(_in(row(designBot), find.byType(QuietUnreadDot)), findsOneWidget);
      expect(d.historyChats.whereType<ChatRef>(), isEmpty, reason: 'a v6 daemon refuses unknown fields');
      await t.tap(find.byKey(row(designBot)));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.markedIds[link], [idOf(57)]);
      // The settings need the newer daemon: shown, not offered.
      await t.tap(find.byKey(const Key('chat-menu-Jordan Lee-agent-design-bot')).first);
      await t.pumpAndSettle();
      final rename = t.widget<PopupMenuItem<Object?>>(find.byKey(const Key('chat-menu-rename')).last);
      expect(rename.enabled, isFalse);
      final off = t.widget<PopupMenuItem<Object?>>(find.byKey(const Key('chat-menu-notify-off')).last);
      expect(off.enabled, isFalse);
      expect(d.calls, isNot(contains('chat_set')));
    });

    testWidgets('a v7 daemon from before chats answers once and the window groups the chats itself', (t) async {
      final d = _team()..chatsEnabled = false;
      final m = await _model(d);
      await m.select(link, chat: ThreadKey.person);
      await _app(t, m);
      expect(m.chatsSupported, isFalse);
      expect(d.calls.where((c) => c == 'chats').length, 1);
      expect(find.byKey(row(backend)), findsOneWidget);
      await m.refreshContacts();
      expect(d.calls.where((c) => c == 'chats').length, 1, reason: 'not asked again');
    });

    test('a preview.7 history becomes rows by the daemon\'s rule, nothing lost', () async {
      // The same history under both daemons: the rows and their counts agree.
      final old = await _model(_team(proto: 6, named: false));
      final now = await _model(_team(named: false));
      await old.select(link);
      for (final k in [ThreadKey.person, backend, designBot]) {
        expect(old.agentChatsOf(link).contains(k) || k.isPerson, isTrue, reason: '$k');
      }
      expect(now.agentChatsOf(link), old.agentChatsOf(link));
      final all = teamHistory().length;
      var sum = 0;
      for (final k in [ThreadKey.person, ...now.agentChatsOf(link)]) {
        sum += now.chatInfoOf(link, k)!.count;
      }
      expect(sum, all, reason: 'every message is in exactly one chat');
      old.dispose();
      now.dispose();
    });
  });
}
