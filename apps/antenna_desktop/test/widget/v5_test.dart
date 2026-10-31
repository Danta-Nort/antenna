// SPDX-License-Identifier: AGPL-3.0-only
// x-control/5 in the window on the fake daemon: "contact / agent" over a bubble and "your agent" over our own
// (via_agent), the peer_kind tag and the contact's agents in the card and in the Agents section; the invite link as a
// web address and antenna://; LAN in Settings (password to turn on, no password to turn off, discovered links); the
// Seatbelt sandbox named in words. Both languages.

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/agents/wake_ui.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

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

/// Russian app strings, for checks of the Russian UI.
final _ruL = l10nFor('ru');

void _ru(WidgetTester t) {
  t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
  addTearDown(t.platformDispatcher.clearLocalesTestValue);
}

void main() {
  testWidgets('via_agent: “contact / agent” over an incoming bubble, “your agent” over mine (en)', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    d.historyMap[jordan.linkId] = [
      ...d.historyMap[jordan.linkId]!,
      msg(25, true, 'Thanks, merged.', ago(minutes: 30), viaAgent: 'wake-jordan'),
    ];
    final m = await _model(d);
    await m.select(jordan.linkId);
    await _app(t, m);
    // My agent's reply is the latest message: the person's thread opens, the reply signed with my agent's name.
    final mine = d.historyMap[jordan.linkId]!.last;
    final author = find.byKey(Key('author-${mine.id}'));
    expect(find.descendant(of: author, matching: find.text('wake-jordan')), findsOneWidget);
    expect(find.descendant(of: author, matching: find.text(l10nFor('en').authorYourAgentTag)), findsOneWidget);
    // The contact's agent has its own thread, and its message is signed "contact / agent" there.
    await m.openThread(jordan.linkId, const ThreadKey.agent('claude-backend'));
    await t.pump(const Duration(milliseconds: 300));
    final theirs = d.historyMap[jordan.linkId]!.firstWhere((x) => x.viaAgent == 'claude-backend');
    expect(
      find.descendant(of: find.byKey(Key('author-${theirs.id}')), matching: find.text('${jordan.label} / claude-backend')),
      findsOneWidget,
    );
    // In the list, a person with agents gets the "+ agents" tag.
    expect(find.byKey(Key('peer-kind-${jordan.label}')), findsWidgets);
  });

  testWidgets('the contact card lists the contact\'s agents; unknown kind is said honestly (ru)', (t) async {
    _ru(t);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await m.select(jordan.linkId);
    await _app(t, m);
    expect(find.text('${jordan.label} / claude-backend'), findsWidgets, reason: 'the thread and the caption over the bubble');
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.scrollUntilVisible(find.byKey(const Key('peer-agent-claude-backend')), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text(_ruL.cardAgentsTitle.toUpperCase()), findsOneWidget);
    // Emily's kind is unknown, and the card says so.
    await m.select(emily.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await t.scrollUntilVisible(find.textContaining(_ruL.cardAgentsUnknown), 300, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining(_ruL.cardAgentsUnknown), findsOneWidget);
  });

  testWidgets('a `contact` event with peer_kind updates the list without reloading', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    m.handleEvent(ContactEvent(ContactSummary(
      contact: emily.label,
      linkId: emily.linkId,
      trust: 4,
      netMode: 'direct',
      presence: 'online',
      peerKind: 'agent',
    )));
    expect(m.contactById(emily.linkId)!.peerKind, 'agent');
  });

  testWidgets('Agents section shows contacts\' agents next to my own (en)', (t) async {
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()));
    await _app(t, m);
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text("Contacts' agents"), findsOneWidget);
    expect(find.byKey(Key('contact-agent-${jordan.label}-claude-backend')), findsOneWidget);
  });

  testWidgets('invite: the web link goes to the person and the QR, antenna:// is copied separately', (t) async {
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    d.dialogs.last.emit(InviteCreated(
      id: 'i5',
      link: demoWebLink,
      linkApp: demoAppLink,
      expiresMs: ms(fixedNow) + 600000,
      trust: 3,
      netMode: 'direct',
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(demoWebLink), findsOneWidget);
    await t.tap(find.byKey(const Key('copy-link')));
    await t.tap(find.byKey(const Key('copy-link-app')));
    await t.pump();
    expect(clip, [demoWebLink, demoAppLink]);
  });

  testWidgets('LAN: password to turn on, off without password, found contacts shown (en)', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..lanLinks = [LanLink(contact: emily.label, beacon: false, found: const ['192.168.1.23:51820'])];
    final m = await _model(d);
    await _app(t, m);
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('settings-network')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Local network (no internet)'), findsOneWidget);
    // Minimal settings: the explanation and the privacy note are behind the "?"…
    expect(find.textContaining('neighbours can see that it is looking'), findsNothing);
    await t.tap(find.byKey(const Key('help-lan')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: find.byKey(const Key('help-lan-card')), matching: find.textContaining('neighbours can see')),
        findsOneWidget, reason: 'honest privacy note');
    await t.tap(find.byKey(const Key('help-lan')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('help-lan-card')), findsNothing);
    await t.tap(find.byKey(const Key('lan-switch')));
    await t.pump(const Duration(milliseconds: 300));
    // …and stand in the page while the owner turns it on.
    expect(find.descendant(of: find.byKey(const Key('lan-privacy')), matching: find.textContaining('neighbours can see')),
        findsOneWidget, reason: 'the trade-off is shown at the moment of choice');
    expect(d.calls.where((c) => c == 'lan_set'), isEmpty, reason: 'nothing changes without the password');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('lan-enable')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['lan_set'], d.password);
    expect(d.lanEnabled, isTrue);
    expect(find.text('Listening on the local network'), findsOneWidget);
    expect(find.text('found nearby: 192.168.1.23:51820'), findsOneWidget);
    await t.tap(find.byKey(const Key('lan-switch')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.lanEnabled, isFalse);
    expect(find.text('Listening on the local network'), findsNothing);
  });

  testWidgets('wake on macOS: the Seatbelt sandbox is named, not “unknown” (ru)', (t) async {
    _ru(t);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..wakeSandbox = 'seatbelt';
    final m = await _model(d);
    await _app(t, m);
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('wake-add')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(WakeDialog), findsOneWidget);
    expect(find.textContaining(_ruL.wakeSandboxSeatbelt), findsWidgets);
    expect(find.textContaining(_ruL.wakeSandboxNone), findsNothing, reason: 'macOS with Seatbelt is not shown as “no sandbox”');
  });
}
