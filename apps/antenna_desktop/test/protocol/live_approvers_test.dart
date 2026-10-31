// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents (x-control/7, CONTROL §31, PG-57; experimental) against REAL daemons: the Mac mini (this computer,
// the window) and its two own computers, the laptop and the build server, all at ∞. The mini's agent builder reads a
// message of the laptop and asks to send a summary to the build server: a flow between links, so the request waits.
// From the window client the owner names volna an approver for builder's requests with the password; the request
// then says volna may answer it. volna, with its own token, reads the request and approves it with a reason: the
// daemon sends the message to the build server, and the window's subscription gets the request with `decided_by`
// (volna and its reason). Narrowing takes no password (a wider scope answers `password_required`); removing takes none;
// afterwards volna's answer to a new request does not count, and the card says why (`scope`).
// Run: ANTENNAD_BIN=<path to a debug antennad> flutter test --tags live test/protocol/live_approvers_test.dart
// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 45), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Pair [a] (inviting) and [b] at [trust] both ways; [a] calls [b] by [bn]'s name and the other way round.
Future<void> _pair(XControlClient a, XdNode an, XControlClient b, XdNode bn, int trust) async {
  final inv = Events(a.open(InviteRequest(trust: trust, ttlSecs: 120, label: bn.name, password: an.password)));
  final created = await inv.next<InviteCreated>();
  final join = Events(b.open(JoinRequest(
    link: created.link,
    trust: trust,
    label: an.name,
    connectTimeoutMs: 5000,
    password: bn.password,
  )));
  final sas = await inv.next<SasEvent>();
  await join.next<NeedInput>((e) => e.isSasCode);
  join.dialog.input(SasCodeInput(sas.code));
  await inv.next<NeedInput>((e) => e.isConfirm);
  inv.dialog.input(ConfirmInput(true, code: sas.code));
  await join.dialog.result;
}

/// One agent request over the agent's own connection (its token): (true, the `ok` body) or (false, the `err` body).
Future<(bool, Map<String, Object?>)> _agent(String socket, String token, Map<String, Object?> req) async {
  final s = await Socket.connect(InternetAddress(socket, type: InternetAddressType.unix), 0);
  try {
    s.write('${jsonEncode({'hello': {'proto': 'x-control/7', 'role': 'agent', 'token': token}})}\n');
    s.write('${jsonEncode({'req': req})}\n');
    await for (final line in s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
      final v = jsonDecode(line) as Map<String, Object?>;
      if (v['err'] case final Map<String, Object?> e) return (false, e);
      if (v['ok'] case final Map<String, Object?> ok) return (true, ok);
    }
    throw StateError('no reply');
  } finally {
    s.destroy();
  }
}

Future<Map<String, Object?>> _agentOk(String socket, String token, Map<String, Object?> req) async {
  final (ok, body) = await _agent(socket, token, req);
  if (!ok) throw StateError('agent request refused: $body');
  return body;
}

/// [agent] reads [text] from [from]'s owner (its session is then tainted with that link, at ∞).
Future<void> _readFrom(XControlClient from, String to, XdNode mini, String token, String agent, String text) async {
  await from.send(to, text, address: MessageAddress.agent(agent));
  await _until(() async {
    final r = await _agentOk(mini.socket, token, {'cmd': 'inbox', 'wait': false});
    final msgs = (r['messages'] as List?) ?? const [];
    return msgs.any((m) => m is Map && m['text'] == text);
  }, what: '$agent reads "$text"');
}

/// An agent's send that waits for approval: the request.
Future<ApprovalInfo> _pendingSend(XdNode mini, String token, String to, String text) async {
  final (ok, e) = await _agent(mini.socket, token, {'cmd': 'send', 'contact': to, 'text': text, 'wait_ms': 0});
  expect((ok, e['code']), (false, 'approval_required'), reason: '$e');
  return ApprovalInfo.fromJson(e['approval']! as Map<String, Object?>);
}

