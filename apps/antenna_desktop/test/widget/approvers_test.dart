// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents in the window (CONTROL §31, PG-57; experimental), on the fake daemon: an agent's "Can approve
// for…" names it with the red warning first and then the password (or one touch), sending exactly the chosen scope;
// narrowing and Off send neither; widening asks again; an own computer's agent is named from Agents and from My
// devices, and a stale one names again; the approval cards say who may answer, why an agent's answer did not count,
// and who decided in the owner's place with its reason quoted; the approvers list revokes without a password and
// shows the answers; My devices says which requests this computer's agents may answer; an older daemon offers none.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_approvers.dart';
import '../support/fake_daemon.dart';
import '../support/fake_touch_id.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
const _pw = 'correct horse battery';

Future<(AppModel, FakeDaemon)> _model({
  List<ApproverInfo> approvers = const [],
  List<DelegatedAnswer> answers = const [],
  List<ApprovalInfo> approvals = const [],
  bool enabled = true,
  FakeTouchId? touch,
}) async {
  final demo = approversDemo();
  final d = FakeDaemon(contacts: demo.contacts, approvals: [...approvals])
    ..agentList = demo.agents
    ..approversEnabled = enabled
    ..approverList = [...approvers]
    ..answerList = [...answers];
  if (touch != null) touch.preset(touch.dirFor(d.socketPath), d.ownerKeys);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, touchId: touch);
  await m.connect();
  if (touch != null) await m.refreshTouchId();
  return (m, d);
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(Key(k));

