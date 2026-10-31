// SPDX-License-Identifier: AGPL-3.0-only
// Teams of agents (x-control/7, CONTROL §25, D-111; crates/antenna-proto/src/control/teams.rs): a part of models.dart.
// A team is a lead agent and workers on one git repository of this computer; the daemon decides every call. What a
// worker or a check wrote (a report's summary, notes, review comments, a check's output, a diff, a worker's live
// output) is data from that worker: it never reaches `toString`, and the window shows it as plain text.

part of 'models.dart';

/// Task states (CONTROL §25): `open` → `assigned` → `working` → `submitted` → `accepted` → `done`, with `blocked` (a
/// question to the lead), `returned` (changes asked, or a failed check) and `cancelled`.
abstract final class TaskState {
  static const open = 'open';
  static const assigned = 'assigned';
  static const working = 'working';
  static const blocked = 'blocked';
  static const submitted = 'submitted';
  static const returned = 'returned';
  static const accepted = 'accepted';
  static const done = 'done';
  static const cancelled = 'cancelled';

  static const all = [open, assigned, working, blocked, submitted, returned, accepted, done, cancelled];
}

/// A worker's state (`WorkerInfo.state`).
abstract final class WorkerState {
  static const idle = 'idle';
  static const starting = 'starting';
  static const busy = 'busy';
  static const sleeping = 'sleeping';
  static const stopped = 'stopped';
  static const failed = 'failed';
}

/// Worker kinds (`TeamSlot.kind`).
abstract final class WorkerKind {
  /// Claude Code run by the daemon with the owner's login.
  static const claude = 'claude';

  /// Another program that speaks Claude Code's stream-json (its command in `argv`).
  static const program = 'program';

  /// Refused at spawn in this release (the Codex adapter of D-93 is not built).
  static const codex = 'codex';

  /// A local model of this computer (CONTROL §24), named in `model`.
  static const local = 'local';

  /// The kinds whose workers send what they read to a model provider.
  static bool cloud(String kind) => kind != local;
}

/// The roles the daemon knows (`TeamSlot.role`). A local model's class decides which of them it takes.
const teamRoles = ['coder', 'tester', 'reviewer', 'docs', 'drafts', 'translation', 'summaries', 'triage'];

/// "Up to [max] workers of [kind] with role [role]": one line of the owner's budget.
final class TeamSlot {
  const TeamSlot({required this.role, required this.kind, required this.max, this.model, this.argv = const [],
      this.hosts = const []});

  factory TeamSlot.fromJson(Json j) => TeamSlot(
        role: _str(j, 'role'),
        kind: _str(j, 'kind'),
        model: _optStr(j, 'model'),
        max: _int0(j, 'max'),
        argv: _strList(j, 'argv'),
        hosts: _strList(j, 'hosts'),
      );

  final String role;

  /// [WorkerKind].
  final String kind;

  /// `local`: the catalog model.
  final String? model;
  final int max;

  /// `claude`, `program`: the command; empty means `claude` for the `claude` kind.
  final List<String> argv;

  /// Extra hosts the worker's CLI may reach through the daemon's proxy.
  final List<String> hosts;

  Json toJson() => {
        'role': role,
        'kind': kind,
        'model': ?model,
        'max': max,
        if (argv.isNotEmpty) 'argv': argv,
        if (hosts.isNotEmpty) 'hosts': hosts,
      };

  @override
  bool operator ==(Object other) =>
      other is TeamSlot && other.role == role && other.kind == kind && other.model == model && other.max == max;

  @override
  int get hashCode => Object.hash(role, kind, model, max);

  @override
  String toString() => 'TeamSlot($role, $kind, $max)';
}

/// What workers may do, and the review rules (CONTROL §25 `template`). Every field narrows.
final class TeamTemplate {
  const TeamTemplate({
    this.commands = true,
    this.checks = const [],
    this.checkHosts = const [],
    this.checkPaths = const [],
    this.checkEnv = const [],
    this.checkTimeoutSecs = 600,
    this.checkRetries = 3,
    this.turnTimeoutSecs = 1800,
    this.maxTaskTokens = 0,
    this.apply = 'owner',
    this.localOnly = false,
  });

