// SPDX-License-Identifier: AGPL-3.0-only
// The Code mode wake (PG-21) against the REAL Codex CLI, through the window's own machinery: two real daemons (bob
// writes to alice's agent), the agent's token from the owner flow, the bash wrapper, a real pseudo-terminal, the
// session-only hooks and `notify` passed with `-c`, and the window's hook channel. Codex talks to a stand-in for its
// model endpoint on loopback (a few lines of Python below that stream "ok"), so no account is involved: what is tested
// is the CLI itself, its hooks, its screen and its approval of Antenna's hooks.
//
// One run:
// 1. Codex starts with a throwaway CODEX_HOME (its configuration there points at the stand-in; the window passes
//    CODEX_HOME on to the CLI as the user's own setting, and the agent's process inherits the test process's
//    environment, so the variable must be set for the test process itself) and asks the owner to trust
//    the new hooks ("Hooks need review"): nothing is typed into that; the test answers "Trust all and continue" as the
//    owner would;
// 2. at its empty composer, `codexReady` recognises the screen; a quick reply is one turn (the hooks report
//    SessionStart, UserPromptSubmit, Stop);
// 3. a message for the agent at the idle composer: the window types the fixed line once (a new turn by the hooks);
// 4. after the 30 s limit, a turn the owner starts with a quick reply, and a message during it: the turn's Stop hook
//    continues it once, nothing typed.
// Runs only with ANTENNA_REAL_CODEX=<path to codex> and CODEX_HOME=<an empty throwaway folder>; skipped otherwise (the
// account's own ~/.codex is never used). Codex 0.160.1 on 2026-10-06 (PG-21).
// Run: CODEX_HOME=$(mktemp -d) ANTENNA_REAL_CODEX=<path to codex> ANTENNAD_BIN=<path to antennad> nice -n 10 flutter
// test --tags real-cli test/protocol/live_code_real_codex_test.dart
@Tags(['live', 'real-cli'])
@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/pty_native.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

/// A stand-in for an OpenAI Responses endpoint: every request gets "ok" streamed back after [delay] seconds. Prints
/// its port on its first line.
const _endpoint = r'''
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DELAY = float(sys.argv[1])
def sse(name, data):
    return ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", "0")))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        rid, mid = "resp_%d" % (time.time() * 1000), "msg_%d" % (time.time() * 1000)
        item = {"id": mid, "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        self.wfile.write(sse("response.created", {"type": "response.created", "response": {"id": rid, "object": "response", "status": "in_progress", "output": []}}))
        self.wfile.flush()
        time.sleep(DELAY)
        for e in [sse("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress", content=[])}),
                  sse("response.output_text.delta", {"type": "response.output_text.delta", "item_id": mid, "output_index": 0, "content_index": 0, "delta": "ok"}),
                  sse("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
                  sse("response.completed", {"type": "response.completed", "response": {"id": rid, "object": "response", "status": "completed", "output": [item],
                      "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11, "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}})]:
            self.wfile.write(e)
            self.wfile.flush()
        self.close_connection = True
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
''';

