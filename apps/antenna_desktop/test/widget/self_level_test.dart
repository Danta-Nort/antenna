// SPDX-License-Identifier: AGPL-3.0-only
// Trust level 5 "Self" means the owner's own computer (maintainer decision 2026-10-05): files, messages and secrets
// go to it without asking and its tasks run without confirmation. Wherever the owner picks level 5 (the card's
// picker, `/trust 5`, the invite and join forms) the window asks first; Cancel keeps the previous level, and the
// password prompt of the trust change comes only after the owner accepted. Levels 1–4 ask nothing new.

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/theme/tokens.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
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

Future<FakeDaemon> _app(WidgetTester t) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final m = await _model(d);
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  return d;
}

final _warning = find.byKey(const Key('self-warning'));
final _password = find.byKey(const Key('owner-password'));

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pump(const Duration(milliseconds: 300));
}

AppModel _m(WidgetTester t) => (t.widget(find.byType(XApp)) as XApp).model;

Future<void> _send(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer')), text);
  await t.tap(find.byKey(const Key('send')));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the card: 1–4 ask nothing new; 5 warns, Cancel keeps the level, accept → password → trust', (t) async {
    final d = await _app(t);
    final m = _m(t);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _tap(t, 'card-toggle');
    await _tap(t, 'trust-edit');
    for (final level in [1, 2, 4]) {
      await _tap(t, 'trust-$level');
      expect(_warning, findsNothing, reason: 'level $level');
    }
    await _tap(t, 'trust-5');
    expect(_warning, findsOneWidget);
    expect(find.text(en.selfWarnBody), findsOneWidget);
    expect(en.selfWarnBody,
        "∞ 'My computer' is for your own computers only. This contact will get files and messages without asking, "
        'including ones with keys, passwords or tokens, and its tasks run without confirmation.');
    expect(_password, findsNothing, reason: 'the warning comes before the password');
    await _tap(t, 'self-cancel');
    expect(_warning, findsNothing);
    // Cancel keeps the level chosen before (4), not 5: the picker's hint is still level 4's.
    expect(find.textContaining('${en.trust4Name}: ', findRichText: true), findsOneWidget);
    expect(find.textContaining('${en.trustSelfName}: ', findRichText: true), findsNothing);
    expect(d.calls, isNot(contains('trust')));
    // Accept: then the password, then `trust … 5`.
    await _tap(t, 'trust-5');
    await _tap(t, 'self-accept');
    expect(_warning, findsNothing);
    expect(d.calls, isNot(contains('trust')), reason: 'nothing is sent before Apply and the password');
    await _tap(t, 'trust-apply');
    expect(_password, findsOneWidget);
    await t.enterText(_password, d.password);
    await _tap(t, 'password-ok');
    expect(d.calls.where((c) => c == 'trust'), hasLength(1));
    expect(d.passwords['trust'], d.password);
    expect(m.selected!.trust, 5);
  });

  testWidgets('/trust 5 warns before the password; Cancel sends nothing; /trust 4 does not warn', (t) async {
    final d = await _app(t);
    final m = _m(t);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _send(t, '/trust 5');
    expect(_warning, findsOneWidget);
    expect(_password, findsNothing);
    await _tap(t, 'self-cancel');
    expect(_password, findsNothing, reason: 'Cancel ends it: no password prompt');
    expect(d.calls, isNot(contains('trust')));
    expect(m.selected!.trust, 3);
    await _send(t, '/trust 5');
    await _tap(t, 'self-accept');
    expect(_password, findsOneWidget);
    await t.enterText(_password, d.password);
    await _tap(t, 'password-ok');
    expect(m.selected!.trust, 5);
    // Already at 5, or another level: no warning.
    await _send(t, '/trust 4');
    expect(_warning, findsNothing);
    expect(_password, findsOneWidget);
    await t.enterText(_password, d.password);
    await _tap(t, 'password-ok');
    expect(m.selected!.trust, 4);
    expect(d.calls.where((c) => c == 'trust'), hasLength(2));
  });

  testWidgets('invite form: the warning once per form; Cancel keeps the level; the invite goes out at 5', (t) async {
    final d = await _app(t);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await _tap(t, 'trust-5');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-cancel');
    expect(find.textContaining('--trust 2'), findsOneWidget, reason: 'still the default level 2');
    await _tap(t, 'trust-5');
    await _tap(t, 'self-accept');
    expect(find.textContaining('--trust 5'), findsOneWidget);
    // Back to 3 and to 5 again in the same form: the owner accepted already.
    await _tap(t, 'trust-3');
    await _tap(t, 'trust-5');
    expect(_warning, findsNothing);
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-invite');
    await _tap(t, 'invite-create');
    expect(_warning, findsNothing);
    expect((d.dialogs.last.request as InviteRequest).trust, 5);
  });

  testWidgets('an invite opened at level 5 (/invite --trust 5) warns on Create', (t) async {
    final d = await _app(t);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen)), trust: 5));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-invite');
    await _tap(t, 'invite-create');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-cancel');
    expect(d.calls, isNot(contains('invite')), reason: 'nothing created without the owner accepting level 5');
    await _tap(t, 'invite-create');
    await _tap(t, 'self-accept');
    expect((d.dialogs.last.request as InviteRequest).trust, 5);
  });

  testWidgets('join form: level 5 warns; the join goes out at 5', (t) async {
    final d = await _app(t);
    unawaited(showJoinDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('join-link')), demoLink);
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-join');
    await _tap(t, 'trust-4');
    expect(_warning, findsNothing);
    await _tap(t, 'trust-5');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-accept');
    await _tap(t, 'join-start');
    expect(_warning, findsNothing, reason: 'accepted once in this form');
    expect((d.dialogs.last.request as JoinRequest).trust, 5);
  });

  testWidgets('"This is my own computer": 5 with the warning the first time, back to the default, picker in sync',
      (t) async {
    final d = await _app(t);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen)), trust: 3));
    await t.pump(const Duration(milliseconds: 300));
    bool ticked() => t.widget<Checkbox>(find.byKey(const Key('own-computer-box'))).value!;
    expect(ticked(), isFalse);
    expect(find.text(en.selfOwnComputerToggle), findsOneWidget);
    // Cancel on the first tick: nothing changes.
    await _tap(t, 'own-computer');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-cancel');
    expect(ticked(), isFalse);
    expect(find.textContaining('--trust 3'), findsOneWidget);
    // Accept: level 5, the picker follows.
    await _tap(t, 'own-computer');
    await _tap(t, 'self-accept');
    expect(ticked(), isTrue);
    expect(find.textContaining('--trust 5'), findsOneWidget);
    expect(find.textContaining('${en.trustSelfName}: ', findRichText: true), findsOneWidget);
    // Unticked: back to the level the form opened with.
    await _tap(t, 'own-computer');
    expect(_warning, findsNothing);
    expect(ticked(), isFalse);
    expect(find.textContaining('--trust 3'), findsOneWidget);
    // Ticked again: no second warning in the same form.
    await _tap(t, 'own-computer');
    expect(_warning, findsNothing);
    expect(ticked(), isTrue);
    // The picker moves the box: 4 unticks it, 5 ticks it.
    await _tap(t, 'trust-4');
    expect(ticked(), isFalse);
    await _tap(t, 'trust-5');
    expect(_warning, findsNothing);
    expect(ticked(), isTrue);
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-invite');
    await _tap(t, 'invite-create');
    expect((d.dialogs.last.request as InviteRequest).trust, 5);
  });

  testWidgets('join: "This is my own computer" and back to level 2', (t) async {
    final d = await _app(t);
    unawaited(showJoinDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    bool ticked() => t.widget<Checkbox>(find.byKey(const Key('own-computer-box'))).value!;
    await _tap(t, 'trust-4');
    await _tap(t, 'own-computer');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-accept');
    expect(ticked(), isTrue);
    expect(find.textContaining('--trust 5'), findsOneWidget);
    await _tap(t, 'own-computer');
    expect(find.textContaining('--trust 2'), findsOneWidget, reason: "the join form's default");
    await _tap(t, 'own-computer');
    expect(_warning, findsNothing);
    await t.enterText(find.byKey(const Key('join-link')), demoLink);
    await t.enterText(find.byKey(const Key('owner-password')), 'pw-for-join');
    await _tap(t, 'join-start');
    expect((d.dialogs.last.request as JoinRequest).trust, 5);
  });

  testWidgets('a level-5 contact reads as "∞ · My computer" with what goes without asking', (t) async {
    await _app(t);
    final m = _m(t);
    await m.select(buildBot.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _tap(t, 'card-toggle');
    expect(find.text('∞ · ${en.trustSelfName}'), findsOneWidget);
    expect(en.trustSelfName, 'My computer');
    expect(find.byKey(const Key('trust-self-meaning')), findsOneWidget);
    expect(en.trustSelfMeaning, 'Files, messages and secrets go without asking; tasks run without confirmation.');
    // The picker's level-5 hint no longer promises prompts: it says what goes without asking.
    await _tap(t, 'trust-edit');
    expect(find.textContaining('${en.trustSelfName}: ${en.trustPickerSelf}', findRichText: true), findsOneWidget);
    expect(find.textContaining(en.trust5Files.toLowerCase(), findRichText: true), findsNothing);
    // Another level reads as before.
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('3 · ${en.trust3Name}'), findsOneWidget);
    expect(find.byKey(const Key('trust-self-meaning')), findsNothing);
  });

  testWidgets('the picker: two groups, ∞ red at the moment of choice; the chip stays a quiet mark (D-UI-30)',
      (t) async {
    final d = await _app(t);
    final m = _m(t);
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: find.byKey(const Key('chat-header-trust')), matching: find.text('∞')), findsNothing,
        reason: 'level 3: the header shows the digit, not ∞');
    await _tap(t, 'card-toggle');
    await _tap(t, 'trust-edit');

    // Two groups, "My devices" below "People", and ∞ sits in its own row under it (SectionLabel upper-cases).
    expect(find.text(en.trustGroupPeople.toUpperCase()), findsOneWidget);
    expect(find.text(en.trustGroupDevices.toUpperCase()), findsOneWidget);
    final peopleY = t.getTopLeft(find.text(en.trustGroupPeople.toUpperCase())).dy;
    final devicesY = t.getTopLeft(find.text(en.trustGroupDevices.toUpperCase())).dy;
    expect(devicesY, greaterThan(peopleY));
    expect(t.getTopLeft(find.byKey(const Key('trust-4'))).dy, lessThan(devicesY));
    expect(t.getTopLeft(find.byKey(const Key('trust-5'))).dy, greaterThan(devicesY));

    bool sameHue(Color a, Color b) => a.r == b.r && a.g == b.g && a.b == b.b;
    BoxDecoration cellDecoration(String key) => t
        .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(Key(key)), matching: find.byType(AnimatedContainer)))
        .decoration! as BoxDecoration;

    // Red at the moment of choice, even before it is picked: not level 4's colour, which is XColors.line.
    expect(sameHue(cellDecoration('trust-5').border!.top.color, XColors.danger), isTrue);
    expect(sameHue(cellDecoration('trust-4').border!.top.color, XColors.danger), isFalse);

    // The warning is still shown before it is actually chosen.
    await _tap(t, 'trust-5');
    expect(_warning, findsOneWidget);
    await _tap(t, 'self-accept');

    // Chosen: red all the way (fill and border), not the quiet trust-5 colour the resting badge uses.
    expect(sameHue(cellDecoration('trust-5').color!, XColors.danger), isTrue);
    await _tap(t, 'trust-apply');
    await t.enterText(_password, d.password);
    await _tap(t, 'password-ok');
    expect(m.selected!.trust, 5);

    // Afterward: the header's chip shows the glyph, in its own quiet colour — never the picker's red.
    expect(find.descendant(of: find.byKey(const Key('chat-header-trust')), matching: find.text('∞')), findsOneWidget);
    final chip = t
        .widget<Container>(
            find.descendant(of: find.byKey(const Key('chat-header-trust')), matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;
    expect(sameHue(chip.border!.top.color, XColors.danger), isFalse);
    expect(sameHue(chip.color ?? chip.border!.top.color, XColors.trustColor(5)), isTrue);
  });
}
