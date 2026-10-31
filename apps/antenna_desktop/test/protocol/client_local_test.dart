// SPDX-License-Identifier: AGPL-3.0-only
// The client against a stand-in daemon on a real unix socket (no antennad needed): it speaks x-control/7, a v6 daemon
// gets v6 (also when two connections are refused at once, none skips to v5), and the local model commands go on the
// wire exactly as CONTROL §24 describes them, with their replies, events and error codes parsed.

// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A daemon that speaks [versions]; [reply] answers each request with the lines after it (events, then `ok`/`err`).
class _StandIn {
  _StandIn(this.versions, this.reply, {this.helloDelay = Duration.zero});
  final Set<String> versions;
  final List<Map<String, Object?>> Function(Map<String, Object?> req) reply;
  final Duration helloDelay;
  final hellos = <String>[];
  final requests = <Map<String, Object?>>[];
  late final Directory dir;
  late final ServerSocket server;

  String get path => '${dir.path}/antennad.sock';

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('antenna-v7-');
    server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    server.listen((s) {
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
        final j = jsonDecode(line) as Map<String, Object?>;
        if (j['hello'] case final Map<String, Object?> h) {
          final proto = h['proto']! as String;
          hellos.add(proto);
          await Future<void>.delayed(helloDelay);
          if (!versions.contains(proto)) {
            s.write('${jsonEncode({
              'err': {'code': 'bad_request', 'message': 'unsupported control protocol $proto'},
            })}\n');
            unawaited(s.close());
            return;
          }
          s.write('${jsonEncode({
            'hello_ok': {
              'daemon': 'antennad 0.1.2 (test)',
              'protocol': 'x/1',
              'state': 'unlocked',
              'role': 'owner',
              'proto': proto,
              'session': 'held',
            },
          })}\n');
        } else if (j['req'] case final Map<String, Object?> r) {
          requests.add(r);
          for (final out in reply(r)) {
            s.write('${jsonEncode(out)}\n');
          }
        }
      });
    });
  }

  Future<void> stop() async {
    await server.close();
    await dir.delete(recursive: true);
  }
}

Map<String, Object?> _model(String state, {Map<String, Object?> extra = const {}}) => {
      'id': 'qwen3.5-2b',
      'name': 'Qwen3.5 2B',
      'maker': 'Qwen (Alibaba Cloud)',
      'license': 'Apache-2.0',
      'license_url': 'https://huggingface.co/Qwen/Qwen3.5-2B/blob/main/LICENSE',
      'languages': '201 languages',
      'params': '2.27B',
      'quant': 'Q4_K_M',
      'size_bytes': 1280835840,
      'memory_bytes': 2200000000,
      'context': 8192,
      'source': 'huggingface.co/unsloth/Qwen3.5-2B-GGUF@f6d5376/Qwen3.5-2B-Q4_K_M.gguf',
      'fit': 'recommended',
      'fit_detail': '16 GB memory, AVX2',
      'est_tokens_per_s': 24,
      'state': state,
      'done_bytes': 0,
      ...extra,
    };

Map<String, Object?> _agent(String state) => {
      'name': 'helper',
      'model': 'qwen3.5-2b',
      'runtime': 'local',
      'state': state,
      'turns': 3,
      'last_usage': {'prompt_tokens': 31, 'output_tokens': 58},
      'created_ms': 7,
    };

List<Map<String, Object?>> _ok(Map<String, Object?> r) => [
      {'ok': r},
    ];

