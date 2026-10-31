// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's teams of agents (x-control/7, CONTROL §25): the teams, workers, tasks, diffs and log are set by
// the test (or `demoTeam`), and the owner's commands move them the way the daemon's state machine does (only the
// owner's side: the lead and the workers are the test). A fake older than v7, or one without
// [FakeTeams.teamsEnabled] (a v7 daemon built before teams), refuses every command as an unknown variant, as the real
// daemon's strict parser does; [FakeTeams.teamCapacityEnabled] and [FakeTeams.teamWatchEnabled] off stand for a v7
// daemon built before the window's part of teams.

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fake_daemon.dart' show FakeDialog;
import 'fixtures.dart' show fixedNow;

const _h = 3600 * 1000;

/// The demo's "now" in ms (the fixtures' clock).
final demoTeamNow = fixedNow.millisecondsSinceEpoch;

int _ago(int minutes) => demoTeamNow - minutes * 60 * 1000;

/// The first six digits of the demo tasks' IDs (what the window shows and commands take).
const _prefixes = ['0b3e7a', 'a1f3c9', 'b72e04', 'c90d5a', 'd4e8b1', 'e6a17f', 'f05c3d', '17bd92', '2c4e6a', '3d5f7b'];

/// A demo task in full; its ID is 16 hex digits made from [n].
TaskInfo demoTask(
  int n, {
  String team = 'web',
  required String title,
  String brief = '',
  List<String> check = const ['cargo', 'test'],
  String? assignee,
  String state = TaskState.open,
  String createdBy = 'claude',
  int? ceiling,
  int round = 0,
  String notes = '',
  List<TaskReviewInfo> reviews = const [],
  TaskReportInfo? report,
  TaskResultInfo? result,
  CheckRunInfo? checkRun,
  String? applied,
  int tokens = 0,
  int minutes = 30,
}) =>
    TaskInfo(
      id: '${_prefixes[n % _prefixes.length]}5e1d${n.toRadixString(16).padLeft(6, '0')}',
      team: team,
      title: title,
      brief: brief,
      check: check,
      assignee: assignee,
      state: state,
      createdBy: createdBy,
      ceiling: ceiling,
      round: round,
      notes: notes,
      reviews: reviews,
      report: report,
      result: result,
      checkRun: checkRun,
      applied: applied,
      tokens: tokens,
      createdMs: _ago(minutes + 40),
      updatedMs: _ago(minutes),
    );

WorkerInfo demoWorker(String name,
        {String team = 'web',
        String role = 'coder',
        String kind = WorkerKind.claude,
        String? model,
        String state = WorkerState.idle,
        String? task,
        String spawnedBy = 'claude',
        int? ceiling,
        int turns = 0,
        int input = 0,
        int output = 0,
        String detail = '',
        int queued = 0}) =>
    WorkerInfo(
      name: name,
      team: team,
      role: role,
      kind: kind,
      model: model,
      state: state,
      task: task,
      spawnedBy: spawnedBy,
      ceiling: ceiling,
      turns: turns,
      inputTokens: input,
      outputTokens: output,
      detail: detail,
      queued: queued,
      createdMs: demoTeamNow - 2 * _h,
    );

const demoCheck = ['cargo', 'test'];

