// SPDX-License-Identifier: AGPL-3.0-only
// "Urgent: interrupt now" in the composer (CONTROL §33, experimental) on the fake daemon: the toggle stands next to
// Send only in an agent's chat of an own computer (∞) and only with a daemon that speaks x-control/7; it is shown but
// off when the contact's Antenna is older (`peer_urgent` false); it sends `urgent: true` once and turns itself off; a
// long press on Send sends urgently too; a reply `urgent: false` says the message went as a normal one; bubbles carry
// the daemon's urgent mark, outgoing and incoming.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/state/urgent.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _helper = ThreadKey.agent('helper');

ContactInfo _mini({bool peerUrgent = true, int trust = 5}) => contact('Mac mini', 61,
    trust: trust,
    peerKind: 'agent',
    peerUrgent: peerUrgent,
    agents: [PeerAgent(name: 'helper', state: 'active', sinceMs: ms(ago(days: 1)))]);

/// The incoming urgent message as the daemon reports it, and an outgoing one sent with the flag.
List<HistoryItem> _miniHistory() => [
      HistoryItem(
          seq: 70,
          id: hex(70 * 7 + 3),
          direction: 'out',
          kind: 'text',
          text: 'Stop the deploy, the config is wrong',
          ts: ms(ago(minutes: 3)),
          localMs: ms(ago(minutes: 3)),
          lamport: 70,
          status: 'delivered',
          to: 'agent',
          toAgent: 'helper',
          urgent: true),
      HistoryItem(
          seq: 71,
          id: hex(71 * 7 + 3),
          direction: 'in',
          kind: 'text',
          text: 'Stopped. Waiting for the fixed config.',
          ts: ms(ago(minutes: 2)),
          localMs: ms(ago(minutes: 2)),
          lamport: 71,
          status: 'received',
          viaAgent: 'helper',
          to: 'person'),
      msg(72, true, 'Thanks, take your time.', ago(minutes: 1), to: 'agent', toAgent: 'helper'),
    ];

Future<(AppModel, FakeDaemon)> _open(WidgetTester t,
    {ContactInfo? mini, int proto = 7, ThreadKey chat = _helper, String? link}) async {
  final c = mini ?? _mini();
  final d = FakeDaemon(contacts: [...demoContacts(), c], history: {...demoHistory(), c.linkId: _miniHistory()})
    ..protoVersion = proto;
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await m.select(link ?? c.linkId, chat: chat);
  await t.pump(const Duration(milliseconds: 300));
  return (m, d);
}

Future<void> _type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer')), text);
  await t.pump();
}

IconButton _toggle(WidgetTester t) => t.widget<IconButton>(find.byKey(const Key('composer-urgent')));

