// SPDX-License-Identifier: AGPL-3.0-only
// The urgent message and the stop switch on the wire (x-control/7, CONTROL §33; the shapes of
// crates/antenna-proto/src/control.rs and control/stop.rs): `send.urgent`, `task_review.urgent`, `agent_terminal`,
// `agent_stop` and `device_agent_stop` go out with exactly their fields (urgent only when set, so an older daemon's
// strict parser never sees it); `sent.urgent`, the history item's and `message_fact`'s `urgent`, `peer_urgent`,
// `stop_agents`, `agent_stopped` and the `agent` event's `by` parse, and their absence from an older daemon too.

// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A v7 daemon on a real unix socket that records each request and answers with [reply].
class _StandIn {
  _StandIn(this.reply);
  final Map<String, Object?> Function(Map<String, Object?> req) reply;
  final requests = <Map<String, Object?>>[];
  late final Directory dir;
  late final ServerSocket server;

  String get path => '${dir.path}/antennad.sock';

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('antenna-stop-');
    server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    server.listen((s) {
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final j = jsonDecode(line) as Map<String, Object?>;
        if (j['hello'] case final Map<String, Object?> h) {
          s.write('${jsonEncode({
            'hello_ok': {
              'daemon': 'antennad 0.2.0 (test)',
              'protocol': 'x/1',
              'state': 'unlocked',
              'role': 'owner',
              'proto': h['proto'],
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

Map<String, Object?> _item({bool urgent = false, String direction = 'in'}) => {
      'seq': 7,
      'id': 'ab' * 32,
      'direction': direction,
      'kind': 'text',
      'text': 'Stop the build now',
      'ts': 1,
      'local_ms': 2,
      'lamport': 3,
      'status': 'received',
      'to': 'agent',
      'to_agent': 'helper',
      if (urgent) 'urgent': true,
    };

Map<String, Object?> _reply(Map<String, Object?> r) => switch (r['cmd']) {
      'send' => {
          'type': 'sent',
          'id': 'cd' * 32,
          'status': 'delivered',
          'lamport': 7,
          'to': 'agent',
          'to_agent': 'helper',
          if (r['urgent'] == true) 'urgent': false,
        },
      'agent_terminal' => {'type': 'done', 'state': 'noted'},
      'agent_stop' => {
          'type': 'agent_stopped',
          'agent': r['agent'],
          'how': 'terminal',
          'processes': 4,
          'left': 0,
          'names': ['claude', 'node', 'sleep'],
        },
      'device_agent_stop' => {
          'type': 'agent_stopped',
          'agent': r['agent'],
          'contact': r['contact'],
          'how': 'app',
          'processes': 0,
          'left': 0,
        },
      final c => throw StateError('unexpected $c'),
    };

void main() {
  test('requests: urgent only when set; the stop commands with exactly their fields', () {
    final plain = const SendRequest(contact: 'Mac mini', text: 'hi', address: MessageAddress.agent('helper')).toJson();
    expect(plain.containsKey('urgent'), isFalse, reason: 'an older daemon parses send strictly');
    expect(
        const SendRequest(contact: 'Mac mini', text: 'hi', address: MessageAddress.agent('helper'), urgent: true)
            .toJson(),
        {
          'cmd': 'send',
          'contact': 'Mac mini',
          'text': 'hi',
          'wait_ms': 2000,
          'to': 'agent',
          'to_agent': 'helper',
          'urgent': true,
        });
    expect(const TaskReviewRequest(id: 'a1', verdict: TaskVerdict.changes, comments: 'Stop').toJson(),
        {'cmd': 'task_review', 'id': 'a1', 'verdict': 'changes', 'comments': 'Stop'});
    expect(const TaskReviewRequest(id: 'a1', verdict: TaskVerdict.changes, comments: 'Stop', urgent: true).toJson(),
        {'cmd': 'task_review', 'id': 'a1', 'verdict': 'changes', 'comments': 'Stop', 'urgent': true});
    expect(const AgentTerminalRequest(agent: 'helper', pid: 4101).toJson(),
        {'cmd': 'agent_terminal', 'agent': 'helper', 'pid': 4101});
    expect(const AgentStopRequest('helper').toJson(), {'cmd': 'agent_stop', 'agent': 'helper'},
        reason: 'no password: stopping only makes things safer');
    expect(const DeviceAgentStopRequest(contact: 'Mac mini', agent: 'codex').toJson(),
        {'cmd': 'device_agent_stop', 'contact': 'Mac mini', 'agent': 'codex'});
  });

  test('the client sends them over the socket and reads the replies', () async {
    final d = _StandIn(_reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      final sent = await c.send('Mac mini', 'Stop the build now',
          address: const MessageAddress.agent('helper'), urgent: true);
      expect(d.requests.last['urgent'], true);
      expect(sent.urgent, isFalse, reason: 'their Antenna cannot interrupt agents: sent as a normal message');
      await c.send('Mac mini', 'and a normal one', address: const MessageAddress.agent('helper'));
      expect(d.requests.last.containsKey('urgent'), isFalse);
      await c.agentTerminal('helper', 4101);
      expect(d.requests.last, {'cmd': 'agent_terminal', 'agent': 'helper', 'pid': 4101});
      final s = await c.agentStop('helper');
      expect((s.agent, s.contact, s.how, s.processes, s.left), ('helper', null, StopHow.terminal, 4, 0));
      expect(s.names, ['claude', 'node', 'sleep']);
      final r = await c.deviceAgentStop('Mac mini', 'codex');
      expect((r.agent, r.contact, r.how, r.processes), ('codex', 'Mac mini', StopHow.app, 0));
      expect(r.names, isEmpty);
    } finally {
      await d.stop();
    }
  });

  test('replies, items and events: urgent, peer_urgent, stop_agents, by; absent from an older daemon', () {
    final sent = Reply.fromJson({'type': 'sent', 'id': 'x', 'status': 'delivered', 'lamport': 1, 'urgent': true})
        as SentReply;
    expect(sent.urgent, isTrue);
    expect((Reply.fromJson({'type': 'sent', 'id': 'x', 'status': 'delivered', 'lamport': 1}) as SentReply).urgent,
        isNull, reason: 'present only when urgent was asked');

    expect(HistoryItem.fromJson(_item(urgent: true)).urgent, isTrue);
    expect(HistoryItem.fromJson(_item()).urgent, isFalse);
    expect(HistoryItem.fromJson(_item(urgent: true)).withUnread(true).urgent, isTrue);
    final ev = XEvent.fromJson({
      'kind': 'message',
      'contact': 'Mac mini',
      'link_id': 'aa' * 32,
      'message': _item(urgent: true),
    }) as MessageEvent;
    expect(ev.message.urgent, isTrue);

    final fact = XEvent.fromJson({'kind': 'message_fact', 'contact': 'Mac mini', 'id': 'f1', 'trust': 5, 'chars': 12,
        'received_ms': 3, 'urgent': true}) as MessageFactEvent;
    expect(fact.urgent, isTrue);
    expect((XEvent.fromJson({'kind': 'message_fact', 'contact': 'Mac mini', 'id': 'f1'}) as MessageFactEvent).urgent,
        isFalse);

    Map<String, Object?> contact({bool urgent = false}) => {
          'label': 'Mac mini',
          'link_id': 'aa' * 32,
          'trust': 5,
          'net_mode': 'direct',
          'role': 'inviter',
          'created_ms': 1,
          'peer_endpoint': 'e1',
          'local_endpoint': 'e2',
          'transport': {'connected': true},
          if (urgent) 'peer_urgent': true,
        };
    expect(ContactInfo.fromJson(contact(urgent: true)).peerUrgent, isTrue);
    expect(ContactInfo.fromJson(contact(urgent: true)).copyWith(presence: 'online').peerUrgent, isTrue);
    expect(ContactInfo.fromJson(contact()).peerUrgent, isFalse);

    Map<String, Object?> device({bool stop = false}) => {
          'contact': 'Mac mini',
          'link_id': 'aa' * 32,
          'presence': 'online',
          'supported': true,
          if (stop) 'stop_agents': true,
        };
    expect(DeviceInfo.fromJson(device(stop: true)).stopAgents, isTrue);
    expect(DeviceInfo.fromJson(device()).stopAgents, isFalse);

    final stopped =
        XEvent.fromJson({'kind': 'agent', 'name': 'helper', 'change': 'stopped', 'by': 'Mac mini'}) as AgentEvent;
    expect((stopped.change, stopped.by), ('stopped', 'Mac mini'));
    expect((XEvent.fromJson({'kind': 'agent', 'name': 'helper', 'change': 'bound'}) as AgentEvent).by, isNull);

    final minimal =
        Reply.fromJson({'type': 'agent_stopped', 'agent': 'helper', 'how': 'none', 'processes': 0, 'left': 0})
            as AgentStoppedReply;
    expect((minimal.how, minimal.contact), (StopHow.none, null));
    expect(minimal.names, isEmpty);
  });
}