/// The demo team: a Claude Code lead (`claude`), three Claude Code coders and a local docs writer on a web project,
/// one task in every column, and the lead's request to apply the team's branch to `main`.
TeamInfo demoTeam({bool applyRequest = true, String state = 'active', String? lead = 'claude'}) {
  final passed = CheckRunInfo(
    task: 'a',
    commit: '9c41e07d2b5a3f18e6c0d4a7b2e9f1c3a5d7e8f0',
    argv: demoCheck,
    outcome: 'passed',
    exitCode: 0,
    output: 'running 14 tests\n..............\ntest result: ok. 14 passed; 0 failed; 0 ignored; finished in 0.94s\n',
    sandbox: 'bwrap',
    durationMs: 940,
    by: 'daemon',
    atMs: _ago(6),
  );
  final tasks = [
    demoTask(1,
        title: 'Add rate limiting to the login endpoint',
        brief: 'At most 5 attempts per minute per address; answer 429 with Retry-After. Tests for both.',
        minutes: 4),
    demoTask(2,
        title: 'Translate the onboarding screens',
        brief: 'Spanish strings for the three onboarding screens.',
        check: const [],
        createdBy: 'claude',
        ceiling: 2,
        minutes: 12),
    demoTask(3,
        title: 'Fix the date parser for ISO weeks',
        brief: 'Week 53 of 2026 parses as week 1 of 2027. Fix and add a test for 2026-W53.',
        assignee: 'web.coder-1',
        state: TaskState.working,
        round: 1,
        report: TaskReportInfo(
            by: 'web.coder-1', state: 'working', summary: 'Found it: the year rolls over before the week check.', atMs: _ago(2)),
        tokens: 18400,
        minutes: 2),
    demoTask(4,
        title: 'Cache the avatar thumbnails',
        brief: 'Keep the 96 px thumbnails in memory for the session; invalidate on a profile change.',
        assignee: 'web.coder-2',
        state: TaskState.submitted,
        round: 1,
        report: TaskReportInfo(
            by: 'web.coder-2',
            state: 'submitted',
            summary: 'An LRU of 256 entries keyed by user and size; cleared on profile_changed. 3 new tests.',
            atMs: _ago(7)),
        result: TaskResultInfo(
            branch: 'team/5e1d0000004444aa',
            base: '1f3c5a7e9b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a',
            commit: '9c41e07d2b5a3f18e6c0d4a7b2e9f1c3a5d7e8f0',
            files: 3,
            insertions: 42,
            deletions: 8,
            atMs: _ago(7)),
        checkRun: passed,
        tokens: 31200,
        minutes: 6),
    demoTask(5,
        title: 'Write the migration for user settings',
        brief: 'Move the settings from the users table into user_settings, keeping the defaults.',
        assignee: 'web.coder-3',
        state: TaskState.blocked,
        round: 1,
        report: TaskReportInfo(
            by: 'web.coder-3',
            state: 'blocked',
            summary: 'Two tables hold a theme column: settings_v1 and users. Which one is the source of truth?',
            atMs: _ago(9)),
        tokens: 9100,
        minutes: 9),
    demoTask(6,
        title: 'Update the README for the new API',
        check: const [],
        assignee: 'web.docs-1',
        state: TaskState.accepted,
        round: 1,
        report: TaskReportInfo(by: 'web.docs-1', state: 'submitted', summary: 'The API section now lists the v2 routes.', atMs: _ago(25)),
        reviews: [TaskReviewInfo(by: 'claude', verdict: 'accept', atMs: _ago(20))],
        result: TaskResultInfo(branch: '', base: '1f3c5a7e9b2d', commit: '', atMs: _ago(25)),
        minutes: 20),
    demoTask(7,
        title: 'Rename the config loader',
        assignee: 'web.coder-1',
        state: TaskState.done,
        round: 2,
        report: TaskReportInfo(by: 'web.coder-1', state: 'submitted', summary: 'Renamed; the old name stays as an alias.', atMs: _ago(70)),
        reviews: [
          TaskReviewInfo(
              by: 'daemon',
              verdict: 'changes',
              comments: 'The check `cargo test` failed (exit 101). Its output ends with:\nerror[E0425]: cannot find value `cfg`',
              atMs: _ago(80)),
          TaskReviewInfo(by: 'claude', verdict: 'accept', atMs: _ago(62)),
        ],
        result: TaskResultInfo(
            branch: 'team/5e1d0000007777aa',
            base: '0a2c4e6f8b1d3f5a7c9e2b4d6f8a1c3e5b7d9f2a',
            commit: '4f2a9c1e7b3d5f8a0c2e4b6d8f1a3c5e7b9d0f2a',
            files: 5,
            insertions: 61,
            deletions: 59,
            atMs: _ago(70)),
        checkRun: CheckRunInfo(
            task: 'a', argv: demoCheck, outcome: 'passed', exitCode: 0, sandbox: 'bwrap', durationMs: 1210, by: 'daemon', atMs: _ago(69)),
        applied: '7d1e3a5c9b2f4e6a8c0d2b4f6a8e1c3d5f7b9a0e',
        tokens: 22800,
        minutes: 60),
  ];
  return TeamInfo(
    name: 'web',
    project: '/Users/jordan/code/web',
    target: 'main',
    integration: 'antenna/web',
    integrationCommit: '7d1e3a5c9b2f4e6a8c0d2b4f6a8e1c3d5f7b9a0e',
    lead: lead,
    state: state,
    slots: const [
      TeamSlot(role: 'coder', kind: WorkerKind.claude, max: 3, argv: ['claude', '--model', 'sonnet']),
      TeamSlot(role: 'docs', kind: WorkerKind.local, model: 'qwen3.5-9b', max: 1),
    ],
    maxWorkers: 4,
    template: const TeamTemplate(checks: [demoCheck], checkHosts: ['index.crates.io', 'static.crates.io']),
    workers: [
      demoWorker('web.coder-1', state: WorkerState.busy, task: tasks[2].id, turns: 6, input: 182000, output: 9400),
      demoWorker('web.coder-2', task: tasks[3].id, turns: 4, input: 120400, output: 7100, detail: 'Submitted the thumbnail cache.'),
      demoWorker('web.coder-3', task: tasks[4].id, turns: 2, input: 40100, output: 2200),
      demoWorker('web.docs-1', role: 'docs', kind: WorkerKind.local, model: 'qwen3.5-9b', state: WorkerState.sleeping, turns: 1),
    ],
    tasks: tasks,
    applyRequest: applyRequest
        ? TeamApplyRequest(by: 'claude', commit: '7d1e3a5c9b2f4e6a8c0d2b4f6a8e1c3d5f7b9a0e', atMs: _ago(15))
        : null,
    createdMs: demoTeamNow - 3 * _h,
  );
}

