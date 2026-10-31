// SPDX-License-Identifier: AGPL-3.0-only
// The client against a stand-in daemon on a real unix socket (no antennad needed): it speaks x-control/7, falls back
// to x-control/6 and then x-control/5 when an older daemon refuses the hello and stays there; and the v6 requests go on
// the wire exactly as CONTROL §20 describes them (addressing, `mark_read.ids`, `approve_many`, `deny_many`,
// `agent_set`, `topics`).

// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A daemon that speaks the given versions and answers requests with [reply].
class _StandIn {
  _StandIn(this.versions, this.reply);
  final Set<String> versions;
  final Map<String, Object?> Function(Map<String, Object?> req) reply;
  final hellos = <String>[];
  final requests = <Map<String, Object?>>[];
  late final Directory dir;
  late final ServerSocket server;

  String get path => '${dir.path}/antennad.sock';

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('antenna-v6-');
    server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    server.listen((s) {
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final j = jsonDecode(line) as Map<String, Object?>;
        if (j['hello'] case final Map<String, Object?> h) {
          final proto = h['proto']! as String;
          hellos.add(proto);
          if (!versions.contains(proto)) {
            s.write('${jsonEncode({
              'err': {'code': 'bad_request', 'message': 'unsupported control protocol $proto'},
            })}\n');
            unawaited(s.close());
            return;
          }
          s.write('${jsonEncode({
            'hello_ok': {
              'daemon': 'antennad 0.1.0-preview.4 (test)',
              'protocol': 'x/1',
              'state': 'unlocked',
              'role': 'owner',
              'proto': proto,
              'session': 'held',
            },
          })}\n');
        } else if (j['req'] case final Map<String, Object?> r) {
          requests.add(r);
          s.write('${jsonEncode({'ok': reply(r)})}\n');
        }
      });
    });
  }

  Future<void> stop() async {
    await server.close();
    await dir.delete(recursive: true);
  }
}

Map<String, Object?> _approval(String id, String state) => {
      'id': id,
      'state': state,
      'requester': 'builder',
      'contact': 'bob',
      'contact_trust': 3,
      'action': 'send_message',
      'grants': {'read': '-', 'write': '-', 'commands': '-', 'send': 'text'},
      'quote': '',
      'fingerprint': '5e11c0aa',
      'created_ms': 1,
      'expires_ms': 2,
    };

Map<String, Object?> _contact() => {
      'label': 'bob',
      'link_id': 'ab' * 32,
      'trust': 3,
      'net_mode': 'direct',
      'role': 'inviter',
      'created_ms': 1,
      'peer_endpoint': 'e1',
      'local_endpoint': 'e2',
      'transport': {'pairing_kx_group': 'X25519MLKEM768', 'connected': true},
      'peer_addressing': true,
      'unread': 1,
    };

Map<String, Object?> _reply(Map<String, Object?> r) => switch (r['cmd']) {
      'status' => {'type': 'status', 'state': 'unlocked', 'daemon': 'antennad', 'protocol': 'x/1', 'relay': 'n0'},
      'send' => {
          'type': 'sent',
          'id': 'cd' * 32,
          'status': 'delivered',
          'lamport': 7,
          'parents': <String>[],
          'to': r['to'],
          'to_agent': r['to_agent'],
          'topic': {'id': 'ef' * 16, 'title': r['topic'] ?? 'Avatars'},
          'addressed': true,
        },
      'mark_read' => {
          'type': 'contacts',
          'contacts': [_contact()],
        },
      'approve_many' => {
          'type': 'approvals_decided',
          'results': [
            {'id': 'k2', 'approval': _approval('k2', 'approved')},
            {
              'id': 'm7',
              'error': {'code': 'approval_expired', 'message': 'expired'},
            },
          ],
        },
      'deny_many' => {
          'type': 'approvals_decided',
          'results': [
            {'id': 'k2', 'approval': _approval('k2', 'denied')},
          ],
        },
      'agent_set' => {
          'type': 'agents',
          'agents': [
            {'name': 'builder', 'created_ms': 1, 'session': <String, Object?>{}, 'everyone': r['everyone']},
          ],
        },
      'topics' => {
          'type': 'topics',
          'contact': 'bob',
          'link_id': 'ab' * 32,
          'topics': [
            {'id': 'ef' * 16, 'title': 'Avatars', 'count': 3, 'last_seq': 58, 'last_ms': 9},
          ],
        },
      'pairing_confirm' => {
          'type': 'linked',
          'contact': 'bob',
          'link_id': 'ab' * 32,
          'trust': 3,
          'net_mode': 'direct',
          'kx_group': 'X25519MLKEM768',
          'pairing_ms': 2600,
        },
      final c => throw StateError('unexpected $c'),
    };

