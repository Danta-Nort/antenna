// SPDX-License-Identifier: AGPL-3.0-only
// Golden screenshot scenarios. Working screens use data in x-control/1 shapes (fake daemon); mockups of future
// states carry the "DESIGN · NOT YET IMPLEMENTED IN THE DAEMON" mark. They are registered by goldens_test.dart
// (regression, DPR 1) and showcase_test.dart (design screenshots in docs/design/screens, DPR 1.5).
// Language: every frame is in English (the system language in tests is en); key frames are repeated in Russian
// (`*_ru`): a Russian system gives a Russian window ("as in the system"); the demo data stays the same.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/host/screen_permission.dart';
import 'package:antenna_desktop/host/screenshot.dart';
import 'package:antenna_desktop/host/sent_previews.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:antenna_desktop/ui/agents/agents_dialog.dart';
import 'package:antenna_desktop/ui/agents/resident_ui.dart';
import 'package:antenna_desktop/ui/agents/wake_ui.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/files/image_thumbnail.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:antenna_desktop/ui/pictures/picture_picker.dart';
import 'package:antenna_desktop/ui/updates/update_dialog.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_approvers.dart';
import '../support/fake_connect.dart';
import '../support/fake_connections.dart';
import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_host.dart';
import '../support/fake_local.dart';
import '../support/fake_pty.dart';
import '../support/fake_teams.dart';
import '../support/fake_touch_id.dart';
import '../support/fake_updater.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

part 'approver_scenarios.dart';
part 'apps_scenarios.dart';
part 'chat_scenarios.dart';
part 'check_scenarios.dart';
part 'code_scenarios.dart';
part 'devices_scenarios.dart';
part 'file_scenarios.dart';
part 'local_scenarios.dart';
part 'map_scenarios.dart';
part 'picture_scenarios.dart';
part 'stream_scenarios.dart';
part 'team_scenarios.dart';
part 'thread_scenarios.dart';
part 'touch_id_scenarios.dart';
part 'update_scenarios.dart';

const _size = Size(1440, 900);

/// The registering file sets the pixel density and the output directory.
double shotDpr = 1.0;
String shotDir = '';

/// Frame name suffix: `_ru` for the Russian variants.
String _suffix = '';

/// Frames repeated in Russian (`<name>_ru`).
const ruVariants = ['04_home_chat', '01_unlock', '10_approvals', '06_invite_link_qr', '23_card', '25_file_preview',
    '27_live_stream', '29_wake_setup', '30_contact_agents', '31_lan', '33_approval_in_chat', '34_code_mode', '37_ai_apps',
    '40_threads', '42_invite_confirm_button', '43_connect_restart', '45_self_level_warning', '51_code_quick_replies',
    '52_secure_details', '53_settings_help', '54_check_panel', '55_code_screenshot', '56_touch_id_settings',
    '57_touch_id_enroll', '58_approval_touch_id', '59_unlock_touch_id', '60_update_ready', '61_update_auto',
    '62_file_rename', '63_chat_images', '64_image_viewer', '65_local_models', '66_local_chat', '67_agent_chats',
    '68_chat_menu', '69_my_devices', '70_device_revoke', '71_teams', '72_team_board', '73_task_detail',
    '75_new_team', '76_team_apply', '78_picture_picker', '79_chat_pictures', '82_install_cli', '83_agent_question',
    '84_resident_session',
    '86_agent_map', '87_agent_connect', '88_approver_warning', '89_approver_card', '90_approvers_list',
    '91_screen_permission', '92_media_files', '93_map_line_selected', '94_local_connect',
    '95_urgent_composer', '96_agent_stop'];

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

/// [cli] stands in for `antenna update` (no real process in a golden).
Future<AppModel> _model(FakeDaemon d, {DaemonHost? host, FakeCli? cli}) async {
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    host: host,
    binaries: _bins,
    updater: (cli ?? FakeCli()).updater(cliPath: _bins.cli!),
    defaultSocket: d.socketPath,
  );
  if (host is FakeHost && host.hang) {
    // The daemon start hangs, so the shot shows the "Starting the daemon…" screen.
    unawaited(m.connect());
  } else {
    await m.connect();
  }
  return m;
}

