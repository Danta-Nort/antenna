// SPDX-License-Identifier: AGPL-3.0-only
// Minimal settings (reference v3): every setting is one line, its name, a small "?" and the control; the longer
// explanation is behind the "?", shown on hover, on a click or tap, and on keyboard focus; every setting keeps working.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/popover.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

const _bins = CoreBinaries(daemon: '/opt/antenna/antennad', cli: '/opt/antenna/antenna', bundled: true);

Future<(AppModel, Appearance)> _settings(WidgetTester t) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  final look = Appearance(initial: ThemeChoice.light);
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('nav-settings')));
  await _settle(t);
  // Profile opens first; these tests are about the general settings
  await t.tap(find.byKey(const Key('settings-general')));
  await _settle(t);
  return (m, look);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(Key(k));
Finder _card(String id, Finder f) => find.descendant(of: _key('help-$id-card'), matching: f);

void main() {
  testWidgets('each section: names and a "?" on one line, the explanations only behind the "?"', (t) async {
    await _settings(t);
    final sections = <String, Map<String, String>>{
      'profile': {'picture': en.profilePictureHint},
      'general': {'appearance': en.settingsAppearanceHint, 'language': en.settingsLanguageHint},
      'interface': {'interface': en.settingsInterfaceHint},
      'security': {'keys': en.settingsKeysHint},
      'agents': {'agents': en.settingsAgentsHint},
      'advanced': {'daemon': en.daemonStopNote, 'updates': en.updateAbout},
    };
    for (final MapEntry(key: section, value: helps) in sections.entries) {
      await t.tap(_key('settings-$section'));
      await _settle(t);
      for (final MapEntry(key: id, value: text) in helps.entries) {
        expect(_key('help-$id'), findsOneWidget, reason: '$section: the "?" of $id');
        expect(find.text(text), findsNothing, reason: '$section: $id explains itself only behind the "?"');
        await t.tap(_key('help-$id'));
        await _settle(t);
        expect(_card(id, find.text(text)), findsOneWidget, reason: '$section: $id');
        await t.tap(_key('help-$id'));
        await _settle(t);
        expect(_key('help-$id-card'), findsNothing);
      }
    }
    // The role preset (Agents): each role one line, its explanation behind its own "?".
    await t.tap(_key('settings-agents'));
    await _settle(t);
    expect(find.text(en.rolePresetAssistantHint), findsNothing);
    await t.tap(_key('help-role-assistant'));
    await _settle(t);
    expect(_card('role-assistant', find.text(en.rolePresetAssistantHint)), findsOneWidget);
  });

  testWidgets('the "?" opens on hover and closes when the pointer leaves; a click keeps it until a tap outside',
      (t) async {
    await _settings(t);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(_key('help-appearance')));
    await _settle(t);
    expect(_card('appearance', find.text(en.settingsAppearanceHint)), findsOneWidget);
    // The pointer may move onto the card (to read or select) without closing it.
    await mouse.moveTo(t.getCenter(_key('help-appearance-card')));
    await _settle(t);
    expect(_key('help-appearance-card'), findsOneWidget);
    await mouse.moveTo(const Offset(1400, 980));
    await _settle(t);
    expect(_key('help-appearance-card'), findsNothing);

    await t.tap(_key('help-language'));
    await _settle(t);
    await mouse.moveTo(const Offset(1400, 980));
    await _settle(t);
    expect(_key('help-language-card'), findsOneWidget, reason: 'a click pins it');
    await t.tapAt(const Offset(1400, 980));
    await _settle(t);
    expect(_key('help-language-card'), findsNothing, reason: 'a tap outside closes it');
  });

  testWidgets('keyboard: Tab reaches the "?" and shows it, Escape hides it', (t) async {
    await _settings(t);
    var shown = false;
    for (var i = 0; i < 40 && !shown; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(t);
      shown = _key('help-appearance-card').evaluate().isNotEmpty;
    }
    expect(shown, isTrue, reason: 'keyboard focus on the "?" shows the explanation');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t);
    expect(_key('help-appearance-card'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(t);
    expect(_key('help-appearance-card'), findsOneWidget, reason: 'Space opens it again');
  });

  testWidgets('near the bottom right corner the card opens above the "?" and stays in the window', (t) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: Stack(children: [
          Positioned(right: 8, bottom: 8, child: HelpHint('A longer explanation.', id: 'corner', label: 'More')),
          Positioned(left: 8, top: 8, child: HelpHint('Another one.', id: 'top', label: 'More')),
        ]),
      ),
    ));
    await t.tap(_key('help-corner'));
    await _settle(t);
    final anchor = t.getRect(_key('help-corner'));
    final card = t.getRect(_key('help-corner-card'));
    expect(card.bottom, lessThanOrEqualTo(anchor.top), reason: 'above the anchor');
    expect(card.right, lessThanOrEqualTo(800));
    expect(card.left, greaterThanOrEqualTo(0));
    await t.tap(_key('help-top'));
    await _settle(t);
    expect(t.getRect(_key('help-top-card')).top, greaterThanOrEqualTo(t.getRect(_key('help-top')).bottom),
        reason: 'below the anchor near the top');
  });

  testWidgets('the settings still work, and the Russian window has the same lines', (t) async {
    final (_, look) = await _settings(t);
    await t.tap(_key('theme-dark'));
    await _settle(t);
    expect(look.choice, ThemeChoice.dark);
    await t.tap(_key('settings-interface'));
    await _settle(t);
    await t.tap(_key('ui-code'));
    await _settle(t);
    expect(look.ui, InterfaceMode.code);
    await t.tap(_key('settings-general'));
    await _settle(t);
    await t.tap(_key('lang-ru'));
    await _settle(t);
    expect(look.lang, LangChoice.ru);
    expect(find.text(ru.settingsAppearance), findsOneWidget);
    expect(find.text(ru.settingsAppearanceHint), findsNothing);
    await t.tap(_key('help-appearance'));
    await _settle(t);
    expect(_card('appearance', find.text(ru.settingsAppearanceHint)), findsOneWidget);
  });
}
