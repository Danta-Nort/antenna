// SPDX-License-Identifier: AGPL-3.0-only
// macOS Screen Recording before the Code mode screenshot (D-UI-27, D-UI-41) on the fake daemon, a fake pseudo-terminal,
// fake hooks, a fake screenshot tool writing into a real temporary folder and a fake Runner answer: allowed, the tool
// runs; missing, the window's own sheet comes first, the tool does not run, the button opens the System Settings pane,
// "Try again" asks macOS once and runs the tool only when allowed; Linux (no such permission) and a Runner without the
// check run the tool as before; Settings → Check shows the same state with the same fix, and no row on Linux.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/screen_permission.dart';
import 'package:antenna_desktop/host/screenshot.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_shot.dart';
import 'package:antenna_desktop/state/doctor.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _me = 'claude-backend';

const _idle = ClaudeScreen([
  '────────────────────────────────────────',
  '❯ \x1b[2mTry "fix lint errors"\x1b[22m',
  '────────────────────────────────────────',
  '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
], cursor: (1, 2));

String _paste(String path) => '\x1b[200~$path\x1b[201~';

final class _Window {
  _Window(this.m, this.pty, this.capture, this.launcher);
  final AppModel m;
  final FakePty pty;
  final FakeCapture capture;
  final FakeAppLauncher launcher;
}

/// Claude Code at its prompt in Code mode, with [permission] as the Runner's answer (`null`: none, as on Linux).
Future<_Window> _window(WidgetTester t, FakeScreenPermission? permission) async {
  final dir = Directory.systemTemp.createTempSync('antenna-shot-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final capture = FakeCapture();
  final launcher = FakeAppLauncher();
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)];
  final c = FakeAgentComputer(
    hooks: true,
    shots: ScreenshotStore('${dir.path}/screenshots'),
    capture: capture,
    screenPermission: permission,
  );
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
    appLauncher: launcher,
  );
  await m.connect();
  expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: '/home/owner/shop'), auth: PasswordAuth(_pw)),
      isNull);
  final pty = c.last..emit('\x1b[?2004h${drawScreen(_idle)}');
  c.hookChannels.single.emit(ClaudeHookEvent.start);
  await t.pump();
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
  await t.pump(const Duration(milliseconds: 300));
  return _Window(m, pty, capture, launcher);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m
    ..disposeCodeShots()
    ..disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

final _sheet = find.byKey(const Key('screen-permission-sheet'));

