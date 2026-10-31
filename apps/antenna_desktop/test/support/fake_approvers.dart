// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's approver agents (x-control/7, CONTROL §31; experimental): `approver_set` checks the password (or
// a proof, through [FakeDaemon.callWithProof]) and names or widens; `approver_narrow` takes no password and answers
// `password_required` for a wider scope, as the real daemon does; `approver_remove` takes none; `approvers` lists the
// delegations and the answers the test set. Every command is recorded as the exact JSON the window sent (the password
// included: the test checks what went to the daemon). With [FakeApprovers.approversEnabled] off (the default) it
// behaves like a v7 daemon built before approvers: its strict parser refuses the commands as an unknown variant.

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fixtures.dart' show contact, fixedNow;

/// When the own computers' agents were announced in the demo.
int get _since => fixedNow.subtract(const Duration(days: 9)).millisecondsSinceEpoch;

/// The demo of the approver tests and frames: this computer's agents volna (it also answers the Mac mini's requests,
/// set there), builder and docs-bot; the Mac mini and the build server, both ∞, with their agents; Emily Carter at 4.
({List<AgentInfo> agents, List<ContactInfo> contacts}) approversDemo() => (
      agents: [
        const AgentInfo(name: 'volna', createdMs: 0, localLevel: 5, raw: {
          'name': 'volna',
          'session': {
            'approves': [
              {
                'device': 'Mac mini',
                'agents': null,
                'kinds': ['send_message'],
              },
            ],
          },
        }),
        const AgentInfo(name: 'builder', createdMs: 0, localLevel: 3),
        const AgentInfo(name: 'docs-bot', createdMs: 0, localLevel: 3),
      ],
      contacts: [
        contact('Mac mini', 61,
            trust: 5, peerKind: 'agent', agents: [PeerAgent(name: 'session-2', state: 'active', sinceMs: _since)]),
        contact('Build server', 62,
            trust: 5, peerKind: 'agent', agents: [PeerAgent(name: 'lead', state: 'active', sinceMs: _since)]),
        contact('Emily Carter', 64, trust: 4),
      ],
    );

/// A request of [requester] about the Mac mini to send to the build server (a flow between two own computers).
ApprovalInfo approverRequest(
  String id, {
  String state = 'pending',
  String requester = 'builder',
  String action = 'send_message',
  String quote = 'The nightly build finished: 2 warnings, 0 failures.',
  DecidedBy? decidedBy,
  DelegateNote? refused,
  List<String> answerableBy = const [],
  bool completes = true,
  int minutesAgo = 1,
}) {
  final mini = contact('Mac mini', 61, trust: 5);
  final server = contact('Build server', 62, trust: 5);
  return ApprovalInfo(
    id: id,
    state: state,
    requester: requester,
    contact: mini.label,
    contactTrust: 5,
    action: action,
    target: server.label,
    reasons: const ['cross_link:Mac mini'],
    grants: Grants(read: '-', write: '-', commands: '-', send: action == 'send_message' ? 'text' : 'file'),
    quote: quote,
    fingerprint: '9c41e07a',
    createdMs: fixedNow.subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch,
    expiresMs: fixedNow.add(Duration(minutes: 10 - minutesAgo)).millisecondsSinceEpoch,
    linkId: mini.linkId,
    targetLinkId: server.linkId,
    completes: completes,
    decidedBy: decidedBy,
    delegateRefused: refused,
    answerableBy: answerableBy,
  );
}

/// What a test sets and reads.
mixin FakeApprovers {
  int get protoVersion;
  String get password;
  List<AgentInfo> get agentList;
  List<ContactInfo> get contactList;

  /// `false`: a v7 daemon built before approvers.
  bool approversEnabled = false;

  /// The delegations and the latest answers, as `approvers` lists them.
  List<ApproverInfo> approverList = [];
  List<DelegatedAnswer> answerList = [];

  /// Every `approver_set` / `approver_narrow` / `approver_remove`, as the exact JSON the window sent; `proof` marks
  /// one that came with an owner proof.
  final approverCalls = <Map<String, Object?>>[];
  int approversListCalls = 0;

  ApproversReply get _reply => ApproversReply(approvers: [...approverList], answers: [...answerList]);

  ApproverInfo? _find(String name, String? contact) =>
      approverList.where((a) => a.agent == name && a.contact == contact).firstOrNull;

  void _put(ApproverInfo a) => approverList = [
        for (final x in approverList)
          if (!(x.agent == a.agent && x.contact == a.contact)) x,
        a,
      ];

  /// The approver commands of [FakeDaemon.call]; [proof]: `approver_set` arrived with a verified owner proof.
  Reply approversCall(ApproverRequest r, {bool proof = false}) {
    if (protoVersion < 7 || !approversEnabled) {
      throw XControlException(XErrorCode.badRequest,
          'bad message: unknown variant `${r.cmd}`, expected one of `status`, `init`, `unlock`');
    }
    switch (r) {
      case ApproversRequest():
        approversListCalls++;
        return _reply;
      case ApproverSetRequest(:final name, :final contact, :final agents, :final kinds):
        approverCalls.add({...r.toJson(), if (proof) 'proof': true});
        if (!proof && r.password != password) {
          throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        }
        if (contact == null) {
          if (!agentList.any((a) => a.name == name)) throw XControlException(XErrorCode.notFound, 'no agent $name');
        } else {
          final c = contactList.where((c) => c.label == contact).firstOrNull;
          if (c == null) throw XControlException(XErrorCode.notFound, 'no contact $contact');
          if (c.trust < 5) {
            throw XControlException(XErrorCode.forbidden, '$contact is not one of your own computers (∞)');
          }
        }
        final c = contact == null ? null : contactList.firstWhere((x) => x.label == contact);
        _put(ApproverInfo(
          agent: name,
          contact: contact,
          linkId: c?.linkId,
          agents: agents,
          kinds: kinds,
          keyId: contact == null ? null : '9c41e07a3b5d0f12',
          createdMs: fixedNow.millisecondsSinceEpoch,
        ));
        return _reply;
      case ApproverNarrowRequest(:final name, :final contact, :final agents, :final kinds):
        approverCalls.add(r.toJson());
        final cur = _find(name, contact);
        if (cur == null) throw XControlException(XErrorCode.notFound, '$name is not an approver');
        if (!scopeWithin(agents, cur.agents) || !scopeWithin(kinds, cur.kinds)) {
          throw const XControlException(XErrorCode.passwordRequired, 'a wider scope needs the owner password');
        }
        _put(ApproverInfo(
          agent: name,
          contact: contact,
          linkId: cur.linkId,
          agents: agents,
          kinds: kinds,
          keyId: cur.keyId,
          stale: cur.stale,
          createdMs: cur.createdMs,
        ));
        return _reply;
      case ApproverRemoveRequest(:final name, :final contact):
        approverCalls.add(r.toJson());
        if (_find(name, contact) == null) throw XControlException(XErrorCode.notFound, '$name is not an approver');
        approverList = [for (final x in approverList) if (!(x.agent == name && x.contact == contact)) x];
        return _reply;
    }
  }
}
