// SPDX-License-Identifier: AGPL-3.0-only
// Claude Code reports its state to the window through its documented hooks (D-UI-25), not through its screen layout,
// which changes with every release. When Code mode starts Claude Code, the session-only settings (`--settings`, added
// to the user's and the project's own, which stay untouched) register one fixed command per hook event. The command
// runs a small script the window wrote into a folder of its own (0700) and appends only the event's name to the
// `events` file there; nothing the hook receives on its standard input is kept. Checked on Claude Code 2.1.289:
// SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop and SessionEnd fire as named; a
// project's own hooks still run next to these; an Esc that interrupts a turn or closes a permission dialog fires
// nothing (the window learns that from the owner's own keys, claude_state.dart).
//
// The Stop hook can also continue a turn by itself: when the window left a line in the `continue` file (an
// `AllowedLine`, code_lines.dart), the script prints it once as `{"decision":"block","reason":…}`, and Claude Code
// goes on with that line instead of waiting for the keyboard. Not when `stop_hook_active` is set (the stop already
// follows such a continuation: no loops).
//
// The session ID, for a restore after an update (D-103, `claude --resume <id>`): every hook's input carries the CLI's
// `session_id`; the script keeps it in the `session` file only when it looks like a UUID, and the window checks it
// again ([validSessionId]). Nothing else of the input is kept. Codex has a documented `notify` program, run when a turn
// completes with one JSON argument that carries its `thread-id`: the same folder holds a second fixed script for it,
// which records `turn-complete` and keeps only a valid ID, in `session.notify` (Codex runs it for its helper threads
// too, so the hooks' `session` comes first). Codex 0.160 and later also have hooks of the same kind as Claude Code's
// (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop, Interrupt, SessionEnd), passed
// with `-c hooks.<Event>=…` ([codexStateHookOverrides]); Codex asks the owner to trust a new hook definition once, so
// their command text names the folder through [codeHooksVar] and stays the same from one run to the next. Checked on
// Codex 0.160.1 (PG-21).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'program_locator.dart' show isWindowsAbsolute;

/// The hook events the window registers, and the word each one writes.
enum ClaudeHookEvent {
  start('SessionStart'),
  prompt('UserPromptSubmit'),
  tool('PreToolUse'),
  permission('PermissionRequest'),
  toolDone('PostToolUse'),
  notifyPermission('Notification'),
  notifyIdle('Notification'),
  stop('Stop'),
  end('SessionEnd'),

  /// Codex only: Esc ended a turn or closed a dialog (no Stop follows).
  interrupt('Interrupt'),

  /// Written by the script itself: the Stop hook continued the turn with the window's line.
  continued(''),

  /// Written by Codex's `notify` program: a turn of some thread completed (its helper threads' too).
  turnComplete('');

  const ClaudeHookEvent(this.hook);

  /// Claude Code's name of the hook event (`''`: not a hook).
  final String hook;

  /// The word in the `events` file.
  String get word => switch (this) {
        toolDone => 'tool-done',
        notifyPermission => 'notify-permission',
        notifyIdle => 'notify-idle',
        turnComplete => 'turn-complete',
        _ => name,
      };

  static ClaudeHookEvent? parse(String word) => values.where((e) => e.word == word).firstOrNull;
}

/// The script every hook runs (`/bin/sh <dir>/hook.sh <word>`). Fixed text: no path, label or message is built into
/// it; it finds its folder from its own path. The Stop hook's input is short and read whole; of the others only the
/// head is read (`session_id` stands first) and the rest is drained unread, so a large tool output costs nothing. The
/// session ID is kept only when it is 36 characters of `[0-9a-f-]` right after its key (`"session_id":"…"` or
/// `"session_id": "…"`); only the first occurrence counts.
const codeHookScript = r'''# Antenna Code mode: Claude Code calls this for its hook events. Only the event's name and a valid session ID are
# recorded for the window; the rest of what the hook receives is read and dropped. Stop: when the window left a line
# to continue with, print it once.
d=${0%/*}
if [ "$1" = stop ]; then
  p=$(cat)
else
  p=$(head -c 1024)
  cat > /dev/null
fi
case $p in
  *'"session_id"'*)
    s=${p#*'"session_id"'}
    q=${s%%'"'*}
    s=${s#*'"'}
    s=${s%%'"'*}
    case $q in ':'|': ') ;; *) s= ;; esac
    case $s in *[!0-9a-f-]*) s= ;; esac
    if [ ${#s} -eq 36 ]; then
      printf '%s\n' "$s" > "$d/session.$$" && mv -f "$d/session.$$" "$d/session"
    fi
    ;;
esac
if [ "$1" = stop ]; then
  case $p in
    *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) ;;
    *)
      if mv -f "$d/continue" "$d/continue.taken" 2>/dev/null; then
        cat "$d/continue.taken"
        rm -f "$d/continue.taken"
        printf 'continued\n' >> "$d/events"
        exit 0
      fi
      ;;
  esac
fi
printf '%s\n' "$1" >> "$d/events"
''';