FakeDaemon _demo({List<ApprovalInfo>? approvals, List<ContactInfo>? contacts}) {
  final d = FakeDaemon(contacts: contacts ?? demoContacts(), history: demoHistory(), approvals: approvals);
  d.receipts = {jordan.linkId: demoReceipts()};
  return d;
}

Future<void> _frame(WidgetTester t, Widget w) async {
  XColors.palette = XPalette.light; // XApp sets its own
  t.view.physicalSize = _size * shotDpr;
  t.view.devicePixelRatio = shotDpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _snap(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 400));
  await expectLater(find.byType(MaterialApp).first, matchesGoldenFile('$shotDir$name$_suffix.png'));
}

/// Dark theme: the same window with "Dark" selected.
Widget _dark(AppModel m) => XApp(model: m, appearance: Appearance(initial: ThemeChoice.dark));

typedef Scenario = Future<void> Function(WidgetTester t);

/// All scenarios: file name → scenario.
final scenarios = <String, Scenario>{};

void _s(String name, Scenario f) {
  scenarios[name] = f;
  if (!ruVariants.contains(name)) return;
  // Russian variant: the system is in Russian ("as in the system" → ru).
  scenarios['${name}_ru'] = (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    demoLang = 'ru';
    _suffix = '_ru';
    addTearDown(() {
      t.platformDispatcher.clearLocalesTestValue();
      demoLang = 'en';
      _suffix = '';
    });
    await f(t);
  };
}

