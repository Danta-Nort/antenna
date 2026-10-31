// SPDX-License-Identifier: AGPL-3.0-only
// Teams of agents against a REAL `antennad` (x-control/7, CONTROL §25, D-111), real sandboxes and real git: the
// window creates a team (a wrong password refused first); the lead, an agent driven through the agent CLI as a fake
// lead would drive it, spawns workers and writes tasks; the workers are a fake program that speaks Claude Code's
// stream-json and acts through the agent CLI in its sandbox. The window sees the workers, the tasks moving across the
// board, the daemon's check, each worker's live output attributed to that worker only, the diff; the lead's apply to
// `main` is refused (`approval_required`) and shows as the owner's request; a wrong password applies nothing; the
// owner's password moves `main` to the team's branch. Then the owner's own actions: a task, a worker, Stop, Remove.
// Run (one file at a time; Linux with bwrap, git 2.38+, python3):
//   ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_teams_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/state/teams.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 60), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// The fake worker: for a turn that names a task, it reads the task through the agent CLI, says what it does in a
/// few streamed pieces (one marker per worker), uses a "tool", writes the files the brief names
/// (`FILE <path> <base64>`), and submits.
const _fakeWorker = r'''#!/usr/bin/python3
import base64, json, os, re, subprocess, sys, time

def emit(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()

def say(text):
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
          "delta": {"type": "text_delta", "text": text}}, "parent_tool_use_id": None})

def antenna(*args):
    r = subprocess.run(["antenna", "--json", *args], capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    try:
        v = json.loads(lines[-1]) if lines else {}
    except ValueError:
        v = {}
    return r.returncode, v

me = os.environ.get("ANTENNA_AGENT", "worker")
emit({"type": "system", "subtype": "init", "session_id": ""})
for line in sys.stdin:
    try:
        v = json.loads(line)
    except ValueError:
        continue
    if v.get("type") != "user":
        continue
    text = v["message"]["content"]
    m = re.search(r"(?i)task ([0-9a-f]{16})", text)
    if m and "was cancelled" not in text:
        tid = m.group(1)
        code, t = antenna("task", "get", tid)
        say("MARK-%s reading the task. " % t.get("assignee", me))
        time.sleep(0.5)
        emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 1,
              "content_block": {"type": "tool_use", "id": "tool-1", "name": "Bash", "input": {}}},
              "parent_tool_use_id": None})
        time.sleep(0.3)
        for f in re.finditer(r"^FILE (\S+) (\S+)$", t.get("brief", ""), re.M):
            with open(f.group(1), "wb") as out:
                out.write(base64.b64decode(f.group(2)))
        say("Wrote the files. ")
        antenna("task", "report", tid, "submitted", "--summary", "round %s: fixed add()" % t.get("round"))
    emit({"type": "result", "subtype": "success", "is_error": False,
          "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}})
''';

const _calcBuggy = 'def add(a, b):\n    return a - b\n';
const _calcFixed = 'def add(a, b):\n    """The sum of a and b."""\n    return a + b\n';
const _calcTest = 'import unittest\n\nimport calc\n\n\nclass T(unittest.TestCase):\n    def test_add(self):\n'
    '        self.assertEqual(calc.add(2, 3), 5)\n\n    def test_doc(self):\n        self.assertTrue(calc.add.__doc__)\n';
const _check = ['python3', '-m', 'unittest', '-q'];

String _git(String dir, List<String> args) {
  final r = Process.runSync('git', ['-C', dir, ...args], environment: {
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_AUTHOR_NAME': 'Jordan Lee',
    'GIT_AUTHOR_EMAIL': 'jordan@example.com',
    'GIT_COMMITTER_NAME': 'Jordan Lee',
    'GIT_COMMITTER_EMAIL': 'jordan@example.com',
  });
  if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
  return '${r.stdout}'.trim();
}

String _project(Directory root) {
  final p = '${root.path}/project';
  Directory(p).createSync();
  _git(p, ['init', '-q', '-b', 'main']);
  _git(p, ['config', 'user.name', 'Jordan Lee']);
  _git(p, ['config', 'user.email', 'jordan@example.com']);
  File('$p/calc.py').writeAsStringSync(_calcBuggy);
  File('$p/test_calc.py').writeAsStringSync(_calcTest);
  File('$p/.gitignore').writeAsStringSync('__pycache__/\n');
  _git(p, ['add', '-A']);
  _git(p, ['commit', '-q', '-m', 'start']);
  return p;
}

