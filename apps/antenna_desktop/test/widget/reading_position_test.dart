// SPDX-License-Identifier: AGPL-3.0-only
// The reading position per chat (state/drafts.dart `ReadingPosition`, ui/chat/chat_view.dart; fake daemon). A chat
// left at its very end opened in the middle, at an old message, after a visit to another chat of the same contact:
// one list was shared by the chats of a contact and kept the other chat's offset. As in any messenger: left at the end, back at the end; left elsewhere, back to the same message at the same
// height; messages that came meanwhile wait below a "New messages" line with the jump button's count, the view staying
// on the last message read; the person's own message always shows the end.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 700);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

/// Emily's chat with 40 numbered messages, so it scrolls.
FakeDaemon _long() {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  d.historyMap[emily.linkId] = [
    for (var i = 1; i <= 40; i++) msg(200 + i, i.isEven, 'Message number $i', fixedNow.subtract(Duration(minutes: 60 - i))),
  ];
  return d;
}

final _messages = find.byKey(const Key('chat-messages'));
final _jump = find.byKey(const Key('chat-jump-bottom'));
ScrollPosition _pos(WidgetTester t) => t.widget<ListView>(_messages).controller!.position;
Finder _text(String s) => find.descendant(of: _messages, matching: find.text(s));

Future<void> _open(WidgetTester t, AppModel m, ContactInfo c) async {
  await m.select(c.linkId, chat: ThreadKey.person);
  await _settle(t);
}

void main() {
  testWidgets('left at the end: back at the end', (t) async {
    final m = await _model(_long());
    await _app(t, m);
    await _open(t, m, emily);
    expect(_pos(t).pixels, 0);
    await _open(t, m, jordan);
    await _open(t, m, emily);
    expect(_pos(t).pixels, 0);
    expect(_text('Message number 40'), findsOneWidget);
    expect(find.text(en.chatNewMessagesLine), findsNothing);
  });

  testWidgets("two chats of one contact keep their own places", (t) async {
    final d = FakeDaemon(contacts: [jordanTeam, emily], history: demoHistory());
    d.historyMap[jordanTeam.linkId] = [
      for (var i = 1; i <= 30; i++) ...[
        msg(300 + 2 * i, false, 'From Jordan $i', fixedNow.subtract(Duration(minutes: 200 - 2 * i)), to: 'person'),
        msg(301 + 2 * i, false, 'From the agent $i', fixedNow.subtract(Duration(minutes: 199 - 2 * i)),
            viaAgent: 'claude-backend', to: 'person'),
      ],
    ];
    final m = await _model(d);
    await _app(t, m);
    const agent = ThreadKey.agent('claude-backend');
    await m.select(jordanTeam.linkId, chat: ThreadKey.person);
    await _settle(t);
    expect(_pos(t).pixels, 0, reason: 'the person chat, at its end');
    await m.select(jordanTeam.linkId, chat: agent);
    await _settle(t);
    _pos(t).jumpTo(500);
    await _settle(t);
    await m.select(jordanTeam.linkId, chat: ThreadKey.person);
    await _settle(t);
    expect(_pos(t).pixels, 0, reason: "left at its end, back at its end: not the agent chat's place");
    expect(_text('From Jordan 30'), findsOneWidget);
    await m.select(jordanTeam.linkId, chat: agent);
    await _settle(t);
    expect(_pos(t).pixels, closeTo(500, 2), reason: 'the agent chat where it was left');
  });

  testWidgets('left in the middle: back at the same message, at the same height', (t) async {
    final m = await _model(_long());
    await _app(t, m);
    await _open(t, m, emily);
    _pos(t).jumpTo(700);
    await _settle(t);
    final anchor = t.getTopLeft(_text('Message number 25'));
    await _open(t, m, jordan);
    await _open(t, m, emily);
    expect(_pos(t).pixels, greaterThan(500), reason: 'not at the end');
    expect((t.getTopLeft(_text('Message number 25')).dy - anchor.dy).abs(), lessThan(1.5),
        reason: 'the same message where it was');
  });

  testWidgets('left at the end, messages came meanwhile: the last one read stays, the new ones wait below', (t) async {
    final m = await _model(_long());
    await _app(t, m);
    await _open(t, m, emily);
    final last = t.getTopLeft(_text('Message number 40'));
    await _open(t, m, jordan);
    for (var i = 41; i <= 43; i++) {
      m.handleEvent(MessageEvent(
          contact: emily.label,
          linkId: emily.linkId,
          message: msg(200 + i, false, 'Message number $i', fixedNow.add(Duration(minutes: i)))));
    }
    await _settle(t);
    await _open(t, m, emily);
    expect((t.getTopLeft(_text('Message number 40')).dy - last.dy).abs(), lessThan(1.5),
        reason: 'the view stays on the last message read');
    expect(_pos(t).pixels, greaterThan(0));
    expect(find.text(en.chatNewMessagesLine), findsOneWidget);
    expect(find.descendant(of: _jump, matching: find.text('3')), findsOneWidget);
    await t.tap(find.byKey(const Key('chat-jump-bottom-tap')));
    await _settle(t);
    expect(_pos(t).pixels, 0);
  });

  testWidgets('the person\'s own message always shows the end', (t) async {
    final m = await _model(_long());
    await _app(t, m);
    await _open(t, m, emily);
    _pos(t).jumpTo(700);
    await _settle(t);
    await t.enterText(find.byKey(const Key('composer')), 'On my way');
    await t.tap(find.byKey(const Key('send')));
    await _settle(t);
    expect(_pos(t).pixels, 0);
    expect(_text('On my way'), findsOneWidget);
  });
}
