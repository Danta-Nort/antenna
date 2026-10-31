// SPDX-License-Identifier: AGPL-3.0-only
// Local models against a REAL `antennad` (x-control/7, CONTROL §24) with the stand-in runtime
// `tools/fake-llama-server.py` (it echoes "Echo: <the last message>" one word per event) and a test catalog of one tiny
// model file: `local_models` lists it as available; a tampered file fails with `hash_mismatch` and is gone; the real
// file is copied, checked and ready, with `local_model` events on the subscription; a local agent is created with the
// owner password; `local_say` streams `local_delta` words and ends `done`; the window's model sees both turns (one
// from another client, through the `local_agent` event); Stop ends a long reply as `interrupted`; the conversation
// survives a daemon restart; New conversation deletes it.
// Run (one file at a time; needs bwrap or Landlock for the sandboxes, python3 for the stand-in runtime):
//   ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_local_models_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 40), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

String _sha256(String path) => '${Process.runSync('sha256sum', [path]).stdout}'.split(' ').first;

const _model = 'tiny-test';

/// The runtime folder (the stand-in as `llama-server`, its settings, the chat template), a model file and a tampered
/// copy of the same size, and a catalog that pins the model's size and SHA-256 and the template's SHA-256.
({String runtime, String catalog, String good, String tampered, String settings}) _fixture(Directory root) {
  final repo = Directory.current.parent.parent.path;
  final rt = Directory('${root.path}/runtime')..createSync();
  final prog = '${rt.path}/llama-server';
  File('$repo/tools/fake-llama-server.py').copySync(prog);
  Process.runSync('chmod', ['755', prog]);
  final settings = '${rt.path}/fake-llama-server.json';
  File(settings).writeAsStringSync(jsonEncode({'delay_ms': 10}));
  Directory('${rt.path}/templates').createSync();
  final template = File('${rt.path}/templates/tiny.chat_template.jinja')
    ..writeAsStringSync('{% for m in messages %}{{ m.role }}: {{ m.content }}\n{% endfor %}');
  final rnd = Random(7);
  final bytes = [...utf8.encode('GGUF'), for (var i = 0; i < 256 * 1024; i++) rnd.nextInt(256)];
  final good = File('${root.path}/tiny.gguf')..writeAsBytesSync(bytes);
  final tampered = File('${root.path}/tampered.gguf')..writeAsBytesSync([...bytes]..[1000] ^= 0xff);
  final commit = 'ab' * 20;
  final catalog = File('${root.path}/catalog.json')
    ..writeAsStringSync(jsonEncode({
      'version': 1,
      'runtime': {'name': 'llama.cpp llama-server', 'tag': 'test', 'commit': commit, 'license': 'MIT'},
      'models': [
        {
          'id': _model,
          'name': 'Tiny test',
          'family': 'test',
          'maker': 'Example',
          'license': 'Apache-2.0',
          'license_url': 'https://example.com/license',
          'languages': 'English',
          'params': '1M',
          'roles': ['chat'],
          'repo': 'example/tiny-test',
          'commit': commit,
          'file': 'tiny.gguf',
          'size': bytes.length,
          'sha256': _sha256(good.path),
          'quant': 'Q8_0',
          'context': 2048,
          'memory': 64 << 20,
          'memory_metal': 64 << 20,
          'slot_memory': 1 << 20,
          'thinking': false,
          'chat_template': {
            'file': 'tiny.chat_template.jinja',
            'sha256': _sha256(template.path),
            'source': 'example/tiny-test@$commit',
          },
        },
      ],
    }));
  return (runtime: prog, catalog: catalog.path, good: good.path, tampered: tampered.path, settings: settings);
}