  factory TeamTemplate.fromJson(Json j) => TeamTemplate(
        commands: _bool(j, 'commands', fallback: true),
        checks: [
          for (final c in (j['checks'] as List?) ?? const [])
            if (c is List) [for (final a in c) a is String ? a : throw const XProtocolException('checks: strings')]
        ],
        checkHosts: _strList(j, 'check_hosts'),
        checkPaths: _strList(j, 'check_paths'),
        checkEnv: _strList(j, 'check_env'),
        checkTimeoutSecs: _optInt(j, 'check_timeout_secs') ?? 600,
        checkRetries: _optInt(j, 'check_retries') ?? 3,
        turnTimeoutSecs: _optInt(j, 'turn_timeout_secs') ?? 1800,
        maxTaskTokens: _int0(j, 'max_task_tokens'),
        apply: _optStr(j, 'apply') ?? 'owner',
        localOnly: _bool(j, 'local_only'),
      );

  /// Workers may run commands in their sandbox (still capped by a task's ceiling).
  final bool commands;

  /// The check commands tasks may name (exact argument lists).
  final List<List<String>> checks;

  /// Hosts checks may reach through the daemon's proxy; empty: no network.
  final List<String> checkHosts;

  /// Read-only folders checks need (a toolchain).
  final List<String> checkPaths;

  /// `NAME=value` variables for checks.
  final List<String> checkEnv;
  final int checkTimeoutSecs;
  final int checkRetries;
  final int turnTimeoutSecs;

  /// 0: no limit.
  final int maxTaskTokens;

  /// Who applies the integration branch to the project's branch: `owner` or `lead`.
  final String apply;
  final bool localOnly;

  bool get ownerApplies => apply != 'lead';

  Json toJson() => {
        'commands': commands,
        if (checks.isNotEmpty) 'checks': checks,
        if (checkHosts.isNotEmpty) 'check_hosts': checkHosts,
        if (checkPaths.isNotEmpty) 'check_paths': checkPaths,
        if (checkEnv.isNotEmpty) 'check_env': checkEnv,
        'check_timeout_secs': checkTimeoutSecs,
        'check_retries': checkRetries,
        'turn_timeout_secs': turnTimeoutSecs,
        'max_task_tokens': maxTaskTokens,
        'apply': apply,
        if (localOnly) 'local_only': true,
      };
}

/// The lead asked to apply the integration branch to the project's branch; the owner decides (`team_apply`).
final class TeamApplyRequest {
  const TeamApplyRequest({required this.by, required this.commit, required this.atMs});

  factory TeamApplyRequest.fromJson(Json j) =>
      TeamApplyRequest(by: _str(j, 'by'), commit: _str(j, 'commit'), atMs: _int0(j, 'at_ms'));

  /// The lead's name.
  final String by;

  /// The integration commit the lead asked to apply: what the owner reviews and pins with `team_apply.commit`.
  final String commit;
  final int atMs;
}

/// A worker: an agent the daemon created to fill a slot (`<team>.<role>-<n>`).
final class WorkerInfo {
  const WorkerInfo({
    required this.name,
    required this.team,
    required this.role,
    required this.kind,
    this.model,
    this.machine = 'this computer',
    required this.state,
    this.task,
    this.spawnedBy = 'owner',
    this.ceiling,
    this.turns = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.detail = '',
    this.queued = 0,
    this.createdMs = 0,
  });

  factory WorkerInfo.fromJson(Json j) => WorkerInfo(
        name: _str(j, 'name'),
        team: _optStr(j, 'team') ?? '',
        role: _optStr(j, 'role') ?? '',
        kind: _optStr(j, 'kind') ?? '',
        model: _optStr(j, 'model'),
        machine: _optStr(j, 'machine') ?? 'this computer',
        state: _optStr(j, 'state') ?? WorkerState.idle,
        task: _optStr(j, 'task'),
        spawnedBy: _optStr(j, 'spawned_by') ?? 'owner',
        ceiling: _optInt(j, 'ceiling'),
        turns: _int0(j, 'turns'),
        inputTokens: _int0(j, 'input_tokens'),
        outputTokens: _int0(j, 'output_tokens'),
        detail: _optStr(j, 'detail') ?? '',
        queued: _int0(j, 'queued'),
        createdMs: _int0(j, 'created_ms'),
      );

  final String name;
  final String team;
  final String role;

  /// [WorkerKind].
  final String kind;
  final String? model;

  /// Where it runs: `this computer` in this release.
  final String machine;

  /// [WorkerState].
  final String state;

  /// The task it holds now.
  final String? task;

  /// `owner` or the lead's name.
  final String spawnedBy;