String _brief(String content) => 'Fix add().\nFILE calc.py ${base64.encode(utf8.encode(content))}\n';

/// Version of git ≥ 2.38 (`merge-tree --write-tree`).
bool _gitNewEnough() {
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch('${Process.runSync('git', ['--version']).stdout}');
  if (m == null) return false;
  final (a, b) = (int.parse(m.group(1)!), int.parse(m.group(2)!));
  return a > 2 || (a == 2 && b >= 38);
}

void main() {
  final antennad = findXd();
  final cli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final hasTools = Platform.isLinux &&
      ['bwrap', 'python3', 'git'].every((t) => Process.runSync('sh', ['-c', 'command -v $t']).exitCode == 0) &&
      _gitNewEnough();
  // `antenna team` exists only in a CLI (and daemon) with teams.
  final hasTeams = cli != null &&
      File(cli).existsSync() &&
      Process.runSync(cli, ['team', 'create', '--help'], environment: ownerCliEnv(), includeParentEnvironment: false)
              .exitCode ==
          0;

  test('a lead and a worker of a real daemon on the board; the owner applies with the password', () async {
    final root = await tempRoot();
    final node = XdNode('alice', root, antennad!);
    await node.start();
    final a = XControlClient(node.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: node.socket, factsEvery: const Duration(seconds: 5));
    try {
      await a.init(node.password);
      await openOwnerSession(a, node.password);
      final proj = _project(root);
      final start = _git(proj, ['rev-parse', 'main']);
      final fake = File('${root.path}/fake-worker')..writeAsStringSync(_fakeWorker);
      Process.runSync('chmod', ['755', fake.path]);
      final leadToken = (await a.agentAdd('lead', localLevel: 0, password: node.password)).token;

      /// The lead's agent CLI: the JSON of its reply, or of its error with the exit code.
      Future<(int, Map<String, Object?>)> lead(List<String> args) async {
        final r = await Process.run(cli!, ['--json', ...args],
            environment: {...ownerCliEnv(), 'ANTENNA_AGENT_TOKEN': leadToken, 'ANTENNA_SOCKET': node.socket},
            includeParentEnvironment: false);
        final lines = '${r.stdout}'.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final v = lines.isEmpty ? <String, Object?>{} : jsonDecode(lines.last) as Map<String, Object?>;
        return (r.exitCode, v);
      }

      // The window, signed in.
      await m.connect();
      expect(await m.login(node.password), isNull);
      await _until(() => m.subscribed && m.teamsLoaded, what: 'the window reads the teams');
      expect(m.teamsSupported, isTrue);
      expect(m.teams, isEmpty);

      // 1. New team from the window: a wrong password first.
      TeamCreateRequest create(String pw) => TeamCreateRequest(
            name: 'web',
            project: proj,
            lead: 'lead',
            slots: [TeamSlot(role: 'coder', kind: WorkerKind.program, max: 2, argv: [fake.path])],
            template: const TeamTemplate(checks: [_check], checkRetries: 1),
            password: pw,
          );
      final (_, bad) = await m.createTeam(const PasswordAuth('wrong'), create);
      expect(bad, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      final (team, err) = await m.createTeam(PasswordAuth(node.password), create);
      expect(err, isNull);
      expect((team!.integration, team.target, team.lead), ('antenna/web', 'main', 'lead'));
      expect(_git(proj, ['rev-parse', 'antenna/web']), start);

      // 2. The lead spawns a worker and writes a task for it; the window shows both from the `team` events.
      final (sc, spawned) = await lead(['worker', 'spawn', 'coder']);
      expect(sc, 0, reason: '$spawned');
      expect(spawned['name'], 'web.coder-1');
      await _until(() => m.team('web')?.worker('web.coder-1') != null, what: 'the worker on the board');
      final (tc, task) = await lead([
        'task', 'create', 'Fix add', '--brief', _brief(_calcFixed), '--check', _check.join(' '), '--assign', 'web.coder-1',
      ]);
      expect(tc, 0, reason: '$task');
      final id = task['id']! as String;
      await _until(() => m.task(id) != null, what: 'the task on the board');

      // 3. The worker submits, the daemon's check passes: in review, with the worker's note and the passing check.
      await _until(() => m.task(id)?.state == TaskState.submitted && m.task(id)?.checkRun?.outcome == 'passed',
          timeout: const Duration(seconds: 120), what: 'the result in review with its check');
      final board = boardOf(m.team('web')!);
      expect(board[BoardColumn.review]!.map((t) => t.id), [id]);
      await _until(() => (m.taskDetails[id]?.report?.summary ?? '').contains('fixed add()'), what: 'the note');
      final (diff, derr) = await m.taskDiff(id);
      expect(derr, isNull);
      expect(diff!.diff, contains('return a + b'));
      print('TEAMS: the board after the submit: ${[for (final e in board.entries) '${e.key.name} ${e.value.length}']}');

      // The worker's live output, if this daemon streams it (team_watch): attributed to that worker only.
      if (!m.teamWatchAbsent) {
        await _until(() => (m.workerLive['web.coder-1']?.text ?? '').contains('MARK-web.coder-1'),
            what: 'the worker\'s live output');
        expect(m.workerLive.keys, everyElement(startsWith('web.')), reason: 'only this team\'s workers');
        print('TEAMS: live output of web.coder-1: "${m.workerLive['web.coder-1']!.text.trim()}"');
      } else {
        print('TEAMS: this daemon has no team_watch: the window shows the workers\' last detail');
      }
      if (!m.teamCapacityAbsent) expect(m.capacity('web')!.machine, 'this computer');

      // 4. The lead accepts and merges into the team's branch; its apply to main waits for the owner.
      expect((await lead(['task', 'review', id, 'accept'])).$1, 0);
      expect((await lead(['task', 'apply', id])).$1, 0);
      final (ac, asked) = await lead(['task', 'apply', '--target']);
      expect(ac, isNot(0));
      expect(asked['error'], XErrorCode.approvalRequired, reason: '$asked');
      await _until(() => m.team('web')?.applyRequest != null, what: 'the lead\'s request in the window');
      expect(_git(proj, ['rev-parse', 'main']), start, reason: 'nothing moves without the owner');
      final integration = m.team('web')!.integrationCommit;
      expect(integration, _git(proj, ['rev-parse', 'antenna/web']));
      expect(m.task(id)?.state, TaskState.done);

      // 5. The owner: a wrong password applies nothing; the password moves main, pinned to what the window showed.
      final wrong = await m.applyTeam('web', commit: integration, auth: const PasswordAuth('wrong'));
      expect(wrong, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      expect(_git(proj, ['rev-parse', 'main']), start);
      expect(await m.applyTeam('web', commit: integration, auth: PasswordAuth(node.password)), isNull);
      expect(_git(proj, ['rev-parse', 'main']), integration);
      expect(File('$proj/calc.py').readAsStringSync(), _calcFixed, reason: 'the checked-out folder moved too');
      await _until(() => m.team('web')?.applyRequest == null, what: 'the request answered');

      // 6. The owner's own actions: a worker (no password), a task for it, Stop, Remove.
      expect(await m.addTeamWorker('web', 'coder'), isNull);
      expect(m.team('web')!.worker('web.coder-2'), isNotNull);
      final (own, oerr) = await m.newTask(TaskNewRequest(team: 'web', title: 'Owner task', check: _check));
      expect(oerr, isNull);
      expect(own!.createdBy, 'owner');
      expect(m.task(own.id)?.state, TaskState.open);
      expect(await m.stopTeam('web'), isNull);
      expect(m.team('web')!.active, isFalse);
      expect(m.team('web')!.workers.every((w) => w.stopped), isTrue);
      final log = (await m.teamLog('web')).$1;
      expect(log.map((e) => e.action), containsAll(['team_create', 'worker_spawn', 'task_report', 'team_apply']));
      print('TEAMS: ${log.length} log entries: ${log.map((e) => '${e.actor}:${e.action}:${e.decision}').join(', ')}');
      expect(await m.removeTeam('web'), isNull);
      expect(m.teams, isEmpty);
      expect(_git(proj, ['rev-parse', 'antenna/web']), integration, reason: 'the team\'s branch stays');
    } catch (e) {
      print('antennad log:\n${node.log}');
      rethrow;
    } finally {
      m.dispose();
      await node.stop();
      await root.delete(recursive: true);
    }
  },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: antennad == null
          ? noXdReason
          : !hasTeams
              ? 'needs antennad and antenna with teams (x-control/7, CONTROL §25)'
              : (!hasTools ? 'needs Linux with bwrap, python3 and git 2.38+' : false));
}
