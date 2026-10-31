// SPDX-License-Identifier: AGPL-3.0-only
// Updates that install by themselves in the window (D-103, CONTROL §23, D-UI-29), on the fake daemon and a stand-in
// `antenna update`: the switch in Settings → Updates (off by default, the owner password both ways, the daemon checks
// it; an installation that cannot replace itself; a daemon older than v7), what the daemon staged and did; and the
// "ready to install" banner in Files and Settings for a verified newer release, from an accepted manifest (the usual
// install with the password) or staged by the daemon (Install now, Later), never for what is installed already or
// older.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/auto_update.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/experimental_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_updater.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
const _pw = 'correct horse battery';
const _manifest = '/Users/owner/Antenna/links/Emily Carter/shared/antenna-0.1.1-manifest.json';

StagedUpdate _staged({String state = 'waiting', String version = '0.1.3', int? atMs}) => StagedUpdate(
    version: version, source: 'link', contact: 'Mac', stagedMs: ms(ago(minutes: 4)), state: state, atMs: atMs);

FakeDaemon _demo({UpdateAutoInfo? auto, int proto = 7}) {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..protoVersion = proto;
  if (auto != null) d.updateAuto = auto;
  return d;
}

/// An accepted release manifest from Emily, saved in her link folder.
FileInfo _manifestFile() => FileInfo(
      id: hex(0x5E1EA5E, 32),
      contact: emily.label,
      linkId: emily.linkId,
      direction: 'in',
      name: 'antenna-0.1.1-manifest.json',
      size: 1874,
      blake3: hex(0xB1),
      state: 'accepted',
      verdict: 'clean',
      dest: 'shared',
      savedAs: 'antenna-0.1.1-manifest.json',
      savedPath: _manifest,
      createdMs: ms(ago(minutes: 3)),
    );

Future<AppModel> _app(WidgetTester t, FakeDaemon d, {FakeCli? cli}) async {
  final m = AppModel(
      connector: (_) => d,
      socketPath: d.socketPath,
      live: false,
      clock: () => fixedNow,
      updater: (cli ?? FakeCli()).updater());
  await m.connect();
  t.view.physicalSize = const Size(1440, 2200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  return m;
}

Future<void> _settings(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('settings-advanced')));
  await t.pump(const Duration(milliseconds: 400));
  await t.pump();
}