  /// Its session ceiling (taint); `null` while it read nothing below the owner's own data.
  final int? ceiling;
  final int turns;
  final int inputTokens;
  final int outputTokens;

  /// What it does now, or why it stopped: the daemon's text, and after a turn the tail of the worker's own reply
  /// (data from the worker).
  final String detail;

  /// Turns waiting in its queue (newer daemons; 0 otherwise).
  final int queued;
  final int createdMs;

  bool get stopped => state == WorkerState.stopped;
  bool get busy => state == WorkerState.busy || state == WorkerState.starting;

  @override
  String toString() => 'WorkerInfo($name, $state)';
}

/// One review of a task: by the owner, the lead, or `daemon` (a failed check sent it back).
final class TaskReviewInfo {
  const TaskReviewInfo({required this.by, required this.verdict, this.comments = '', required this.atMs});

  factory TaskReviewInfo.fromJson(Json j) => TaskReviewInfo(
        by: _str(j, 'by'),
        verdict: _str(j, 'verdict'),
        comments: _optStr(j, 'comments') ?? '',
        atMs: _int0(j, 'at_ms'),
      );

  final String by;

  /// `accept`, `changes`, `cancel`.
  final String verdict;

  /// The reviewer's text (or the daemon's quote of a check's output).
  final String comments;
  final int atMs;
}

/// A worker's last report on its task.
final class TaskReportInfo {
  const TaskReportInfo({required this.by, required this.state, this.summary = '', required this.atMs});

  factory TaskReportInfo.fromJson(Json j) => TaskReportInfo(
        by: _str(j, 'by'),
        state: _str(j, 'state'),
        summary: _optStr(j, 'summary') ?? '',
        atMs: _int0(j, 'at_ms'),
      );

  final String by;

  /// `working`, `blocked`, `submitted`.
  final String state;

  /// The note, the question or the summary: the worker's text (empty in task summaries).
  final String summary;
  final int atMs;
}

/// A submitted result: a commit on `team/<task>` (empty for a local model's text result).
final class TaskResultInfo {
  const TaskResultInfo({
    required this.branch,
    required this.base,
    required this.commit,
    this.files = 0,
    this.insertions = 0,
    this.deletions = 0,
    this.ceiling,
    required this.atMs,
  });

  factory TaskResultInfo.fromJson(Json j) => TaskResultInfo(
        branch: _optStr(j, 'branch') ?? '',
        base: _optStr(j, 'base') ?? '',
        commit: _optStr(j, 'commit') ?? '',
        files: _int0(j, 'files'),
        insertions: _int0(j, 'insertions'),
        deletions: _int0(j, 'deletions'),
        ceiling: _optInt(j, 'ceiling'),
        atMs: _int0(j, 'at_ms'),
      );

  final String branch;
  final String base;
  final String commit;
  final int files;
  final int insertions;
  final int deletions;

  /// The ceiling of the worker's session when it submitted.
  final int? ceiling;
  final int atMs;

  /// A local model's reply recorded as the result: no commit, no diff.
  bool get textOnly => commit.isEmpty;
}

/// A check run in the check sandbox.
final class CheckRunInfo {
  const CheckRunInfo({
    required this.task,
    this.commit,
    required this.argv,
    required this.outcome,
    this.exitCode,
    this.output = '',
    this.blockedHosts = const [],
    this.sandbox = '',
    this.durationMs = 0,
    required this.by,
    required this.atMs,
  });

  factory CheckRunInfo.fromJson(Json j) => CheckRunInfo(
        task: _optStr(j, 'task') ?? '',
        commit: _optStr(j, 'commit'),
        argv: _strList(j, 'argv'),
        outcome: _str(j, 'outcome'),
        exitCode: _optInt(j, 'exit_code'),
        output: _optStr(j, 'output') ?? '',
        blockedHosts: _strList(j, 'blocked_hosts'),
        sandbox: _optStr(j, 'sandbox') ?? '',
        durationMs: _int0(j, 'duration_ms'),
        by: _optStr(j, 'by') ?? '',
        atMs: _int0(j, 'at_ms'),
      );

  final String task;

  /// The commit it checked; `null`: the worker's folder as it was.
  final String? commit;
  final List<String> argv;

  /// `passed`, `failed`, `timeout`, `refused` (taint or the template), `error` (the sandbox did not come up).
  final String outcome;
  final int? exitCode;

  /// The output's tail: the check's text (empty in task summaries).
  final String output;

  /// Hosts the check tried and the proxy refused.
  final List<String> blockedHosts;