/// The program Codex runs when a turn completes (its documented `notify` setting), with one JSON argument
/// (`{"type":"agent-turn-complete","thread-id":…}`): it appends `turn-complete` to the `events` file when the argument
/// starts with that type (the wake's state for Codex, PG-21; the text inside the argument cannot fake it, only its
/// head counts), and keeps only a valid thread ID, under the same rule as above. `antenna session` writes the same
/// script (crates/antenna-cli/src/session/hooks.rs; a test there compares the two).
const codeNotifyScript = r'''# Antenna Code mode: Codex runs this when a turn completes, with one JSON argument. Only that a turn completed and a
# valid thread ID are recorded for the window (the wake, and resuming the session after an update); the rest of the
# argument is dropped. The ID goes to session.notify: Codex runs this for its helper threads too, so an ID the hooks
# recorded (session) comes first.
d=${0%/*}
p=$1
case $p in
  '{"type":"agent-turn-complete"'*|'{"type": "agent-turn-complete"'*) printf 'turn-complete\n' >> "$d/events" ;;
esac
case $p in
  *'"thread-id"'*)
    s=${p#*'"thread-id"'}
    q=${s%%'"'*}
    s=${s#*'"'}
    s=${s%%'"'*}
    case $q in ':'|': ') ;; *) s= ;; esac
    case $s in *[!0-9a-f-]*) s= ;; esac
    if [ ${#s} -eq 36 ]; then
      printf '%s\n' "$s" > "$d/session.$$" && mv -f "$d/session.$$" "$d/session.notify"
    fi
    ;;
esac
exit 0
''';

final _sessionId = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// [s] as a session ID the window may pass to `claude --resume` or `codex resume`: a lower-case UUID and nothing else
/// (`null` otherwise). The hook folder is writable by the agent, so what the scripts kept is checked again here.
String? validSessionId(String? s) {
  final t = s?.trim();
  return t != null && _sessionId.hasMatch(t) ? t : null;
}

/// The variable that names a session's hook folder for Codex's hooks (`antenna session` sets the same one).
const codeHooksVar = 'ANTENNA_CODE_HOOKS';

/// Codex's `-c` overrides that register the state hooks (the same events and words as for Claude Code, Interrupt for
/// Esc, no Notification). The command finds the folder through [codeHooksVar]: the text is the same in every run, so
/// the owner's trust (Codex's "Hooks need review", asked once) holds. `antenna session` builds the same overrides
/// (crates/antenna-cli/src/session/hooks.rs, `codex_hook_overrides`). On Windows ([windows]) the command is
/// `antenna hook-signal <word>` ([FileCodeHooks.create]), which finds the folder the same way.
List<String> codexStateHookOverrides({bool windows = false}) => [
      for (final (e, matcher) in const [
        (ClaudeHookEvent.start, null),
        (ClaudeHookEvent.prompt, null),
        (ClaudeHookEvent.tool, '*'),
        (ClaudeHookEvent.permission, '*'),
        (ClaudeHookEvent.toolDone, '*'),
        (ClaudeHookEvent.stop, null),
        (ClaudeHookEvent.interrupt, null),
        (ClaudeHookEvent.end, null),
      ]) ...[
        '-c',
        'hooks.${e.hook}=[{${matcher == null ? '' : 'matcher=${jsonEncode(matcher)},'}'
            'hooks=[{type="command",command=${jsonEncode(_codexHook(e.word, windows: windows))}}]}]',
      ],
    ];

String _codexHook(String word, {required bool windows}) =>
    windows ? '$hookSignalCommand $word' : '/bin/sh "\$$codeHooksVar/hook.sh" $word';

/// Code mode's hook command on Windows, before the event's word: a bare `antenna`, which the agent's Path finds first
/// (`windowsAgentEnvironment`). Claude Code and Codex run a hook's command in a shell (Git Bash, cmd or PowerShell),
/// each quoting a path its own way; a bare name is the same in all of them. It reports into [codeHooksVar]'s folder.
const hookSignalCommand = 'antenna hook-signal';

