// SPDX-License-Identifier: AGPL-3.0-only
// The hook channel on the real file system with the real script (host/code_hooks.dart, D-UI-25): Claude Code runs each
// hook command through a shell with the event's JSON on standard input; the script records only the event's word, never
// the payload; the Stop hook prints a waiting continuation once, not when `stop_hook_active` is set; the window can take
// a continuation back; the folder is private and removed with the session.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run [command] as Claude Code does (`sh -c`), with [payload] as the hook's input.
Future<ProcessResult> _hook(String command, Map<String, Object?> payload) async {
  final p = await Process.start('/bin/sh', ['-c', command]);
  p.stdin.write(json.encode(payload));
  await p.stdin.close();
  final out = await p.stdout.transform(utf8.decoder).join();
  final err = await p.stderr.transform(utf8.decoder).join();
  return ProcessResult(p.pid, await p.exitCode, out, err);
}

String _mode(String path) => (FileStat.statSync(path).mode & 0x1ff).toRadixString(8);

void main() {
  late Directory root;
  late FileCodeHooks hooks;
  final seen = <ClaudeHookEvent>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('antenna-hooks-');
    hooks = FileCodeHooks.create('${root.path}/code', poll: const Duration(milliseconds: 20))!;
    seen.clear();
    hooks.listen(seen.add);
  });
  tearDown(() {
    hooks.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

  test('the folder and its files are private', () {
    expect(_mode('${root.path}/code'), '700');
    expect(_mode(hooks.dir), '700');
    expect(_mode('${hooks.dir}/hook.sh'), '700');
    expect(_mode('${hooks.dir}/events'), '600');
  });

  test('each hook records its word only; the payload is dropped', () async {
    for (final e in ClaudeHookEvent.values.where((e) => e != ClaudeHookEvent.continued)) {
      final r = await _hook(hooks.command(e), {
        'session_id': 's-1',
        'hook_event_name': e.hook,
        'prompt': 'my secret plan: sk-ant-api03-XXXX',
        'stop_hook_active': false,
      });
      expect((r.exitCode, r.stdout, r.stderr), (0, '', ''), reason: e.name);
    }
    await settle();
    expect(seen, ClaudeHookEvent.values.where((e) => e != ClaudeHookEvent.continued).toList());
    final recorded = File('${hooks.dir}/events').readAsStringSync();
    expect(recorded, isNot(contains('secret')));
    expect(recorded.split('\n').where((l) => l.isNotEmpty).every((l) => ClaudeHookEvent.parse(l) != null), isTrue);
  });

  test('Stop prints a waiting continuation once; not when stop_hook_active; the window can take it back', () async {
    final line = json.encode({'decision': 'block', 'reason': 'New Antenna messages: read your inbox and continue.'});
    expect(hooks.offerContinue(line), isTrue);
    expect(_mode('${hooks.dir}/continue'), '600');
    // The stop that follows a continuation does not continue again (no loops).
    var r = await _hook(hooks.command(ClaudeHookEvent.stop), {'hook_event_name': 'Stop', 'stop_hook_active': true});
    expect(r.stdout, '');
    // Claude Code 2.1.289 writes the payload compactly; a spaced variant is accepted as well.
    r = await _hook(hooks.command(ClaudeHookEvent.stop), {'hook_event_name': 'Stop', 'stop_hook_active': false});
    expect(r.stdout, line);
    expect(json.decode(r.stdout as String), {'decision': 'block', 'reason': 'New Antenna messages: read your inbox and continue.'});
    r = await _hook(hooks.command(ClaudeHookEvent.stop), {'hook_event_name': 'Stop', 'stop_hook_active': false});
    expect(r.stdout, '', reason: 'used once');
    await settle();
    expect(seen, [ClaudeHookEvent.stop, ClaudeHookEvent.continued, ClaudeHookEvent.stop]);
    expect(hooks.withdrawContinue(), isFalse, reason: 'already used');
    expect(hooks.offerContinue(line), isTrue);
    expect(hooks.withdrawContinue(), isTrue);
    r = await _hook(hooks.command(ClaudeHookEvent.stop), {'hook_event_name': 'Stop', 'stop_hook_active': false});
    expect(r.stdout, '', reason: 'taken back');
  });

  test('the session settings: the state hooks join the policy hooks; matchers where Claude Code takes them', () {
    final merged = mergeHooks({
      'hooks': {
        'PreToolUse': [
          {'matcher': '*', 'hooks': [{'type': 'command', 'command': 'antenna hook claude-code'}]},
        ],
      },
    }, claudeStateHooks(hooks.command));
    final h = merged['hooks']! as Map<String, Object?>;
    expect((h['PreToolUse']! as List).length, 2);
    final notes = (h['Notification']! as List).cast<Map<String, Object?>>();
    expect(notes.map((e) => e['matcher']), ['permission_prompt', 'idle_prompt']);
    expect((h['Stop']! as List).single, isNot(contains('matcher')));
    expect(hooks.command(ClaudeHookEvent.toolDone), "/bin/sh '${hooks.dir}/hook.sh' tool-done");
  });

  test('a path with a quote stays one shell word', () {
    expect(shellWord("/tmp/it's here"), "'/tmp/it'\\''s here'");
  });

  test('close removes the folder', () {
    final dir = hooks.dir;
    hooks.close();
    expect(Directory(dir).existsSync(), isFalse);
  });

  // D-103: the session ID for `claude --resume` after an update; nothing else of the hook input is kept.
  group('the session ID', () {
    const id = '5f0c2a9e-7d41-4b8e-9a63-2c1d0e8f4b17';
    final ids = <String>[];
    setUp(() {
      ids.clear();
      hooks.onSession(ids.add);
    });
    String? kept() => File('${hooks.dir}/session').existsSync()
        ? File('${hooks.dir}/session').readAsStringSync()
        : null;

    test('a hook keeps a UUID session_id, compact or spaced, and the window reports it once', () async {
      var r = await _hook(hooks.command(ClaudeHookEvent.start), {
        'session_id': id,
        'transcript_path': '/home/owner/.claude/projects/x/$id.jsonl',
        'hook_event_name': 'SessionStart',
        'source': 'startup',
      });
      expect(r.exitCode, 0);
      expect(kept(), '$id\n');
      expect(_mode('${hooks.dir}/session'), anyOf('600', '644', '664'), reason: 'written by the agent\'s own umask');
      // Claude Code writes its JSON compactly; a spaced payload is read too.
      const other = 'a1b2c3d4-0000-4000-8000-0123456789ab';
      final p = await Process.start('/bin/sh', ['-c', hooks.command(ClaudeHookEvent.prompt)]);
      p.stdin.write('{"session_id": "$other", "prompt": "the plan"}');
      await p.stdin.close();
      expect(await p.exitCode, 0);
      expect(kept(), '$other\n');
      r = await _hook(hooks.command(ClaudeHookEvent.toolDone), {'session_id': other, 'tool_response': 'x' * 200000});
      expect(r.exitCode, 0, reason: 'a large tool output is drained, not parsed');
      await settle();
      expect(ids.last, other, reason: 'the window polls: the last valid ID');
      expect(ids.toSet().length, ids.length, reason: 'each reported once');
      expect(File('${hooks.dir}/events').readAsStringSync(), isNot(contains('plan')));
    });

    test('anything that is not a UUID right after the key is ignored', () async {
      for (final bad in [
        {'session_id': 's-1'},
        {'session_id': '$id; rm -rf ~'},
        {'session_id': 'G${id.substring(1)}'},
        {'session_id': '${id}0'},
        {'session_id': null, 'x': id},
        {'session_id': 42},
        {'prompt': '"session_id":"$id"'},
      ]) {
        final r = await _hook(hooks.command(ClaudeHookEvent.prompt), bad);
        expect(r.exitCode, 0, reason: '$bad');
        expect(kept(), isNull, reason: '$bad');
      }
      // The window checks what it reads again: a file the agent wrote itself counts only as a UUID.
      File('${hooks.dir}/session').writeAsStringSync('../../etc/passwd\n');
      await settle();
      expect(ids, isEmpty);
      expect(validSessionId(id.toUpperCase()), isNull);
      expect(validSessionId(' $id\n'), id);
    });

    test('Codex: the notify program records the completed turn and keeps only a valid thread-id from its one JSON '
        'argument, in session.notify; the hooks\' session ID wins over it', () async {
      expect(hooks.notifyArgv, ['/bin/sh', '${hooks.dir}/notify.sh']);
      expect(_mode('${hooks.dir}/notify.sh'), '700');
      Future<int> notify(Object payload) async {
        final r = await Process.run(hooks.notifyArgv.first, [...hooks.notifyArgv.skip(1), json.encode(payload)]);
        return r.exitCode;
      }

      String? keptNotify() => File('${hooks.dir}/session.notify').existsSync()
          ? File('${hooks.dir}/session.notify').readAsStringSync()
          : null;
      String events() => File('${hooks.dir}/events').readAsStringSync();
      expect(await notify({'type': 'agent-turn-complete', 'thread-id': 'nope', 'last-assistant-message': id}), 0);
      expect(keptNotify(), isNull);
      expect(events(), 'turn-complete\n');
      // The type only counts at the head of the argument: text inside a message cannot fake it.
      expect(await notify({'type': 'other', 'last-assistant-message': '{"type":"agent-turn-complete"}'}), 0);
      expect(events(), 'turn-complete\n');
      expect(
          await notify({
            'type': 'agent-turn-complete',
            'thread-id': id,
            'turn-id': '12',
            'input-messages': ['secret plan'],
            'last-assistant-message': 'done',
          }),
          0);
      expect(keptNotify(), '$id\n');
      expect(kept(), isNull, reason: 'notify keeps its own file');
      await settle();
      expect(ids, [id]);
      // A hook's session ID (the conversation itself) comes first: Codex runs notify for its helper threads too.
      const other = '0f8fad5b-d9cb-469f-a165-70867728950e';
      await _hook(hooks.command(ClaudeHookEvent.stop), {'session_id': other, 'stop_hook_active': false});
      await settle();
      expect(ids, [id, other]);
    });
  });
}