/// The diff of the demo's task 4.
final demoDiff = TaskDiffReply(
  task: demoTask(4, title: '').id,
  base: '1f3c5a7e9b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a',
  commit: '9c41e07d2b5a3f18e6c0d4a7b2e9f1c3a5d7e8f0',
  stat: ' src/avatar/cache.rs | 38 ++++++++++++++++++++++++\n src/avatar/mod.rs   |  6 +++--\n tests/avatar.rs     |  6 ++++--\n 3 files changed, 42 insertions(+), 8 deletions(-)\n',
  diff: 'diff --git a/src/avatar/mod.rs b/src/avatar/mod.rs\n'
      'index 3b18e51..a1d2c4f 100644\n'
      '--- a/src/avatar/mod.rs\n'
      '+++ b/src/avatar/mod.rs\n'
      '@@ -12,7 +12,9 @@ pub fn thumbnail(user: UserId, size: u32) -> Image {\n'
      '-    let img = load(user)?;\n'
      '-    resize(&img, size)\n'
      '+    if let Some(hit) = cache::get(user, size) {\n'
      '+        return hit;\n'
      '+    }\n'
      '+    let img = resize(&load(user)?, size);\n'
      '+    cache::put(user, size, img.clone());\n'
      '+    img\n'
      ' }\n',
);

/// A full task as the summaries in `team_show` and `task_list` give it: no brief, notes, reviews, report text or check
/// output (CONTROL §25).
TaskInfo summaryOf(TaskInfo t) => TaskInfo(
      id: t.id,
      team: t.team,
      title: t.title,
      check: t.check,
      assignee: t.assignee,
      state: t.state,
      createdBy: t.createdBy,
      ceiling: t.ceiling,
      round: t.round,
      report: t.report == null
          ? null
          : TaskReportInfo(by: t.report!.by, state: t.report!.state, atMs: t.report!.atMs),
      result: t.result,
      checkRun: t.checkRun == null
          ? null
          : CheckRunInfo(
              task: t.checkRun!.task,
              commit: t.checkRun!.commit,
              argv: t.checkRun!.argv,
              outcome: t.checkRun!.outcome,
              exitCode: t.checkRun!.exitCode,
              blockedHosts: t.checkRun!.blockedHosts,
              sandbox: t.checkRun!.sandbox,
              durationMs: t.checkRun!.durationMs,
              by: t.checkRun!.by,
              atMs: t.checkRun!.atMs),
      applied: t.applied,
      tokens: t.tokens,
      createdMs: t.createdMs,
      updatedMs: t.updatedMs,
    );