/// A path as one single-quoted shell word.
String shellWord(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// The `hooks` entries for one Claude Code session, each running [command] with the event's word.
Map<String, List<Map<String, Object?>>> claudeStateHooks(String Function(ClaudeHookEvent e) command) {
  Map<String, Object?> entry(ClaudeHookEvent e, {String? matcher}) => {
        'matcher': ?matcher,
        'hooks': [
          {'type': 'command', 'command': command(e)},
        ],
      };
  return {
    'SessionStart': [entry(ClaudeHookEvent.start)],
    'UserPromptSubmit': [entry(ClaudeHookEvent.prompt)],
    'PreToolUse': [entry(ClaudeHookEvent.tool, matcher: '*')],
    'PermissionRequest': [entry(ClaudeHookEvent.permission, matcher: '*')],
    'PostToolUse': [entry(ClaudeHookEvent.toolDone, matcher: '*')],
    'Notification': [
      entry(ClaudeHookEvent.notifyPermission, matcher: 'permission_prompt'),
      entry(ClaudeHookEvent.notifyIdle, matcher: 'idle_prompt'),
    ],
    'Stop': [entry(ClaudeHookEvent.stop)],
    'SessionEnd': [entry(ClaudeHookEvent.end)],
  };
}

/// Hooks [extra] added to the session settings [base] (both `{"hooks": {event: [entries]}}`): entries of the same
/// event are kept side by side, as Claude Code itself merges settings.
Map<String, Object?> mergeHooks(Map<String, Object?> base, Map<String, List<Map<String, Object?>>> extra) {
  final hooks = <String, Object?>{...(base['hooks'] as Map<String, Object?>? ?? const {})};
  for (final e in extra.entries) {
    hooks[e.key] = [...(hooks[e.key] as List<Object?>? ?? const []), ...e.value];
  }
  return {...base, 'hooks': hooks};
}

/// One running Claude Code session's channel to the window.
abstract interface class CodeHooks {
  /// The hook command for [e] (what the session settings name).
  String command(ClaudeHookEvent e);

  /// Start reporting events (in the order Claude Code ran the hooks).
  void listen(void Function(ClaudeHookEvent e) onEvent);

  /// Report the CLI's session ID each time the scripts record a new valid one ([validSessionId]).
  void onSession(void Function(String id) onId);

  /// Codex's `notify` program: the argv of the fixed script that records its thread ID.
  List<String> get notifyArgv;

  /// The folder Codex's hooks find through [codeHooksVar].
  String get folder;

  /// Leave [json] (the Stop hook's answer) for the next Stop. `false` when it could not be written.
  bool offerContinue(String json);

  /// Take back a continuation the Stop hook has not used; `true` when it was still there.
  bool withdrawContinue();

  /// The session is over: stop listening and remove the folder.
  void close();
}

/// Where the channels live: macOS ~/Library/Caches/Antenna/code, Linux $XDG_CACHE_HOME/antenna/code, Windows
/// %LOCALAPPDATA%\AntennaCache\code: beside the data folder (%LOCALAPPDATA%\Antenna, made and checked by antennad
/// alone), never inside it, with the profile's entries (the user, SYSTEM and the Administrators).
String? codeHooksRoot(Map<String, String> env, {bool? macos, bool? windows}) {
  if (windows ?? Platform.isWindows) {
    final local = env.entries.where((e) => e.key.toUpperCase() == 'LOCALAPPDATA').map((e) => e.value).firstOrNull;
    return local != null && isWindowsAbsolute(local) ? '$local\\AntennaCache\\code' : null;
  }
  final home = env['HOME'] ?? '';
  if (!home.startsWith('/')) return null;
  if (macos ?? Platform.isMacOS) return '$home/Library/Caches/Antenna/code';
  final xdg = env['XDG_CACHE_HOME'];
  return '${(xdg != null && xdg.startsWith('/')) ? xdg : '$home/.cache'}/antenna/code';
}

/// The real channel: a 0700 folder with the scripts, the `events` file (polled), the `session` file (polled) and,
/// while one waits, `continue`.
final class FileCodeHooks implements CodeHooks {
  FileCodeHooks._(this.dir, {this.poll = const Duration(milliseconds: 250), this.windowsCli});

  /// A new channel under [root] (`null` when the folder cannot be made private). On Windows ([windowsCli]: the
  /// `antenna` CLI's full path) the folder takes %LOCALAPPDATA%'s entries and holds no scripts: the hooks run
  /// [hookSignalCommand], and Codex's `notify` runs `<windowsCli> hook-signal --notify` (an argv, so the full path),
  /// which write the same files.
  static FileCodeHooks? create(String root, {Duration poll = const Duration(milliseconds: 250), String? windowsCli}) {
    try {
      final top = Directory(root);
      if (FileSystemEntity.typeSync(root, followLinks: false) == FileSystemEntityType.notFound) {
        top.createSync(recursive: true);
      }
      if (FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.directory) return null;
      if (windowsCli != null) {
        final dir = top.createTempSync('session-');
        File('${dir.path}/events').writeAsStringSync('', flush: true);
        return FileCodeHooks._(dir.path, poll: poll, windowsCli: windowsCli);
      }
      _chmod(root, '700');
      final dir = top.createTempSync('session-');
      _chmod(dir.path, '700');
      final script = File('${dir.path}/hook.sh')..writeAsStringSync(codeHookScript, flush: true);
      _chmod(script.path, '700');
      final notify = File('${dir.path}/notify.sh')..writeAsStringSync(codeNotifyScript, flush: true);
      _chmod(notify.path, '700');
      final events = File('${dir.path}/events')..writeAsStringSync('', flush: true);
      _chmod(events.path, '600');
      return FileCodeHooks._(dir.path, poll: poll);
    } on Object catch (e) {
      debugPrint('code hooks: $e');
      return null;
    }
  }

  final String dir;
  final Duration poll;

  /// Windows: the `antenna` CLI the hooks run (`null` elsewhere: the scripts).
  final String? windowsCli;

  @override
  String get folder => dir;
  Timer? _timer;
  Timer? _sessionTimer;
  int _offset = 0;
  String _partial = '';
  void Function(String id)? _onId;
  String? _lastId;

  @override
  String command(ClaudeHookEvent e) =>
      windowsCli != null ? '$hookSignalCommand ${e.word}' : '/bin/sh ${shellWord('$dir/hook.sh')} ${e.word}';

  @override
  List<String> get notifyArgv => switch (windowsCli) {
        final cli? => [cli, 'hook-signal', '--notify'],
        null => ['/bin/sh', '$dir/notify.sh'],
      };

  @override
  void onSession(void Function(String id) onId) {
    _onId = onId;
    _sessionTimer ??= Timer.periodic(poll, (_) => _readSession());
  }

  void _readSession() {
    final on = _onId;
    if (on == null) return;
    // The hooks' ID first; Codex's notify program records one for its helper threads too.
    for (final name in const ['session', 'session.notify']) {
      try {
        final f = File('$dir/$name');
        // A UUID and a newline; anything longer is not one the scripts wrote.
        if (!f.existsSync() || f.lengthSync() > 64) continue;
        final id = validSessionId(f.readAsStringSync());
        if (id == null) continue;
        if (id == _lastId) return;
        _lastId = id;
        on(id);
        return;
      } on FileSystemException {
        continue;
      }
    }
  }

  @override
  void listen(void Function(ClaudeHookEvent e) onEvent) {
    _timer?.cancel();
    _timer = Timer.periodic(poll, (_) {
      final f = File('$dir/events');
      try {
        final len = f.lengthSync();
        if (len <= _offset) return;
        final raf = f.openSync();
        try {
          raf.setPositionSync(_offset);
          final bytes = raf.readSync(len - _offset);
          _offset += bytes.length;
          final text = _partial + utf8.decode(bytes, allowMalformed: true);
          final lines = text.split('\n');
          _partial = lines.removeLast();
          for (final l in lines) {
            final e = ClaudeHookEvent.parse(l.trim());
            if (e != null) onEvent(e);
          }
        } finally {
          raf.closeSync();
        }
      } on FileSystemException {
        return;
      }
    });
  }

  @override
  bool offerContinue(String json) {
    try {
      final tmp = File('$dir/continue.tmp')..writeAsStringSync(json, flush: true);
      if (windowsCli == null) _chmod(tmp.path, '600');
      tmp.renameSync('$dir/continue');
      return true;
    } on FileSystemException catch (e) {
      debugPrint('code hooks: $e');
      return false;
    }
  }

  @override
  bool withdrawContinue() {
    // A rename is atomic against the script's own `mv`: exactly one of the two gets the file.
    try {
      File('$dir/continue').renameSync('$dir/continue.withdrawn');
      File('$dir/continue.withdrawn').deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  void close() {
    _timer?.cancel();
    _timer = null;
    // The last ID the session recorded (its final hooks) still counts.
    _readSession();
    _onId = null;
    _sessionTimer?.cancel();
    _sessionTimer = null;
    try {
      if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('code hooks: $e');
    }
  }

  static void _chmod(String path, String mode) {
    final r = Process.runSync('/bin/chmod', [mode, path]);
    if (r.exitCode != 0) throw FileSystemException('chmod $mode: ${r.stderr}', path);
  }
}
