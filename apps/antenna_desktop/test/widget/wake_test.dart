// SPDX-License-Identifier: AGPL-3.0-only
// "An agent that replies on its own" in the window (x-control/4, CONTROL §16) on the fake daemon: command presets, the
// secret goes to the daemon and is never shown, --no-home-files, hosts, limits, password; forbidden flags and a missing
// sandbox give plain-language errors; the rule in the Agents section and in the card, the run log, turning it off.
// Command parsing without a shell.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/wake.dart';
import 'package:antenna_desktop/ui/agents/wake_ui.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
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

Future<void> _openFromAgents(WidgetTester t) async {
  await t.tap(find.byKey(const Key('agents-button')));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('wake-add')));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _pickContact(WidgetTester t, String label) async {
  await t.tap(find.byKey(const Key('wake-contact')));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.text(label).last);
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  test('splitCommand: like the shell, without the shell', () {
    expect(splitCommand('claude -p --output-format stream-json'), ['claude', '-p', '--output-format', 'stream-json']);
    expect(splitCommand('codex exec "write a reply" --model o4'), ['codex', 'exec', 'write a reply', '--model', 'o4']);
    expect(splitCommand(r"/opt/my\ agent 'a b' x"), ['/opt/my agent', 'a b', 'x']);
    expect(splitCommand('echo \$HOME `id`'), ['echo', r'$HOME', '`id`'], reason: 'no substitutions');
    expect(splitCommand('bad "quote'), isNull);
  });

  testWidgets('set up Claude Code with a secret: the request carries it, the window never shows it (en)', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await _openFromAgents(t);
    expect(find.byType(WakeDialog), findsOneWidget);
    expect(find.textContaining('bubblewrap'), findsWidgets, reason: 'honest sandbox note');
    await _pickContact(t, buildBot.label);
    await t.enterText(find.byKey(const Key('wake-secret-value')), 'sk-ant-oat01-secret');
    await t.enterText(find.byKey(const Key('wake-hosts')), 'example.com, api.example.org');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('wake-submit')));
    await t.pump(const Duration(milliseconds: 300));
    final r = d.lastWakeSet!;
    expect(r.argv, ['claude', '-p', '--output-format', 'stream-json']);
    expect(r.contact, buildBot.linkId);
    expect(r.secretEnv.single.name, 'CLAUDE_CODE_OAUTH_TOKEN');
    expect(r.secretEnv.single.value, 'sk-ant-oat01-secret');
    expect(r.homeFiles, isEmpty, reason: 'a token → no sign-in files from home (--no-home-files)');
    expect(r.allowHosts, ['example.com', 'api.example.org']);
    expect(r.timeoutSecs, 600);
    expect(r.maxRunsPerHour, 20);
    expect(d.passwords['wake_set'], d.password);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(WakeDialog), findsNothing);
    // The rule in the Agents section: secret names yes, values no.
    expect(find.byKey(Key('wake-rule-${buildBot.label}')), findsOneWidget);
    expect(find.textContaining('CLAUDE_CODE_OAUTH_TOKEN'), findsOneWidget);
    expect(find.textContaining('sk-ant-oat01'), findsNothing);
    // Turn it off.
    await t.tap(find.byKey(Key('wake-off-${buildBot.label}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('wake_off'));
    expect(find.byKey(Key('wake-rule-${buildBot.label}')), findsNothing);
  });

  testWidgets('a forbidden flag: the daemon refuses, the window explains (ru)', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    await _openFromAgents(t);
    await _pickContact(t, buildBot.label);
    await t.tap(find.byKey(const Key('wake-preset-custom')));
    await t.pump();
    await t.enterText(find.byKey(const Key('wake-cmd')), 'claude -p --dangerously-skip-permissions');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('wake-submit')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(l10nFor('ru').wakeErrDenied), findsOneWidget);
    expect(find.byType(WakeDialog), findsOneWidget, reason: 'the dialog stays — fix and retry');
    expect(d.wakeRuleList, isEmpty);
  });

  testWidgets('no sandbox on this OS (macOS): honest note and the daemon error in words', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..wakeSandbox = 'none';
    final m = await _model(d);
    await _app(t, m);
    await _openFromAgents(t);
    expect(find.textContaining('no sandbox for agents'), findsWidgets);
    await _pickContact(t, buildBot.label);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('wake-submit')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining("Antenna doesn't start an agent without one"), findsOneWidget);
  });

  testWidgets('the contact card offers set-up and shows the rule with its run log', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    d.receipts = {
      buildBot.linkId: [
        ReceiptInfo.fromJson({
          'seq': 7,
          'ts': ms(fixedNow),
          'actor': 'wake-build',
          'action': 'wake',
          'decision': 'ok',
          'reason': 'run r1: ok (exit 0) in 4.2 s, sandbox bwrap; reply 7c1e',
          'source': 'local',
        }),
      ],
    };
    final m = await _model(d);
    await m.select(buildBot.linkId);
    await _app(t, m);
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.scrollUntilVisible(find.byKey(const Key('wake-card-setup')), 300, scrollable: find.byType(Scrollable).last);
    await t.ensureVisible(find.byKey(const Key('wake-card-setup')));
    await t.pump();
    await t.tap(find.byKey(const Key('wake-card-setup')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(WakeDialog), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('wake-submit')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.lastWakeSet!.contact, buildBot.linkId, reason: 'preselected from the card');
    expect(d.lastWakeSet!.homeFiles, isNull, reason: 'no token → the daemon default (read-only CLI sign-in)');
    await t.scrollUntilVisible(find.byKey(Key('wake-log-${buildBot.label}')), 300, scrollable: find.byType(Scrollable).last);
    await t.ensureVisible(find.byKey(Key('wake-log-${buildBot.label}')));
    await t.pump();
    await t.tap(find.byKey(Key('wake-log-${buildBot.label}')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.byKey(const Key('wake-log-row-7')), findsOneWidget);
    expect(find.textContaining('sandbox bwrap'), findsWidgets);
  });
}
