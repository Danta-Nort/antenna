// SPDX-License-Identifier: AGPL-3.0-only
// The agent map on the wire (x-control/7, CONTROL §30; the shapes of crates/antenna-proto/src/control/connections.rs):
// `agent_connected` and `agent_traffic` become typed replies, an agent's `session.counterpart` and an own device's
// `status.agents[].counterpart` / `takes_tasks` are read (and absent from an older daemon), the three requests carry
// exactly their fields with the defaults left out, and the password never reaches toString. Local connections: a local
// counterpart, `local_routes` (the sign of a daemon that knows them), local traffic pairs, `local` in the requests.

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _agent({Map<String, Object?>? counterpart}) => {
      'name': 'volna',
      'created_ms': 1,
      'session': {
        'links': ['Mac mini'],
        'tasks_from': ['Mac mini'],
        'tasks_from_default': false,
        'counterpart': ?counterpart,
      },
    };

void main() {
  test('agent_connected: the agent with its counterpart, and each state of the other side', () {
    final r = Reply.fromJson({
      'type': 'agent_connected',
      'agent': _agent(counterpart: {'contact': 'Mac mini', 'agent': 'session-2'}),
      'other_side': {'state': 'requested', 'id': 'k2ab9c1d'},
    }) as AgentConnectedReply;
    expect(r.agent.counterpart, const Counterpart(contact: 'Mac mini', agent: 'session-2'));
    expect(r.agent.tasksFrom, ['Mac mini']);
    expect((r.otherSide.state, r.otherSide.id), (OtherSideState.requested, 'k2ab9c1d'));

    final refused = Reply.fromJson({
      'type': 'agent_connected',
      'agent': _agent(counterpart: {'contact': 'Mac mini', 'agent': 'session-2'}),
      'other_side': {'state': 'refused', 'code': 'not_found', 'message': 'no agent session-2 there'},
    }) as AgentConnectedReply;
    expect((refused.otherSide.code, refused.otherSide.message), ('not_found', 'no agent session-2 there'));
    expect(refused.otherSide.id, isNull);

    final person = Reply.fromJson({
      'type': 'agent_connected',
      'agent': _agent(counterpart: {'contact': 'Bob'}),
      'other_side': {'state': 'person'},
    }) as AgentConnectedReply;
    expect(person.agent.counterpart!.person, isTrue);
    expect(person.agent.counterpart!.agent, isNull);

    final cleared = Reply.fromJson({'type': 'agent_connected', 'agent': _agent(), 'other_side': {'state': 'unreachable', 'message': 'timeout'}})
        as AgentConnectedReply;
    expect(cleared.agent.counterpart, isNull, reason: 'no counterpart after a disconnect');
  });

  test('an older daemon: no counterpart in the session, no connection fields in a device status', () {
    final old = (Reply.fromJson({
      'type': 'agents',
      'agents': [
        {
          'name': 'volna',
          'created_ms': 1,
          'session': {'links': null},
        },
      ],
    }) as AgentsReply)
        .agents
        .single;
    expect(old.counterpart, isNull);
    final dev = DeviceAgent.fromJson(const {'name': 'codex', 'app': 'codex', 'state': 'idle'});
    expect((dev.counterpart, dev.takesTasks), (null, false));
    final now = DeviceAgent.fromJson(
        const {'name': 'session-2', 'app': 'claude', 'state': 'connected', 'counterpart': 'volna', 'takes_tasks': true});
    expect((now.counterpart, now.takesTasks), ('volna', true));
    final person = DeviceAgent.fromJson(const {'name': 'session-2', 'state': 'idle', 'counterpart': ''});
    expect(person.counterpart, '', reason: '"" is this computer\'s person');
  });

  test('agent_traffic: one entry per pair, the owner and a person as ""', () {
    final t = Reply.fromJson({
      'type': 'agent_traffic',
      'since_ms': 5,
      'pairs': [
        {'agent': 'volna', 'contact': 'Emily Carter', 'peer_agent': 'chatgpt', 'last_ms': 9, 'sent': 3, 'received': 2},
        {'agent': '', 'contact': 'Bob', 'peer_agent': '', 'last_ms': 7, 'sent': 1, 'received': 0},
      ],
    }) as AgentTrafficReply;
    expect(t.sinceMs, 5);
    expect([for (final p in t.pairs) (p.agent, p.contact, p.peerAgent, p.lastMs, p.sent, p.received)], [
      ('volna', 'Emily Carter', 'chatgpt', 9, 3, 2),
      ('', 'Bob', '', 7, 1, 0),
    ]);
  });

  test('requests: exactly their fields, the defaults left out, the password never printed', () {
    const full = AgentConnectRequest(
        name: 'volna', contact: 'Mac mini', agent: 'session-2', tasks: true, peerTasks: true, password: 'hunter2');
    expect(full.toJson(), {
      'cmd': 'agent_connect',
      'name': 'volna',
      'contact': 'Mac mini',
      'agent': 'session-2',
      'tasks': true,
      'peer_tasks': true,
      'password': 'hunter2',
    });
    expect('$full', isNot(contains('hunter2')));
    expect(const AgentConnectRequest(name: 'volna', contact: 'Bob', password: 'pw').toJson(),
        {'cmd': 'agent_connect', 'name': 'volna', 'contact': 'Bob', 'password': 'pw'},
        reason: 'a person: no agent; tasks unchanged; ask left as the default');
    expect(const AgentConnectRequest(name: 'volna', contact: 'Bob', ask: false, tasks: false, password: 'pw').toJson(),
        {'cmd': 'agent_connect', 'name': 'volna', 'contact': 'Bob', 'tasks': false, 'ask': false, 'password': 'pw'});
    expect(full.withPassword('other').toJson()['password'], 'other');
    expect({...full.withPassword('other').toJson()}..remove('password'), {...full.toJson()}..remove('password'),
        reason: 'Ask again sends the same choices');

    expect(const AgentDisconnectRequest(name: 'volna').toJson(), {'cmd': 'agent_disconnect', 'name': 'volna'});
    final off = const AgentDisconnectRequest(
            name: 'volna', contact: 'Mac mini', agent: 'session-2', tasks: false, peerTasks: false, ask: false)
        .toJson();
    expect(off, {
      'cmd': 'agent_disconnect',
      'name': 'volna',
      'contact': 'Mac mini',
      'agent': 'session-2',
      'tasks': false,
      'peer_tasks': false,
      'ask': false,
    });
    expect(off.containsKey('password'), isFalse, reason: 'disconnecting only takes away (D-84)');

    expect(const AgentTrafficRequest().toJson(), {'cmd': 'agent_traffic'});
    expect(const AgentTrafficRequest(days: 7).toJson(), {'cmd': 'agent_traffic', 'days': 7});
  });

  test('local connections: a local counterpart, local_routes (absent from an older daemon), local traffic pairs', () {
    final r = Reply.fromJson({
      'type': 'agent_connected',
      'agent': {
        'name': 'volna',
        'created_ms': 1,
        'session': {
          'counterpart': {'contact': '', 'agent': 'reviewer', 'local': true},
          'local_routes': [
            {'agent': 'reviewer', 'tasks': true},
            {'agent': 'docs-bot'},
            {'tasks': true},
          ],
        },
      },
      'other_side': {'state': 'local'},
    }) as AgentConnectedReply;
    expect(r.agent.counterpart, const Counterpart(contact: '', agent: 'reviewer', local: true));
    expect(r.agent.counterpart!.person, isFalse, reason: 'an agent of this computer, not a person');
    expect(r.agent.localRoutes, const [LocalRoute(agent: 'reviewer', tasks: true), LocalRoute(agent: 'docs-bot')],
        reason: 'an entry without an agent is dropped');
    expect(r.otherSide.state, OtherSideState.local);
    // A newer daemon always sends the key, empty or not; an older one never does
    final empty = AgentInfo.fromJson({
      'name': 'docs-bot',
      'created_ms': 1,
      'session': {'local_routes': <Object?>[]},
    });
    expect(empty.localRoutes, isEmpty);
    expect(AgentInfo.fromJson(_agent()).localRoutes, isNull);
    expect(AgentInfo.fromJson(_agent(counterpart: {'local': true})).counterpart, isNull, reason: 'no agent named');
    final t = Reply.fromJson({
      'type': 'agent_traffic',
      'since_ms': 5,
      'pairs': [
        {'agent': 'volna', 'contact': '', 'peer_agent': 'reviewer', 'local': true, 'last_ms': 9, 'sent': 3, 'received': 1},
        {'agent': 'volna', 'peer_agent': 'docs-bot', 'local': true, 'last_ms': 8},
      ],
    }) as AgentTrafficReply;
    expect([for (final p in t.pairs) (p.agent, p.contact, p.peerAgent, p.local, p.sent, p.received)], [
      ('volna', '', 'reviewer', true, 3, 1),
      ('volna', '', 'docs-bot', true, 0, 0),
    ]);
  });

  test('local requests: `local` and no contact; ask left out by default; disconnect without a password', () {
    const on = LocalConnectRequest(name: 'volna', local: 'reviewer', tasks: true, peerTasks: false, password: 'hunter2');
    expect(on.toJson(), {
      'cmd': 'agent_connect',
      'name': 'volna',
      'local': 'reviewer',
      'tasks': true,
      'peer_tasks': false,
      'password': 'hunter2',
    });
    expect('$on', isNot(contains('hunter2')));
    expect(const LocalConnectRequest(name: 'volna', local: 'reviewer', ask: false, password: 'pw').toJson(),
        {'cmd': 'agent_connect', 'name': 'volna', 'local': 'reviewer', 'ask': false, 'password': 'pw'});
    const off = LocalDisconnectRequest(name: 'volna', local: 'reviewer');
    expect(off.toJson(), {'cmd': 'agent_disconnect', 'name': 'volna', 'local': 'reviewer'});
    expect(const LocalDisconnectRequest(name: 'volna', local: 'reviewer', tasks: false, peerTasks: false).toJson(),
        {'cmd': 'agent_disconnect', 'name': 'volna', 'local': 'reviewer', 'tasks': false, 'peer_tasks': false});
  });
}