  /// `bwrap`, `landlock`, `seatbelt`.
  final String sandbox;
  final int durationMs;

  /// A worker, the lead, `owner` or `daemon` (on submit).
  final String by;
  final int atMs;

  bool get passed => outcome == 'passed';

  @override
  String toString() => 'CheckRunInfo($task, $outcome)';
}

/// A task (`task`); summaries in lists leave out the brief, notes, reviews, the report's text and the check's output.
final class TaskInfo {
  const TaskInfo({
    required this.id,
    required this.team,
    required this.title,
    this.brief = '',
    this.check = const [],
    this.assignee,
    required this.state,
    this.createdBy = 'owner',
    this.ceiling,
    this.round = 0,
    this.notes = '',
    this.reviews = const [],
    this.report,
    this.result,
    this.checkRun,
    this.applied,
    this.tokens = 0,
    this.createdMs = 0,
    this.updatedMs = 0,
  });

  factory TaskInfo.fromJson(Json j) => TaskInfo(
        id: _str(j, 'id'),
        team: _optStr(j, 'team') ?? '',
        title: _optStr(j, 'title') ?? '',
        brief: _optStr(j, 'brief') ?? '',
        check: _strList(j, 'check'),
        assignee: _optStr(j, 'assignee'),
        state: _optStr(j, 'state') ?? TaskState.open,
        createdBy: _optStr(j, 'created_by') ?? 'owner',
        ceiling: _optInt(j, 'ceiling'),
        round: _int0(j, 'round'),
        notes: _optStr(j, 'notes') ?? '',
        reviews: [for (final r in _list(j, 'reviews')) TaskReviewInfo.fromJson(r)],
        report: j['report'] is Map<String, Object?> ? TaskReportInfo.fromJson(_obj(j, 'report')) : null,
        result: j['result'] is Map<String, Object?> ? TaskResultInfo.fromJson(_obj(j, 'result')) : null,
        checkRun: j['check_run'] is Map<String, Object?> ? CheckRunInfo.fromJson(_obj(j, 'check_run')) : null,
        applied: _optStr(j, 'applied'),
        tokens: _int0(j, 'tokens'),
        createdMs: _int0(j, 'created_ms'),
        updatedMs: _int0(j, 'updated_ms'),
      );

  /// 16 hex digits (the first 6 are enough for a command).
  final String id;
  final String team;

  /// One line, written by the lead or the owner.
  final String title;

  /// What done means.
  final String brief;

  /// The check command (one of the template's).
  final List<String> check;
  final String? assignee;

  /// [TaskState].
  final String state;

  /// `owner` or the lead's name.
  final String createdBy;

  /// The lowest trust level the session that wrote it had read (`null`: none): a worker that reads it is capped by
  /// it (SPEC §9 taint). Below 4 its worker runs no command and no check.
  final int? ceiling;

  /// 1 at the first assignment, +1 at every return.
  final int round;

  /// The task's notes file (full view only).
  final String notes;

  /// Reviews, oldest first (full view only).
  final List<TaskReviewInfo> reviews;
  final TaskReportInfo? report;
  final TaskResultInfo? result;
  final CheckRunInfo? checkRun;

  /// The integration commit that merged it.
  final String? applied;
  final int tokens;
  final int createdMs;
  final int updatedMs;

  /// The first six digits, as commands accept them.
  String get shortId => id.length > 6 ? id.substring(0, 6) : id;

  @override
  String toString() => 'TaskInfo($shortId, $state)';
}

/// A team (`team`): its project, branches, lead, budget, rules, workers and (in `team_show`) task summaries.
final class TeamInfo {
  const TeamInfo({
    required this.name,
    required this.project,
    required this.target,
    required this.integration,
    this.integrationCommit,
    this.lead,
    required this.state,
    this.slots = const [],
    this.maxWorkers = 0,
    this.template = const TeamTemplate(),
    this.workers = const [],
    this.tasks = const [],
    this.applyRequest,
    this.role,
    this.createdMs = 0,
  });

