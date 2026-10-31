// SPDX-License-Identifier: AGPL-3.0-only
// App theme and language: light theme by default, "as in the system" follows the system, and the choice in Settings
// switches the palette without losing state and is saved to window.json. Language: English by default, Russian if the
// system is in Russian (by the order of PlatformDispatcher.locales) or if chosen explicitly; switching keeps state.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/theme/tokens.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

Future<AppModel> _model() async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, Appearance a) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: a));
  await t.pump(const Duration(milliseconds: 400));
}

/// Russian app strings, for checks of the Russian UI.
final _ru = l10nFor('ru');

void main() {
  testWidgets('default is light; "system" follows the platform brightness', (t) async {
    final a = Appearance();
    await _app(t, await _model(), a);
    expect(XColors.isDark, isFalse, reason: 'light theme by default (owner reference v2)');
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    await t.pump();
    expect(XColors.isDark, isTrue);
    a.choice = ThemeChoice.light;
    await t.pump();
    expect(XColors.isDark, isFalse, reason: 'an explicit choice beats the system');
  });

  testWidgets('Settings → Dark: palette switches, choice is saved, selection survives', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-look-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/antenna/window.json');
    final a = settledLook(store);
    expect(a.choice, ThemeChoice.system);
    final m = await _model();
    final selected = m.selectedLinkId;
    await _app(t, m, a);
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('settings-general')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('theme-dark')));
    await t.pump(const Duration(milliseconds: 300));
    expect(XColors.isDark, isTrue);
    await t.pump(const Duration(milliseconds: 300));
    expect(Theme.of(t.element(find.text('Settings').first)).brightness, Brightness.dark);
    expect(json.decode(File(store.path).readAsStringSync()), {'theme': 'dark', 'lang': 'system', 'self_notice_shown': true});
    expect(AppearanceStore(store.path).load().theme, ThemeChoice.dark);
    expect(m.selectedLinkId, selected);
    await t.tap(find.byKey(const Key('theme-light')));
    await t.pump(const Duration(milliseconds: 300));
    expect(XColors.isDark, isFalse);
  });

  test('window.json location: macOS Application Support, Linux XDG config', () {
    expect(AppearanceStore.forEnv({'HOME': '/Users/o'}, macos: true)!.path,
        '/Users/o/Library/Application Support/Antenna/window.json');
    expect(AppearanceStore.forEnv({'HOME': '/home/o'}, macos: false)!.path, '/home/o/.config/antenna/window.json');
    expect(AppearanceStore.forEnv({'HOME': '/home/o', 'XDG_CONFIG_HOME': '/x/cfg'}, macos: false)!.path,
        '/x/cfg/antenna/window.json');
    expect(AppearanceStore.forEnv({}), isNull);
  });

  test('a broken window.json falls back to "system"', () {
    final dir = Directory.systemTemp.createTempSync('antenna-look-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/window.json').writeAsStringSync('{not json');
    final p = AppearanceStore('${dir.path}/window.json').load();
    expect(p.theme, ThemeChoice.system);
    expect(p.lang, LangChoice.system);
    File('${dir.path}/window.json').writeAsStringSync('{"theme": 7, "lang": "fr"}');
    final odd = AppearanceStore('${dir.path}/window.json').load();
    expect((odd.theme, odd.lang), (ThemeChoice.system, LangChoice.system), reason: 'unknown values → system');
  });

  test('an old window.json with only "theme" still reads; language is "system"', () {
    final dir = Directory.systemTemp.createTempSync('antenna-look-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/window.json';
    File(path).writeAsStringSync('{"theme":"dark"}');
    final a = Appearance.load(AppearanceStore(path));
    expect(a.choice, ThemeChoice.dark);
    expect(a.lang, LangChoice.system);
    a.lang = LangChoice.ru;
    expect(json.decode(File(path).readAsStringSync()), {'theme': 'dark', 'lang': 'ru'});
    expect(AppearanceStore(path).load().lang, LangChoice.ru);
  });

  test('language: "system" picks the first system language the window knows, otherwise English', () {
    Locale lang(LangChoice c, List<Locale> system) => resolveLanguage(c, system);
    expect(lang(LangChoice.system, const [Locale('ru', 'RU')]), const Locale('ru'));
    expect(lang(LangChoice.system, const [Locale('de'), Locale('ru')]), const Locale('ru'), reason: 'in order');
    expect(lang(LangChoice.system, const [Locale('en', 'GB'), Locale('ru')]), const Locale('en'));
    expect(lang(LangChoice.system, const [Locale('de'), Locale('fr')]), const Locale('en'));
    expect(lang(LangChoice.system, const []), const Locale('en'));
    expect(lang(LangChoice.en, const [Locale('ru')]), const Locale('en'), reason: 'an explicit choice beats the system');
    expect(lang(LangChoice.ru, const [Locale('en')]), const Locale('ru'));
  });

  testWidgets('English by default; a Russian system makes the window Russian', (t) async {
    await _app(t, await _model(), Appearance());
    expect(find.text('Chats'), findsWidgets);
    expect(find.text('Lock keys'), findsOneWidget);
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await t.pump();
    expect(find.text(_ru.navChats), findsWidgets);
    expect(find.text(_ru.commonLockKeys), findsOneWidget);
  });

  testWidgets('Settings → Russian / English: strings switch at once, saved, state survives', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-look-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/antenna/window.json');
    final a = settledLook(store);
    final m = await _model();
    final selected = m.selectedLinkId;
    await _app(t, m, a);
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('settings-general')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Language'), findsOneWidget);
    // Each language is named in itself.
    expect(find.text('English'), findsOneWidget);
    expect(find.text(_ru.langRussian), findsOneWidget);
    await t.tap(find.byKey(const Key('lang-ru')));
    await t.pump(const Duration(milliseconds: 300));
    // Settings is still open (the home screen state was not reset), and the strings are Russian.
    expect(find.text(_ru.settingsLanguage), findsOneWidget);
    expect(find.text(_ru.settingsAppearance), findsOneWidget);
    expect(find.text(_ru.langRussian), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(json.decode(File(store.path).readAsStringSync()), {'theme': 'system', 'lang': 'ru', 'self_notice_shown': true});
    expect(m.selectedLinkId, selected);
    await t.tap(find.byKey(const Key('lang-en')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Language'), findsOneWidget);
    expect(AppearanceStore(store.path).load().lang, LangChoice.en);
    // An explicit English choice beats a Russian system.
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await t.pump();
    expect(find.text('Language'), findsOneWidget);
    await t.tap(find.byKey(const Key('lang-system')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(_ru.settingsLanguage), findsOneWidget);
  });

  test('agent_runs: the start dialog\'s choice and the restore fields live side by side; a field set to null goes away',
      () {
    final dir = Directory.systemTemp.createTempSync('antenna-look-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    final look = Appearance.load(store)
      ..patchAgentRun('claude-backend', {
        'cli': 'claude',
        'dir': '/home/owner/shop',
        'running': true,
        'session': '5f0c2a9e-7d41-4b8e-9a63-2c1d0e8f4b17',
        'token_file': '/home/owner/.local/share/antenna/agents/claude-backend.token',
        'started_ms': 7,
      })
      // The start dialog remembers its choice after the start: the restore fields stay.
      ..rememberAgentRun('claude-backend', {'cli': 'codex', 'dir': '/home/owner/api'});
    var r = Appearance.load(store).agentRunRecord('claude-backend')!;
    expect(r, {
      'cli': 'codex',
      'dir': '/home/owner/api',
      'running': true,
      'session': '5f0c2a9e-7d41-4b8e-9a63-2c1d0e8f4b17',
      'token_file': '/home/owner/.local/share/antenna/agents/claude-backend.token',
      'started_ms': 7,
    });
    look.patchAgentRun('claude-backend', {'running': null, 'restore': false});
    r = Appearance.load(store).agentRunRecord('claude-backend')!;
    expect(r.containsKey('running'), isFalse);
    expect(r['restore'], isFalse);
    expect(look.agentRunNames, ['claude-backend']);
    expect(File(store.path).readAsStringSync(), isNot(contains('xat_')));
  });
}
