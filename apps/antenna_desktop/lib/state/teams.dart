// SPDX-License-Identifier: AGPL-3.0-only
// Teams of agents in the window (x-control/7, CONTROL §25, D-111; DESIGN "Teams"). A team is a lead agent and workers
// on one git repository of this computer; the daemon decides every permission and keeps every record. The window owns
// none of it: the teams, workers and tasks come from `team_list`, `team_show` and `task_show`, the board is derived
// from those (principle 4: derived state, never the source of truth), the `team` event says when to read again, and a
// worker's live output comes from `team_watch`. What a worker or a check wrote is data from that worker: the window
// shows it as plain text and never types it anywhere.
//
// A daemon older than v7, or a v7 daemon built before teams, gets none of these commands: the Teams section is not
// shown. A v7 daemon without `team_capacity` or `team_watch` (built before the window's part) keeps working: the
// capacity strip is derived from the budget, and the live output falls back to each worker's last `detail`.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'local_models.dart' show plainModelText;
import 'owner_auth.dart';

final _teamName = RegExp(r'^[a-z0-9-]{1,24}$');

/// A name the daemon accepts for a team (`[a-z0-9-]{1,24}`: workers are named `<team>.<role>-<n>`).
bool validTeamName(String name) => _teamName.hasMatch(name);

/// The board's columns: a view of the task states (CONTROL §25), in the order work moves.
enum BoardColumn {
  open,

  /// Assigned, working, or returned to the worker (changes asked, or a failed check).
  working,

  /// Submitted: waiting for the reviewer (the lead, or the owner when the owner leads).
  review,

  /// The worker asks the lead something, or the daemon handed the task back (limits).
  blocked,

  /// Accepted: waiting to be merged into the team's branch.
  accepted,

  /// Done: merged into the team's branch.
  applied,
  cancelled;

  static BoardColumn of(String state) => switch (state) {
        TaskState.open => open,
        TaskState.assigned || TaskState.working || TaskState.returned => working,
        TaskState.submitted => review,
        TaskState.blocked => blocked,
        TaskState.accepted => accepted,
        TaskState.done => applied,
        TaskState.cancelled => cancelled,
        // A state this window does not know yet: where nothing is decided (the card shows the daemon's word).
        _ => open,
      };
}

/// The tasks of [team] by column, each column newest change first.
Map<BoardColumn, List<TaskInfo>> boardOf(TeamInfo team) {
  final out = {for (final c in BoardColumn.values) c: <TaskInfo>[]};
  for (final t in team.tasks) {
    out[BoardColumn.of(t.state)]!.add(t);
  }
  for (final l in out.values) {
    l.sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
  }
  return out;
}

/// What the capacity strip shows for one slot of the budget.
final class SlotUse {
  const SlotUse({required this.slot, required this.used, this.unavailable});
  final TeamSlot slot;
  final int used;

  /// Why no worker of the slot can start now (the daemon's English text; only from `team_capacity`).
  final String? unavailable;
  int get free => (slot.max - used).clamp(0, slot.max);
}

/// The capacity strip of a team: the daemon's `team_capacity` when it has it, otherwise the same facts derived from
/// the budget and the workers (`derived`: the machine's own limit and sandbox are then unknown).
final class TeamCapacityView {
  const TeamCapacityView({
    required this.machine,
    required this.sandbox,
    required this.machineWorkers,
    required this.machineMax,
    required this.teamWorkers,
    required this.teamMax,
    required this.slots,
    required this.openTasks,
    required this.queuedTurns,
    required this.modelsLoaded,
    required this.derived,
    this.otherMachines = const [],
  });

  /// `this computer`.
  final String machine;

  /// `bwrap`, `landlock`, `seatbelt`, `none`; empty when [derived].
  final String sandbox;

  /// Workers of all teams on the machine, and its own limit (0 when [derived]).
  final int machineWorkers;
  final int machineMax;

  /// This team's workers that are not stopped, and its limit at once.
  final int teamWorkers;
  final int teamMax;
  final List<SlotUse> slots;

  /// Work waiting: tasks nobody holds, and worker turns queued in the daemon.
  final int openTasks;
  final int queuedTurns;

