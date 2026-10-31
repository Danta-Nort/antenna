// SPDX-License-Identifier: AGPL-3.0-only
// The owner's team commands (x-control/7, CONTROL §25) on any [XDaemon]: typed calls over `call` and `open`, so the
// socket client and the test daemons share one implementation.

import 'daemon.dart';
import 'errors.dart';
import 'models.dart';
import 'requests.dart';

T _as<T extends Reply>(Reply r) {
  if (r is T) return r;
  throw XProtocolException('expected ${T.toString()}, got ${r.runtimeType}');
}

extension TeamCommands on XDaemon {
  Future<List<TeamInfo>> teamList() async => _as<TeamsReply>(await call(const TeamListRequest())).teams;

  Future<TeamInfo> teamShow(String team) async => _as<TeamReply>(await call(TeamShowRequest(team))).team;

  Future<TeamInfo> teamCreate(TeamCreateRequest request) async => _as<TeamReply>(await call(request)).team;

  Future<TeamInfo> teamSet(TeamSetRequest request) async => _as<TeamReply>(await call(request)).team;

  Future<WorkerInfo> teamAddWorker(String team, String role, {String? kind}) async =>
      _as<TeamWorkerReply>(await call(TeamAddWorkerRequest(team: team, role: role, kind: kind))).worker;

  Future<TeamInfo> teamStop(String team, {String? worker}) async =>
      _as<TeamReply>(await call(TeamStopRequest(team, worker: worker))).team;

  Future<List<TeamInfo>> teamRemove(String team) async => _as<TeamsReply>(await call(TeamRemoveRequest(team))).teams;

  Future<TeamInfo> teamApply(String team, {String? commit, required String password}) async =>
      _as<TeamReply>(await call(TeamApplyOwnerRequest(team: team, commit: commit, password: password))).team;

  Future<List<TeamLogEntry>> teamLog(String team, {int? limit}) async =>
      _as<TeamLogReply>(await call(TeamLogRequest(team, limit: limit))).entries;

  Future<CapacityReply> teamCapacity(String team) async => _as<CapacityReply>(await call(TeamCapacityRequest(team)));

  /// `worker_output` events of [team]'s workers until [XDialog.cancel].
  XDialog teamWatch(String team) => open(TeamWatchRequest(team));

  Future<TaskInfo> taskNew(TaskNewRequest request) async => _as<TaskReply>(await call(request)).task;

  Future<List<TaskInfo>> taskList(String team) async => _as<TasksReply>(await call(TaskListRequest(team))).tasks;

  Future<TaskInfo> taskShow(String id) async => _as<TaskReply>(await call(TaskShowRequest(id))).task;

  Future<TaskDiffReply> taskDiff(String id) async => _as<TaskDiffReply>(await call(TaskDiffRequest(id)));

  Future<TaskInfo> taskReview(String id, String verdict, {String comments = '', bool urgent = false}) async =>
      _as<TaskReply>(await call(TaskReviewRequest(id: id, verdict: verdict, comments: comments, urgent: urgent))).task;

  Future<TaskInfo> taskAssign(String id, String worker) async =>
      _as<TaskReply>(await call(TaskAssignRequest(id: id, worker: worker))).task;

  Future<TaskInfo> taskApply(String id) async => _as<TaskReply>(await call(TaskApplyRequest(id))).task;
}
