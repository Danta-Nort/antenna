// SPDX-License-Identifier: AGPL-3.0-only
// An own computer's file settings on its card (D-130, D-UI-46): where its files and its agents' files are saved, and
// which of its programs and installers are saved without waiting. Setting takes the owner (the password here, Touch
// ID being off), going back does not; the section is only on an own computer's card (∞). Rules under test are in each
// test's reason.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart' show FolderChooser;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

class _Folder implements FolderChooser {
  _Folder(this.path);
  final String? path;
  @override
  Future<String?> pick(String confirm) async => path;
}

ContactInfo get _server => contact('Server', 61,
    trust: 5,
    role: 'joiner',
    agents: const [PeerAgent(name: 'volna', state: 'active', sinceMs: 0)],
    peerKind: 'mixed');

void main() {
  late FakeDaemon d;

  Future<AppModel> open(WidgetTester t, ContactInfo c) async {
    d = FakeDaemon(contacts: [...demoContacts(), c], history: demoHistory());
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    await m.select(c.linkId);
    t.view.physicalSize = const Size(1440, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    return m;
  }

  /// The card is a list: scroll to [key] first.
  Future<void> tap(WidgetTester t, String key) async {
    await t.ensureVisible(find.byKey(Key(key)));
    await t.pump();
    await t.tap(find.byKey(Key(key)));
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> password(WidgetTester t) async {
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a save folder for the computer and one of its agents: chosen with the password, back without',
      (t) async {
    final saved = FolderChooser.instance;
    addTearDown(() => FolderChooser.instance = saved);
    await open(t, _server);
    expect(find.byKey(const Key('card-files')), findsOneWidget);
    expect(find.text(en.cardSaveFolderDefault), findsOneWidget);
    expect(find.text(en.cardSaveFolderAsContact), findsOneWidget, reason: 'the agent follows the computer');

    FolderChooser.instance = _Folder('/home/owner/Desktop/Volna');
    await tap(t, 'card-save-dir-choose-person');
    expect(d.calls, isNot(contains('file_save_dir')), reason: 'the owner first');
    await password(t);
    expect(d.passwords['file_save_dir'], d.password);
    expect(d.contactList.last.saveDirs.single.path, '/home/owner/Desktop/Volna');
    expect(find.textContaining('Desktop/Volna'), findsOneWidget);

    FolderChooser.instance = _Folder('/home/owner/Desktop/Volna/agent');
    await tap(t, 'card-save-dir-choose-volna');
    await password(t);
    expect(d.contactList.last.saveDirs.map((x) => (x.agent, x.path)),
        containsAll([(null, '/home/owner/Desktop/Volna'), ('volna', '/home/owner/Desktop/Volna/agent')]));

    d.passwords.clear();
    await tap(t, 'card-save-dir-clear-person');
    expect(find.byKey(const Key('owner-password')), findsNothing, reason: 'going back needs no password');
    expect(d.passwords, isEmpty);
    expect(d.contactList.last.saveDirs.single.agent, 'volna');
    expect(find.text(en.cardSaveFolderDefault), findsOneWidget);
  });

  testWidgets('programs and an extension saved without asking: added with the password, taken off without',
      (t) async {
    await open(t, _server);
    await tap(t, 'card-allow-add-executables');
    await password(t);
    expect(d.passwords['file_allow'], d.password);
    expect(find.byKey(const Key('card-allow-executables')), findsOneWidget);
    expect(find.byKey(const Key('card-allow-add-executables')), findsNothing);

    await tap(t, 'card-allow-add-extension');
    await t.enterText(find.byKey(const Key('card-allow-extension-field')), 'd mg');
    await t.pump();
    expect(t.widget<FilledButton>(find.byKey(const Key('card-allow-extension-ok'))).onPressed, isNull,
        reason: 'not an extension the daemon takes');
    await t.enterText(find.byKey(const Key('card-allow-extension-field')), 'dmg');
    await t.pump();
    await tap(t, 'card-allow-extension-ok');
    await password(t);
    expect(d.contactList.last.fileAllow, ['executables', '.dmg']);

    d.passwords.clear();
    await t.tap(
        find.descendant(of: find.byKey(const Key('card-allow-.dmg')), matching: find.byTooltip(en.cardAllowRemove)));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords, isEmpty, reason: 'asking again needs no password');
    expect(d.contactList.last.fileAllow, ['executables']);
  });

  testWidgets('not on the card of a contact below ∞', (t) async {
    await open(t, contact('Colleague', 62, trust: 4));
    expect(find.byKey(const Key('card-files')), findsNothing);
  });
}