  factory TeamInfo.fromJson(Json j) => TeamInfo(
        name: _str(j, 'name'),
        project: _optStr(j, 'project') ?? '',
        target: _optStr(j, 'target') ?? '',
        integration: _optStr(j, 'integration') ?? '',
        integrationCommit: _optStr(j, 'integration_commit'),
        lead: _optStr(j, 'lead'),
        state: _optStr(j, 'state') ?? 'active',
        slots: [for (final s in _list(j, 'slots')) TeamSlot.fromJson(s)],
        maxWorkers: _int0(j, 'max_workers'),
        template: TeamTemplate.fromJson(_obj(j, 'template')),
        workers: [for (final w in _list(j, 'workers')) WorkerInfo.fromJson(w)],
        tasks: [for (final t in _list(j, 'tasks')) TaskInfo.fromJson(t)],
        applyRequest: j['apply_request'] is Map<String, Object?> ? TeamApplyRequest.fromJson(_obj(j, 'apply_request')) : null,
        role: _optStr(j, 'role'),
        createdMs: _int0(j, 'created_ms'),
      );

  /// `[a-z0-9-]{1,24}`.
  final String name;

  /// The project folder (a git repository of this computer).
  final String project;

  /// The project's branch results are applied to.
  final String target;

  /// `antenna/<team>`: accepted results are merged here first.
  final String integration;
  final String? integrationCommit;

  /// The lead's agent name; `null`: the owner leads.
  final String? lead;

  /// `active`, `stopped`.
  final String state;
  final List<TeamSlot> slots;
  final int maxWorkers;
  final TeamTemplate template;
  final List<WorkerInfo> workers;
  final List<TaskInfo> tasks;
  final TeamApplyRequest? applyRequest;

  /// The caller's role when an agent asks (`lead`/`worker`); absent for the owner.
  final String? role;
  final int createdMs;

  bool get active => state == 'active';
  bool get ownerLeads => lead == null;

  WorkerInfo? worker(String name) => workers.where((w) => w.name == name).firstOrNull;

  @override
  String toString() => 'TeamInfo($name, $state)';
}

/// `teams`: the teams (summaries: no tasks).
final class TeamsReply extends Reply {
  const TeamsReply(this.teams);
  final List<TeamInfo> teams;
}

/// `team`.
final class TeamReply extends Reply {
  const TeamReply(this.team);
  final TeamInfo team;
}

/// `team_worker`.
final class TeamWorkerReply extends Reply {
  const TeamWorkerReply(this.worker);
  final WorkerInfo worker;
}

/// `task`.
final class TaskReply extends Reply {
  const TaskReply(this.task);
  final TaskInfo task;
}

/// `tasks`.
final class TasksReply extends Reply {
  const TasksReply(this.tasks);
  final List<TaskInfo> tasks;
}

/// `task_diff`: what a result changes.
final class TaskDiffReply extends Reply {
  const TaskDiffReply({required this.task, required this.base, this.commit, this.stat = '', this.diff = '',
      this.truncated = false});

  factory TaskDiffReply.fromJson(Json j) => TaskDiffReply(
        task: _optStr(j, 'task') ?? '',
        base: _optStr(j, 'base') ?? '',
        commit: _optStr(j, 'commit'),
        stat: _optStr(j, 'stat') ?? '',
        diff: _optStr(j, 'diff') ?? '',
        truncated: _bool(j, 'truncated'),
      );

  final String task;
  final String base;

  /// The result's commit; `null`: a worker's folder not submitted yet.
  final String? commit;

  /// `git diff --stat`.
  final String stat;

  /// The diff (at most 256 KiB): the worker's text.
  final String diff;
  final bool truncated;

  @override
  String toString() => 'TaskDiffReply($task, ${diff.length} chars)';
}

/// One slot's use on a machine.
final class SlotCapacity {
  const SlotCapacity({required this.role, required this.kind, required this.used, required this.max, this.unavailable});

  factory SlotCapacity.fromJson(Json j) => SlotCapacity(
        role: _str(j, 'role'),
        kind: _str(j, 'kind'),
        used: _int0(j, 'used'),
        max: _int0(j, 'max'),
        unavailable: _optStr(j, 'unavailable'),
      );

  final String role;
  final String kind;
  final int used;
  final int max;

  /// Why no worker of this slot can start on this machine now (the daemon's English text).
  final String? unavailable;
}

/// One machine's capacity for a team.
final class MachineCapacity {
  const MachineCapacity({
    required this.name,
    required this.sandbox,
    required this.workers,
    required this.maxWorkers,
    this.slots = const [],
    this.localModels = const [],
  });

  factory MachineCapacity.fromJson(Json j) => MachineCapacity(
        name: _str(j, 'name'),
        sandbox: _optStr(j, 'sandbox') ?? 'none',
        workers: _int0(j, 'workers'),
        maxWorkers: _int0(j, 'max_workers'),
        slots: [for (final s in _list(j, 'slots')) SlotCapacity.fromJson(s)],
        localModels: _strList(j, 'local_models'),
      );