  /// Local models the runtime holds in memory now (their names).
  final List<String> modelsLoaded;
  final bool derived;

  /// The owner's other computers that lend themselves to the team's work (their names), as the daemon lists them.
  final List<String> otherMachines;
}

/// [team]'s capacity: from [reply] (`team_capacity`) when there is one, else derived. [models] are this computer's
/// local models (their `loaded` flag).
TeamCapacityView capacityOf(TeamInfo team, CapacityReply? reply, List<LocalModelInfo> models) {
  final live = [for (final w in team.workers) if (!w.stopped) w];
  final open = team.tasks.where((t) => t.state == TaskState.open).length;
  final queued = team.workers.fold<int>(0, (a, w) => a + w.queued);
  final loaded = [for (final m in models) if (m.loaded) m.name];
  final machine = reply?.machines.firstOrNull;
  final slots = <SlotUse>[];
  for (final s in team.slots) {
    final fact = machine?.slots.where((c) => c.role == s.role && c.kind == s.kind).firstOrNull;
    final used = fact?.used ?? live.where((w) => w.role == s.role && w.kind == s.kind).length;
    slots.add(SlotUse(slot: s, used: used, unavailable: fact?.unavailable));
  }
  final sum = team.slots.fold<int>(0, (a, s) => a + s.max);
  return TeamCapacityView(
    machine: machine?.name ?? 'this computer',
    sandbox: machine?.sandbox ?? '',
    machineWorkers: machine?.workers ?? 0,
    machineMax: machine?.maxWorkers ?? 0,
    teamWorkers: reply?.workers ?? live.length,
    teamMax: reply?.maxWorkers ?? (team.maxWorkers > 0 ? team.maxWorkers : sum),
    slots: slots,
    openTasks: open,
    queuedTurns: queued,
    modelsLoaded: loaded,
    derived: machine == null,
    otherMachines: [for (final x in reply?.machines.skip(1) ?? const <MachineCapacity>[]) x.name],
  );
}

/// What a `team` event means for a team's lead that runs in this window's terminal: wake it with the team's line
/// when somebody else did something the lead acts on. Never for the lead's own changes (it knows them), never for a
/// worker's progress note or the daemon's own return of a failed check (the worker continues by itself), and never
/// for a daemon that does not say who acted ("could not check" is no).
bool teamEventWakesLead(TeamInfo team, TeamEvent e) {
  final lead = team.lead;
  final by = e.by;
  if (lead == null || by == null || by == lead) return false;
  return switch (e.change) {
    'task' => switch (e.state) {
        TaskState.submitted || TaskState.blocked => true,
        TaskState.working || TaskState.assigned => by == 'owner',
        TaskState.returned => by != 'daemon',
        TaskState.accepted || TaskState.done || TaskState.cancelled || TaskState.open => by == 'owner',
        _ => false,
      },
    // The owner changed the budget or the rules, or applied the team's branch (the lead waits for that approval).
    'changed' => by == 'owner',
    // The owner added or stopped a worker; the daemon's own state changes of workers are not news for the lead.
    'worker' => by == 'owner',
    _ => false,
  };
}

/// The longest live text the window keeps per worker (the tail).
const maxLiveText = 64 * 1024;

/// One worker's live output on a `team_watch` connection.
class WorkerLive {
  /// The turn on screen, and its task.
  int? turn;
  String? task;

  /// The turn's reply so far (plain text, control characters removed; the last [maxLiveText]).
  String text = '';

  /// What it does besides writing (`tool:Bash`; a local model: `loading`, `waiting`), until the next piece of text.
  String? activity;
  bool running = false;

  /// How the last turn ended (`done`, `interrupted`, `timeout`, `failed`, `error: …`).
  String? ended;
  DateTime? at;

  void _add(String piece) {
    text += plainModelText(piece);
    if (text.length > maxLiveText) text = text.substring(text.length - maxLiveText);
  }
}

