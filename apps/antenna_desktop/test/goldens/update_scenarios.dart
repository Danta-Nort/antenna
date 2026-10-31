// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for updates: the release the CLI verified, over Settings scrolled to the Updates card; a release that is
// ready to install (the banner over Files, with the re-sent copies of its files), "Install signed updates by itself"
// in Settings → Updates, and "Another name" for a received file whose name is taken by another file (D-UI-29).

part of 'scenarios.dart';

class _GoldenPicker implements UpdatePicker {
  @override
  Future<String?> manifest(String confirm) async => null;

  @override
  Future<String?> folder(String confirm) async => '/Users/owner/Downloads/antenna-0.1.1';
}

void _defineUpdateScenarios() {
  _s('32_update', (t) async {
    const name = '32_update';
    final previous = UpdatePicker.instance;
    UpdatePicker.instance = _GoldenPicker();
    addTearDown(() => UpdatePicker.instance = previous);
    final cli = FakeCli(status: statusJson(updateUrl: 'https://example.com/releases/latest.json'));
    final m = await _model(_demo(), cli: cli);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('settings-advanced')));
    await t.pump(const Duration(milliseconds: 400));
    await t.scrollUntilVisible(find.byKey(const Key('update-from-file')), 300,
        scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('update-from-file')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('update-pick-folder')));
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await _snap(t, name);
  });

  _s('60_update_ready', (t) => _updateReady(t, '60_update_ready'));
  _s('60_update_ready_dark', (t) => _updateReady(t, '60_update_ready_dark', dark: true));

  _s('61_update_auto', (t) async {
    const name = '61_update_auto';
    final d = _demo()
      ..updateAuto = UpdateAutoInfo(
        enabled: true,
        supported: true,
        keysKept: true,
        url: 'https://example.com/releases/latest.json',
        lastCheckMs: ms(ago(hours: 3)),
        staged: StagedUpdate(
            version: '0.1.3',
            source: 'link',
            contact: buildBotName,
            stagedMs: ms(ago(minutes: 12)),
            state: 'soon',
            atMs: ms(fixedNow.add(const Duration(minutes: 5)))),
        last: UpdateRecord(
            version: '0.1.2',
            result: 'installed',
            source: 'link',
            contact: buildBotName,
            from: '0.1.0-preview.7',
            unlocked: true,
            atMs: ms(DateTime(2026, 10, 1, 3, 12))),
        failed: const ['0.1.0-preview.6'],
      );
    final m = await _model(d, cli: FakeCli(status: statusJson(updateUrl: 'https://example.com/releases/latest.json')));
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('settings-advanced')));
    await t.pump(const Duration(milliseconds: 400));
    // The whole Updates card: the banner at its top, the setting and what the daemon did at its bottom.
    // The CLI's facts arrive after the first frame of the card: let them lay out, then scroll to the end.
    await t.pump(const Duration(milliseconds: 400));
    final list = t.state<ScrollableState>(
        find.ancestor(of: find.byKey(const Key('update-auto')), matching: find.byType(Scrollable)).first);
    list.position.jumpTo(list.position.maxScrollExtent);
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('62_file_rename', (t) async {
    const name = '62_file_rename';
    final d = _demo();
    final f = FileInfo(
      id: hex(0x2E9A3E, 32),
      contact: emily.label,
      linkId: emily.linkId,
      direction: 'in',
      name: 'report.pdf',
      size: 412000,
      blake3: hex(0xA1A1),
      senderMime: 'application/pdf',
      state: 'checked',
      verdict: 'clean',
      mime: 'application/pdf',
      createdMs: ms(ago(minutes: 4)),
    );
    d.fileMap[f.id] = f;
    // Another report.pdf is in Emily's link folder already, and so is report (2).pdf. A daemon before D-128, which
    // refuses the taken name (a D-128 daemon saves it as report (3).pdf and no dialog opens): the window's fallback.
    d.folderFiles[emily.linkId] = {'report.pdf': hex(0xD0D0), 'report (2).pdf': hex(0xD1D1)};
    d.numbersTakenNames = false;
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-files')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(Key('file-accept-${f.id.substring(0, 8)}')));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('file-name')), 'Report.PDF');
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });
}

/// Release files re-sent by the owner's own computer (level 5): the daemon verified and staged the release; one copy
/// was accepted without a second file, another waits and its card already says it is the same file.
Future<void> _updateReady(WidgetTester t, String name, {bool dark = false}) async {
  const dmg = 'Antenna-0.1.3-macos-arm64.dmg';
  final content = hex(0xD9D9);
  FileInfo copy(int seed, String state) => FileInfo(
        id: hex(0xC0B1 + seed, 32),
        contact: buildBotName,
        linkId: buildBot.linkId,
        direction: 'in',
        name: dmg,
        size: 48700249,
        blake3: content,
        senderMime: 'application/x-apple-diskimage',
        state: state,
        verdict: 'suspicious',
        mime: 'application/x-apple-diskimage',
        findings: const [FileFinding(code: 'no_safe_preview', severity: 'info', detail: 'disk image: no safe preview')],
        dest: state == 'accepted' ? 'project' : null,
        savedAs: state == 'accepted' ? dmg : null,
        duplicate: state == 'accepted',
        createdMs: ms(ago(minutes: 20 - seed)),
      );
  final d = _demo()
    ..updateAuto = UpdateAutoInfo(
      enabled: true,
      supported: true,
      keysKept: true,
      staged: StagedUpdate(
          version: '0.1.3',
          source: 'link',
          contact: buildBotName,
          stagedMs: ms(ago(minutes: 6)),
          state: 'waiting'),
    );
  for (final f in [copy(1, 'accepted'), copy(2, 'checked')]) {
    d.fileMap[f.id] = f;
  }
  d.folderFiles[buildBot.linkId] = {dmg.toLowerCase(): content};
  final m = await _model(d);
  await _frame(t, dark ? _dark(m) : XApp(model: m));
  await t.tap(find.byKey(const Key('nav-files')));
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
  await _snap(t, name);
}

