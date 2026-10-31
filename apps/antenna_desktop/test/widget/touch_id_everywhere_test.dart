// SPDX-License-Identifier: AGPL-3.0-only
// Touch ID wherever the window asked for the owner password (D-131), on the fake daemon and a fake Secure Enclave:
// with Touch ID on, each owner prompt starts one touch whose proof covers that one request, and a form's password
// field gives way to a line with "Use password"; with Touch ID off, the same places ask for the password; a touch that
// does not go through always leads to the password, saying why; turning automatic installs on keeps the password; the
// first gate at app start opens the sheet by itself once; Settings → Security says what Touch ID covers.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/touch_id.dart';
import 'package:antenna_desktop/host/updater.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/invite_dialog.dart';
import 'package:antenna_desktop/ui/security/owner_confirm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fake_touch_id.dart';
import '../support/fake_updater.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

/// A window with Touch ID on ([touch]) or off; [atStart]: as when the app opens (otherwise as after "Lock keys").
Future<(AppModel, FakeDaemon, FakeTouchId)> _setup({
  bool touch = true,
  DaemonState state = DaemonState.unlocked,
  bool atStart = false,
  List<AgentInfo> agents = const [],
  List<FileInfo> files = const [],
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), state: state)
    ..protoVersion = 7
    ..agentList = [...agents];
  for (final f in files) {
    d.fileMap[f.id] = f;
  }
  final h = FakeTouchId();
  if (touch) h.preset(h.dirFor(d.socketPath), d.ownerKeys);
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    touchId: h,
    binaries: _bins,
    agentHost: FakeAgentComputer().host,
    defaultSocket: d.socketPath,
    updater: FakeCli().updater(),
  );
  await m.connect();
  m.touchIdAtStart = atStart;
  addTearDown(() {
    for (final r in m.runs) {
      r.kill();
    }
  });
  return (m, d, h);
}

Future<void> _app(WidgetTester t, AppModel m, {InterfaceMode ui = InterfaceMode.chat}) async {
  t.view.physicalSize = const Size(1440, 2000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: ui)));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(Key(k));

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(_key(key));
  await _settle(t);
}

Future<void> _trustToTwo(WidgetTester t) async {
  await _tap(t, 'card-toggle');
  await _tap(t, 'trust-edit');
  await _tap(t, 'trust-2');
  await _tap(t, 'trust-apply');
}

Future<void> _settings(WidgetTester t, String section) async {
  await _tap(t, 'nav-settings');
  await _tap(t, 'settings-$section');
}