void main() {
  final antennad = findXd();

  test('the window names volna an approver; volna approves builder\'s request; narrowed and removed without a password',
      () async {
    final root = await tempRoot();
    final mini = XdNode('mini', root, antennad!);
    final lap = XdNode('lap', root, antennad);
    final srv = XdNode('srv', root, antennad);
    await Future.wait([mini.start(), lap.start(), srv.start()]);
    AppModel? m;
    try {
      final c = XControlClient(mini.socket);
      final l = XControlClient(lap.socket);
      final s = XControlClient(srv.socket);
      await c.init(mini.password);
      await l.init(lap.password);
      await s.init(srv.password);
      await openOwnerSession(c, mini.password);
      await openOwnerSession(l, lap.password);
      await openOwnerSession(s, srv.password);
      await _pair(c, mini, l, lap, 5);
      await _pair(c, mini, s, srv, 5);
      final builder = (await c.agentAdd('builder', localLevel: 0, password: mini.password)).token;
      final volna = (await c.agentAdd('volna', localLevel: 0, password: mini.password)).token;

      final w = AppModel(connector: XControlClient.new, socketPath: mini.socket);
      m = w;
      await w.connect();
      expect(await w.login(mini.password), isNull);
      await w.refreshApprovers();
      expect(w.approversKnown, isTrue, reason: 'this daemon answers `approvers`');
      expect(w.approvers!.approvers, isEmpty);

      // builder reads the laptop's message and asks to send to the build server: a flow between links waits
      await _readFrom(l, 'mini', mini, builder, 'builder', 'the nightly build finished: 2 warnings');
      final first = await _pendingSend(mini, builder, 'srv', 'summary for the server: 2 warnings');
      expect(first.completes, isTrue);
      await w.refreshApprovals();
      expect(w.approvals[first.id]?.answerableBy, isEmpty, reason: 'nobody may answer it yet');

      // Named from the window with the password: whose requests and which kinds
      expect(
          await w.setApprover(const ApproverSetRequest(name: 'volna', agents: ['builder'], password: 'wrong password')),
          isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      expect(w.approvers!.approvers, isEmpty);
      expect(await w.setApprover(ApproverSetRequest(name: 'volna', agents: const ['builder'], password: mini.password)),
          isNull);
      expect(w.approverOf('volna')?.agents, ['builder']);
      expect(w.approverOf('volna')?.kinds, isNull);
      await _until(() async {
        await w.refreshApprovals();
        return w.approvals[first.id]?.answerableBy.contains('volna') ?? false;
      }, what: 'the card says volna may answer it');
      final session = await _agentOk(mini.socket, volna, {'cmd': 'session'});
      expect(jsonEncode(session), contains('"approves"'), reason: 'volna sees what it may answer');
      print('NAMED: volna answers for builder; the request says so');

      // volna reads the request (as data) and approves it with a reason
      final toAnswer = await _agentOk(mini.socket, volna, {'cmd': 'approvals_to_answer'});
      final req = ((toAnswer['requests']! as List).cast<Map<String, Object?>>()).firstWhere((r) => r['id'] == first.id);
      expect(req['quote'], 'summary for the server: 2 warnings');
      const reason = 'the build summary for my own server, as the task said';
      final answered = await _agentOk(mini.socket, volna, {
        'cmd': 'approval_answer',
        'id': first.id,
        'decision': 'approve',
        'fingerprint': req['fingerprint'],
        'reason': reason,
      });
      expect(answered['state'], 'approved', reason: '$answered');

      // The window's subscription: decided by volna, with its reason; the build server got the message
      await _until(() async => w.decidedByApprovers.containsKey(first.id), what: 'the window hears volna decided');
      final decided = w.decidedByApprovers[first.id]!;
      expect((decided.decidedBy!.agent, decided.decidedBy!.device, decided.decidedBy!.reason), ('volna', null, reason));
      expect(w.approvals.containsKey(first.id), isFalse, reason: 'no longer waiting for the owner');
      expect(w.decidedFor(w.contacts.firstWhere((x) => x.label == 'srv').linkId).map((a) => a.id), [first.id]);
      await _until(() async {
        final h = await s.history('mini', limit: 50);
        return h.messages.any((x) => x.text == 'summary for the server: 2 warnings');
      }, what: 'the build server gets the summary');
      await _until(() async {
        await w.refreshApprovers();
        return w.approvers!.answers.any((a) => a.approvalId == first.id && a.decision == AnswerDecision.approved);
      }, what: 'the answer in the approvers list');
      print('APPROVED by volna: "$reason"; sent to srv');

      // Narrowed without a password (the request has no password field); a wider scope is refused
      expect(await w.narrowApprover(const ApproverNarrowRequest(name: 'volna', agents: ['builder'], kinds: ['send_message'])),
          isNull);
      expect(w.approverOf('volna')?.kinds, ['send_message']);
      expect(await w.narrowApprover(const ApproverNarrowRequest(name: 'volna', agents: ['builder'])),
          isA<XControlException>().having((e) => e.code, 'code', XErrorCode.passwordRequired),
          reason: 'every kind is wider than one: narrowing cannot widen');
      expect(w.approverOf('volna')?.kinds, ['send_message']);

      // Removed without a password; then volna's answer does not count, and the card says why
      expect(await w.removeApprover('volna'), isNull);
      expect(w.approvers!.approvers, isEmpty);
      await _readFrom(l, 'mini', mini, builder, 'builder', 'and the changelog, please');
      final second = await _pendingSend(mini, builder, 'srv', 'changelog: fixed the wake');
      final (ok, refused) = await _agent(mini.socket, volna, {
        'cmd': 'approval_answer',
        'id': second.id,
        'decision': 'approve',
        'fingerprint': second.fingerprint,
        'reason': 'looks fine',
      });
      expect(ok, isFalse, reason: '$refused');
      await _until(() async => w.approvals[second.id]?.delegateRefused != null, what: 'the card hears it did not count');
      expect(w.approvals[second.id]!.delegateRefused!.why, DelegateWhy.scope);
      expect(w.approvals[second.id]!.pending, isTrue, reason: 'it waits for the person');
      print('REMOVED: volna\'s answer to ${second.id} did not count (scope)');
    } finally {
      m?.dispose();
      await Future.wait([mini.stop(), lap.stop(), srv.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 4)));
}
