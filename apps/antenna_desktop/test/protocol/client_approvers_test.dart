// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents on the wire (x-control/7, CONTROL §31; the shapes of crates/antenna-proto/src/control/approvers.rs):
// the four owner commands carry exactly their fields (absent scope = all, the password only on `approver_set`, never
// in toString), `approvers` becomes a typed reply, an approval carries `decided_by`, `delegate_refused` and
// `answerable_by` (absent from an older daemon), `approval_resolved` carries `decided_by`, an agent's
// `session.approves`, an own computer's status names this computer's approvers, and the agent's fact
// `approval_to_answer` parses. The scope rule matches the daemon's `within`, and the window's change rule follows it.

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/approvers.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _approval({Map<String, Object?> extra = const {}}) => {
      'id': 'k2abcdefg',
      'state': 'pending',
      'quiet': false,
      'requester': 'builder',
      'contact': 'lap',
      'contact_trust': 5,
      'action': 'send_message',
      'target': 'srv',
      'reasons': ['cross_link:lap'],
      'grants': {'read': '-', 'write': '-', 'commands': '-', 'send': 'text → srv'},
      'quote': 'summary for the server',
      'fingerprint': '9c41e07a3b5d0f12',
      'created_ms': 1,
      'expires_ms': 600001,
      'completes': true,
      ...extra,
    };