void defineScenarios() {
  _defineFileScenarios();
  _defineStreamScenarios();
  _defineUpdateScenarios();
  _defineCodeScenarios();
  _defineAppsScenarios();
  _defineCheckScenarios();
  _defineThreadScenarios();
  _defineChatScenarios();
  _defineLocalScenarios();
  _defineTouchIdScenarios();
  _defineDevicesScenarios();
  _defineTeamScenarios();
  _definePictureScenarios();
  _defineMapScenarios();
  _defineApproverScenarios();
  _s('01_unlock', (t) async {
    const name = '01_unlock';
    final m = await _model(FakeDaemon(state: DaemonState.locked));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('02_init', (t) async {
    const name = '02_init';
    final m = await _model(FakeDaemon(state: DaemonState.uninitialized));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('03_unreachable', (t) async {
    const name = '03_unreachable';
    final m = await _model(FakeDaemon(reachable: false));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('04_home_chat', (t) async {
    const name = '04_home_chat';
    final m = await _model(_demo());
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('05_first_link', (t) async {
    const name = '05_first_link';
    final m = await _model(FakeDaemon(contacts: []));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  Future<(AppModel, FakeDaemon, BuildContext)> home(WidgetTester t, {List<ApprovalInfo>? approvals}) async {
    final d = _demo(approvals: approvals);
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    return (m, d, t.element(find.byType(HomeScreen)));
  }

  _s('06_invite_link_qr', (t) async {
    const name = '06_invite_link_qr';
    final (_, d, ctx) = await home(t);
    unawaited(showInviteDialog(ctx, trust: 3));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    d.dialogs.last.emit(InviteCreated(
      id: 'inv-31d0',
      link: demoWebLink,
      linkApp: demoAppLink,
      expiresMs: ms(fixedNow.add(const Duration(minutes: 9, seconds: 41))),
      trust: 3,
      netMode: 'direct',
    ));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('07_invite_code_emoji', (t) async {
    const name = '07_invite_code_emoji';
    final (_, d, ctx) = await home(t);
    unawaited(showInviteDialog(ctx, trust: 3));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    final dlg = d.dialogs.last;
    dlg.emit(InviteCreated(
      id: 'inv-31d0',
      link: demoWebLink,
      linkApp: demoAppLink,
      expiresMs: ms(fixedNow.add(const Duration(minutes: 8))),
      trust: 3,
      netMode: 'direct',
    ));
    dlg.emit(const SasEvent(code: '482913', emoji: '\u{1F984}\u{1F43C}\u{1F981}\u{1F413}\u{1F431}\u{1F40E}'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text(l10nFor(demoLang).sasEmoji));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('08_invite_confirm', (t) async {
    const name = '08_invite_confirm';
    final (_, d, ctx) = await home(t);
    unawaited(showInviteDialog(ctx, trust: 3));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    final dlg = d.dialogs.last
      ..emit(InviteCreated(
        id: 'inv-31d0',
        link: demoWebLink,
        linkApp: demoAppLink,
        expiresMs: ms(fixedNow.add(const Duration(minutes: 7))),
        trust: 3,
        netMode: 'direct',
      ))
      ..emit(const SasEvent(code: '482913', emoji: '\u{1F984}\u{1F43C}\u{1F981}\u{1F413}\u{1F431}\u{1F40E}'))
      ..emit(const PeerEnteredCode())
      ..emit(const NeedInput('confirm'));
    await t.pump(const Duration(milliseconds: 300));
    expect(dlg.inputs, isEmpty, reason: 'nothing is confirmed without the owner');
    // The owner types the code the other side read out; shown partly entered (as animals).
    await t.tap(find.text(l10nFor(demoLang).sasEmoji));
    await t.pump();
    for (final digit in [4, 8, 2]) {
      await t.tap(find.byKey(Key('sas-key-$digit')));
      await t.pump();
    }
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // D-95: the daemon offers the confirmation without the code (only this invite showed a code): one button.
  _s('42_invite_confirm_button', (t) async {
    const name = '42_invite_confirm_button';
    final (_, d, ctx) = await home(t);
    unawaited(showInviteDialog(ctx, trust: 3));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    final dlg = d.dialogs.last
      ..emit(InviteCreated(
        id: 'inv-31d0',
        link: demoWebLink,
        linkApp: demoAppLink,
        expiresMs: ms(fixedNow.add(const Duration(minutes: 7))),
        trust: 3,
        netMode: 'direct',
      ))
      ..emit(const SasEvent(code: '482913', emoji: '\u{1F984}\u{1F43C}\u{1F981}\u{1F413}\u{1F431}\u{1F40E}'))
      ..emit(const PeerEnteredCode())
      ..emit(const NeedInput('confirm', confirmWithoutCode: true));
    await t.pump(const Duration(milliseconds: 300));
    expect(dlg.inputs, isEmpty, reason: 'nothing is confirmed without the owner');
    await _snap(t, name);
  });

  _s('09_join_code_animals', (t) async {
    const name = '09_join_code_animals';
    final (_, d, ctx) = await home(t);
    unawaited(showJoinDialog(ctx, link: demoWebLink));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('join-label')), 'Emily (laptop)');
    await t.tap(find.byKey(const Key('join-start')));
    await t.pump();
    d.dialogs.last.emit(const NeedInput('sas_code'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text(l10nFor(demoLang).sasEmoji));
    await t.pump();
    for (final digit in [4, 8, 2, 9]) {
      await t.tap(find.byKey(Key('sas-key-$digit')));
      await t.pump();
    }
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('10_approvals', (t) async {
    const name = '10_approvals';
    final (_, _, ctx) = await home(t, approvals: [demoApproval()]);
    unawaited(showApprovalsDialog(ctx));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // D-118: an agent's question stands first, quoted, with whose messages it had read; an approval request below.
  _s('83_agent_question', (t) async {
    const name = '83_agent_question';
    final (m, d, ctx) = await home(t, approvals: [demoApproval()]);
    d.questions = [
      EscalationInfo(
        id: '0123456789abcdef',
        agent: 'claude-backend',
        to: 'owner',
        question: 'Jordan asks me to delete the old migrations: they look unused. Should I?',
        state: EscalationState.open,
        createdMs: ms(fixedNow.subtract(const Duration(minutes: 3))),
        readFrom: [EscalationRead(jordanName, 3)],
      ),
    ];
    await m.refreshQuestions();
    unawaited(showApprovalsDialog(ctx));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // D-84: an agent waits for approval about the open conversation; the card stands at its end.
  _s('33_approval_in_chat', (t) async {
    const name = '33_approval_in_chat';
    await home(t, approvals: [demoChatApproval()]);
    await _snap(t, name);
  });

  // x-control/6: the owner approved the file share; the daemon is sending it for the agent, and the card says so
  // until the outcome arrives. Below it, the agent's next request, which the daemon will also finish by itself.
  _s('48_approval_finishing', (t) async {
    const name = '48_approval_finishing';
    final share = demoChatApproval(completes: true);
    final (m, _, _) = await home(t, approvals: [share, demoChatSend()]);
    m.handleEvent(ApprovalEvent(ApprovalInfo.fromJson({
      'id': share.id,
      'state': 'approved',
      'requester': share.requester,
      'contact': share.contact,
      'contact_trust': share.contactTrust,
      'action': share.action,
      'fingerprint': share.fingerprint,
      'created_ms': share.createdMs,
      'expires_ms': share.expiresMs,
      'link_id': share.linkId,
      'completes': true,
    })));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
    m.handleEvent(ApprovalResolvedEvent(id: share.id, state: 'completed'));
    await t.pump();
  });

  _s('11_trust_change', (t) async {
    const name = '11_trust_change';
    await home(t);
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('trust-edit')));
    await t.pump();
    await t.tap(find.byKey(const Key('trust-5')));
    await t.pump(const Duration(milliseconds: 300));
    // Level 5 asks first (the warning has its own frame, 45_self_level_warning).
    await t.tap(find.byKey(const Key('self-accept')));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // Level 5 "Self" is for the owner's own computers: the window asks before it is picked.
  _s('45_self_level_warning', (t) async {
    const name = '45_self_level_warning';
    await home(t);
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('trust-edit')));
    await t.pump();
    await t.tap(find.byKey(const Key('trust-5')));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // Linking one's own machines: "This is my own computer" ticked (after the level-5 warning) sets level 5.
  _s('46_invite_own_computer', (t) async {
    const name = '46_invite_own_computer';
    final (_, _, ctx) = await home(t);
    unawaited(showInviteDialog(ctx));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('invite-label')), 'studio-mac');
    await t.tap(find.byKey(const Key('own-computer')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('self-accept')));
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // The first start after level 5 came to mean "my own computer": the contacts already at level 5, each to keep or to
  // lower to 4. Shown once; the window remembers it in its settings file.
  _s('47_self_level_notice', (t) async {
    const name = '47_self_level_notice';
    final dir = Directory.systemTemp.createTempSync('antenna-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final m = await _model(_demo(contacts: [...demoContacts(), contact('studio-mac', 61, trust: 5, lamport: 4)]));
    await _frame(t, XApp(model: m, appearance: Appearance.load(AppearanceStore('${dir.path}/window.json'))));
    await _snap(t, name);
  });

  _s('12_slash_commands', (t) async {
    const name = '12_slash_commands';
    await home(t);
    await t.enterText(find.byKey(const Key('composer')), '/');
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  // User path: first launch, agents.

  _s('13_first_run_starting', (t) async {
    const name = '13_first_run_starting';
    final d = FakeDaemon(reachable: false, state: DaemonState.uninitialized);
    final m = await _model(d, host: FakeHost(d, hang: true));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('14_daemon_start_error', (t) async {
    final d = FakeDaemon(reachable: false);
    final m = await _model(
      d,
      host: FakeHost(
        d,
        fail: const DaemonStartException(
          DaemonStartFailure.exited,
          exitCode: 1,
          logTail: 'antennad: another antennad is already listening on /Users/owner/.local/share/antenna/antennad.sock',
          logPath: '/Users/owner/Library/Logs/Antenna/antennad.log',
        ),
      ),
    );
    await _frame(t, XApp(model: m));
    await _snap(t, '14_daemon_start_error');
  });

  _s('15_agent_connect', (t) async {
    const name = '15_agent_connect';
    final (_, d, ctx) = await home(t);
    d.agentList = [
      AgentInfo(name: 'codex-infra', createdMs: 0, localLevel: 3, links: [buildBotName]),
    ];
    unawaited(showAgentsDialog(ctx));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('agent-name')), 'jarvis');
    await t.tap(find.byKey(const Key('label-5')));
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('16_agent_token_snippets', (t) async {
    const name = '16_agent_token_snippets';
    final (_, _, ctx) = await home(t);
    unawaited(showXDialogForTest(
      ctx,
      const AgentsDialog(
        initialName: 'jarvis',
        initialToken: 'xat_k3v9q2m7x1c8b4n6p0z5r2t7y4w1e8u3i6o9a2s5d8f',
        initialTokenFile: '/Users/owner/.local/share/antenna/agents/jarvis.token',
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // History verification and rekey (x-control/2).

  _s('17_history_mismatch', (t) async {
    const name = '17_history_mismatch';
    final bad = contact(emilyName, 11, trust: 4, lamport: 14, created: DateTime(2026, 9, 28, 19, 4),
        history: mismatchHistory(11));
    final m = await _model(_demo(contacts: [bad, jordan, buildBot, ryan, rachel]));
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('18_rekey_contact_asks', (t) async {
    const name = '18_rekey_contact_asks';
    final peer = contact(emilyName, 11, trust: 4, lamport: 14, created: DateTime(2026, 9, 28, 19, 4),
        history: const HistoryStatus(state: 'peer_rolled_back', sendBlocked: true, rollback: 'contact_numbers',
            detail: 'The contact restored an old copy: delivery waits for a rekey.'));
    final m = await _model(_demo(contacts: [peer, jordan, buildBot, ryan, rachel]));
    m.handleEvent(RekeyEvent(contact: emilyName, state: 'requested_by_contact'));
    await _frame(t, XApp(model: m));
    await t.enterText(find.byKey(const Key('sas-input')), '3051');
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 300));
    await _snap(t, name);
  });

  _s('19_rekey_my_code', (t) async {
    const name = '19_rekey_my_code';
    final mine = contact(emilyName, 11, trust: 4, lamport: 14, created: DateTime(2026, 9, 28, 19, 4),
        history: const HistoryStatus(state: 'rolled_back', sendBlocked: true, rollback: 'local_counter',
            detail: 'This node restored an old copy of the link state.'));
    final m = await _model(_demo(contacts: [mine, jordan, buildBot, ryan, rachel]));
    m.rekeyOf(mine.linkId)
      ..stage = RekeyStage.myCodeShown
      ..code = '305172'
      ..codeEmoji = '\u{1F40E}\u{1F436}\u{1F437}\u{1F431}\u{1F430}\u{1F981}';
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('20_login', (t) async {
    const name = '20_login';
    final d = _demo()..sessionToken = null;
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  // Navigation sections and the dark theme.

  _s('21_agents', (t) async {
    const name = '21_agents';
    final d = _demo();
    // v6: each agent says whether it reads messages to everyone (the switch).
    d.agentList = [
      AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 4, links: [jordanName, buildBotName], everyone: true),
      AgentInfo(name: 'codex-infra', createdMs: 0, localLevel: 3, links: [buildBotName], everyone: false),
    ];
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('22_settings', (t) async {
    const name = '22_settings';
    final m = await _model(_demo(), host: FakeHost(FakeDaemon()));
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    // The general settings (theme, language); Profile, the first section, has its own frame (80)
    await t.tap(find.byKey(const Key('settings-general')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // The one "Secure" indicator (D-UI-24) with its popover pinned open: the facts in plain words.
  _s('52_secure_details', (t) async {
    const name = '52_secure_details';
    await home(t);
    await t.tap(find.byKey(const Key('secure-indicator')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('52_secure_details_dark', (t) async {
    const name = '52_secure_details_dark';
    final m = await _model(_demo());
    await _frame(t, _dark(m));
    await t.tap(find.byKey(const Key('secure-indicator')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // Minimal settings (D-UI-24): one line per setting, the explanation behind the "?" (here the local network's).
  _s('53_settings_help', (t) async {
    const name = '53_settings_help';
    final m = await _model(_demo()..lanEnabled = false);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('settings-network')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('help-lan')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('23_card', (t) async {
    const name = '23_card';
    await home(t);
    await t.tap(find.byKey(const Key('card-toggle')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('04_home_chat_dark', (t) async {
    const name = '04_home_chat_dark';
    final m = await _model(_demo());
    await _frame(t, _dark(m));
    await _snap(t, name);
  });

  _s('10_approvals_dark', (t) async {
    const name = '10_approvals_dark';
    final m = await _model(_demo(approvals: [demoApproval()]));
    await _frame(t, _dark(m));
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

}

/// Show a dialog the way the app does (for scenarios).
Future<void> showXDialogForTest(BuildContext ctx, Widget dialog) => showDialog<void>(
      context: ctx,
      barrierColor: XColors.scrim,
      builder: (_) => dialog,
    );