void main() {
  testWidgets('Screen Recording allowed for this build: the tool runs at once, no sheet', (t) async {
    final p = FakeScreenPermission(ScreenPermission.granted);
    final w = await _window(t, p);
    await t.tap(find.byKey(const Key('code-shot')));
    await _settle(t);
    expect(_sheet, findsNothing);
    expect(w.pty.written, [_paste(w.capture.paths.single)]);
    expect((p.checks, p.requests), (1, 0), reason: 'checked without asking');
    expect(w.m.screenPermission, ScreenPermission.granted);
    await _end(t, w.m);
  });

  testWidgets('missing: our sheet first, the tool does not run, the button opens the pane, Try again asks macOS once',
      (t) async {
    final p = FakeScreenPermission(ScreenPermission.missing);
    final w = await _window(t, p);
    await t.tap(find.byKey(const Key('code-shot')));
    await _settle(t);
    expect(_sheet, findsOneWidget);
    expect(w.capture.paths, isEmpty, reason: 'nothing runs before the owner read the sheet');
    expect(p.requests, 0, reason: 'macOS is not asked before the sheet');
    expect(find.text('Allow Screen Recording for this build of Antenna'), findsOneWidget);
    expect(find.textContaining('until Antenna is signed with a Developer ID'), findsOneWidget);
    expect(find.textContaining('remove it with −'), findsOneWidget);
    expect(find.textContaining('Quit and reopen Antenna'), findsOneWidget);
    expect(find.byKey(const Key('screen-permission-still')), findsNothing);

    await t.tap(find.byKey(const Key('screen-permission-open')));
    await _settle(t);
    expect(w.launcher.urls, [screenRecordingSettingsUrl]);
    expect(screenRecordingSettingsUrl, 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture');
    expect(_sheet, findsOneWidget, reason: 'the sheet stays while the owner works in System Settings');

    // Still missing: macOS was asked once, the tool did not run, the sheet says so.
    await t.tap(find.byKey(const Key('screen-permission-retry')));
    await _settle(t);
    expect(p.requests, 1);
    expect(w.capture.paths, isEmpty);
    expect(_sheet, findsOneWidget);
    expect(find.byKey(const Key('screen-permission-still')), findsOneWidget);

    await t.tap(find.byKey(const Key('screen-permission-close')));
    await _settle(t);
    expect(_sheet, findsNothing);
    expect(w.capture.paths, isEmpty);
    expect(w.pty.written, isEmpty);
    expect(find.text('The screenshot could not be taken'), findsNothing, reason: 'not a failure: nothing was tried');
    expect(w.m.screenPermissionBlocked, isTrue);
    await _end(t, w.m);
  });

  testWidgets('Try again after the owner allowed it: the tool runs and the image is pasted', (t) async {
    final p = FakeScreenPermission(ScreenPermission.missing, afterRequest: ScreenPermission.granted);
    final w = await _window(t, p);
    await t.tap(find.byKey(const Key('code-shot')));
    await _settle(t);
    expect(_sheet, findsOneWidget);
    await t.tap(find.byKey(const Key('screen-permission-retry')));
    await _settle(t);
    expect(_sheet, findsNothing);
    expect(p.requests, 1);
    expect(w.pty.written, [_paste(w.capture.paths.single)]);
    await _end(t, w.m);
  });

  testWidgets('System Settings does not open: the sheet says where to go', (t) async {
    final w = await _window(t, FakeScreenPermission(ScreenPermission.missing));
    w.launcher.ok = false;
    await t.tap(find.byKey(const Key('code-shot')));
    await _settle(t);
    await t.tap(find.byKey(const Key('screen-permission-open')));
    await _settle(t);
    expect(find.byKey(const Key('screen-permission-open-failed')), findsOneWidget);
    expect(find.textContaining('Privacy & Security → Screen & System Audio Recording'), findsWidgets);
    await _end(t, w.m);
  });

  for (final (what, unknown) in [('Linux (no such permission)', false), ('a Runner without the check', true)]) {
    testWidgets('$what: the tool runs as before', (t) async {
      final p = unknown ? FakeScreenPermission(ScreenPermission.unknown) : null;
      final w = await _window(t, p);
      await t.tap(find.byKey(const Key('code-shot')));
      await _settle(t);
      expect(_sheet, findsNothing);
      expect(w.capture.paths, hasLength(1));
      expect(p?.requests ?? 0, 0);
      await _end(t, w.m);
    });
  }

  test('the check row: none on Linux; ok; missing is worth knowing until a screenshot met it, then a problem', () {
    expect(checkScreenRecording(ScreenPermission.notApplicable, blocked: true), isNull);
    final ok = checkScreenRecording(ScreenPermission.granted, blocked: false)!;
    expect((ok.state, ok.code), (CheckState.ok, null));
    final info = checkScreenRecording(ScreenPermission.missing, blocked: false)!;
    expect((info.state, info.code), (CheckState.info, 'screen_recording_missing'));
    final problem = checkScreenRecording(ScreenPermission.missing, blocked: true)!;
    expect((problem.state, problem.code), (CheckState.problem, 'screen_recording_missing'));
    expect(checkScreenRecording(ScreenPermission.unknown, blocked: false)!.state, CheckState.unknown);
  });

  group('Settings → Check', () {
    Future<_Window> check(WidgetTester t, FakeScreenPermission? p) async {
      final w = await _window(t, p);
      await t.pumpWidget(XApp(model: w.m, appearance: Appearance()));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('nav-settings')));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('settings-check')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      return w;
    }

    final row = find.byKey(const Key('check-row-screen-recording'));

    testWidgets('missing: the row with the same fix and the same button', (t) async {
      final w = await check(t, FakeScreenPermission(ScreenPermission.missing));
      await t.ensureVisible(row);
      await t.pump();
      expect(find.descendant(of: row, matching: find.text('screen_recording_missing')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Not allowed for this build')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('remove it with −')), findsOneWidget);
      expect(w.m.checks.whereType<ScreenRecordingCheck>().single.state, CheckState.info);
      final open = find.descendant(of: row, matching: find.byKey(const Key('screen-permission-open')));
      await t.ensureVisible(open);
      await t.pump();
      await t.tap(open);
      await _settle(t);
      expect(w.launcher.urls, [screenRecordingSettingsUrl]);
      expect(w.capture.paths, isEmpty);
      await _end(t, w.m);
    });

    testWidgets('a screenshot met it: the same row is a problem', (t) async {
      final w = await check(t, FakeScreenPermission(ScreenPermission.missing));
      expect((await w.m.takeScreenshot(w.m.runOf(_me)!)).outcome, ShotOutcome.needsPermission);
      await w.m.runChecks();
      await t.pump();
      expect(w.m.checks.whereType<ScreenRecordingCheck>().single.state, CheckState.problem);
      await _end(t, w.m);
    });

    testWidgets('allowed: the row says so, with nothing to fix', (t) async {
      final w = await check(t, FakeScreenPermission(ScreenPermission.granted));
      await t.ensureVisible(row);
      await t.pump();
      expect(find.descendant(of: row, matching: find.text('Allowed for this build of Antenna.')), findsOneWidget);
      expect(find.byKey(const Key('screen-permission-open')), findsNothing);
      await _end(t, w.m);
    });

    testWidgets('Linux: no Screen Recording row', (t) async {
      final w = await check(t, null);
      expect(find.byKey(const Key('check-panel')), findsOneWidget);
      expect(row, findsNothing);
      expect(w.m.checks.whereType<ScreenRecordingCheck>(), isEmpty);
      await _end(t, w.m);
    });
  });
}