void main() {
  final antennad = findXd();
  final hasTools = ['python3', 'sha256sum'].every((t) => Process.runSync('sh', ['-c', 'command -v $t']).exitCode == 0);
  final hasSandbox = Platform.isLinux && Process.runSync('sh', ['-c', 'command -v bwrap']).exitCode == 0;
  // The flags exist only in a daemon with local models (hidden, so ask the parser rather than --help's text).
  final speaksV7 = antennad != null &&
      Process.runSync(antennad, ['--local-idle-secs', '30', '--local-catalog', '/nonexistent', '--help']).exitCode == 0;

  test('local models: catalog, a checked install, a local agent, a streamed turn, Stop, restart, reset', () async {
    final root = await tempRoot();
    final fx = _fixture(root);
    final args = ['--local-runtime', fx.runtime, '--local-catalog', fx.catalog, '--local-idle-secs', '60'];
    final node = XdNode('alice', root, antennad!, extraArgs: args);
    await node.start();
    final a = XControlClient(node.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: node.socket, factsEvery: const Duration(seconds: 5));
    Events? sub;
    var disposed = false;
    try {
      await a.init(node.password);
      await openOwnerSession(a, node.password);
      expect((await a.hello()).proto, 'x-control/7');
      sub = Events(a.subscribe());
      await sub.next<Subscribed>();

      // 1. The catalog: the test model, not on this computer yet; the computer and the runtime as the daemon read them.
      final all = await a.localModels();
      print('LOCAL: ${all.hardware.cpu} · ${all.hardware.memoryBytes >> 30} GiB · runtime ${all.runtime.available} '
          '${all.runtime.sandbox} (${all.runtime.detail})');
      final tiny = all.models.singleWhere((x) => x.id == _model);
      expect((tiny.state, tiny.sizeBytes, tiny.licenseUrl), (LocalModelState.available, 4 + 256 * 1024, 'https://example.com/license'));
      expect(all.runtime.available, isTrue, reason: all.runtime.detail);
      expect(all.agents, isEmpty);

      // 2. A tampered file of the right size: the check refuses it, and nothing of it stays.
      await a.modelInstall(_model, fromFile: fx.tampered);
      final bad = await sub.next<LocalModelEvent>(
          (e) => e.model.id == _model && e.model.state == LocalModelState.failed, const Duration(seconds: 30));
      expect(bad.model.errorCode, XErrorCode.hashMismatch);
      final models = Directory('${node.dir}/local/models');
      final left = models.existsSync() ? models.listSync().map((f) => f.path.split('/').last).toList() : <String>[];
      expect(left.where((n) => n.startsWith(_model)), isEmpty, reason: 'the mismatching file was deleted: $left');
      print('LOCAL: tampered → ${bad.model.errorCode} (${bad.model.error}); files left: $left');

      // 3. The real file: copied, checked, ready.
      sub.seen.removeWhere((e) => e is LocalModelEvent); // the tampered install's progress
      final states = <String>[];
      final installing = a.modelInstall(_model, fromFile: fx.good);
      final ready = await sub.next<LocalModelEvent>((e) {
        if (e.model.id == _model) states.add(e.model.state);
        return e.model.id == _model && e.model.state == LocalModelState.ready;
      }, const Duration(seconds: 30));
      print('LOCAL: install reply ${(await installing).state}, events $states');
      expect(ready.model.doneBytes, ready.model.sizeBytes);
      expect(File('${node.dir}/local/models/$_model.gguf').existsSync(), isTrue);

      // 4. A local agent on it (owner password, checked).
      await expectLater(a.localAgentAdd('helper', model: _model, password: 'wrong'),
          throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword)));
      final helper = await a.localAgentAdd('helper', model: _model, password: node.password);
      expect((helper.name, helper.model, helper.runtime), ('helper', _model, 'local'));
      final listed = (await a.agents()).singleWhere((x) => x.name == 'helper');
      expect(listed.localModel, _model);

      // The window: unlocked with the same password, it lists the model and the agent and opens the conversation.
      await m.connect();
      expect(await m.login(node.password), isNull);
      await _until(() => m.subscribed && m.localAgents.isNotEmpty, what: 'the window sees the local agent');
      expect(m.localModelsSupported, isTrue);
      expect(m.localModel(_model)?.state, LocalModelState.ready);
      expect(m.localAgent('helper')?.runsHere, isTrue);
      await m.selectLocalAgent('helper');
      expect(m.localChats['helper']!.items, isEmpty);

      // 5. A turn from another client: the reply streams word by word and ends done; the window, which did not ask,
      // reads the conversation again on the `local_agent` event.
      final say = a.localSay('helper', 'Hi from the test');
      final deltas = say.events.toList();
      final turn = await say.result.timeout(const Duration(seconds: 60)) as LocalTurnReply;
      final words = (await deltas).cast<LocalDeltaEvent>();
      print('LOCAL: turn ${turn.turn} ${turn.outcome} "${turn.text}" in ${words.length} events '
          '(activities ${words.map((e) => e.activity).whereType<String>().toSet()}), usage ${turn.usage?.outputTokens}');
      expect((turn.outcome, turn.text), ('done', 'Echo: Hi from the test'));
      expect(words.map((e) => e.delta).join(), turn.text);
      expect(words.where((e) => e.delta.isNotEmpty).length, greaterThanOrEqualTo(2), reason: 'one word per event');
      expect(words.map((e) => e.activity), contains('loading'), reason: 'a cold start: the model is loaded first');
      await _until(() => m.localChats['helper']!.items.length == 2, what: 'the window reads the turn from the event');

      // 6. A turn from the window itself.
      expect(await m.sayLocal('helper', 'And from the window'), isNull);
      final items = m.localChats['helper']!.items;
      expect(items.map((i) => (i.role, i.text)), [
        ('owner', 'Hi from the test'),
        ('agent', 'Echo: Hi from the test'),
        ('owner', 'And from the window'),
        ('agent', 'Echo: And from the window'),
      ]);
      expect(items.where((i) => !i.byOwner).map((i) => i.outcome), ['done', 'done']);
      final h = await a.localHistory('helper');
      expect(h.items.length, 4);

      // 7. Stop: a slow reply (the runtime restarts with the new setting) ends interrupted, its words so far kept.
      File(fx.settings).writeAsStringSync(jsonEncode({'delay_ms': 400}));
      await a.localSession('helper', LocalSessionAction.stop);
      final long = a.localSay('helper', 'one two three four five six seven eight nine ten eleven twelve');
      final longEvents = Events(long);
      await longEvents.next<LocalDeltaEvent>((e) => e.delta.isNotEmpty, const Duration(seconds: 60));
      await a.localSession('helper', LocalSessionAction.interrupt);
      final cut = await long.result.timeout(const Duration(seconds: 30)) as LocalTurnReply;
      print('LOCAL: interrupted turn "${cut.text}"');
      expect(cut.outcome, 'interrupted');
      expect(cut.text, startsWith('Echo:'));
      expect(cut.text, isNot('Echo: one two three four five six seven eight nine ten eleven twelve'));
      final afterCut = (await a.localHistory('helper')).items;
      expect(afterCut.last.outcome, 'interrupted');
      print('LOCAL: the interrupted turn in the history: detail "${afterCut.last.detail}"');
      expect(afterCut.last.detail, isNotEmpty, reason: 'the history says why a turn stopped (the window shows it)');
      expect(afterCut.length, 6);

      // 8. A restart: the conversation is still there (the node's encrypted database), the model ready.
      m.dispose();
      disposed = true;
      await node.stop();
      await node.start();
      a.sessionToken = null;
      await a.unlock(node.password);
      await openOwnerSession(a, node.password);
      final again = await a.localHistory('helper');
      expect(again.items.map((i) => i.text).take(4).toList(),
          ['Hi from the test', 'Echo: Hi from the test', 'And from the window', 'Echo: And from the window']);
      final after = await a.localModels();
      expect(after.models.singleWhere((x) => x.id == _model).state, LocalModelState.ready);
      expect(after.agents.single.name, 'helper');

      // 9. New conversation: the daemon deletes it.
      await a.localSession('helper', LocalSessionAction.reset);
      expect((await a.localHistory('helper')).items, isEmpty);
    } catch (e) {
      print('antennad log:\n${node.log}');
      rethrow;
    } finally {
      if (!disposed) m.dispose();
      await sub?.close();
      await node.stop();
      await root.delete(recursive: true);
    }
  },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: antennad == null
          ? noXdReason
          : !speaksV7
              ? 'needs antennad with local models (x-control/7: --local-runtime, --local-catalog)'
              : !hasTools
                  ? 'needs python3 and sha256sum'
                  : (!hasSandbox ? 'needs Linux with bwrap for the model sandboxes' : false));
}