void main() {
  /// The maintainer's case (preview.8): Agents → Start an agent showed "Owner password" though Touch ID was on.
  /// Negative control (seen failing): `OwnerAuthController.usesTouch` returning `false`.
  testWidgets('Start an agent: with Touch ID on, no password field; one touch issues the token', (t) async {
    final (m, d, h) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, ui: InterfaceMode.code);
    await _tap(t, 'code-start-empty');
    expect(_key('owner-touch'), findsOneWidget);
    expect(_key('owner-password'), findsNothing);
    await _tap(t, 'code-start-go');
    expect(d.proven, ['agent_token']);
    expect(d.passwords['agent_token'], '', reason: 'the proof stands in for the password');
    expect(h.prompts.single.reason, en.touchIdReasonStartAgent('jarvis'));
    expect(h.prompts.single.request, contains('"cmd":"agent_token"'));
    expect(m.runOf('jarvis'), isNotNull, reason: 'the agent started');
  });

  testWidgets('Start an agent with Touch ID off: the password field, as before', (t) async {
    final (m, d, h) = await _setup(touch: false, agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    await _app(t, m, ui: InterfaceMode.code);
    await _tap(t, 'code-start-empty');
    expect(_key('owner-touch'), findsNothing);
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'code-start-go');
    expect(d.passwords['agent_token'], d.password);
    expect(d.proven, isEmpty);
    expect(h.prompts, isEmpty);
  });

  testWidgets('Start an agent: a cancelled touch brings the password field, no error; the password issues the token',
      (t) async {
    final (m, d, h) = await _setup(agents: [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)]);
    h.nextFailure = TouchIdFailure.cancelled;
    await _app(t, m, ui: InterfaceMode.code);
    await _tap(t, 'code-start-empty');
    await _tap(t, 'code-start-go');
    expect(m.runOf('jarvis'), isNull, reason: 'a cancel is never "allowed"');
    expect(d.calls, isNot(contains('agent_token')), reason: 'nothing reached the daemon');
    expect(_key('owner-password'), findsOneWidget);
    expect(find.text(en.touchIdErrCancelled), findsNothing);
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'code-start-go');
    expect(d.passwords['agent_token'], d.password);
    expect(m.runOf('jarvis'), isNotNull);
  });

  /// Negative control (seen failing): `confirmOwner` asking for the password without trying Touch ID.
  testWidgets('trust in the contact card: one touch first, no password prompt', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    await _trustToTwo(t);
    expect(_key('password-ok'), findsNothing, reason: 'no password prompt with Touch ID on');
    expect(d.proven, ['trust']);
    expect(m.selected!.trust, 2);
    expect(h.prompts.single.reason, startsWith('confirm “'));
    expect(h.prompts.single.request, '{"cmd":"trust","contact":"${m.selected!.linkId}","level":2,"password":""}');
  });

  testWidgets('trust with Touch ID off: the password prompt', (t) async {
    final (m, d, h) = await _setup(touch: false);
    await _app(t, m);
    await _trustToTwo(t);
    expect(_key('password-ok'), findsOneWidget);
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'password-ok');
    expect(d.passwords['trust'], d.password);
    expect(m.selected!.trust, 2);
    expect(h.prompts, isEmpty);
  });

  testWidgets('Touch ID unavailable in the middle: the password prompt says why, and the password does it', (t) async {
    final (m, d, h) = await _setup();
    h.nextFailure = TouchIdFailure.unavailable;
    await _app(t, m);
    await _trustToTwo(t);
    expect(_key('password-note'), findsOneWidget);
    expect(find.text(en.touchIdNoteUnavailable), findsOneWidget);
    expect(m.selected!.trust, isNot(2));
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'password-ok');
    expect(d.passwords['trust'], d.password);
    expect(m.selected!.trust, 2);
  });

  testWidgets('the password due (14 days): no sheet at all, the password prompt says so', (t) async {
    final (m, d, h) = await _setup();
    d.ownerKeys.needPassword = true;
    await _app(t, m);
    await _trustToTwo(t);
    expect(h.prompts, isEmpty, reason: 'the challenge is asked before any prompt');
    expect(_key('password-note'), findsOneWidget);
  });

  testWidgets('remove a contact: the dialog says Touch ID, Remove asks for one touch', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    final link = m.selected!.linkId;
    await _tap(t, 'card-toggle');
    await _tap(t, 'contact-revoke');
    expect(_key('owner-touch'), findsOneWidget);
    await _tap(t, 'revoke-ok');
    expect(d.proven, ['revoke']);
    expect(m.contacts.any((c) => c.linkId == link), isFalse);
    expect(h.prompts.single.request, contains('"cmd":"revoke"'));
  });

  testWidgets('invite: one touch creates the invite', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    final ctx = t.element(find.byType(HomeScreen));
    // ignore: unawaited_futures
    showInviteDialog(ctx);
    await _settle(t);
    expect(_key('owner-touch'), findsOneWidget);
    await _tap(t, 'invite-create');
    await _settle(t);
    expect(d.proven, ['invite']);
    expect(h.prompts.single.request, contains('"cmd":"invite"'));
    expect(h.prompts.single.request, contains('"password":""'));
  });

  /// The file checks' Keep anyway (D-130) on a held program: force with one touch, the password one click away.
  testWidgets('Keep anyway on a held file: one touch sends force with a proof', (t) async {
    final base = demoFile(7,
        from: buildBot,
        name: 'tool',
        size: 52000,
        mime: 'application/x-executable',
        state: 'checked',
        verdict: 'clean',
        at: ago(minutes: 5));
    final f = FileInfo(
      id: base.id,
      contact: base.contact,
      linkId: base.linkId,
      direction: base.direction,
      name: base.name,
      size: base.size,
      blake3: base.blake3,
      state: base.state,
      createdMs: base.createdMs,
      verdict: base.verdict,
      mime: 'application/x-executable',
      messageId: base.messageId,
      held: const FileHeld(code: 'executable', rules: ['elf']),
    );
    final (m, d, h) = await _setup(files: [f]);
    await _app(t, m);
    await _tap(t, 'nav-files');
    final keep = _key('file-keep-${f.id.substring(0, 8)}');
    await t.ensureVisible(keep);
    await t.tap(keep);
    await _settle(t);
    expect(_key('password-ok'), findsNothing);
    expect(d.proven, ['file_accept']);
    expect(h.prompts.single.request, contains('"force":true'));
    expect(m.files[f.id]!.state, 'accepted');
  });

  testWidgets('LAN in Settings: "Use password" brings the field back; the password turns it on', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    await _settings(t, 'network');
    await _tap(t, 'lan-switch');
    expect(_key('owner-touch'), findsOneWidget);
    await _tap(t, 'owner-use-password');
    expect(_key('owner-password'), findsOneWidget);
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'lan-enable');
    expect(d.passwords['lan_set'], d.password);
    expect(h.prompts, isEmpty);
  });

  testWidgets('automatic installs: on keeps the password even with Touch ID, off takes one touch', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    await _settings(t, 'advanced');
    await _tap(t, 'update-auto-switch');
    expect(_key('password-ok'), findsOneWidget, reason: 'the daemon opens the root key with the password (D-103)');
    expect(h.prompts, isEmpty);
    await t.enterText(_key('owner-password'), d.password);
    await _tap(t, 'password-ok');
    expect(d.updateAutoSets.last, (true, d.password));
    await _tap(t, 'update-auto-switch');
    expect(_key('password-ok'), findsNothing);
    expect(d.proven, ['update_auto_set']);
    expect(d.updateAutoSets.last, (false, ''));
  });

  testWidgets('Settings → Security says what Touch ID confirms and when the password is still asked', (t) async {
    final (m, _, _) = await _setup();
    await _app(t, m);
    await _settings(t, 'security');
    expect(_key('touchid-covers'), findsOneWidget);
    expect(find.text(en.touchIdCovers), findsOneWidget);
    expect(find.text(en.touchIdCoversPassword), findsOneWidget);
  });

  testWidgets('Settings → Security with Touch ID off: no list', (t) async {
    final (m, _, _) = await _setup(touch: false);
    await _app(t, m);
    await _settings(t, 'security');
    expect(_key('touchid-covers'), findsNothing);
  });

  /// Negative control (seen failing): the gate's at-start check ignoring `touchIdAtStart` (a sheet after the lock).
  testWidgets('at app start the gate opens the sheet by itself once; after Lock keys it waits for a click', (t) async {
    final (m, _, h) = await _setup(state: DaemonState.locked, atStart: true);
    await _app(t, m);
    await _settle(t);
    expect(m.phase, Phase.unlocked, reason: 'one touch at start unlocked and signed in');
    expect(h.shown, 1);
    expect(h.prompts.first.method, 'openSlot');
    await m.lock();
    await _settle(t);
    await t.pump(const Duration(seconds: 1));
    expect(m.phase, Phase.locked);
    expect(h.shown, 1, reason: 'after Lock keys no sheet without a click');
    expect(_key('touchid-unlock'), findsOneWidget);
  });

  testWidgets('at app start with Touch ID off: the password field, no sheet', (t) async {
    final (m, _, h) = await _setup(touch: false, state: DaemonState.locked, atStart: true);
    await _app(t, m);
    await _settle(t);
    expect(m.phase, Phase.locked);
    expect(h.prompts, isEmpty);
    expect(_key('password'), findsOneWidget);
  });

  test('installing an update with Touch ID: the CLI asks for the touch itself, nothing on stdin', () {
    final touch = AntennaUpdater.installArgs(['/d'], touchId: true);
    expect(touch, contains('--touch-id'));
    expect(touch, isNot(contains('--password-stdin')));
    expect(AntennaUpdater.installArgs(['/d']), contains('--password-stdin'));
  });

  test('reasons for confirmations name the action and are cut to one line', () {
    expect(touchIdConfirmReason(en, 'Change trust'), 'confirm “Change trust”');
    final long = touchIdConfirmReason(en, 'x' * 200);
    expect(long.length, lessThan(100));
    expect(touchIdConfirmReason(en, 'a\nb'), 'confirm “a b”');
  });
}