final class Broke implements Exception {
  const Broke(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 30), required String what}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw Broke('no $what within ${timeout.inSeconds} s');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final codex = Platform.environment['ANTENNA_REAL_CODEX'];
  final codexHome = Platform.environment['CODEX_HOME'];
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';

  test('the Code mode wake works with the real Codex CLI', () async {
    var stage = 'prerequisites';
    AgentRun? run;
    FileCodeHooks? channel;
    Process? endpoint;
    List<String> events() {
      final f = File('${channel?.dir}/events');
      return channel != null && f.existsSync() ? f.readAsLinesSync() : const [];
    }

    Future<int> event(String word, {required int from, Duration timeout = const Duration(seconds: 60)}) async {
      var at = -1;
      await until(() {
        final e = events();
        for (var i = from; i < e.length; i++) {
          if (e[i] == 'permission') throw Broke('an approval opened (hook events: ${e.join(' ')})');
          if (e[i] == word) {
            at = i;
            return true;
          }
        }
        return false;
      }, timeout: timeout, what: 'hook event "$word" (events: ${events().join(' ')})');
      return at;
    }

    final root = await tempRoot();
    final home = Directory('${root.path}/home')..createSync();
    final work = Directory('${root.path}/project')..createSync();
    XdNode? alice, bob;
    AppModel? m;
    try {
      if (antennad == null) throw Broke(noXdReason);
      final noPty = await loadPtyLibrary();
      if (noPty != null) throw Broke(noPty);
      final version = '${Process.runSync(codex!, ['--version']).stdout}'.trim();
      print('CODEX version $version');

      stage = 'the model stand-in';
      File('${root.path}/endpoint.py').writeAsStringSync(_endpoint);
      endpoint = await Process.start('python3', ['${root.path}/endpoint.py', '4']);
      final port = await endpoint.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      // A configuration there means a real one: never overwritten (`codex --version` above only adds its state files)
      if (File('$codexHome/config.toml').existsSync()) throw Broke('CODEX_HOME must be a throwaway folder');
      File('$codexHome/config.toml').writeAsStringSync('''
model_provider = "fake"
model = "fake-model"

[model_providers.fake]
name = "Fake"
base_url = "http://127.0.0.1:$port/v1"
wire_api = "responses"
requires_openai_auth = false
''');

      stage = 'two daemons and a link';
      alice = XdNode('alice', root, antennad);
      bob = XdNode('bob', root, antennad);
      await Future.wait([alice.start(), bob.start()]);
      final a = XControlClient(alice.socket);
      final b = XControlClient(bob.socket);
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'Bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
          link: created.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: bob.password)));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      final agent = await a.agentAdd('codex-canary', localLevel: 0, password: alice.password, links: ['Bob']);
      final hi = await Process.run(xCli!, ['--json', 'send', 'Bob', 'codex here', '--wait', '3s'],
          environment: {'ANTENNA_AGENT_TOKEN': agent.token, 'ANTENNA_SOCKET': alice.socket});
      if (hi.exitCode != 0) throw Broke('the agent could not write to bob: ${hi.stdout}${hi.stderr}');
      final announced = Stopwatch()..start();
      while (!(await b.contacts()).single.agents.any((x) => x.name == 'codex-canary')) {
        if (announced.elapsed > const Duration(seconds: 20)) throw const Broke('bob does not see the agent');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      stage = 'Start agent';
      final env = {
        'HOME': home.path,
        'PATH': '${File(codex).parent.path}:/usr/local/bin:/usr/bin:/bin',
        'LANG': 'C.UTF-8',
      };
      final model = m = AppModel(
        connector: XControlClient.new,
        socketPath: alice.socket,
        binaries: CoreBinaries(daemon: antennad, cli: xCli),
        agentHost: AgentHost(
          startPty: SystemPty.start,
          env: env,
          newHooks: () => channel = FileCodeHooks.create('${root.path}/code'),
        ),
      );
      await model.connect();
      final loginErr = await model.login(alice.password);
      if (loginErr != null) throw Broke('login: $loginErr');
      await until(() => model.subscribed, what: 'subscription');
      final startErr = await model.startAgent(
          AgentRunSpec(agent: 'codex-canary', cli: AgentCli.codex, workDir: work.path),
          auth: PasswordAuth(alice.password));
      if (startErr != null) throw Broke('startAgent: $startErr');
      final r = run = model.runOf('codex-canary')!;
      String rows() => r.screenRows().join('\n');

      stage = 'the hooks review';
      // Codex draws its composer for a moment before the review comes up: only a steady composer counts
      var steady = DateTime.now();
      await until(() {
        if (!codexReady(r.screen())) steady = DateTime.now();
        return rows().contains('Hooks need review') || DateTime.now().difference(steady) > const Duration(seconds: 3);
      }, timeout: const Duration(seconds: 40), what: 'the hooks review or the composer');
      if (rows().contains('Hooks need review')) {
        // A message now must not be typed into Codex's question
        await b.send('alice', 'early message', address: const MessageAddress.agent('codex-canary'));
        await Future<void>.delayed(const Duration(seconds: 8));
        if (!rows().contains('Hooks need review')) throw Broke('the hooks review went away by itself:\n${rows()}');
        // The owner: "2. Trust all and continue" (the digit selects, Enter confirms)
        r.terminal.textInput('2');
        await until(() => rows().contains('› 2. Trust all'), what: '"Trust all" selected');
        r.terminal.textInput('\r');
      }
      // The composer, steadily (a dialog closing can show it for a frame)
      var since = DateTime.now();
      await until(() {
        if (!codexReady(r.screen())) since = DateTime.now();
        return DateTime.now().difference(since) > const Duration(seconds: 2);
      }, timeout: const Duration(seconds: 30), what: 'the empty composer');

      stage = 'turn 1 (quick reply)';
      // The early message's wake may come first, at the composer: let it run its turn
      await Future<void>.delayed(const Duration(seconds: 8));
      await until(() => r.claude.state != ClaudeState.working, timeout: const Duration(seconds: 60), what: 'idle');
      final from1 = events().length;
      model.quickReply(r, QuickReply.goAhead);
      await event('prompt', from: from1);
      await event('stop', from: from1);
      print('CODEX turn 1 hook events: ${events().join(' ')}');
      if (!events().contains('start')) throw Broke('no SessionStart (events: ${events().join(' ')})');

      stage = 'a message at the idle composer';
      await Future<void>.delayed(const Duration(seconds: 31));
      await until(() => codexReady(r.screen()), what: 'the empty composer after the turn');
      final from2 = events().length;
      final sent = Stopwatch()..start();
      await b.send('alice', 'Codex check from Bob: nothing to do.', address: const MessageAddress.agent('codex-canary'));
      await event('prompt', from: from2, timeout: const Duration(seconds: 30));
      print('CODEX typed line started a turn ${sent.elapsedMilliseconds} ms after the message');
      await event('stop', from: from2);
      final typed = [for (final e in model.codeLineLog) if (e.kind == CodeLineKind.wake && !e.continued) e];
      if (typed.isEmpty) throw Broke('no typed wake line in the log');

      stage = 'a message during a turn';
      await Future<void>.delayed(const Duration(seconds: 31));
      final from3 = events().length;
      model.quickReply(r, QuickReply.checkChat);
      await event('prompt', from: from3);
      await b.send('alice', 'Second check from Bob.', address: const MessageAddress.agent('codex-canary'));
      await until(() {
        final e = events().sublist(from3);
        if (e.contains('continued')) return true;
        if (e.contains('stop')) throw Broke('the turn ended without the Stop hook continuing it (${e.join(' ')})');
        return false;
      }, timeout: const Duration(seconds: 60), what: 'the Stop hook continuing the turn');
      await event('stop', from: events().indexOf('continued', from3));
      print('CODEX turn 3 hook events: ${events().sublist(from3).join(' ')}');
      print('CODEX PASS $version: hooks trusted once, typed at the idle composer, continued by the Stop hook');
    } on Object catch (e) {
      print('CODEX FAIL $stage: $e');
      fail('at "$stage": $e\nhook events: ${events().join(' ')}\nscreen:\n${run?.screenRows().join('\n')}');
    } finally {
      await m?.stopAllRuns();
      m?.dispose();
      endpoint?.kill();
      await Future.wait([?alice?.stop(), ?bob?.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: codex == null || codex.isEmpty || codexHome == null || codexHome.isEmpty
          ? 'the real Codex runs only with ANTENNA_REAL_CODEX=<path to codex> and CODEX_HOME=<an empty throwaway '
              'folder> (no account needed: a stand-in endpoint)'
          : false,
      timeout: const Timeout(Duration(minutes: 6)));
}