Future<void> _agents(WidgetTester t) async {
  await t.tap(_key('agents-button'));
  await _settle(t);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

/// Through the warning and the password prompt.
Future<void> _acceptAndType(WidgetTester t, String password) async {
  expect(_key('approver-warning'), findsOneWidget);
  await _tap(t, _key('approver-warning-accept'));
  await t.enterText(_key('owner-password'), password);
  await _tap(t, _key('password-ok'));
}

DelegatedAnswer _answer(String id, String decision, {String? device, String reason = 'the build report'}) =>
    DelegatedAnswer(
      approvalId: id,
      action: 'send_message',
      requester: 'builder',
      contact: 'Mac mini',
      target: 'Build server',
      approver: device == null ? 'volna' : 'session-2',
      device: device,
      decision: decision,
      reason: reason,
      atMs: fixedNow.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch,
    );

void main() {
  testWidgets('naming an approver: the red warning before anything is sent, then the password; the exact scope goes',
      (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _agents(t);
    expect(d.approversListCalls, 1, reason: 'the Agents page asks the daemon first');
    await _tap(t, _key('agent-approver-edit-volna'));
    expect(find.textContaining(en.approverTitle('volna')), findsOneWidget);
    expect(_key('experimental-approver-dialog'), findsOneWidget);
    await _tap(t, _key('approver-on'));
    await _tap(t, _key('approver-agents-chosen'));
    expect(_key('approver-agent-volna'), findsNothing, reason: 'an approver never answers its own requests');
    await _tap(t, _key('approver-agent-builder'));
    for (final k in ['share_file', 'request_file', 'accept_file']) {
      await _tap(t, _key('approver-kind-$k'));
    }
    expect(_key('approver-note-widen'), findsOneWidget, reason: 'the dialog says Save asks for the password');

    // Save: the warning, red, before anything goes to the daemon; Cancel sends nothing
    await _tap(t, _key('approver-save'));
    expect(_key('approver-warning'), findsOneWidget);
    expect(find.text(en.approverWarnBody('volna')), findsOneWidget);
    final icon = t.widget<Icon>(find.descendant(of: _key('approver-warning'), matching: find.byIcon(Icons.gpp_maybe_outlined)));
    expect(icon.color, XColors.danger, reason: 'red at the moment of choosing (D-UI-30)');
    final accept = t.widget<FilledButton>(_key('approver-warning-accept'));
    expect(accept.style!.foregroundColor!.resolve({}), XColors.danger, reason: 'the confirm is red too');
    expect(_key('owner-password'), findsNothing, reason: 'the password comes after the warning');
    expect(d.approverCalls, isEmpty);
    await _tap(t, _key('approver-warning-cancel'));
    expect(d.approverCalls, isEmpty, reason: 'cancelled: nothing named');
    expect(m.approverOf('volna'), isNull);

    // Save again: the warning again, then the password
    await _tap(t, _key('approver-save'));
    await _acceptAndType(t, _pw);
    expect(d.approverCalls.single, {
      'cmd': 'approver_set',
      'name': 'volna',
      'agents': ['builder'],
      'kinds': ['send_message'],
      'password': _pw,
    });
    expect(_key('approver-save'), findsNothing, reason: 'done: the dialog closed');
    expect(find.text(en.approverRow(en.approverScope('builder', en.approverKindSendShort))), findsOneWidget);
  });

  testWidgets('a wrong password: the daemon refuses, the dialog says so; the next Save asks only for the password',
      (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _agents(t);
    await _tap(t, _key('agent-approver-edit-volna'));
    await _tap(t, _key('approver-on'));
    await _tap(t, _key('approver-save'));
    await _acceptAndType(t, 'not the password');
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(m.approverOf('volna'), isNull);
    await _tap(t, _key('approver-save'));
    expect(_key('approver-warning'), findsNothing, reason: 'accepted once in this dialog');
    await t.enterText(_key('owner-password'), _pw);
    await _tap(t, _key('password-ok'));
    expect([for (final c in d.approverCalls) c['password']], ['not the password', _pw]);
    expect(d.approverCalls.last.containsKey('agents'), isFalse, reason: 'all agents: no list');
    expect(d.approverCalls.last.containsKey('kinds'), isFalse, reason: 'every kind: no list');
    expect(m.approverOf('volna')?.agents, isNull);
  });

  testWidgets('narrowing needs no password and no warning; widening back asks for both', (t) async {
    final (m, d) = await _model(approvers: const [ApproverInfo(agent: 'volna', createdMs: 0)]);
    await _app(t, m);
    await _agents(t);
    expect(find.text(en.approverRow(en.approverScope(en.approverAgentsAll, en.approverKindsAll))), findsOneWidget);
    await _tap(t, _key('agent-approver-edit-volna'));
    await _tap(t, _key('approver-kind-share_file'));
    expect(_key('approver-note-narrow'), findsOneWidget);
    await _tap(t, _key('approver-save'));
    expect(_key('approver-warning'), findsNothing);
    expect(_key('owner-password'), findsNothing);
    expect(d.approverCalls.single, {
      'cmd': 'approver_narrow',
      'name': 'volna',
      'kinds': ['send_message', 'request_file', 'accept_file'],
    });
    // Negative control: the same dialog, the kind ticked again, is wider than what the daemon has now
    await _tap(t, _key('agent-approver-edit-volna'));
    await _tap(t, _key('approver-kind-share_file'));
    expect(_key('approver-note-widen'), findsOneWidget);
    await _tap(t, _key('approver-save'));
    expect(_key('approver-warning'), findsOneWidget, reason: 'widening shows the warning');
    await _acceptAndType(t, _pw);
    expect(d.approverCalls.last['cmd'], 'approver_set');
    expect(d.approverCalls.last['password'], _pw);
    expect(m.approverOf('volna')?.kinds, isNull);
  });

  testWidgets('Off removes it without a password', (t) async {
    final (m, d) = await _model(approvers: const [
      ApproverInfo(agent: 'volna', createdMs: 0, agents: ['builder'])
    ]);
    await _app(t, m);
    await _agents(t);
    await _tap(t, _key('agent-approver-edit-volna'));
    await _tap(t, _key('approver-off'));
    expect(_key('approver-note-narrow'), findsOneWidget);
    await _tap(t, _key('approver-save'));
    expect(_key('owner-password'), findsNothing);
    expect(d.approverCalls.single, {'cmd': 'approver_remove', 'name': 'volna'});
    expect(m.approverOf('volna'), isNull);
    expect(find.textContaining(en.approverRow('')), findsNothing);
  });

  testWidgets('Touch ID: after the warning, one touch names it; the signed request carries no password', (t) async {
    final touch = FakeTouchId();
    final (m, d) = await _model(touch: touch);
    expect(m.touchIdReady, isTrue);
    await _app(t, m);
    await _agents(t);
    await _tap(t, _key('agent-approver-edit-volna'));
    await _tap(t, _key('approver-on'));
    await _tap(t, _key('approver-save'));
    expect(touch.prompts, isEmpty, reason: 'no Touch ID sheet before the warning is accepted');
    await _tap(t, _key('approver-warning-accept'));
    expect(_key('owner-password'), findsNothing);
    expect(touch.prompts.single.reason, en.touchIdReasonApprover('volna'));
    expect(touch.prompts.single.request, contains('"cmd":"approver_set"'));
    expect(d.approverCalls.single, {'cmd': 'approver_set', 'name': 'volna', 'password': '', 'proof': true});
    expect(m.approverOf('volna'), isNotNull);
  });

  testWidgets('an own computer\'s agent: from Agents and from My devices; a stale one says so and names again',
      (t) async {
    final (m, d) = await _model(approvers: [
      ApproverInfo(agent: 'lead', contact: 'Build server', linkId: contact('Build server', 62).linkId, stale: true, createdMs: 0),
    ]);
    d
      ..devicesEnabled = true
      ..devicesState = DevicesReply(
        self: const ThisDevice(name: 'Mayas-MacBook-Pro', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
        devices: [
          DeviceInfo(
            contact: 'Mac mini',
            linkId: contact('Mac mini', 61).linkId,
            presence: 'online',
            supported: true,
            status: DeviceView(
              atMs: fixedNow.millisecondsSinceEpoch,
              name: 'Mac-mini',
              os: 'macos',
              arch: 'aarch64',
              version: 'antennad 0.2.0',
              agents: const [DeviceAgent(name: 'session-2', app: 'claude', state: 'connected')],
            ),
          ),
        ],
      );
    await m.refreshDevices();
    await _app(t, m);
    await _agents(t);
    // A level-5 contact's agent has the action; a contact below ∞ has none (Emily has no agents here)
    expect(_key('contact-agent-approver-Mac mini-session-2'), findsOneWidget);
    expect(t.widget<Text>(_key('contact-agent-approver-line-Build server-lead')).data, en.approverStale('Build server'));
    await _tap(t, _key('contact-agent-approver-Mac mini-session-2'));
    expect(find.textContaining(en.approverTitle(en.approverOnDevice('session-2', 'Mac mini'))), findsOneWidget);
    await _tap(t, _key('approver-on'));
    await _tap(t, _key('approver-save'));
    expect(find.text(en.approverWarnBody(en.approverOnDevice('session-2', 'Mac mini'))), findsOneWidget);
    await _acceptAndType(t, _pw);
    expect(d.approverCalls.single, {'cmd': 'approver_set', 'name': 'session-2', 'contact': 'Mac mini', 'password': _pw});

    // The stale one: its key was revoked there; Name it again takes the warning and the password, same scope
    await _tap(t, _key('contact-agent-approver-Build server-lead'));
    expect(_key('approver-stale'), findsOneWidget);
    await _tap(t, _key('approver-name-again'));
    await _acceptAndType(t, _pw);
    expect(d.approverCalls.last, {'cmd': 'approver_set', 'name': 'lead', 'contact': 'Build server', 'password': _pw});
    await t.tap(find.text(en.commonCancel).last);
    await _settle(t);

    // My devices: the same action on that computer's agents
    await t.tap(_key('nav-devices'));
    await _settle(t);
    expect(_key('device-agent-approver-Mac mini-session-2'), findsOneWidget);
    await _tap(t, _key('device-agent-approver-Mac mini-session-2'));
    expect(find.textContaining(en.approverTitle(en.approverOnDevice('session-2', 'Mac mini'))), findsOneWidget);
    expect(t.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue, isTrue, reason: 'named above');
  });

  testWidgets('a pending card: who may answer it; an answer that did not count says why, for each reason', (t) async {
    final (m, _) = await _model(approvals: [
      approverRequest('ap-1', answerableBy: const ['volna', 'session-2@Mac mini']),
    ]);
    await m.refreshApprovals();
    await _app(t, m);
    await m.select(contact('Build server', 62).linkId);
    await _settle(t);
    expect(find.text(en.approvalAnswerableBy('volna, ${en.approverOnDevice('session-2', 'Mac mini')}')), findsOneWidget);
    expect(_key('approval-refused-ap-1'), findsNothing);

    final whys = {
      DelegateWhy.scope: en.delegateWhyScope('volna'),
      DelegateWhy.self: en.delegateWhySelf('volna'),
      DelegateWhy.chain: en.delegateWhyChain('builder'),
      DelegateWhy.tainted: en.delegateWhyTainted('volna'),
      DelegateWhy.outside: en.delegateWhyOutside,
      DelegateWhy.levelChanged: en.delegateWhyLevelChanged,
      DelegateWhy.unverified: en.delegateWhyUnverified('volna'),
      'something new': 'the daemon\'s own words',
    };
    for (final MapEntry(key: why, value: text) in whys.entries) {
      m.handleEvent(ApprovalEvent(approverRequest('ap-1',
          refused: DelegateNote(agent: 'volna', why: why, message: 'the daemon\'s own words', atMs: 1))));
      await _settle(t);
      expect(find.text(en.approvalRefusedTitle('volna')), findsOneWidget, reason: why);
      expect(t.widget<Text>(_key('approval-refused-why-ap-1')).data, text, reason: why);
      expect(find.text(en.approvalRefusedYours), findsOneWidget);
      // The person still answers: Approve and Deny stay
      expect(_key('approve-ap-1'), findsOneWidget);
      expect(_key('deny-ap-1'), findsOneWidget);
    }
    m.handleEvent(ApprovalEvent(approverRequest('ap-1',
        refused: const DelegateNote(agent: 'session-2', device: 'Mac mini', why: 'unverified', atMs: 1))));
    await _settle(t);
    expect(t.widget<Text>(_key('approval-refused-why-ap-1')).data, en.delegateWhyUnverified('Mac mini'));
  });

  testWidgets('decided by an approver: who, on which computer, its reason quoted; in the chat and in the list; '
      'one card while Antenna finishes it; Change opens the approvers; Dismiss', (t) async {
    final (m, d) = await _model(
      approvers: const [ApproverInfo(agent: 'volna', createdMs: 0)],
      approvals: [approverRequest('ap-2'), approverRequest('ap-3', action: 'share_file', minutesAgo: 2)],
      answers: [_answer('ap-2', 'approved')],
    );
    await m.refreshApprovals();
    await m.refreshApprovers();
    await _app(t, m);
    await m.select(contact('Build server', 62).linkId);
    await _settle(t);
    const reason = 'The build summary for my own server, as the task asked.';
    m.handleEvent(ApprovalEvent(approverRequest('ap-2',
        state: 'approved', decidedBy: DecidedBy(agent: 'volna', reason: reason, atMs: fixedNow.millisecondsSinceEpoch))));
    m.handleEvent(ApprovalEvent(approverRequest('ap-3',
        action: 'share_file',
        minutesAgo: 2,
        state: 'denied',
        decidedBy: DecidedBy(agent: 'session-2', device: 'Mac mini', reason: 'Not this file.', atMs: 1))));
    await _settle(t);
    // Who decided, in words: never a decision without its approver's name
    expect(t.widget<Text>(_key('decided-title-ap-2')).data, en.decidedApprovedBy('volna'));
    expect(t.widget<Text>(_key('decided-title-ap-3')).data, en.decidedDeniedByOn('session-2', 'Mac mini'));
    expect(find.descendant(of: _key('decided-reason-ap-2'), matching: find.text(reason)), findsOneWidget);
    expect(find.text(en.decidedReasonLabel('volna')), findsOneWidget);
    expect(find.text(en.decidedFinishing), findsOneWidget, reason: 'approved: Antenna carries it out');
    expect(_key('chat-approval-card-ap-2'), findsNothing, reason: 'one card per request, not a finishing card too');
    expect(_key('approve-ap-2'), findsNothing);

    // The daemon finished it: the decided card stays until dismissed
    m.handleEvent(const ApprovalResolvedEvent(id: 'ap-2', state: 'completed', decidedBy: DecidedBy(agent: 'volna', reason: reason, atMs: 1)));
    await _settle(t);
    expect(find.text(en.decidedFinishing), findsNothing);
    expect(_key('decided-ap-2'), findsOneWidget);

    // In Approval requests too, under its own title, above a request that still waits
    m.handleEvent(ApprovalEvent(approverRequest('ap-4', minutesAgo: 0)));
    await _settle(t);
    await _tap(t, _key('approval-details-ap-4'));
    expect(_key('decided-title'), findsOneWidget);
    expect(find.descendant(of: find.byType(Dialog), matching: _key('decided-ap-2')), findsOneWidget);
    expect(find.descendant(of: find.byType(Dialog), matching: _key('decided-ap-3')), findsOneWidget);
    expect(find.text(en.decidedSectionTitle), findsOneWidget);

    // Change: the approvers and their answers
    await _tap(t, find.descendant(of: find.byType(Dialog).last, matching: _key('decided-change-ap-2')));
    expect(_key('approvers-dialog'), findsOneWidget);
    expect(_key('approver-row-/volna'), findsOneWidget);
    expect(find.text(en.approversAnswerApproved('volna', 'builder', '${en.actionSendMessage} → Build server')), findsOneWidget);
    await t.tap(find.text(en.commonClose).last);
    await _settle(t);
    await _tap(t, find.descendant(of: find.byType(Dialog).last, matching: _key('decided-dismiss-ap-2')));
    expect(m.decidedByApprovers.containsKey('ap-2'), isFalse);
    expect(d.approverCalls, isEmpty, reason: 'reading and dismissing change nothing');
  });

  testWidgets('the approvers list on the Agents page: scope, a stale one, Revoke without a password, the answers',
      (t) async {
    final (m, d) = await _model(
      approvers: [
        const ApproverInfo(agent: 'volna', createdMs: 0, agents: ['builder'], kinds: ['send_message', 'share_file']),
        ApproverInfo(agent: 'session-2', contact: 'Mac mini', linkId: contact('Mac mini', 61).linkId, stale: true, createdMs: 0),
      ],
      answers: [
        _answer('ap-1', 'approved'),
        _answer('ap-2', 'denied', device: 'Mac mini', reason: 'Not this file.'),
        _answer('ap-3', 'refused', reason: 'its session read a contact below level 5'),
        _answer('ap-4', 'approved'),
      ],
    );
    await _app(t, m);
    await _agents(t);
    expect(_key('approvers-section'), findsOneWidget);
    final what = '${en.actionSendMessage} → Build server';
    expect(find.text(en.approverScope('builder', '${en.approverKindSendShort}, ${en.approverKindShareShort}')),
        findsOneWidget);
    expect(_key('approver-row-stale-session-2'), findsOneWidget);
    expect(find.text(en.approversAnswerApproved('volna', 'builder', what)), findsOneWidget);
    expect(find.text(en.approversAnswerDenied(en.approverOnDevice('session-2', 'Mac mini'), 'builder', what)),
        findsOneWidget);
    expect(find.text(en.approversAnswerRefused('volna', 'builder', what)), findsOneWidget);
    expect(find.text('“Not this file.”'), findsOneWidget, reason: 'the reason, quoted');
    expect(find.text(en.approversAllAnswers(4)), findsOneWidget, reason: 'three shown, the rest in the dialog');
    await _tap(t, _key('approver-revoke-Mac mini/session-2'));
    expect(_key('owner-password'), findsNothing);
    expect(d.approverCalls.single, {'cmd': 'approver_remove', 'name': 'session-2', 'contact': 'Mac mini'});
    expect(_key('approver-row-Mac mini/session-2'), findsNothing);
  });

  testWidgets('an answer that did not count says why in the window\'s words; a change from elsewhere is read again',
      (t) async {
    final refused = DelegatedAnswer(
      approvalId: 'ap-9',
      action: 'send_message',
      requester: 'builder',
      contact: 'Mac mini',
      target: 'Build server',
      approver: 'volna',
      decision: 'refused',
      reason: 'the daemon words in English',
      why: DelegateWhy.tainted,
      atMs: fixedNow.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );
    final (m, d) = await _model(
      approvers: [const ApproverInfo(agent: 'volna', createdMs: 0)],
      answers: [refused],
    );
    await _app(t, m);
    await _agents(t);
    expect(_key('approver-answer-why-ap-9'), findsOneWidget);
    expect(find.text(en.delegateWhyTainted('volna')), findsOneWidget, reason: 'the code, in this window\'s words');
    expect(find.text('the daemon words in English'), findsNothing);
    // The CLI (or another window) names another approver: the agent event says so, and the list is read again
    d.approverList.add(const ApproverInfo(agent: 'builder', createdMs: 0));
    final before = d.calls.where((c) => c == 'approvers').length;
    m.handleEvent(const AgentEvent(name: 'builder', change: 'approver'));
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    expect(d.calls.where((c) => c == 'approvers').length, before + 1);
    expect(_key('approver-row-/builder'), findsOneWidget);
    // An own computer's approver changed: the device event
    m.handleEvent(DeviceEvent(contact: 'Mac mini', linkId: contact('Mac mini', 61).linkId, change: 'approvers'));
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    expect(d.calls.where((c) => c == 'approvers').length, before + 2);
  });

  testWidgets('My devices: a request this computer\'s agent may answer says so; which agents that computer accepts',
      (t) async {
    final (m, d) = await _model(approvers: const [ApproverInfo(agent: 'volna', createdMs: 0)]);
    final now = fixedNow.millisecondsSinceEpoch;
    d
      ..devicesEnabled = true
      ..devicesState = DevicesReply(
        self: const ThisDevice(name: 'Mayas-MacBook-Pro', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
        devices: [
          DeviceInfo(
            contact: 'Mac mini',
            linkId: contact('Mac mini', 61).linkId,
            presence: 'online',
            supported: true,
            receivedMs: now,
            status: DeviceView(
              atMs: now,
              name: 'Mac-mini',
              os: 'macos',
              arch: 'aarch64',
              version: 'antennad 0.2.0',
              approvers: const [StatusApprover(agent: 'volna', kinds: ['send_message'])],
              approvals: [
                DeviceApproval(
                  id: 'k9',
                  action: 'send_message',
                  requester: 'session-2',
                  contact: 'Mayas-MacBook-Pro',
                  contactTrust: 5,
                  fingerprint: '0011223344556677',
                  createdMs: now,
                  expiresMs: now + 600000,
                  approvers: const ['volna'],
                ),
                DeviceApproval(
                  id: 'k8',
                  action: 'check:exec',
                  requester: 'codex',
                  contact: 'Mayas-MacBook-Pro',
                  contactTrust: 5,
                  fingerprint: 'ffeeddccbbaa9988',
                  createdMs: now,
                  expiresMs: now + 600000,
                ),
              ],
              pendingApprovals: 2,
            ),
          ),
        ],
      );
    await m.refreshDevices();
    await _app(t, m);
    await t.tap(_key('nav-devices'));
    await _settle(t);
    expect(_key('device-request-approvers-k9'), findsOneWidget);
    expect(find.text(en.devicesRequestApprovers('volna')), findsOneWidget);
    expect(_key('device-request-approvers-k8'), findsNothing, reason: 'a tool check stays with the person');
    expect(find.text(en.devicesAcceptsApprovers('Mac mini', 'volna (${en.approverScope(en.approverAgentsAll, en.approverKindSendShort)})')),
        findsOneWidget);
  });

  testWidgets('the agent\'s card says what it answers on another computer, set there', (t) async {
    final (m, _) = await _model();
    await _app(t, m);
    await _agents(t);
    expect(find.text(en.approverRowThere('Mac mini')), findsOneWidget);
  });

  testWidgets('an older daemon: no "Can approve for…", no approvers section, nothing sent but the probe', (t) async {
    final (m, d) = await _model(enabled: false, approvals: [approverRequest('ap-1')]);
    await m.refreshApprovals();
    await _app(t, m);
    await _agents(t);
    expect(m.approversAbsent, isTrue);
    expect(_key('agent-approver-edit-volna'), findsNothing);
    expect(_key('contact-agent-approver-Mac mini-session-2'), findsNothing);
    expect(_key('approvers-section'), findsNothing);
    expect(d.approverCalls, isEmpty);
    // A card from an older daemon carries none of the fields: nothing about approvers on it
    await m.select(contact('Build server', 62).linkId);
    await _settle(t);
    expect(_key('approval-answerable-ap-1'), findsNothing);
    expect(_key('approval-refused-ap-1'), findsNothing);
  });
}
