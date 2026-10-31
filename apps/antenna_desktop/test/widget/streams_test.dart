// SPDX-License-Identifier: AGPL-3.0-only
// The live bubble of streaming messages (x-control/4, CONTROL §15) on the fake daemon: it grows chunk by chunk; a gap
// in `seq` or a `text_len` mismatch reloads `streams`; the final message replaces the bubble (and waits for the
// message if it has not arrived yet); a break shows "interrupted" with the reason; a secret in our own stream shows
// "waiting for your approval"; the "what it is doing" line. Both languages.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/streams.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

HistoryItem _final(String id, ContactInfo c, String text, {bool out = false}) => HistoryItem(
      seq: 900,
      id: id,
      direction: out ? 'out' : 'in',
      kind: 'text',
      text: text,
      ts: ms(fixedNow),
      localMs: ms(fixedNow),
      lamport: 90,
      status: out ? 'delivered' : 'received',
    );

void main() {
  test('model: chunks grow; final after the message replaces the bubble; final before it waits', () async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final resyncs = d.calls.where((c) => c == 'streams').length; // on sign-in the window already asked for live streams
    final f = StreamFeed(buildBot);
    m
      ..handleEvent(f.open())
      ..handleEvent(f.chunk('Hel'))
      ..handleEvent(f.chunk('lo, ', activity: 'tool:Read'))
      ..handleEvent(f.chunk('wörld'));
      final s = m.streamsOf(buildBot.linkId).single;
      expect(s.text, 'Hello, wörld');
    expect(s.state, LiveStreamState.streaming);
    expect(d.calls.where((c) => c == 'streams').length, resyncs, reason: 'seq and text_len agree — no resync');
    // The final event before the message: the bubble waits.
    m.handleEvent(f.finalOf('final-1'));
    expect(m.streamsOf(buildBot.linkId).single.state, LiveStreamState.awaitingMessage);
    m.handleEvent(MessageEvent(contact: buildBot.label, linkId: buildBot.linkId, message: _final('final-1', buildBot, 'Hello, wörld')));
    expect(m.streamsOf(buildBot.linkId), isEmpty);
    expect(m.chatOf(buildBot.linkId).last.text, 'Hello, wörld');

    // The message before the final event: the bubble goes away right on `final`.
    final g = StreamFeed(buildBot, id: 'b5f0c0de00000000000000000000beef');
    m
      ..handleEvent(g.open())
      ..handleEvent(g.chunk('done'))
      ..handleEvent(MessageEvent(contact: buildBot.label, linkId: buildBot.linkId, message: _final('final-2', buildBot, 'done')))
      ..handleEvent(g.finalOf('final-2', end: 'interrupted'));
    expect(m.streamsOf(buildBot.linkId), isEmpty);
    expect(m.interruptedFinals, contains('final-2'), reason: 'the final message is marked “interrupted”');
  });

  test('model: a seq gap or a text_len mismatch re-reads `streams`', () async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    final resyncs = d.calls.where((c) => c == 'streams').length;
    final f = StreamFeed(emily);
    m.handleEvent(f.open());
    m.handleEvent(f.chunk('one '));
    f.chunk('lost '); // this event is lost
    d.streamViews = [
      StreamView(
        contact: emily.label,
        linkId: emily.linkId,
        streamId: f.id,
        direction: 'in',
        text: 'one lost three ',
        live: true,
        seq: 3,
        startedMs: ms(fixedNow),
      ),
    ];
    m.handleEvent(f.chunk('three '));
    await Future<void>.delayed(Duration.zero);
    expect(d.calls.where((c) => c == 'streams').length, resyncs + 1);
    expect(m.streamsOf(emily.linkId).single.text, 'one lost three ');
  });

  test('model: an approved held reply arrives as my message without `final` — the bubble goes by its text', () async {
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    final f = StreamFeed(jordan, direction: 'out');
    m
      ..handleEvent(f.open())
      ..handleEvent(f.chunk('Here is the key: '))
      ..handleEvent(f.interrupted('cut', 'Here is the key: AAAA'));
    expect(m.streamsOf(jordan.linkId).single.awaitingApproval, isTrue);
    // Another outgoing message with different text leaves the bubble alone.
    m.handleEvent(MessageEvent(contact: jordan.label, linkId: jordan.linkId, message: _final('o1', jordan, 'unrelated', out: true)));
    expect(m.streamsOf(jordan.linkId), hasLength(1));
    m.handleEvent(MessageEvent(
        contact: jordan.label, linkId: jordan.linkId, message: _final('o2', jordan, 'Here is the key: AAAA and the rest.', out: true)));
    expect(m.streamsOf(jordan.linkId), isEmpty);
  });

  testWidgets('UI: live bubble with cursor and activity; interrupted shows the reason (en)', (t) async {
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await m.select(buildBot.linkId);
    await _app(t, m);
    final f = StreamFeed(buildBot);
    m
      ..handleEvent(f.open(activity: 'tool:Bash'))
      ..handleEvent(f.chunk('Checking the build ', activity: 'tool:Bash'));
    await t.pump();
    expect(find.text('typing…'), findsOneWidget);
    expect(find.text('using Bash…'), findsOneWidget);
    m.handleEvent(f.interrupted('connection_lost', 'Checking the build log'));
    await t.pump();
    expect(find.text('Checking the build log'), findsOneWidget);
    expect(find.text('interrupted · the connection was lost'), findsOneWidget);
    expect(find.text('typing…'), findsNothing);
  });

  testWidgets('UI: a contact\'s agent is named on its live bubble and writes in its own chat (PG-20)', (t) async {
    final en = l10nFor('en');
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await m.select(jordan.linkId);
    await m.openThread(jordan.linkId, const ThreadKey.agent('claude-backend'));
    await _app(t, m);
    final f = StreamFeed(jordan, viaAgent: 'claude-backend');
    m
      ..handleEvent(f.open())
      ..handleEvent(f.chunk('Looking at the migrations'));
    await t.pump();
    final bubble = find.byKey(const ValueKey('chat-row-stream-a5f0c0de00000000000000000000beef'));
    expect(bubble, findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text(en.viaContactAgent('Jordan Lee', 'claude-backend'))),
        findsOneWidget);
    expect(m.streamsOf(jordan.linkId).single.viaAgent, 'claude-backend');
    // Not in the person's chat
    await m.openThread(jordan.linkId, ThreadKey.person);
    await t.pump();
    expect(bubble, findsNothing);
    // A stream whose node does not name anyone shows in every chat, as before
    final g = StreamFeed(jordan, id: 'c6f0c0de00000000000000000000beef');
    m
      ..handleEvent(g.open())
      ..handleEvent(g.chunk('Typing'));
    await t.pump();
    final unnamed = find.byKey(const ValueKey('chat-row-stream-c6f0c0de00000000000000000000beef'));
    expect(unnamed, findsOneWidget);
    expect(find.descendant(of: unnamed, matching: find.text('Jordan Lee')), findsOneWidget);
    await m.openThread(jordan.linkId, const ThreadKey.agent('claude-backend'));
    await t.pump();
    expect(unnamed, findsOneWidget);
    expect(bubble, findsOneWidget);
  });

  testWidgets('UI: my agent\'s stream cut by a secret waits for my approval (ru)', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    d.wakeRuleList = [
      WakeRuleInfo(
        contact: jordan.label,
        linkId: jordan.linkId,
        agent: 'wake-jordan',
        argv: const ['/usr/local/bin/claude', '-p', '--output-format', 'stream-json'],
        mode: 'claude_stream',
        timeoutSecs: 600,
        maxRunsPerHour: 20,
      ),
    ];
    final m = await _model(d);
    await m.select(jordan.linkId);
    // The owner looks at Jordan himself; the wake agent's reply, unaddressed here, lands in his thread.
    await m.openThread(jordan.linkId, ThreadKey.person);
    await _app(t, m);
    final f = StreamFeed(jordan, direction: 'out');
    m
      ..handleEvent(f.open())
      ..handleEvent(f.chunk('Here is the key: '))
      ..handleEvent(f.interrupted('cut', 'Here is the key: '));
      await t.pump();
      final ru = l10nFor('ru');
      expect(find.text(ru.streamOutAgent('wake-jordan')), findsOneWidget);
      expect(find.textContaining(ru.streamAwaitingApproval), findsOneWidget);
      expect(find.text(ru.streamOpenApprovals), findsOneWidget);
      // After approval the final message arrives with the same stream_id.
      m.handleEvent(MessageEvent(contact: jordan.label, linkId: jordan.linkId, message: _final('fin-x', jordan, 'Here is the key: …', out: true)));
    m.handleEvent(f.finalOf('fin-x'));
    await t.pump();
    expect(find.textContaining(ru.streamAwaitingApproval), findsNothing);
    expect(find.text('Here is the key: …'), findsOneWidget);
  });
}