TeamInfo _with(TeamInfo t,
        {List<WorkerInfo>? workers,
        List<TaskInfo>? tasks,
        String? state,
        String? integrationCommit,
        bool clearApply = false}) =>
    TeamInfo(
      name: t.name,
      project: t.project,
      target: t.target,
      integration: t.integration,
      integrationCommit: integrationCommit ?? t.integrationCommit,
      lead: t.lead,
      state: state ?? t.state,
      slots: t.slots,
      maxWorkers: t.maxWorkers,
      template: t.template,
      workers: workers ?? t.workers,
      tasks: tasks ?? t.tasks,
      applyRequest: clearApply ? null : t.applyRequest,
      createdMs: t.createdMs,
    );

TaskInfo _task(TaskInfo t,
        {String? state, String? assignee, int? round, List<TaskReviewInfo>? reviews, String? applied, int? at}) =>
    TaskInfo(
      id: t.id,
      team: t.team,
      title: t.title,
      brief: t.brief,
      check: t.check,
      assignee: assignee ?? t.assignee,
      state: state ?? t.state,
      createdBy: t.createdBy,
      ceiling: t.ceiling,
      round: round ?? t.round,
      notes: t.notes,
      reviews: reviews ?? t.reviews,
      report: t.report,
      result: t.result,
      checkRun: t.checkRun,
      applied: applied ?? t.applied,
      tokens: t.tokens,
      createdMs: t.createdMs,
      updatedMs: at ?? t.updatedMs + 1000,
    );

WorkerInfo _worker(WorkerInfo w, {String? state, String? task, bool clearTask = false}) => WorkerInfo(
      name: w.name,
      team: w.team,
      role: w.role,
      kind: w.kind,
      model: w.model,
      machine: w.machine,
      state: state ?? w.state,
      task: clearTask ? null : (task ?? w.task),
      spawnedBy: w.spawnedBy,
      ceiling: w.ceiling,
      turns: w.turns,
      inputTokens: w.inputTokens,
      outputTokens: w.outputTokens,
      detail: w.detail,
      queued: w.queued,
      createdMs: w.createdMs,
    );

const _holding = {TaskState.assigned, TaskState.working, TaskState.blocked, TaskState.submitted, TaskState.returned};