mixin TeamsMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  HelloOk? get hello;
  DateTime now();
  bool get live;
  void safeNotify();
  List<LocalModelInfo> get localModels;

  /// A team changed in a way its lead (running in this window) acts on: give it the team's line (code_wake.dart).
  void onTeamLeadNews(String lead, String team);

  /// The daemon speaks x-control/7 and answers `team_list`.
  bool get teamsSupported => controlVersion(hello?.proto) >= teamsVersion && !teamsAbsent;

  /// A v7 daemon refused `team_list` as unknown: one built before teams. Nothing of teams is shown until it reconnects.
  bool teamsAbsent = false;

  /// `team_capacity` and `team_watch` are unknown to this daemon (built before the window's part of teams).
  bool teamCapacityAbsent = false;
  bool teamWatchAbsent = false;

  /// `team_list` answered at least once since the keys were unlocked.
  bool teamsLoaded = false;
  Object? teamsError;

  /// The teams, as `team_list` gives them (no tasks); a team whose board was read is in [teamDetails] too.
  List<TeamInfo> teams = const [];
  final Map<String, TeamInfo> teamDetails = {};
  final Map<String, CapacityReply> teamCapacities = {};
  final Map<String, Object> teamErrors = {};

  /// Tasks in full (`task_show`), by ID: the cards' last notes and the task view.
  final Map<String, TaskInfo> taskDetails = {};

  /// The team whose board is on screen.
  String? openTeam;

  /// A worker shown in the Code mode dock instead of a terminal.
  String? dockWorker;

  /// Live output per worker name, from the `team_watch` connections.
  final Map<String, WorkerLive> workerLive = {};
  final Map<String, XDialog> _watches = {};
  final Map<String, Future<void>> _refreshing = {};
  final Set<String> _dirty = {};
  int _teamsGen = 0;

  /// The team as the window knows it best: its board if it was read, else the list's summary.
  TeamInfo? team(String name) => teamDetails[name] ?? teams.where((t) => t.name == name).firstOrNull;

  /// The team [worker] belongs to.
  TeamInfo? teamOfWorker(String worker) {
    for (final t in [...teamDetails.values, ...teams]) {
      if (t.worker(worker) != null) return t;
    }
    return null;
  }

  /// The task in full if it was read, else its summary from the board.
  TaskInfo? task(String id) {
    final full = taskDetails[id];
    if (full != null) return full;
    for (final t in teamDetails.values) {
      for (final x in t.tasks) {
        if (x.id == id) return x;
      }
    }
    return null;
  }

  /// The team [lead] leads, if any.
  TeamInfo? teamLedBy(String lead) =>
      [...teamDetails.values, ...teams].where((t) => t.lead == lead).firstOrNull;

  /// The capacity strip of [name].
  TeamCapacityView? capacity(String name) {
    final t = team(name);
    return t == null ? null : capacityOf(t, teamCapacities[name], localModels);
  }

  /// Workers of every team whose output the Code mode dock offers as read-only tabs: cloud CLIs the daemon runs, not
  /// stopped (a local model's turns are in its team's board).
  List<WorkerInfo> get dockWorkers => [
        for (final t in teamDetails.values)
          for (final w in t.workers)
            if (!w.stopped && WorkerKind.cloud(w.kind)) w,
      ];

  void showWorkerInDock(String? worker) {
    dockWorker = worker;
    safeNotify();
  }

  /// Show [name]'s board (`null`: the list of teams), read again. [show]: switch the window to the Teams section too
  /// (from the Code mode dock, which stands next to every section).
  void openBoard(String? name, {bool show = false}) {
    openTeam = name;
    safeNotify();
    if (show) _showTeams.add(null);
    if (name != null) unawaited(refreshTeam(name));
  }

  /// The Teams section is asked for (the home screen switches to it).
  Stream<void> get showTeamsRequests => _showTeams.stream;
  final _showTeams = StreamController<void>.broadcast();

  /// What waits for the owner (the Teams badge): a lead's request to apply the team's branch, and in a team the
  /// owner leads, the tasks that wait for a review or an answer.
  int get teamsWaiting {
    var n = 0;
    for (final t in teams) {
      final d = teamDetails[t.name] ?? t;
      if (d.applyRequest != null) n++;
      if (d.ownerLeads) {
        n += d.tasks.where((x) => x.state == TaskState.submitted || x.state == TaskState.blocked).length;
      }
    }
    return n;
  }

  bool _unknown(XControlException e) =>
      e.code == XErrorCode.unknownCommand || (e.code == XErrorCode.badRequest && e.message.contains('unknown variant'));

  Future<void> refreshTeams() async {
    if (!teamsSupported) return;
    final gen = _teamsGen;
    try {
      final list = await daemon.teamList();
      if (gen != _teamsGen) return;
      teams = list;
      teamsLoaded = true;
      teamsError = null;
      final names = {for (final t in list) t.name};
      teamDetails.removeWhere((k, _) => !names.contains(k));
      teamCapacities.removeWhere((k, _) => !names.contains(k));
      if (openTeam != null && !names.contains(openTeam)) openTeam = null;
      // Every team's board is read: the dock's worker tabs and a lead's wake need the workers and the lead.
      await Future.wait([for (final t in list) refreshTeam(t.name)]);
      _syncWatches();
    } on XControlException catch (e) {
      if (_unknown(e)) {
        teamsAbsent = true;
      } else {
        teamsError = e;
      }
    } on XClientException catch (e) {
      teamsError = e;
    }
    safeNotify();
  }

  /// Read [name]'s board (`team_show`) and capacity again; a read already running is repeated once after it, and the
  /// caller waits for that repeat (an action's caller sees the board as the daemon has it after the action).
  Future<void> refreshTeam(String name) {
    final running = _refreshing[name];
    if (running != null) {
      _dirty.add(name);
      // The read in progress takes the request in its next round; one that ended before it saw it reads once more.
      return running.then((_) => _dirty.contains(name) ? refreshTeam(name) : null);
    }
    final done = _readTeam(name);
    _refreshing[name] = done;
    // Registered first, so the entry is gone before a waiting caller looks again.
    unawaited(done.then((_) {
      if (identical(_refreshing[name], done)) _refreshing.remove(name);
    }));
    return done;
  }

  Future<void> _readTeam(String name) async {
    final gen = _teamsGen;
    {
      do {
        _dirty.remove(name);
        try {
          final t = await daemon.teamShow(name);
          if (gen != _teamsGen) return;
          teamDetails[name] = t;
          teamErrors.remove(name);
          final i = teams.indexWhere((x) => x.name == name);
          teams = i < 0 ? [...teams, t] : ([...teams]..[i] = t);
          _dropGoneTasks(t);
          if (!teamCapacityAbsent) {
            try {
              teamCapacities[name] = await daemon.teamCapacity(name);
            } on XControlException catch (e) {
              if (_unknown(e)) teamCapacityAbsent = true;
            }
          }
          await _refreshNotes(t);
          // A worker the lead just spawned: its team's output is watched from now on.
          _syncWatches();
        } on XControlException catch (e) {
          if (e.code == XErrorCode.notFound) {
            _forgetTeam(name);
          } else {
            teamErrors[name] = e;
          }
        } on XClientException catch (e) {
          teamErrors[name] = e;
        }
        safeNotify();
      } while (_dirty.contains(name) && gen == _teamsGen);
    }
  }

  void _forgetTeam(String name) {
    teamDetails.remove(name);
    teamCapacities.remove(name);
    teams = teams.where((t) => t.name != name).toList();
    if (openTeam == name) openTeam = null;
    final w = _watches.remove(name);
    if (w != null) unawaited(w.cancel());
  }

  void _dropGoneTasks(TeamInfo t) {
    final ids = {for (final x in t.tasks) x.id};
    taskDetails.removeWhere((id, v) => v.team == t.name && !ids.contains(id));
  }

  /// The cards show each task's last note: tasks whose summary changed since the full view was read are read again
  /// (a task's report, reviews and check output are only in the full view).
  Future<void> _refreshNotes(TeamInfo t) async {
    var n = 0;
    for (final s in t.tasks) {
      if (s.state == TaskState.open && s.report == null) continue;
      final known = taskDetails[s.id];
      if (known != null && known.updatedMs == s.updatedMs && known.state == s.state) continue;
      if (++n > 40) break;
      await loadTask(s.id);
    }
  }

  /// Read one task in full. Returns the daemon's error or `null`.
  Future<Object?> loadTask(String id) async {
    try {
      taskDetails[id] = await daemon.taskShow(id);
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// The owner's subscription says a team changed: read it again; wake its lead when it should know.
  void onTeamEvent(TeamEvent e) {
    if (!teamsSupported) return;
    if (e.change == 'removed') {
      _forgetTeam(e.team);
      safeNotify();
      unawaited(refreshTeams());
      return;
    }
    final known = team(e.team);
    if (known == null || e.change == 'created') {
      unawaited(refreshTeams());
    } else {
      unawaited(refreshTeam(e.team));
    }
    if (e.task case final id? when taskDetails.containsKey(id)) unawaited(loadTask(id));
    if (known != null && teamEventWakesLead(known, e)) onTeamLeadNews(known.lead!, known.name);
  }

  // The live output of workers (`team_watch`).

  /// Keep one watch per team that has workers, while the daemon has the command.
  void _syncWatches() {
    if (!live || teamWatchAbsent || !teamsSupported) return;
    final want = {for (final t in teams) if (t.active && t.workers.any((w) => !w.stopped)) t.name};
    for (final name in _watches.keys.toList()) {
      if (!want.contains(name)) unawaited(_watches.remove(name)!.cancel());
    }
    for (final name in want) {
      if (!_watches.containsKey(name)) _watch(name);
    }
  }

  void _watch(String name) {
    final gen = _teamsGen;
    final d = daemon.teamWatch(name);
    _watches[name] = d;
    d.events.listen((e) {
      if (gen != _teamsGen) return;
      if (e is WorkerOutputEvent && e.team == name) onWorkerOutput(e);
      // Fell behind: a new watch starts with a fresh snapshot of the turns in progress.
      if (e is Lagged && identical(_watches[name], d)) {
        _watches.remove(name);
        unawaited(d.cancel());
        _syncWatches();
      }
    });
    unawaited(d.result.then((_) {}, onError: (Object e) async {
      if (gen != _teamsGen || !identical(_watches[name], d)) return;
      _watches.remove(name);
      if (e is XControlException && _unknown(e)) {
        teamWatchAbsent = true;
        safeNotify();
        return;
      }
      if (e is XControlException && (e.code == XErrorCode.notFound || e.code == XErrorCode.locked)) return;
      // A dropped connection: look again in a moment (the snapshot brings back what was missed).
      await Future<void>.delayed(const Duration(seconds: 2));
      if (gen == _teamsGen) _syncWatches();
    }));
  }

  /// A piece of a worker's turn (public for tests).
  void onWorkerOutput(WorkerOutputEvent e) {
    final w = workerLive.putIfAbsent(e.worker, WorkerLive.new);
    switch (e.part) {
      case 'snapshot':
        w
          ..turn = e.turn
          ..task = e.task
          ..text = ''
          ..activity = null
          ..running = true
          ..ended = null;
        w._add(e.text);
      case 'start':
        w
          ..turn = e.turn
          ..task = e.task
          ..text = ''
          ..activity = null
          ..running = true
          ..ended = null;
      case 'text':
        if (w.turn != e.turn) {
          w
            ..turn = e.turn
            ..task = e.task
            ..text = '';
        }
        w
          ..running = true
          ..activity = null;
        w._add(e.text);
      case 'activity':
        w
          ..running = true
          ..activity = plainModelText(e.text);
      case 'end':
        w
          ..running = false
          ..activity = null
          ..ended = plainModelText(e.text);
      default:
        return;
    }
    w.at = now();
    safeNotify();
  }

  /// The model is disposed.
  void disposeTeams() {
    clearTeams();
    unawaited(_showTeams.close());
  }

  void clearTeams() {
    _teamsGen++;
    for (final d in _watches.values) {
      unawaited(d.cancel());
    }
    _watches.clear();
    _refreshing.clear();
    _dirty.clear();
    teamsAbsent = false;
    teamCapacityAbsent = false;
    teamWatchAbsent = false;
    teamsLoaded = false;
    teamsError = null;
    teams = const [];
    teamDetails.clear();
    teamCapacities.clear();
    teamErrors.clear();
    taskDetails.clear();
    workerLive.clear();
    openTeam = null;
    dockWorker = null;
  }

  // The owner's actions. Each returns the daemon's error (or `null`); the board is read again either way.

  /// [request] gets the password to send (`''` with one touch, D-131).
  Future<(TeamInfo?, Object?)> createTeam(OwnerAuth auth, TeamCreateRequest Function(String password) request) async {
    try {
      final t = await ownerOp(auth, (d, pw) => d.teamCreate(request(pw)));
      teamDetails[t.name] = t;
      teams = [...teams.where((x) => x.name != t.name), t];
      safeNotify();
      unawaited(refreshTeam(t.name).then((_) => _syncWatches()));
      return (t, null);
    } on XClientException catch (e) {
      return (null, e);
    }
  }

  Future<Object?> _act(String team, Future<void> Function() op) async {
    try {
      await op();
      return null;
    } on XClientException catch (e) {
      return e;
    } finally {
      await refreshTeam(team);
      _syncWatches();
    }
  }

  Future<Object?> addTeamWorker(String team, String role, {String? kind}) =>
      _act(team, () => daemon.teamAddWorker(team, role, kind: kind));

  /// Stop every worker of [team], or one (no password).
  Future<Object?> stopTeam(String team, {String? worker}) => _act(team, () => daemon.teamStop(team, worker: worker));

  /// Make a stopped team active again (`team_set` with the password; nothing else changes).
  Future<Object?> reactivateTeam(String team, OwnerAuth auth) =>
      _act(team, () => ownerOp(auth, (d, pw) => d.teamSet(TeamSetRequest(team: team, password: pw))));

  /// [request] gets the password to send (`''` with one touch).
  Future<Object?> setTeam(String team, OwnerAuth auth, TeamSetRequest Function(String password) request) =>
      _act(team, () => ownerOp(auth, (d, pw) => d.teamSet(request(pw))));

  Future<Object?> removeTeam(String name) async {
    try {
      teams = await daemon.teamRemove(name);
      _forgetTeam(name);
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Merge the team's branch into the project's branch: the approval the team's rules keep for the owner. [commit] is
  /// what the owner reviewed (`approval_mismatch` when the branch moved since).
  Future<Object?> applyTeam(String team, {String? commit, required OwnerAuth auth}) =>
      _act(team, () => ownerOp(auth, (d, pw) => d.teamApply(team, commit: commit, password: pw)));

  Future<(TaskInfo?, Object?)> newTask(TaskNewRequest request) async {
    try {
      final t = await daemon.taskNew(request);
      taskDetails[t.id] = t;
      await refreshTeam(request.team);
      return (t, null);
    } on XClientException catch (e) {
      return (null, e);
    }
  }

  Future<Object?> _taskAct(String id, Future<TaskInfo> Function() op) async {
    try {
      final t = await op();
      taskDetails[t.id] = t;
      safeNotify();
      await refreshTeam(t.team);
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// [urgent] (CONTROL §33, experimental; only with `changes`): the worker's turn in progress is interrupted and the
  /// task returns to it with the comments at once, also while it is assigned, working or returned.
  Future<Object?> reviewTask(String id, String verdict, {String comments = '', bool urgent = false}) => _taskAct(
      id, () => daemon.taskReview(id, verdict, comments: comments, urgent: urgent && verdict == TaskVerdict.changes));

  Future<Object?> assignTask(String id, String worker) => _taskAct(id, () => daemon.taskAssign(id, worker));

  /// Merge an accepted task into the team's branch (no password: the project's branch does not move).
  Future<Object?> applyTask(String id) => _taskAct(id, () => daemon.taskApply(id));

  Future<(TaskDiffReply?, Object?)> taskDiff(String id) async {
    try {
      return (await daemon.taskDiff(id), null);
    } on XClientException catch (e) {
      return (null, e);
    }
  }

  Future<(List<TeamLogEntry>, Object?)> teamLog(String team, {int limit = 200}) async {
    try {
      return (await daemon.teamLog(team, limit: limit), null);
    } on XClientException catch (e) {
      return (const <TeamLogEntry>[], e);
    }
  }
}