void main() {
  test('the offer: only an agent chat of a contact at ∞, with x-control/7; older peers shown but off', () {
    const agent = Recipient.agent('helper');
    expect(urgentOffer(_mini(), agent, daemonProto: 7), UrgentOffer.available);
    expect(urgentOffer(_mini(peerUrgent: false), agent, daemonProto: 7), UrgentOffer.olderPeer);
    expect(urgentOffer(_mini(), Recipient.person, daemonProto: 7), UrgentOffer.hidden);
    expect(urgentOffer(_mini(), Recipient.everyone, daemonProto: 7), UrgentOffer.hidden);
    expect(urgentOffer(_mini(trust: 4), agent, daemonProto: 7), UrgentOffer.hidden);
    expect(urgentOffer(_mini(), agent, daemonProto: 6), UrgentOffer.hidden);
  });

  testWidgets('the toggle stands in an own computer\'s agent chat; not in its person chat, nor below ∞', (t) async {
    final (m, _) = await _open(t);
    expect(find.byKey(const Key('composer-urgent')), findsOneWidget);
    expect(_toggle(t).tooltip, contains(en.composerUrgent));
    expect(_toggle(t).tooltip, contains(en.experimentalTag));
    expect(_toggle(t).onPressed, isNotNull);

    await m.select(_mini().linkId, chat: ThreadKey.person);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('composer-urgent')), findsNothing, reason: 'the person of an own computer: no agent');

    // Jordan (level 3) and his agent: no urgent, whatever the chat.
    await m.select(jordan.linkId, chat: const ThreadKey.agent('claude-backend'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('composer-urgent')), findsNothing);
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('composer-urgent')), findsNothing);
  });

  testWidgets('an older daemon gets no toggle at all', (t) async {
    await _open(t, proto: 6);
    expect(find.byKey(const Key('composer-urgent')), findsNothing);
  });

  testWidgets('their Antenna is older: the toggle is shown off, says why, and a long press sends normally', (t) async {
    final (_, d) = await _open(t, mini: _mini(peerUrgent: false));
    expect(_toggle(t).onPressed, isNull);
    expect(_toggle(t).tooltip, contains(en.composerUrgentOlder('Mac mini')));
    await _type(t, 'status?');
    await t.longPress(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, isEmpty, reason: 'no urgent send without urgent');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [false]);
  });

  testWidgets('on: Send carries urgent once, then the toggle is off again', (t) async {
    final (_, d) = await _open(t);
    await t.tap(find.byKey(const Key('composer-urgent')));
    await t.pump();
    expect(find.byKey(const Key('composer-urgent-on')), findsOneWidget);
    expect(find.text(en.composerUrgentOn('helper')), findsOneWidget);
    expect(_toggle(t).isSelected, isTrue);
    await _type(t, 'Stop now: the build server is out of disk');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [true]);
    expect(d.sentAddresses.last, const MessageAddress.agent('helper'));
    expect(find.byKey(const Key('composer-urgent-on')), findsNothing, reason: 'urgent is for one message');
    expect(_toggle(t).isSelected, isFalse);
    await _type(t, 'and a normal one');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [true, false]);
    // The new urgent message carries the mark in its bubble (the daemon's history says it went with the flag).
    final sent = d.historyMap[_mini().linkId]!.where((h) => h.text.startsWith('Stop now')).single;
    expect(sent.urgent, isTrue);
    expect(find.byKey(Key('urgent-${sent.id}')), findsOneWidget);
  });

  testWidgets('the toggle belongs to its chat: switching to another chat and back leaves it off', (t) async {
    final (m, d) = await _open(t);
    await t.tap(find.byKey(const Key('composer-urgent')));
    await t.pump();
    await m.select(_mini().linkId, chat: ThreadKey.person);
    await t.pump(const Duration(milliseconds: 300));
    await _type(t, 'to the person');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [false], reason: 'never urgent to the person, whatever was on in the agent chat');
  });

  testWidgets('a long press on Send sends as urgent', (t) async {
    final (_, d) = await _open(t);
    expect(find.byTooltip(en.composerSendOrUrgent), findsOneWidget);
    await _type(t, 'Interrupt and read this');
    await t.longPress(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [true]);
    expect(find.byKey(const Key('composer')).evaluate().single.widget, isA<TextField>());
    expect((t.widget<TextField>(find.byKey(const Key('composer')))).controller!.text, isEmpty);
  });

  testWidgets('the reply says their Antenna cannot take it: sent as a normal message, and the composer says so',
      (t) async {
    final (_, d) = await _open(t);
    // The contact's node was downgraded after the window read the contacts.
    d.contactList = [for (final c in d.contactList) c.label == 'Mac mini' ? _mini(peerUrgent: false) : c];
    await t.tap(find.byKey(const Key('composer-urgent')));
    await t.pump();
    await _type(t, 'Stop now');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.sentUrgent, [true]);
    expect(find.text(en.composerUrgentFellBack('Mac mini')), findsOneWidget);
    final sent = d.historyMap[_mini().linkId]!.where((h) => h.text == 'Stop now').single;
    expect(find.byKey(Key('urgent-${sent.id}')), findsNothing, reason: 'it did not go as urgent');
  });

  testWidgets('bubbles: the urgent mark on what the daemon says was urgent, nothing on the rest', (t) async {
    await _open(t);
    final h = _miniHistory();
    expect(find.byKey(Key('urgent-${h[0].id}')), findsOneWidget);
    expect(find.byKey(Key('urgent-${h[2].id}')), findsNothing);
    expect(find.text('${en.bubbleUrgent} · '), findsOneWidget);
  });

  testWidgets('an incoming urgent message (honoured by the daemon here) carries the mark too', (t) async {
    final (m, _) = await _open(t, chat: ThreadKey.person);
    final c = _mini();
    final item = HistoryItem(
        seq: 80,
        id: hex(80 * 7 + 3),
        direction: 'in',
        kind: 'text',
        text: 'Read this first',
        ts: ms(fixedNow),
        localMs: ms(fixedNow),
        lamport: 80,
        status: 'received',
        to: 'person',
        urgent: true);
    m.handleEvent(MessageEvent(contact: c.label, linkId: c.linkId, message: item));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(Key('urgent-${item.id}')), findsOneWidget);
  });
}
