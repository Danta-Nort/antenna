// SPDX-License-Identifier: AGPL-3.0-only
// The Files screen (D-UI-46): what needs the owner first, as full cards with their buttons; then what is
// downloading; then every other file newest first, pictures as a grid (or everything as a list), other files as
// compact rows; filters for Images, Files and Text; a search by name. Rules under test are in each test's reason.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';
import '../support/png.dart';

final en = l10nFor('en');

String _k(FileInfo f) => f.id.substring(0, 8);

void main() {
  late FakeDaemon d;
  late FileInfo logo, banner, sheet, readme;

  setUp(() {
    d = FakeDaemon(contacts: [...demoContacts(), buildBot], history: demoHistory());
    addDemoFiles(d); // a PDF and a sheet waiting, a disguised program, a log downloading, a sent note, an accepted scan
    FileInfo f(int seed, String name, String mime, int minutes) => demoFile(seed,
        from: buildBot,
        name: name,
        size: 900 + seed,
        mime: mime,
        state: 'accepted',
        verdict: 'clean',
        dest: 'shared',
        at: ago(minutes: minutes));
    logo = f(60, 'volna-logo-1024.png', 'image/png', 3);
    banner = f(61, 'volna-banner.png', 'image/png', 2);
    sheet = f(62, 'budget.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 1);
    readme = f(63, 'README.md', 'text/markdown', 1);
    for (final x in [logo, banner, sheet, readme]) {
      d.fileMap[x.id] = x;
    }
    d.previewMap[logo.id] = FilePreview(kind: 'image', imagesPng: [plainPng(64, 64)]);
    d.previewMap[banner.id] = FilePreview(kind: 'image', imagesPng: [plainPng(128, 32, rgb: 0x2266AA)]);
  });

  Future<void> open(WidgetTester t) async {
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    t.view.physicalSize = const Size(1440, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('nav-files')));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('what needs you comes first with its buttons; pictures as a grid; other files as rows', (t) async {
    await open(t);
    final awaiting = find.byKey(const Key('files-group-awaiting'));
    final all = find.byKey(const Key('files-group-all'));
    expect(awaiting, findsOneWidget);
    expect(t.getTopLeft(awaiting).dy, lessThan(t.getTopLeft(all).dy), reason: 'decisions on top');
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsOneWidget, reason: 'with its decision buttons');
    expect(find.byKey(Key('picture-square-${_k(logo)}')), findsOneWidget);
    expect(find.byKey(Key('picture-square-${_k(banner)}')), findsOneWidget);
    expect(find.byKey(Key('file-row-${_k(sheet)}')), findsOneWidget);
    expect(find.byKey(Key('file-${_k(sheet)}')), findsNothing, reason: 'a decided file is a row, not a card');

    // Everything as a list: the pictures become rows too.
    await t.tap(find.byKey(const Key('files-view-list')));
    await t.pump();
    expect(find.byKey(Key('picture-square-${_k(logo)}')), findsNothing);
    expect(find.byKey(Key('file-row-${_k(logo)}')), findsOneWidget);
  });

  testWidgets('filters and the search narrow every group by kind and name', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('files-filter-image')));
    await t.pump();
    expect(find.byKey(Key('picture-square-${_k(logo)}')), findsOneWidget);
    expect(find.byKey(Key('file-row-${_k(sheet)}')), findsNothing);
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsNothing, reason: 'a PDF is not an image');

    await t.tap(find.byKey(const Key('files-filter-text')));
    await t.pump();
    expect(find.byKey(Key('file-row-${_k(readme)}')), findsOneWidget);
    expect(find.byKey(Key('picture-square-${_k(logo)}')), findsNothing);

    await t.tap(find.byKey(const Key('files-filter-all')));
    await t.enterText(find.byKey(const Key('files-search')), 'volna');
    await t.pump();
    expect(find.byKey(Key('picture-square-${_k(logo)}')), findsOneWidget);
    expect(find.byKey(Key('picture-square-${_k(banner)}')), findsOneWidget);
    expect(find.byKey(Key('file-row-${_k(readme)}')), findsNothing);
    expect(find.byKey(const Key('files-group-awaiting')), findsNothing, reason: 'nothing waiting is named so');

    await t.enterText(find.byKey(const Key('files-search')), 'nothing-like-this');
    await t.pump();
    expect(find.text(en.mediaNoMatch('nothing-like-this')), findsOneWidget);
  });
}