Future<void> _files(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-files')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _password(WidgetTester t, String pw) async {
  await t.pump(const Duration(milliseconds: 300));
  await t.enterText(find.byKey(const Key('owner-password')), pw);
  await t.tap(find.byKey(const Key('password-ok')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

bool _switchOn(WidgetTester t) => t.widget<Switch>(find.byKey(const Key('update-auto-switch'))).value;

void main() {
  testWidgets('the switch: off by default, experimental; on and off each ask for the password, the daemon checks it',
      (t) async {
    final d = _demo();
    final m = await _app(t, d);
    await _settings(t);
    expect(d.calls, contains('update_auto_status'));
    expect(find.text(en.updateAutoTitle), findsOneWidget);
    expect(find.byKey(const Key('experimental-update-auto')), findsOneWidget);
    expect(find.byType(ExperimentalTag), findsWidgets);
    expect(_switchOn(t), isFalse);

    // A wrong password: the daemon refuses, the switch stays off, the reason is shown.
    await t.tap(find.byKey(const Key('update-auto-switch')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateAutoOnAction), findsOneWidget);
    await _password(t, 'nope');
    expect(d.updateAutoSets.single, (true, 'nope'));
    expect(_switchOn(t), isFalse);
    expect(find.byKey(const Key('update-auto-error')), findsOneWidget);

    await t.tap(find.byKey(const Key('update-auto-switch')));
    await _password(t, _pw);
    expect(d.updateAutoSets.last, (true, _pw));
    expect(_switchOn(t), isTrue);
    expect(m.updateAuto!.enabled, isTrue);
    expect(find.byKey(const Key('update-auto-error')), findsNothing);

    // Off asks too (D-103: the password both ways).
    await t.tap(find.byKey(const Key('update-auto-switch')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateAutoOffAction), findsOneWidget);
    await _password(t, _pw);
    expect(d.updateAutoSets.last, (false, _pw));
    expect(_switchOn(t), isFalse);

    // Cancelling the password sends nothing.
    await t.tap(find.byKey(const Key('update-auto-switch')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text(en.commonCancel).last);
    await t.pump(const Duration(milliseconds: 300));
    expect(d.updateAutoSets.length, 3);
  });

  testWidgets('an installation that cannot replace itself: the switch is disabled with the reason; the daemon\'s '
      'refusal is shown', (t) async {
    const reason = 'a development build cannot replace itself';
    final d = _demo(auto: const UpdateAutoInfo(enabled: false, supported: false, unsupportedReason: reason));
    final m = await _app(t, d);
    await _settings(t);
    expect(find.text(en.updateAutoUnsupported(reason)), findsOneWidget);
    expect(t.widget<Switch>(find.byKey(const Key('update-auto-switch'))).onChanged, isNull);

    // The window's view is older than the daemon's (it said "supported" before): the daemon's refusal is shown.
    m.updateAuto = const UpdateAutoInfo(enabled: false, supported: true);
    m.safeNotify();
    await t.pump();
    await t.tap(find.byKey(const Key('update-auto-switch')));
    await _password(t, _pw);
    expect(find.text(en.updateAutoErrUnsupported(reason)), findsOneWidget);
    expect(_switchOn(t), isFalse);
  });

  testWidgets('a daemon older than v7: one line saying so, no switch', (t) async {
    final d = _demo(proto: 6);
    final m = await _app(t, d);
    await _settings(t);
    expect(m.updateAutoAvailable, isFalse);
    expect(d.calls.where((c) => c.startsWith('update_auto')), isEmpty, reason: 'an older daemon is never asked');
    expect(find.byKey(const Key('update-auto-old')), findsOneWidget);
    expect(find.byKey(const Key('update-auto-switch')), findsNothing);
  });

  testWidgets('what the daemon staged and did: the staged release, the last record, the versions not retried',
      (t) async {
    final d = _demo(
      auto: UpdateAutoInfo(
        enabled: true,
        supported: true,
        keysKept: true,
        staged: _staged(),
        last: UpdateRecord(
            version: '0.1.2',
            result: 'failed',
            reason: 'install_failed: the new version did not answer in 30 s',
            source: 'link',
            contact: 'Mac',
            atMs: ms(ago(hours: 20))),
        failed: const ['0.1.2'],
        url: 'https://example.com/releases/latest.json',
      ),
    );
    await _app(t, d);
    await _settings(t);
    expect(find.text(en.updateAutoStagedFrom('0.1.3', 'Mac')), findsOneWidget);
    expect(find.textContaining('0.1.2 failed to install'), findsOneWidget);
    expect(find.textContaining('install_failed: the new version did not answer in 30 s'), findsOneWidget);
    expect(find.byKey(const Key('update-auto-failed')), findsOneWidget);
    expect(find.text('https://example.com/releases/latest.json'), findsOneWidget);
  });

  testWidgets('the banner for a staged release: Files and Settings, Install now; while it is coming, Later', (t) async {
    final d = _demo(auto: UpdateAutoInfo(enabled: true, supported: true, keysKept: true, staged: _staged()));
    final m = await _app(t, d);
    await _files(t);
    expect(find.text(en.updateReadyTitle('0.1.3')), findsOneWidget);
    expect(find.text(en.updateReadyByItself), findsOneWidget);
    expect(find.byKey(const Key('update-ready-install')), findsNothing, reason: 'the staged one installs with one click');
    await t.tap(find.byKey(const Key('update-ready-now')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls.where((c) => c == 'update_auto_now').length, 1);
    expect(find.text(en.updateReadyInstalling), findsOneWidget);
    expect(find.byKey(const Key('update-ready-now')), findsNothing);

    // The daemon says it installs soon: Later postpones it.
    final at = ms(fixedNow.add(const Duration(minutes: 5)));
    d.updateAuto =
        UpdateAutoInfo(enabled: true, supported: true, keysKept: true, staged: _staged(state: 'soon', atMs: at));
    m.handleEvent(UpdateAutoEvent(state: 'soon', version: '0.1.3', source: 'link', contact: 'Mac', atMs: at));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateReadySoon('14:37')), findsOneWidget);
    await t.tap(find.byKey(const Key('update-ready-later')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('update_auto_later'));
    expect(find.text(en.updateReadyByItself), findsOneWidget);

    // Nothing staged any more by the time of the click: the daemon's answer is shown, not swallowed.
    d.updateAuto = const UpdateAutoInfo(enabled: true, supported: true, keysKept: true);
    await t.tap(find.byKey(const Key('update-ready-now')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateAutoErrNothingStaged), findsOneWidget);

    await _settings(t);
    expect(find.byKey(const Key('update-ready')), findsNothing, reason: 'the daemon has nothing staged now');
  });

  testWidgets('with the setting off, a release from the daily check waits for the owner: Install asks for the password '
      'and sends it with update_auto_now, so the keys stay unlocked across the restart (D-137)', (t) async {
    final d = _demo(
      auto: UpdateAutoInfo(
        enabled: false,
        supported: true,
        url: 'https://example.com/antenna-preview-manifest.json',
        staged: StagedUpdate(version: '0.1.3', source: 'url', stagedMs: ms(ago(minutes: 4)), state: 'waiting'),
      ),
    );
    await _app(t, d);
    await _settings(t);
    expect(find.text(en.updateAutoStagedWaiting('0.1.3')), findsOneWidget);
    expect(_switchOn(t), isFalse, reason: 'the daily check does not turn automatic installs on');

    await _files(t);
    expect(find.text(en.updateReadyTitle('0.1.3')), findsOneWidget);
    expect(find.text(en.updateReadyChecked), findsOneWidget);
    expect(find.text(en.updateReadyByItself), findsNothing);
    expect(find.byKey(const Key('update-ready-later')), findsNothing);
    expect(find.text(en.updateReadyInstall), findsOneWidget);
    await t.tap(find.byKey(const Key('update-ready-now')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls.where((c) => c == 'update_auto_now'), isEmpty, reason: 'not before the password');
    await _password(t, _pw);
    expect(d.calls.where((c) => c == 'update_auto_now').length, 1);
    expect(d.passwords['update_auto_now'], _pw);
    expect(find.text(en.updateReadyInstalling), findsOneWidget);
  });

  testWidgets('the banner for an accepted manifest the CLI verified with this computer\'s file: Install opens the '
      'usual dialog', (t) async {
    final d = _demo()..fileMap[_manifestFile().id] = _manifestFile();
    final cli = FakeCli()..verify = (paths, {required manifestOnly}) => verifyJson(dir: paths.single);
    await _app(t, d, cli: cli);
    await _files(t);
    expect(find.text(en.updateReadyTitle('0.1.1')), findsOneWidget);
    expect(find.text(en.updateReadyFrom(emily.label)), findsOneWidget);
    await t.tap(find.byKey(const Key('update-ready-install')));
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
    expect(cli.calls.last, contains(_manifest));
    expect(cli.calls.last, contains('--dry-run'));
    // The card keeps its own button.
    await t.tap(find.text(en.commonCancel).last);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('update-file-install')), findsOneWidget);
  });

  testWidgets('never offered: no file for this computer, not newer by the CLI, or not newer than the daemon that runs',
      (t) async {
    for (final (verify, daemon, why) in [
      (verifyJson(asset: false), null, 'this computer\'s file is not next to the manifest'),
      (verifyJson(newer: false), null, 'the CLI says it is not newer'),
      (verifyJson(), 'antennad 0.1.1 (8e21d04b5a9f)', 'installed already (the CLI\'s answer was stale)'),
      (verifyJson(), 'antennad 0.1.2 (0)', 'older than what runs'),
    ]) {
      final d = _demo()..fileMap[_manifestFile().id] = _manifestFile();
      final m = AppModel(
          connector: (_) => d,
          socketPath: d.socketPath,
          live: false,
          clock: () => fixedNow,
          updater: (FakeCli()..verify = (_, {required manifestOnly}) => verify).updater());
      await m.connect();
      if (daemon != null) {
        m.status = StatusReply(state: DaemonState.unlocked, daemon: daemon, protocol: 'x/0', relay: 'n0');
      }
      t.view.physicalSize = const Size(1440, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(XApp(model: m));
      await t.pump(const Duration(milliseconds: 400));
      await _files(t);
      expect(find.byKey(const Key('update-ready')), findsNothing, reason: why);
      await t.pumpWidget(const SizedBox());
      m.dispose();
    }
  });

  testWidgets('a staged release and the same version from a manifest: one banner, the staged one', (t) async {
    final d = _demo(
        auto: UpdateAutoInfo(enabled: true, supported: true, keysKept: true, staged: _staged(version: '0.1.1')))
      ..fileMap[_manifestFile().id] = _manifestFile();
    final cli = FakeCli()..verify = (paths, {required manifestOnly}) => verifyJson(dir: paths.single);
    await _app(t, d, cli: cli);
    await _files(t);
    expect(find.byKey(const Key('update-ready')), findsOneWidget);
    expect(find.byKey(const Key('update-ready-now')), findsOneWidget);
    expect(find.byKey(const Key('update-ready-install')), findsNothing);
  });

  test('SemVer precedence and the daemon\'s version', () {
    expect(compareVersions('0.1.0-preview.10', '0.1.0-preview.9'), 1);
    expect(compareVersions('0.1.0', '0.1.0-preview.9'), 1);
    expect(compareVersions('0.1.0-preview.9', '0.1.0-preview.9+abc'), 0);
    expect(compareVersions('0.2.0-alpha', '0.1.9'), 1);
    expect(compareVersions('0.1.0-alpha.1', '0.1.0-alpha.beta'), -1);
    expect(compareVersions('bogus', '0.1.0'), isNull);
    expect(daemonVersionOf('antennad 0.1.0-preview.7 (e142081)'), '0.1.0-preview.7');
    expect(daemonVersionOf('antennad'), isNull);
  });
}