void main() {
  test('the four commands carry exactly their fields; the password only on approver_set, never printed', () {
    expect(const ApproverSetRequest(name: 'volna', password: 'pw').toJson(),
        {'cmd': 'approver_set', 'name': 'volna', 'password': 'pw'},
        reason: 'no scope: all agents, every kind');
    const set = ApproverSetRequest(
        name: 'session-2', contact: 'Mac mini', agents: ['builder'], kinds: ['send_message'], password: 'pw');
    expect(set.toJson(), {
      'cmd': 'approver_set',
      'name': 'session-2',
      'contact': 'Mac mini',
      'agents': ['builder'],
      'kinds': ['send_message'],
      'password': 'pw',
    });
    expect(set.withPassword('').toJson()['password'], '', reason: 'next to a proof');
    expect(set.withPassword('').toJson()['agents'], ['builder']);
    expect('$set', isNot(contains('pw')));
    expect(const ApproverNarrowRequest(name: 'volna', kinds: ['send_message']).toJson(),
        {'cmd': 'approver_narrow', 'name': 'volna', 'kinds': ['send_message']});
    expect(const ApproverNarrowRequest(name: 'volna').toJson().containsKey('password'), isFalse);
    expect(const ApproverRemoveRequest(name: 'session-2', contact: 'Mac mini').toJson(),
        {'cmd': 'approver_remove', 'name': 'session-2', 'contact': 'Mac mini'});
    expect(const ApproversRequest().toJson(), {'cmd': 'approvers'});
  });

  test('approvers: the delegations (null scope = all) and the answers, newest first', () {
    final r = Reply.fromJson({
      'type': 'approvers',
      'approvers': [
        {'agent': 'volna', 'agents': null, 'kinds': null, 'created_ms': 5},
        {
          'agent': 'session-2',
          'contact': 'Mac mini',
          'link_id': 'ab' * 32,
          'agents': ['builder'],
          'kinds': ['send_message', 'share_file'],
          'key_id': '9c41e07a3b5d0f12',
          'stale': true,
          'created_ms': 6,
        },
      ],
      'answers': [
        {
          'approval_id': 'k2abcdefg',
          'action': 'send_message',
          'requester': 'builder',
          'contact': 'lap',
          'target': 'srv',
          'approver': 'volna',
          'decision': 'approved',
          'reason': 'the build report for my own server',
          'summary': 'send text → srv',
          'at_ms': 9,
        },
        {
          'approval_id': 'k3',
          'action': 'share_file',
          'requester': 'builder',
          'contact': 'lap',
          'approver': 'session-2',
          'device': 'Mac mini',
          'decision': 'refused',
          'reason': 'the owner did not make this approver answer that agent\'s requests',
          'why': 'scope',
          'summary': '',
          'at_ms': 8,
        },
      ],
    }) as ApproversReply;
    expect(r.approvers.first.agents, isNull);
    expect(r.approvers.first.kinds, isNull);
    expect(r.approvers.first.local, isTrue);
    final remote = r.of('session-2', contact: 'Mac mini')!;
    expect((remote.stale, remote.keyId), (true, '9c41e07a3b5d0f12'));
    expect(remote.agents, ['builder']);
    expect(remote.kinds, ['send_message', 'share_file']);
    expect(r.of('session-2'), isNull, reason: 'the computer is part of who the approver is');
    expect((r.answers[0].decision, r.answers[0].target, r.answers[0].device), ('approved', 'srv', null));
    expect((r.answers[1].decision, r.answers[1].device), (AnswerDecision.refused, 'Mac mini'));
    expect((r.answers[1].why, r.answers[0].why), (DelegateWhy.scope, null), reason: 'the code of a refused answer');
  });

  test('an approval: who decided, an answer that did not count, who may answer; none from an older daemon', () {
    final old = ApprovalInfo.fromJson(_approval());
    expect((old.decidedBy, old.delegateRefused), (null, null));
    expect(old.answerableBy, isEmpty);

    final pending = ApprovalInfo.fromJson(_approval(extra: {
      'answerable_by': ['volna', 'session-2@Mac mini'],
      'delegate_refused': {
        'agent': 'codex',
        'device': 'Mac mini',
        'why': 'tainted',
        'message': 'its session read a contact below level 5',
        'at_ms': 7,
      },
    }));
    expect(pending.answerableBy, ['volna', 'session-2@Mac mini']);
    expect((pending.delegateRefused!.agent, pending.delegateRefused!.device, pending.delegateRefused!.why),
        ('codex', 'Mac mini', DelegateWhy.tainted));

    final decided = ApprovalInfo.fromJson(_approval(extra: {
      'state': 'approved',
      'decided_by': {'agent': 'volna', 'reason': 'the build report, as the task said', 'at_ms': 8},
    }));
    expect((decided.decidedBy!.agent, decided.decidedBy!.device, decided.decidedBy!.reason),
        ('volna', null, 'the build report, as the task said'));

    final e = XEvent.fromJson({
      'kind': 'approval_resolved',
      'id': 'k2abcdefg',
      'state': 'completed',
      'message': 'volna, an approver the owner named, approved it',
      'at_ms': 9,
      'decided_by': {'agent': 'session-2', 'device': 'Mac mini', 'reason': 'ok', 'at_ms': 9},
    }) as ApprovalResolvedEvent;
    expect((e.decidedBy!.agent, e.decidedBy!.device), ('session-2', 'Mac mini'));
  });

  test('an agent\'s session.approves; an own computer\'s status names this computer\'s approvers; the agent\'s fact', () {
    final a = AgentInfo.fromJson({
      'name': 'volna',
      'created_ms': 1,
      'session': {
        'approves': [
          {'agents': null, 'kinds': null},
          {
            'device': 'Mac mini',
            'agents': ['session-2'],
            'kinds': ['send_message'],
          },
        ],
      },
    });
    expect([for (final x in a.approves) x.device], [null, 'Mac mini']);
    expect(a.approves[1].agents, ['session-2']);
    expect(AgentInfo.fromJson({'name': 'old', 'created_ms': 1, 'session': <String, Object?>{}}).approves, isEmpty);

    final d = DeviceView.fromJson({
      'name': 'Mac-mini',
      'approvers': [
        {'agent': 'volna', 'kinds': ['send_message']},
      ],
      'approvals': [
        {
          'id': 'k9',
          'action': 'send_message',
          'requester': 'session-2',
          'contact': 'lap',
          'contact_trust': 5,
          'fingerprint': '0011223344556677',
          'approvers': ['volna'],
        },
        {'id': 'k8', 'action': 'check:exec', 'requester': 'codex', 'contact': 'lap', 'fingerprint': 'ff'},
      ],
    });
    expect((d.approvers.single.agent, d.approvers.single.agents), ('volna', null));
    expect(d.approvers.single.kinds, ['send_message']);
    expect(d.approvals[0].approvers, ['volna']);
    expect(d.approvals[1].approvers, isEmpty);

    final f = XEvent.fromJson({
      'kind': 'approval_to_answer',
      'id': 'k9',
      'device': 'Mac mini',
      'action': 'send_message',
      'requester': 'session-2',
      'expires_ms': 9,
    }) as ApprovalToAnswerEvent;
    expect((f.id, f.device, f.action, f.requester, f.expiresMs), ('k9', 'Mac mini', 'send_message', 'session-2', 9));
  });

  test('the scope rule is the daemon\'s within; naming and widening ask, narrowing and Off do not', () {
    expect(scopeWithin(['b'], ['a', 'b']), isTrue);
    expect(scopeWithin(['a', 'b'], null), isTrue);
    expect(scopeWithin(null, null), isTrue);
    expect(scopeWithin(null, ['a']), isFalse, reason: 'everything is wider than a list');
    expect(scopeWithin(['a', 'c'], ['a']), isFalse);
    expect(normalKinds(delegableKinds.reversed), isNull, reason: 'every kind is "all", also the ones added later');
    expect(normalKinds(['accept_file', 'send_message']), ['send_message', 'accept_file']);

    const all = ApproverInfo(agent: 'volna', createdMs: 0);
    const two = ApproverInfo(agent: 'volna', createdMs: 0, agents: ['builder', 'docs'], kinds: ['send_message']);
    ApproverChange change(ApproverInfo? cur, {bool on = true, List<String>? agents, List<String>? kinds}) =>
        approverChange(name: 'volna', current: cur, on: on, agents: agents, kinds: kinds);
    expect(change(null), isA<ApproverWiden>(), reason: 'naming');
    expect(change(null, on: false), isA<ApproverUnchanged>());
    expect(change(all), isA<ApproverUnchanged>());
    expect(change(all, kinds: ['send_message']), isA<ApproverNarrow>());
    expect(change(two, agents: ['builder'], kinds: ['send_message']), isA<ApproverNarrow>());
    expect(change(two, agents: ['builder', 'docs', 'more'], kinds: ['send_message']), isA<ApproverWiden>());
    expect(change(two, kinds: ['send_message']), isA<ApproverWiden>(), reason: 'all agents is wider than two');
    expect(change(two, agents: ['builder', 'docs']), isA<ApproverWiden>(), reason: 'every kind is wider than one');
    expect(change(two, on: false), isA<ApproverOff>());
    const stale = ApproverInfo(agent: 'volna', createdMs: 0, contact: 'Mac mini', stale: true);
    expect(approverChange(name: 'volna', contact: 'Mac mini', current: stale, on: true), isA<ApproverWiden>(),
        reason: 'a stale approver is named again with the password');
    final w = change(null, agents: ['builder']) as ApproverWiden;
    expect(w.request.toJson(), {'cmd': 'approver_set', 'name': 'volna', 'agents': ['builder'], 'password': ''});
    final n = change(all, kinds: ['share_file']) as ApproverNarrow;
    expect(n.request.toJson(), {'cmd': 'approver_narrow', 'name': 'volna', 'kinds': ['share_file']});
    expect(splitApproverLabel('volna'), ('volna', null));
    expect(splitApproverLabel('session-2@Mac mini @home'), ('session-2', 'Mac mini @home'));
    expect(approverCli(const ApproverSetRequest(
            name: 'session-2', contact: 'Mac mini', agents: ['a', 'b'], kinds: ['send_message'], password: 'pw')),
        'antenna approver set session-2 --on "Mac mini" --agents a,b --kinds send_message');
  });
}
