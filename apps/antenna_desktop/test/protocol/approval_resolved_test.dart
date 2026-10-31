// SPDX-License-Identifier: AGPL-3.0-only
// After an approval the daemon finishes the agent's action itself (x-control/6): `ApprovalInfo.completes` and the
// `approval_resolved` subscription event, parsed as CONTROL §8 describes them; an older daemon sends neither, and
// the client reads its requests as before.

import 'dart:convert';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _approval({Object? completes}) => {
      'id': 'k2abcdefg',
      'state': 'pending',
      'requester': 'claude-code',
      'contact': 'bob',
      'contact_trust': 4,
      'action': 'share_file',
      'target': 'bob',
      'reasons': ['secret:api_key'],
      'grants': {'read': 'local file /tmp/notes.txt', 'write': '-', 'commands': '-', 'send': 'file notes.txt'},
      'quote': '/tmp/notes.txt → notes.txt',
      'fingerprint': '9c41e07a',
      'created_ms': 1790000000000,
      'expires_ms': 1790000600000,
      'link_id': 'a' * 64,
      'target_link_id': 'a' * 64,
      'completes': ?completes,
    };

/// One line of a subscription, as the daemon writes it.
XEvent _line(Map<String, Object?> event) =>
    XEvent.fromJson((jsonDecode(jsonEncode({'event': event})) as Map<String, Object?>)['event']! as Map<String, Object?>);

void main() {
  test('ApprovalInfo.completes: true when the daemon finishes the action itself; absent means false', () {
    expect(ApprovalInfo.fromJson(_approval(completes: true)).completes, isTrue);
    expect(ApprovalInfo.fromJson(_approval(completes: false)).completes, isFalse);
    // An older daemon (x-control/5 and before) has no such field.
    final old = ApprovalInfo.fromJson(_approval());
    expect(old.completes, isFalse);
    expect(old.pending, isTrue);
    expect(old.linkId, 'a' * 64);
    // In the `approval` event and in an `approve` reply alike.
    final e = _line({'kind': 'approval', 'approval': _approval(completes: true)});
    expect(e, isA<ApprovalEvent>().having((e) => e.approval.completes, 'completes', isTrue));
    final r = Reply.fromJson({..._approval(completes: true), 'type': 'approval', 'state': 'approved'});
    expect(r, isA<ApprovalReply>().having((r) => r.approval.completes, 'completes', isTrue));
  });

  test('approval_resolved, completed: every field, the result as the reply of the action', () {
    final e = _line({
      'kind': 'approval_resolved',
      'id': 'k2abcdefg',
      'action': 'share_file',
      'requester': 'claude-code',
      'contact': 'bob',
      'link_id': 'a' * 64,
      'target': 'bob',
      'target_link_id': 'b' * 64,
      'state': 'completed',
      'result': {
        'type': 'file',
        'id': '0123456789abcdef',
        'contact': 'bob',
        'link_id': 'a' * 64,
        'direction': 'out',
        'name': 'notes.txt',
        'size': 2140,
        'state': 'offered',
        'created_ms': 1790000000000,
      },
      'error': null,
      'message': 'The owner approved; Antenna sent the file for the agent.',
      'at_ms': 1790000000000,
    });
    expect(e, isA<ApprovalResolvedEvent>());
    final r = e as ApprovalResolvedEvent;
    expect(r.id, 'k2abcdefg');
    expect(r.action, 'share_file');
    expect(r.requester, 'claude-code');
    expect(r.contact, 'bob');
    expect(r.linkId, 'a' * 64);
    expect(r.target, 'bob');
    expect(r.targetLinkId, 'b' * 64);
    expect(r.completed, isTrue);
    expect(r.failed, isFalse);
    expect(r.error, isNull);
    expect(r.message, 'The owner approved; Antenna sent the file for the agent.');
    expect(r.atMs, 1790000000000);
    expect(r.resultType, 'file');
    expect(r.result!['name'], 'notes.txt', reason: 'the raw reply is kept');
  });

  test('approval_resolved, failed: the error code and message', () {
    final r = _line({
      'kind': 'approval_resolved',
      'id': 'm7abcdefg',
      'action': 'send_message',
      'requester': 'builder',
      'contact': 'bob',
      'state': 'failed',
      'error': {'code': 'network', 'message': 'the contact is unreachable'},
      'message': 'The owner approved, but Antenna could not send the message.',
      'at_ms': 1790000000000,
    }) as ApprovalResolvedEvent;
    expect(r.failed, isTrue);
    expect(r.completed, isFalse);
    expect(r.error, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.network));
    expect(r.error!.message, 'the contact is unreachable');
    expect(r.result, isNull);
    expect(r.resultType, isNull);
    expect(r.resultReply, isNull);
  });

  test('approval_resolved with only the mandatory fields; a result the window does not know stays raw', () {
    final r = _line({'kind': 'approval_resolved', 'id': 'q1', 'state': 'approved'}) as ApprovalResolvedEvent;
    expect(r.state, 'approved');
    expect(r.completed || r.failed, isFalse);
    expect((r.action, r.requester, r.contact, r.message), ('', '', '', ''));
    expect((r.linkId, r.target, r.targetLinkId, r.atMs, r.error, r.result), (null, null, null, null, null, null));
    final unknown = _line({
      'kind': 'approval_resolved',
      'id': 'q2',
      'state': 'completed',
      'result': {'type': 'something_new', 'n': 1},
    }) as ApprovalResolvedEvent;
    expect(unknown.resultType, 'something_new');
    expect(unknown.resultReply, isNull);
    expect(unknown.result, {'type': 'something_new', 'n': 1});
    // A known type that the reply parser accepts.
    final sent = _line({
      'kind': 'approval_resolved',
      'id': 'q3',
      'state': 'completed',
      'result': {'type': 'file_requested', 'contact': 'bob', 'id': '00ff', 'status': 'requested'},
    }) as ApprovalResolvedEvent;
    expect(sent.resultReply, isA<FileRequestedReply>());
  });

  test('an older daemon: approval_resolved never comes, and an unknown kind stays an UnknownEvent', () {
    expect(_line({'kind': 'approval', 'approval': {..._approval(), 'state': 'approved'}}), isA<ApprovalEvent>());
    expect(_line({'kind': 'something_later', 'id': 'x'}), isA<UnknownEvent>());
  });
}