List<Map<String, Object?>> _reply(Map<String, Object?> r) => switch (r['cmd']) {
      'status' => _ok({'type': 'status', 'state': 'unlocked', 'daemon': 'antennad', 'protocol': 'x/1', 'relay': 'n0'}),
      'local_models' => _ok({
          'type': 'local_models',
          'hardware': {
            'os': 'linux',
            'arch': 'x86_64',
            'cpu': 'AMD Ryzen 7 7840U',
            'cores': 8,
            'threads': 16,
            'avx2': true,
            'accel': 'cpu',
            'memory_bytes': 32 << 30,
            'available_bytes': 20 << 30,
            'budget_bytes': 15 << 30,
            'disk_free_bytes': 140 << 30,
          },
          'runtime': {'available': false, 'version': '', 'sandbox': 'none', 'detail': 'no runtime in this build'},
          'models': [_model('available')],
          'agents': [_agent('sleeping')],
        }),
      'model_install' when r['model'] == 'huge' => [
          {
            'err': {'code': 'no_space', 'message': 'needs 18.2 GB, 9.1 GB free'},
          },
        ],
      'model_install' => _ok({'type': 'local_model', ..._model('downloading', extra: {'speed_bytes_per_s': 9000000})}),
      'model_remove' => _ok({'type': 'local_model', ..._model('available')}),
      'local_agent_add' => _ok({'type': 'local_agent', ..._agent('sleeping')}),
      'local_say' => [
          {
            'event': {'kind': 'local_delta', 'agent': 'helper', 'turn': 3, 'delta': '', 'activity': 'loading'},
          },
          {
            'event': {'kind': 'local_delta', 'agent': 'helper', 'turn': 3, 'delta': 'Hi! I can '},
          },
          {
            'event': {'kind': 'local_delta', 'agent': 'helper', 'turn': 3, 'delta': 'help.'},
          },
          {
            'ok': {
              'type': 'local_turn',
              'agent': 'helper',
              'turn': 3,
              'outcome': 'done',
              'text': 'Hi! I can help.',
              'usage': {'prompt_tokens': 31, 'cached_tokens': 412, 'output_tokens': 58, 'prompt_ms': 190, 'output_ms': 1760},
            },
          },
        ],
      'local_history' => _ok({
          'type': 'local_history',
          'agent': 'helper',
          'items': [
            {'seq': 11, 'turn': 3, 'role': 'owner', 'text': 'Hi! What can you do?', 'ts_ms': 100},
            {
              'seq': 12,
              'turn': 3,
              'role': 'agent',
              'text': 'Hi! I can help.',
              'ts_ms': 200,
              'outcome': 'done',
              'usage': {'prompt_tokens': 31, 'output_tokens': 58},
            },
            {'seq': 13, 'turn': 4, 'role': 'owner', 'text': 'Again?', 'ts_ms': 300},
            {'seq': 14, 'turn': 4, 'role': 'agent', 'text': '', 'ts_ms': 400, 'outcome': 'failed', 'detail': 'no sandbox'},
          ],
          'more': true,
        }),
      'local_session' => _ok({'type': 'local_agent', ..._agent('idle')}),
      final c => throw StateError('unexpected $c'),
    };