mixin FakeTeams {
  // From FakeDaemon.
  List<String> get calls;
  int get protoVersion;
  String get password;

  /// A proof by an enrolled key was checked for the request being carried out (D-131): its password field is empty.
  bool get proofChecked;
  Map<String, String> get passwords;
  List<FakeDialog> get dialogs;

  /// This daemon has teams (with `protoVersion` 7). Off by default, so other features' frames stay as they are.
  bool teamsEnabled = false;

  /// `team_capacity`, `team_watch` and `team_event.by` exist (a daemon with the window's part of teams).
  bool teamCapacityEnabled = true;
  bool teamWatchEnabled = true;

  /// The owner's other computers that lend themselves, as `team_capacity` lists them after this computer.
  List<String> lendingMachines = const [];

  /// The teams in full (tasks with their texts); `team_show` gives summaries of the tasks.
  final teamMap = <String, TeamInfo>{};
  final teamDiffs = <String, TaskDiffReply>{};
  final teamLogs = <String, List<TeamLogEntry>>{};

  /// The owner's team commands as the window sent them: the command and its fields (passwords left out).
  final teamCalls = <(String, Map<String, Object?>)>[];

  /// `team_apply` calls that went through (the team, the commit).
  final teamApplied = <(String, String?)>[];

  /// The next team command fails with this error.
  XControlException? teamError;

  /// `team_show` answers this much later with the board as it was when asked.
  Duration teamShowDelay = Duration.zero;
  int _taskSeq = 0x900;

  void addTeam(TeamInfo t) => teamMap[t.name] = t;

  TeamInfo _team(String name) =>
      teamMap[name] ?? (throw XControlException(XErrorCode.notFound, 'no team $name'));

  (TeamInfo, TaskInfo) _taskById(String id) {
    for (final t in teamMap.values) {
      for (final x in t.tasks) {
        if (x.id.startsWith(id)) return (t, x);
      }
    }
    throw XControlException(XErrorCode.notFound, 'no task $id');
  }

  TeamInfo _summary(TeamInfo t, {bool tasks = true}) =>
      _with(t, tasks: tasks ? [for (final x in t.tasks) summaryOf(x)] : const []);

  void _putTask(TeamInfo team, TaskInfo task, {List<WorkerInfo>? workers}) {
    teamMap[team.name] = _with(team,
        workers: workers, tasks: [for (final x in team.tasks) x.id == task.id ? task : x]);
  }

  void _log(String team, String action, String decision, {String? task, String detail = ''}) =>
      teamLogs.putIfAbsent(team, () => []).add(TeamLogEntry(
          ts: demoTeamNow, actor: 'owner', action: action, task: task, decision: decision, detail: detail));

  XControlException _state(String what) => XControlException(XErrorCode.taskState, what);

  /// A team command (FakeDaemon.call has counted it in `calls`).
  Future<Reply> teamCall(TeamRequest r) async {
    if (protoVersion < 7 || !teamsEnabled) {
      throw XControlException(XErrorCode.badRequest, 'bad message: unknown variant `${r.cmd}`');
    }
    if (r is TeamCapacityRequest && !teamCapacityEnabled) {
      throw XControlException(XErrorCode.badRequest, 'bad message: unknown variant `${r.cmd}`');
    }
    teamCalls.add((r.cmd, {...r.fields}..remove('password')));
    final err = teamError;
    if (err != null) {
      teamError = null;
      throw err;
    }
    switch (r) {
      case TeamListRequest():
        return TeamsReply([for (final t in teamMap.values) _summary(t, tasks: false)]);
      case TeamShowRequest(:final team):
        // The board as it is now, answered after [teamShowDelay] (a slow read that an action overtakes).
        final reply = TeamReply(_summary(_team(team)));
        if (teamShowDelay > Duration.zero) await Future<void>.delayed(teamShowDelay);
        return reply;
      case TeamCreateRequest():
        passwords['team_create'] = r.password;
        if (!proofChecked && r.password != password) {
          throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        }
        if (teamMap.containsKey(r.name)) throw XControlException(XErrorCode.badRequest, 'a team ${r.name} exists');
        final t = TeamInfo(
          name: r.name,
          project: r.project,
          target: r.target ?? 'main',
          integration: 'antenna/${r.name}',
          integrationCommit: '1f3c5a7e9b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a',
          lead: r.lead,
          state: 'active',
          slots: r.slots,
          maxWorkers: r.maxWorkers ?? r.slots.fold<int>(0, (a, s) => a + s.max),
          template: r.template ?? const TeamTemplate(),
          createdMs: demoTeamNow,
        );
        teamMap[t.name] = t;
        _log(t.name, 'team_create', 'done');
        return TeamReply(t);
      case TeamSetRequest():
        passwords['team_set'] = r.password;
        if (!proofChecked && r.password != password) {
          throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        }
        final t = _with(_team(r.team), state: 'active');
        teamMap[t.name] = t;
        return TeamReply(_summary(t));
      case TeamAddWorkerRequest(:final team, :final role, :final kind):
        final t = _team(team);
        final slot = t.slots.where((s) => s.role == role && (kind == null || s.kind == kind)).firstOrNull;
        if (slot == null) throw XControlException(XErrorCode.noCapacity, 'no slot for the role $role');
        final used = t.workers.where((w) => !w.stopped && w.role == role && w.kind == slot.kind).length;
        if (used >= slot.max) throw XControlException(XErrorCode.noCapacity, 'the $role slot is full ($used of ${slot.max})');
        final n = t.workers.where((w) => w.role == role).length + 1;
        final w = demoWorker('${t.name}.$role-$n', team: t.name, role: role, kind: slot.kind, model: slot.model, spawnedBy: 'owner');
        teamMap[team] = _with(t, workers: [...t.workers, w]);
        return TeamWorkerReply(w);
      case TeamStopRequest(:final team, :final worker):
        final t = _team(team);
        final ws = [for (final w in t.workers) worker == null || w.name == worker ? _worker(w, state: WorkerState.stopped) : w];
        final next = _with(t, workers: ws, state: worker == null ? 'stopped' : null);
        teamMap[team] = next;
        return TeamReply(_summary(next));
      case TeamRemoveRequest(:final team):
        _team(team);
        teamMap.remove(team);
        return TeamsReply([for (final t in teamMap.values) _summary(t, tasks: false)]);
      case TeamApplyOwnerRequest(:final team, :final commit):
        passwords['team_apply'] = r.password;
        if (!proofChecked && r.password != password) {
          throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        }
        final t = _team(team);
        if (commit != null && commit != t.integrationCommit) {
          throw const XControlException(XErrorCode.approvalMismatch, 'the integration branch moved since');
        }
        teamApplied.add((team, commit));
        final next = _with(t, clearApply: true);
        teamMap[team] = next;
        _log(team, 'team_apply', 'done', detail: 'main ← ${t.integrationCommit?.substring(0, 12)}');
        return TeamReply(_summary(next));
      case TeamLogRequest(:final team):
        _team(team);
        return TeamLogReply(teamLogs[team] ?? const []);
      case TeamCapacityRequest(:final team):
        final t = _team(team);
        final live = [for (final w in t.workers) if (!w.stopped) w];
        final all = teamMap.values.fold<int>(0, (a, x) => a + x.workers.where((w) => !w.stopped).length);
        return CapacityReply(team: team, workers: live.length, maxWorkers: t.maxWorkers, machines: [
          MachineCapacity(
            name: 'this computer',
            sandbox: 'bwrap',
            workers: all,
            maxWorkers: 8,
            slots: [
              for (final s in t.slots)
                SlotCapacity(
                  role: s.role,
                  kind: s.kind,
                  used: live.where((w) => w.role == s.role && w.kind == s.kind).length,
                  max: s.max,
                  unavailable: s.kind == WorkerKind.local ? null : null,
                ),
            ],
            localModels: const ['qwen3.5-9b'],
          ),
          // Own computers that lend themselves (D-114): listed, every slot unavailable until remote workers exist.
          for (final name in lendingMachines)
            MachineCapacity(name: name, sandbox: 'bwrap', workers: 0, maxWorkers: 8, slots: [
              for (final s in t.slots)
                SlotCapacity(role: s.role, kind: s.kind, used: 0, max: s.max, unavailable: 'no remote workers yet'),
            ]),
        ]);
      case TeamWatchRequest():
        throw const XControlException(XErrorCode.badRequest, 'team_watch is a dialog');
      case TaskNewRequest():
        final t = _team(r.team);
        final id = (0x7a5c0000000000 + ++_taskSeq).toRadixString(16).padLeft(16, 'b');
        var task = TaskInfo(
          id: id,
          team: t.name,
          title: r.title,
          brief: r.brief,
          check: r.check,
          state: TaskState.open,
          createdBy: 'owner',
          createdMs: demoTeamNow,
          updatedMs: demoTeamNow,
        );
        var workers = t.workers;
        if (r.assignee case final a?) {
          (task, workers) = _assign(t, task, a);
        }
        teamMap[t.name] = _with(t, workers: workers, tasks: [...t.tasks, task]);
        _log(t.name, 'task_create', 'done', task: id);
        return TaskReply(task);
      case TaskListRequest(:final team):
        return TasksReply([for (final x in _team(team).tasks) summaryOf(x)]);
      case TaskShowRequest(:final id):
        return TaskReply(_taskById(id).$2);
      case TaskDiffRequest(:final id):
        final (_, t) = _taskById(id);
        final d = teamDiffs[t.id];
        if (d == null) {
          if (t.result == null) throw _state('the task is ${t.state}: it has no result yet');
          return TaskDiffReply(task: t.id, base: t.result!.base, commit: t.result!.commit);
        }
        return d;
      case TaskReviewRequest(:final id, :final verdict, :final comments, :final urgent):
        final (team, t) = _taskById(id);
        if (urgent && verdict != TaskVerdict.changes) {
          throw XControlException(XErrorCode.badRequest, 'urgent needs changes');
        }
        final review = TaskReviewInfo(by: 'owner', verdict: verdict, comments: comments, atMs: demoTeamNow);
        final TaskInfo next;
        switch (verdict) {
          case TaskVerdict.accept:
            if (t.state != TaskState.submitted) throw _state('the task is ${t.state}: only a submitted result is accepted');
            next = _task(t, state: TaskState.accepted, reviews: [...t.reviews, review]);
          case TaskVerdict.changes:
            // CONTROL §33: an urgent request for changes also interrupts a worker that is on the task now.
            final working = {TaskState.assigned, TaskState.working, TaskState.returned};
            if (!{TaskState.submitted, TaskState.blocked, TaskState.accepted}.contains(t.state) &&
                !(urgent && working.contains(t.state))) {
              throw _state('the task is ${t.state}: changes are asked of a submitted, blocked or accepted task');
            }
            next = _task(t, state: TaskState.returned, round: t.round + 1, reviews: [...t.reviews, review]);
          case TaskVerdict.cancel:
            if (t.state == TaskState.done || t.state == TaskState.cancelled) throw _state('the task is ${t.state}');
            next = _task(t, state: TaskState.cancelled, reviews: [...t.reviews, review]);
          default:
            throw XControlException(XErrorCode.badRequest, 'verdict $verdict');
        }
        final workers = verdict == TaskVerdict.cancel
            ? [for (final w in team.workers) w.task == t.id ? _worker(w, clearTask: true) : w]
            : null;
        _putTask(team, next, workers: workers);
        _log(team.name, 'task_review', verdict, task: t.id);
        return TaskReply(next);
      case TaskAssignRequest(:final id, :final worker):
        final (team, t) = _taskById(id);
        if (t.state != TaskState.open) throw _state('the task is ${t.state}: only an open task is assigned');
        final (next, workers) = _assign(team, t, worker);
        _putTask(team, next, workers: workers);
        _log(team.name, 'task_assign', 'done', task: t.id, detail: worker);
        return TaskReply(next);
      case TaskApplyRequest(:final id):
        final (team, t) = _taskById(id);
        if (t.state != TaskState.accepted) throw _state('the task is ${t.state}: only an accepted task is applied');
        const commit = 'b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a1c3e5b7d9';
        final next = _task(t, state: TaskState.done, applied: commit);
        final ws = [for (final w in team.workers) w.task == t.id ? _worker(w, clearTask: true) : w];
        teamMap[team.name] = _with(team,
            workers: ws, integrationCommit: commit, tasks: [for (final x in team.tasks) x.id == t.id ? next : x]);
        _log(team.name, 'apply_result', 'done', task: t.id);
        return TaskReply(next);
    }
  }

  (TaskInfo, List<WorkerInfo>) _assign(TeamInfo team, TaskInfo t, String worker) {
    final w = team.worker(worker);
    if (w == null) throw XControlException(XErrorCode.notFound, 'no worker $worker in ${team.name}');
    final holds = team.tasks.any((x) => x.assignee == worker && _holding.contains(x.state));
    if (holds) throw _state('$worker already holds a task');
    final next = _task(t, state: TaskState.assigned, assignee: worker, round: 1);
    return (next, [for (final x in team.workers) x.name == worker ? _worker(x, task: t.id, state: WorkerState.busy) : x]);
  }

  /// `team_watch`: a dialog the test drives with `worker_output` events; refused as unknown without the command.
  FakeDialog teamWatchOpen(TeamWatchRequest r, FakeDialog d) {
    if (protoVersion < 7 || !teamsEnabled || !teamWatchEnabled) {
      d.fail(XControlException(XErrorCode.badRequest, 'bad message: unknown variant `${r.cmd}`'));
    } else if (!teamMap.containsKey(r.team)) {
      d.fail(XControlException(XErrorCode.notFound, 'no team ${r.team}'));
    }
    return d;
  }

  /// The watch dialogs of [team] still open.
  List<FakeDialog> teamWatches(String team) => [
        for (final d in dialogs)
          if (d.request case TeamWatchRequest(team: final t) when t == team && !d.cancelled) d,
      ];
}
