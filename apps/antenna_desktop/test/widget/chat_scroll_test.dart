// SPDX-License-Identifier: AGPL-3.0-only
// The conversation list is a reversed ListView anchored at `pixels == 0` (the newest message, at the bottom). At the
// bottom already, new content scrolling into view is the reversed list's natural behaviour and needs nothing extra.
// Scrolled away reading something older, the same anchor otherwise shifts everything above the new content by its
// own height on every arrival (a short message, a long one, a growing stream bubble): `_MessagesState.compensate`
// keeps the read position exactly where it is, and a round jump button with a count takes the place of the "it just
// scrolled by itself" surprise.

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
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
  // Short enough that emily's demo history overflows the viewport (scrolling is the whole point of this file).
  t.view.physicalSize = const Size(1440, 420);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

final _messages = find.byKey(const Key('chat-messages'));
final _jumpButton = find.byKey(const Key('chat-jump-bottom'));

/// Scoped to the timeline itself: the sidebar's own "last message" preview (and the composer's selectable text
/// rendering) can repeat the same words.
Finder _inTimeline(String text) => find.descendant(of: _messages, matching: find.text(text));

ScrollPosition _position(WidgetTester t) => t.widget<ListView>(_messages).controller!.position;

/// Two pumps: the first builds and runs `_MessagesState`'s post-frame compensation, which calls `jumpTo` — itself
/// only a request until a second frame actually lays out and paints the corrected offset. One pump leaves
/// `getTopLeft`/`pixels` reads still showing the pre-compensation geometry.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump();
}

/// Scrolls all the way to the oldest end (deterministic regardless of content height, unlike an arbitrary offset):
/// the first message ("Hi! I'm not on my phone yet…") sits just under the history head, a stable anchor to watch.
Future<void> _scrollToOldest(WidgetTester t) async {
  final p = _position(t);
  p.jumpTo(p.maxScrollExtent);
  await _settle(t);
}

HistoryItem _incoming(int seq, String text) => msg(seq, false, text, fixedNow.add(const Duration(minutes: 1)));

Future<void> _arrive(WidgetTester t, AppModel m, ContactInfo c, HistoryItem item) async {
  m.handleEvent(MessageEvent(contact: c.label, linkId: c.linkId, message: item));
  await _settle(t);
}

void main() {
  testWidgets('at the bottom: a new message scrolls into view, no jump button', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(_position(t).pixels, 0, reason: 'freshly opened: already at the newest message');
    expect(_jumpButton, findsNothing);

    await _arrive(t, m, emily, _incoming(100, 'Running a bit late, sorry!'));
    expect(_inTimeline('Running a bit late, sorry!'), findsOneWidget, reason: 'it scrolled into view by itself');
    expect(_jumpButton, findsNothing, reason: 'the reader already saw it arrive');
    expect(_position(t).pixels, 0);
  });

  testWidgets('scrolled away: a short new message does not move the read position', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _scrollToOldest(t);
    final before = t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop."));
    final extentBefore = _position(t).maxScrollExtent;

    await _arrive(t, m, emily, _incoming(100, 'Short reply.'));

    expect(t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop.")), before,
        reason: 'not a pixel of movement for what is on screen');
    final grew = _position(t).maxScrollExtent - extentBefore;
    expect(grew, greaterThan(0), reason: 'the new bubble did add height to the list');
    expect(_position(t).pixels, _position(t).maxScrollExtent, reason: 'still pinned to the oldest end it was reading');
    expect(_jumpButton, findsOneWidget);
    expect(find.descendant(of: _jumpButton, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('scrolled away: a long new message does not move the read position either', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _scrollToOldest(t);
    final before = t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop."));

    await _arrive(
        t,
        m,
        emily,
        _incoming(
            100,
            'A much longer message that wraps onto several lines in the bubble, the way a real paragraph from a '
            'contact would, with enough text in it that the bubble grows noticeably taller than a one-line reply '
            'and would shift everything above it if nothing compensated for the extra height.'));

    expect(t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop.")), before);
    expect(_jumpButton, findsOneWidget);
  });

  testWidgets('scrolled away: a growing stream bubble does not move the read position', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _scrollToOldest(t);
    final before = t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop."));

    final f = StreamFeed(emily);
    m.handleEvent(f.open());
    await _settle(t);
    expect(t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop.")), before,
        reason: 'the stream opened');
    m.handleEvent(f.chunk('Building the release notes for preview.8 now'));
    await _settle(t);
    expect(t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop.")), before,
        reason: 'first chunk');
    m.handleEvent(f.chunk(' — a longer line than the first chunk, so the bubble grows taller still as it streams in'));
    await _settle(t);
    expect(t.getTopLeft(_inTimeline("Hi! I'm not on my phone yet — writing from the laptop.")), before,
        reason: 'second, longer chunk');
    // A stream growing in place is not counted as a new message (nothing arrived in the history yet).
    expect(_jumpButton, findsNothing);
  });

  testWidgets('the jump button scrolls to the newest and clears the count', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _scrollToOldest(t);
    await _arrive(t, m, emily, _incoming(100, 'One.'));
    await _arrive(t, m, emily, _incoming(101, 'Two.'));
    expect(find.descendant(of: _jumpButton, matching: find.text('2')), findsOneWidget);

    await t.tap(_jumpButton);
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(_position(t).pixels, 0);
    expect(_jumpButton, findsNothing);
    expect(_inTimeline('Two.'), findsOneWidget, reason: 'scrolled to the newest message');
  });

  testWidgets('reaching the bottom by hand hides the button', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _scrollToOldest(t);
    await _arrive(t, m, emily, _incoming(100, 'Catch me if you can.'));
    expect(_jumpButton, findsOneWidget);

    _position(t).jumpTo(0);
    await t.pump();
    expect(_jumpButton, findsNothing, reason: 'the reader got there on their own');
  });
}