void main() {
  test('an older daemon refuses x-control/7 and /6: the client falls back to x-control/5 and stays there', () async {
    final d = _StandIn({'x-control/5'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      final h = await c.hello();
      expect(h.proto, 'x-control/5');
      expect(c.proto, 'x-control/5');
      expect(controlVersion(h.proto), 5);
      await c.status();
      expect(d.hellos, ['x-control/7', 'x-control/6', 'x-control/5', 'x-control/5'],
          reason: 'one refusal per newer version, then v5 only');
    } finally {
      await d.stop();
    }
  });

  test('a v6 daemon refuses x-control/7: the client falls back to x-control/6 and stays there', () async {
    final d = _StandIn({'x-control/5', 'x-control/6'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      expect((await c.hello()).proto, 'x-control/6');
      expect(c.proto, 'x-control/6');
      await c.status();
      expect(d.hellos, ['x-control/7', 'x-control/6', 'x-control/6'], reason: 'one refusal, then v6 only');
    } finally {
      await d.stop();
    }
  });

  test('a daemon that refuses every version: each fallback tried once, then the error', () async {
    final d = _StandIn({}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      await expectLater(c.hello(), throwsA(isA<XControlException>()));
      expect(d.hellos, ['x-control/7', 'x-control/6', 'x-control/5'], reason: 'v6 and v5 were tried once each');
    } finally {
      await d.stop();
    }
  });

  test('v6 on the wire: addressing, mark_read ids, approve_many, deny_many, agent_set, topics', () async {
    final d = _StandIn({'x-control/5', 'x-control/6'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      expect((await c.hello()).proto, 'x-control/6');

      final sent = await c.send('bob', 'hi', address: const MessageAddress.agent('lead', topic: 'Avatars'));
      expect(d.requests.last, {
        'cmd': 'send',
        'contact': 'bob',
        'text': 'hi',
        'wait_ms': 2000,
        'to': 'agent',
        'to_agent': 'lead',
        'topic': 'Avatars',
      });
      expect((sent.to, sent.toAgent, sent.topic?.title, sent.addressed), ('agent', 'lead', 'Avatars', true));
      await c.send('bob', 'plain');
      expect(d.requests.last.keys, isNot(contains('to')), reason: 'no address: no addressing fields at all');

      final contact = await c.markRead('bob', 0, ids: ['aa', 'bb']);
      expect(d.requests.last, {'cmd': 'mark_read', 'contact': 'bob', 'up_to_seq': 0, 'ids': ['aa', 'bb']});
      expect(contact.peerAddressing, isTrue);

      final results = await c.approveMany(const [ApproveItem('k2', fingerprint: '9c41e07a'), ApproveItem('m7')], 'pw');
      expect(d.requests.last, {
        'cmd': 'approve_many',
        'items': [
          {'id': 'k2', 'fingerprint': '9c41e07a'},
          {'id': 'm7'},
        ],
        'password': 'pw',
      });
      expect(results.first.ok, isTrue);
      expect(results.last.error!.code, XErrorCode.approvalExpired);

      await c.denyMany(['k2']);
      expect(d.requests.last, {'cmd': 'deny_many', 'ids': ['k2'], 'hour': false});
      expect(d.requests.last.keys, isNot(contains('password')));

      final agents = await c.agentSet('builder', everyone: false);
      expect(d.requests.last, {'cmd': 'agent_set', 'name': 'builder', 'everyone': false});
      expect(agents.single.everyone, isFalse);
      await c.agentSet('builder', everyone: true, password: 'pw');
      expect(d.requests.last, {'cmd': 'agent_set', 'name': 'builder', 'everyone': true, 'password': 'pw'});

      final topics = await c.topics('bob');
      expect(d.requests.last, {'cmd': 'topics', 'contact': 'bob'});
      expect(topics.topics.single.title, 'Avatars');
      expect(d.hellos, ['x-control/7', ...List.filled(d.hellos.length - 1, 'x-control/6')],
          reason: 'a v6 daemon refuses v7 once; v6 from then on');
    } finally {
      await d.stop();
    }
  });

  test('D-95 on the wire: pairing_confirm without a code, "yes" without a code, confirm_without_code parsed', () async {
    final d = _StandIn({'x-control/6'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      await c.pairingConfirm('inv1', 'pw');
      expect(d.requests.last, {'cmd': 'pairing_confirm', 'id': 'inv1', 'password': 'pw'},
          reason: 'no `code` field at all, not null: the owner confirms with the click');
      await c.pairingConfirm('inv1', 'pw', code: '482913');
      expect(d.requests.last, {'cmd': 'pairing_confirm', 'id': 'inv1', 'code': '482913', 'password': 'pw'});
    } finally {
      await d.stop();
    }
    expect(const ConfirmInput(true).toJson(), {
      'confirm': {'yes': true},
    });
    expect(const ConfirmInput(true, code: '482913').toJson(), {
      'confirm': {'yes': true, 'code': '482913'},
    });
    final offered = XEvent.fromJson({'kind': 'need_input', 'what': 'confirm', 'confirm_without_code': true});
    expect(offered, isA<NeedInput>().having((e) => e.confirmWithoutCode, 'without code', isTrue));
    final older = XEvent.fromJson({'kind': 'need_input', 'what': 'confirm'});
    expect(older, isA<NeedInput>().having((e) => e.confirmWithoutCode, 'without code', isFalse));
    final invite = {
      'id': 'inv1',
      'link': '',
      'trust': 3,
      'net_mode': 'direct',
      'created_ms': 1,
      'expires_ms': 2,
      'phase': 'needs_confirm',
    };
    expect(InviteInfo.fromJson({...invite, 'confirm_without_code': true}).confirmWithoutCode, isTrue);
    expect(InviteInfo.fromJson(invite).confirmWithoutCode, isFalse, reason: 'older daemons omit it');
    // An `invite` event (no link) merged over a revealed invite keeps the event's flag.
    final revealed = InviteInfo.fromJson({...invite, 'link': 'https://antenna.contact/#x'});
    expect(InviteInfo.fromJson({...invite, 'confirm_without_code': true}).mergedOver(revealed).confirmWithoutCode, isTrue);
  });

  test('D-97: agent_list says how many MCP processes an agent has; older daemons omit it', () {
    final several = AgentInfo.fromJson({
      'name': 'claude-desktop',
      'created_ms': 1,
      'session': {'bound_pid': 3100, 'bound_comm': 'Claude', 'bound_alive': true, 'mcp_processes': 2},
    });
    expect(several.mcpProcesses, 2);
    final older = AgentInfo.fromJson({'name': 'chatgpt', 'created_ms': 1, 'session': <String, Object?>{}});
    expect(older.mcpProcesses, isNull);
  });

  test('history items and events carry the v6 fields; older ones parse without them', () {
    final item = HistoryItem.fromJson({
      'seq': 5,
      'id': 'aa',
      'direction': 'in',
      'kind': 'text',
      'text': 'hi',
      'ts': 1,
      'local_ms': 2,
      'lamport': 3,
      'status': 'received',
      'via_agent': 'lead',
      'to': 'agent',
      'to_agent': 'builder',
      'topic': {'id': 'ef' * 16, 'title': 'Avatars'},
      'unread': true,
    });
    expect((item.to, item.toAgent, item.topic?.title, item.unread), ('agent', 'builder', 'Avatars', true));
    final old = HistoryItem.fromJson({
      'seq': 5,
      'id': 'aa',
      'direction': 'in',
      'kind': 'text',
      'text': 'hi',
      'ts': 1,
      'local_ms': 2,
      'lamport': 3,
      'status': 'received',
    });
    expect((old.to, old.toAgent, old.topic, old.unread), (null, null, null, false));
  });
}