void main() {
  test('the versions: v7 first, then each older one once; the newest is the first of the list', () {
    expect(controlProto, controlProtos.first);
    expect(controlProtos, ['x-control/7', 'x-control/6', 'x-control/5']);
    expect(olderControlProto('x-control/7'), 'x-control/6');
    expect(olderControlProto('x-control/6'), 'x-control/5');
    expect(olderControlProto('x-control/5'), isNull);
    expect(olderControlProto('x-control/9'), isNull);
    expect(controlVersion(controlProto), localModelsVersion);
  });

  test('a v6 daemon refuses x-control/7: the client falls back to x-control/6 and stays there', () async {
    final d = _StandIn({'x-control/5', 'x-control/6'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      final h = await c.hello();
      expect(h.proto, 'x-control/6');
      expect(c.proto, 'x-control/6');
      await c.status();
      expect(d.hellos, ['x-control/7', 'x-control/6', 'x-control/6'], reason: 'one refusal, then v6 only');
    } finally {
      await d.stop();
    }
  });

  test('two connections refused at once both land on v6: neither skips a version', () async {
    final d = _StandIn({'x-control/5', 'x-control/6'}, _reply, helloDelay: const Duration(milliseconds: 50));
    await d.start();
    try {
      final c = XControlClient(d.path);
      final both = await Future.wait([c.hello(), c.hello()]);
      expect(both.map((h) => h.proto), ['x-control/6', 'x-control/6']);
      expect(c.proto, 'x-control/6');
      expect(d.hellos.where((v) => v == 'x-control/5'), isEmpty, reason: 'v5 was never asked: v6 was accepted');
    } finally {
      await d.stop();
    }
  });

  test('v7 on the wire: local_models, model_install, model_remove, local_agent_add, local_history, local_session',
      () async {
    final d = _StandIn({'x-control/6', 'x-control/7'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      expect((await c.hello()).proto, 'x-control/7');

      final all = await c.localModels();
      expect(d.requests.last, {'cmd': 'local_models'});
      expect((all.hardware.cpu, all.hardware.avx2, all.hardware.memoryBytes, all.hardware.macos),
          ('AMD Ryzen 7 7840U', true, 32 << 30, false));
      expect((all.runtime.available, all.runtime.detail), (false, 'no runtime in this build'));
      final m = all.models.single;
      expect((m.id, m.fit, m.state, m.sizeBytes, m.estTokensPerS, m.host),
          ('qwen3.5-2b', LocalFit.recommended, LocalModelState.available, 1280835840, 24, 'huggingface.co'));
      expect((all.agents.single.name, all.agents.single.runsHere, all.agents.single.lastUsage?.outputTokens),
          ('helper', true, 58));

      final dl = await c.modelInstall('qwen3.5-2b');
      expect(d.requests.last, {'cmd': 'model_install', 'model': 'qwen3.5-2b'}, reason: 'no from_file field at all');
      expect((dl.state, dl.speedBytesPerS), (LocalModelState.downloading, 9000000));
      await c.modelInstall('qwen3.5-2b', fromFile: '/media/usb/q.gguf');
      expect(d.requests.last, {'cmd': 'model_install', 'model': 'qwen3.5-2b', 'from_file': '/media/usb/q.gguf'});
      await expectLater(
          c.modelInstall('huge'), throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.noSpace)));

      expect((await c.modelRemove('qwen3.5-2b')).state, LocalModelState.available);
      expect(d.requests.last, {'cmd': 'model_remove', 'model': 'qwen3.5-2b'});

      final a = await c.localAgentAdd('helper', model: 'qwen3.5-2b', password: 'pw');
      expect(d.requests.last, {'cmd': 'local_agent_add', 'name': 'helper', 'model': 'qwen3.5-2b', 'password': 'pw'});
      expect((a.name, a.state), ('helper', LocalAgentState.sleeping));

      final h = await c.localHistory('helper', limit: 100, before: 13);
      expect(d.requests.last, {'cmd': 'local_history', 'agent': 'helper', 'limit': 100, 'before': 13});
      expect(h.items.map((i) => (i.role, i.outcome, i.detail)),
          [('owner', null, ''), ('agent', 'done', ''), ('owner', null, ''), ('agent', 'failed', 'no sandbox')]);
      expect(h.more, isTrue);
      await c.localHistory('helper');
      expect(d.requests.last, {'cmd': 'local_history', 'agent': 'helper'});

      for (final action in [
        LocalSessionAction.status,
        LocalSessionAction.interrupt,
        LocalSessionAction.stop,
        LocalSessionAction.reset,
      ]) {
        final s = await c.localSession('helper', action);
        expect(d.requests.last, {'cmd': 'local_session', 'agent': 'helper', 'action': action});
        expect(s.state, LocalAgentState.idle);
      }
    } finally {
      await d.stop();
    }
  });

  test('local_say is a dialog: local_delta events, then local_turn; no text in toString', () async {
    final d = _StandIn({'x-control/7'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      final say = c.localSay('helper', 'Hi! What can you do?');
      final all = say.events.toList();
      final turn = await say.result as LocalTurnReply;
      final events = (await all).cast<LocalDeltaEvent>();
      expect(d.requests.last, {'cmd': 'local_say', 'agent': 'helper', 'text': 'Hi! What can you do?'},
          reason: 'no interrupt or timeout_ms fields unless asked');
      expect(events.map((e) => (e.delta, e.activity)), [('', 'loading'), ('Hi! I can ', null), ('help.', null)]);
      expect((turn.turn, turn.outcome, turn.text, turn.usage?.cachedTokens), (3, 'done', 'Hi! I can help.', 412));
      expect('$turn ${events.first} ${const LocalSayRequest(agent: 'a', text: 'secret words')}',
          isNot(contains('secret')));
      expect('$turn', isNot(contains('Hi!')));
      c.localSay('helper', 'stop that', interrupt: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(d.requests.last, {'cmd': 'local_say', 'agent': 'helper', 'text': 'stop that', 'interrupt': true});
    } finally {
      await d.stop();
    }
  });

  test('events and agent_list: local_model, local_agent, agents[].local_model; older shapes parse', () {
    final ev = XEvent.fromJson({'kind': 'local_model', ..._model('verifying', extra: {'done_bytes': 640})});
    expect(ev, isA<LocalModelEvent>().having((e) => (e.model.state, e.model.doneBytes), 'state', ('verifying', 640)));
    final failed = XEvent.fromJson({
      'kind': 'local_model',
      ..._model('failed', extra: {'error_code': 'hash_mismatch', 'error': 'sha256 differs; the file was deleted'}),
    });
    expect((failed as LocalModelEvent).model.errorCode, XErrorCode.hashMismatch);
    final ag = XEvent.fromJson({'kind': 'local_agent', ..._agent('busy')});
    expect(ag, isA<LocalAgentEvent>().having((e) => e.agent.state, 'state', LocalAgentState.busy));
    final local = AgentInfo.fromJson({'name': 'helper', 'created_ms': 1, 'session': {'links': <String>[]}, 'local_model': 'qwen3.5-2b'});
    expect(local.localModel, 'qwen3.5-2b');
    final plain = AgentInfo.fromJson({'name': 'claude', 'created_ms': 1, 'session': <String, Object?>{}});
    expect(plain.localModel, isNull);
    // A model with only the required fields, as a future daemon might trim it.
    final bare = LocalModelInfo.fromJson({'id': 'x', 'fit': 'fits', 'state': 'available'});
    expect((bare.name, bare.sizeBytes, bare.agents.length), ('x', 0, 0));
  });
}