  /// `this computer`.
  final String name;

  /// The sandbox workers and checks run in, or `none` (no worker starts).
  final String sandbox;

  /// Workers of all teams on this machine now, and the machine's limit.
  final int workers;
  final int maxWorkers;
  final List<SlotCapacity> slots;

  /// Local models installed here (their IDs).
  final List<String> localModels;
}

/// `capacity`: facts about the machines a team may use.
final class CapacityReply extends Reply {
  const CapacityReply({required this.team, required this.workers, required this.maxWorkers, this.machines = const []});

  factory CapacityReply.fromJson(Json j) => CapacityReply(
        team: _optStr(j, 'team') ?? '',
        workers: _int0(j, 'workers'),
        maxWorkers: _int0(j, 'max_workers'),
        machines: [for (final m in _list(j, 'machines')) MachineCapacity.fromJson(m)],
      );

  final String team;

  /// The team's workers now, and its limit.
  final int workers;
  final int maxWorkers;
  final List<MachineCapacity> machines;
}

/// One entry of a team's audit log.
final class TeamLogEntry {
  const TeamLogEntry({required this.ts, required this.actor, required this.action, this.task, required this.decision,
      this.detail = ''});

  factory TeamLogEntry.fromJson(Json j) => TeamLogEntry(
        ts: _int0(j, 'ts'),
        actor: _optStr(j, 'actor') ?? '',
        action: _optStr(j, 'action') ?? '',
        task: _optStr(j, 'task'),
        decision: _optStr(j, 'decision') ?? '',
        detail: _optStr(j, 'detail') ?? '',
      );

  final int ts;

  /// `owner`, an agent's name, or `daemon`.
  final String actor;

  /// `team_create`, `worker_spawn`, `task_create`, `task_assign`, `task_report`, `run_check`, `task_review`, …
  final String action;
  final String? task;

  /// `done`, `denied`, `refused`, `failed`, `approval_required`, …
  final String decision;

  /// The daemon's details (never a worker's text).
  final String detail;
}

/// `team_log`: entries, oldest first.
final class TeamLogReply extends Reply {
  const TeamLogReply(this.entries);
  final List<TeamLogEntry> entries;
}

/// The owner's `team` event (v7): a team, one of its workers or tasks changed; the window reads `team_show` again.
final class TeamEvent extends XEvent {
  const TeamEvent({required this.team, required this.change, this.task, this.state, this.worker, this.by});

  factory TeamEvent.fromJson(Json j) => TeamEvent(
        team: _str(j, 'team'),
        change: _optStr(j, 'change') ?? '',
        task: _optStr(j, 'task'),
        state: _optStr(j, 'state'),
        worker: _optStr(j, 'worker'),
        by: _optStr(j, 'by'),
      );

  final String team;

  /// `created`, `changed`, `removed`, `worker`, `task`, `apply_request`.
  final String change;
  final String? task;

  /// The task's state or the worker's state.
  final String? state;
  final String? worker;

  /// Who made the change: `owner`, an agent's name, `daemon`; `null` from a daemon that does not say.
  final String? by;

  @override
  String toString() => 'TeamEvent($team, $change, ${task ?? worker ?? ''}, $state, $by)';
}

/// A piece of a worker's turn on a `team_watch` connection. [text] is the worker's output (data): shown as plain text.
final class WorkerOutputEvent extends XEvent {
  const WorkerOutputEvent({required this.team, required this.worker, this.task, this.turn = 0, required this.part,
      this.text = ''});

  factory WorkerOutputEvent.fromJson(Json j) => WorkerOutputEvent(
        team: _str(j, 'team'),
        worker: _str(j, 'worker'),
        task: _optStr(j, 'task'),
        turn: _int0(j, 'turn'),
        part: _optStr(j, 'part') ?? 'text',
        text: _optStr(j, 'text') ?? '',
      );

  final String team;
  final String worker;
  final String? task;
  final int turn;

  /// `snapshot` (the turn so far, first on a new connection), `start`, `text`, `activity` (`tool:<name>`), `end`
  /// (`done`, `interrupted`, `timeout`, `failed`, `error: …`).
  final String part;
  final String text;

  @override
  String toString() => 'WorkerOutputEvent($team, $worker, $turn, $part, ${text.length} chars)';
}
