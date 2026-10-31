// SPDX-License-Identifier: AGPL-3.0-only
// Teams of agents (x-control/7, CONTROL §25, D-111): a part of requests.dart. The owner's commands only: no agent
// connection has any of them (the lead's and the workers' commands are the daemon's agent commands). Sent only to a
// daemon whose `hello_ok.proto` is x-control/7; a v7 daemon built before teams refuses them as unknown.

part of 'requests.dart';

/// Every team command of the owner (the fake daemon routes them by this type).
sealed class TeamRequest extends XRequest {
  const TeamRequest();
}

/// The teams (summaries: no tasks).
final class TeamListRequest extends TeamRequest {
  const TeamListRequest();
  @override
  String get cmd => 'team_list';
  @override
  Json get fields => const {};
}

/// One team with its workers and task summaries.
final class TeamShowRequest extends TeamRequest {
  const TeamShowRequest(this.team);
  final String team;
  @override
  String get cmd => 'team_show';
  @override
  Json get fields => {'team': team};
}

/// Create a team (owner password: the budget lets the lead create agents). [lead] `null`: the owner leads.
final class TeamCreateRequest extends TeamRequest {
  const TeamCreateRequest({
    required this.name,
    required this.project,
    this.lead,
    this.slots = const [],
    this.maxWorkers,
    this.template,
    this.target,
    required this.password,
  });
  final String name;
  final String project;
  final String? lead;
  final List<TeamSlot> slots;
  final int? maxWorkers;
  final TeamTemplate? template;
  final String? target;
  final String password;
  @override
  String get cmd => 'team_create';
  @override
  Json get fields => {
        'name': name,
        'project': project,
        'lead': ?lead,
        'slots': [for (final s in slots) s.toJson()],
        'max_workers': ?maxWorkers,
        if (template case final t?) 'template': t.toJson(),
        'target': ?target,
        'password': password,
      };

  @override
  String toString() => 'XRequest::team_create($name)';
}

/// Change a team's lead, budget or template (owner password); it also makes a stopped team active again. [lead] `""`:
/// the owner leads.
final class TeamSetRequest extends TeamRequest {
  const TeamSetRequest({required this.team, this.lead, this.slots, this.maxWorkers, this.template,
      required this.password});
  final String team;
  final String? lead;
  final List<TeamSlot>? slots;
  final int? maxWorkers;
  final TeamTemplate? template;
  final String password;
  @override
  String get cmd => 'team_set';
  @override
  Json get fields => {
        'team': team,
        'lead': ?lead,
        if (slots case final s?) 'slots': [for (final x in s) x.toJson()],
        'max_workers': ?maxWorkers,
        if (template case final t?) 'template': t.toJson(),
        'password': password,
      };

  @override
  String toString() => 'XRequest::team_set($team)';
}

/// Add a worker within the budget, as the lead's `worker_spawn` does (no password: the budget is the authority).
final class TeamAddWorkerRequest extends TeamRequest {
  const TeamAddWorkerRequest({required this.team, required this.role, this.kind});
  final String team;
  final String role;
  final String? kind;
  @override
  String get cmd => 'team_add_worker';
  @override
  Json get fields => {'team': team, 'role': role, 'kind': ?kind};
}

/// Stop every worker of a team, or one (no password: it only takes work away).
final class TeamStopRequest extends TeamRequest {
  const TeamStopRequest(this.team, {this.worker});
  final String team;
  final String? worker;
  @override
  String get cmd => 'team_stop';
  @override
  Json get fields => {'team': team, 'worker': ?worker};
}

/// Remove a team: its workers, their folders and the branches of unapplied tasks go; the project and the integration
/// branch stay.
final class TeamRemoveRequest extends TeamRequest {
  const TeamRemoveRequest(this.team);
  final String team;
  @override
  String get cmd => 'team_remove';
  @override
  Json get fields => {'team': team};
}

/// Merge the team's integration branch into the project's branch (owner password: the approval the template keeps
/// for the owner). [commit]: only if the integration branch is still there (what the owner reviewed).
final class TeamApplyOwnerRequest extends TeamRequest {
  const TeamApplyOwnerRequest({required this.team, this.commit, required this.password});
  final String team;
  final String? commit;
  final String password;
  @override
  String get cmd => 'team_apply';
  @override
  Json get fields => {'team': team, 'commit': ?commit, 'password': password};

  @override
  String toString() => 'XRequest::team_apply($team)';
}

/// The team's audit log, newest last.
final class TeamLogRequest extends TeamRequest {
  const TeamLogRequest(this.team, {this.limit});
  final String team;
  final int? limit;
  @override
  String get cmd => 'team_log';
  @override
  Json get fields => {'team': team, 'limit': ?limit};
}

/// The machines the team may use, their sandboxes, workers and the slots' use (the lead's `capacity`, for the owner).
final class TeamCapacityRequest extends TeamRequest {
  const TeamCapacityRequest(this.team);
  final String team;
  @override
  String get cmd => 'team_capacity';
  @override
  Json get fields => {'team': team};
}

/// Watch the team's workers: a dialog of `worker_output` events (a snapshot of each running turn first) until the
/// client closes it; `not_found` when the team goes, `locked` when the keys lock.
final class TeamWatchRequest extends TeamRequest {
  const TeamWatchRequest(this.team);
  final String team;
  @override
  String get cmd => 'team_watch';
  @override
  Json get fields => {'team': team};
  @override
  bool get isDialog => true;
}

/// The owner writes a task; [assignee] gives it to a worker at once.
final class TaskNewRequest extends TeamRequest {
  const TaskNewRequest({required this.team, required this.title, this.brief = '', this.check = const [], this.assignee});
  final String team;
  final String title;
  final String brief;
  final List<String> check;
  final String? assignee;
  @override
  String get cmd => 'task_new';
  @override
  Json get fields => {
        'team': team,
        'title': title,
        if (brief.isNotEmpty) 'brief': brief,
        if (check.isNotEmpty) 'check': check,
        'assignee': ?assignee,
      };
}

/// A team's tasks (summaries).
final class TaskListRequest extends TeamRequest {
  const TaskListRequest(this.team);
  final String team;
  @override
  String get cmd => 'task_list';
  @override
  Json get fields => {'team': team};
}

/// One task in full: brief, notes, reviews, report, result, check output.
final class TaskShowRequest extends TeamRequest {
  const TaskShowRequest(this.id);
  final String id;
  @override
  String get cmd => 'task_show';
  @override
  Json get fields => {'id': id};
}

/// What a task's result changes.
final class TaskDiffRequest extends TeamRequest {
  const TaskDiffRequest(this.id);
  final String id;
  @override
  String get cmd => 'task_diff';
  @override
  Json get fields => {'id': id};
}

/// The owner's review verdicts (`task_review`).
abstract final class TaskVerdict {
  /// Accept a submitted result: it waits to be applied to the integration branch.
  static const accept = 'accept';

  /// Back to the worker with the comments; also the answer to a blocked worker's question.
  static const changes = 'changes';
  static const cancel = 'cancel';
}

/// The owner reviews a task as its lead would.
final class TaskReviewRequest extends TeamRequest {
  const TaskReviewRequest({required this.id, required this.verdict, this.comments = '', this.urgent = false});
  final String id;
  final String verdict;
  final String comments;

  /// CONTROL §33 (experimental): with `changes` only, "Urgent: interrupt the worker now": the worker's turn in
  /// progress is interrupted and the task returns to it at once, also while it is assigned, working or returned. Sent
  /// only when set.
  final bool urgent;
  @override
  String get cmd => 'task_review';
  @override
  Json get fields =>
      {'id': id, 'verdict': verdict, if (comments.isNotEmpty) 'comments': comments, if (urgent) 'urgent': true};
}

/// The owner gives an open task to one of the team's workers (as the lead's `task_assign`).
final class TaskAssignRequest extends TeamRequest {
  const TaskAssignRequest({required this.id, required this.worker});
  final String id;
  final String worker;
  @override
  String get cmd => 'task_assign';
  @override
  Json get fields => {'id': id, 'worker': worker};
}

/// The owner merges an accepted task into the team's integration branch (no password: the project's branch is not
/// touched; that is `team_apply`).
final class TaskApplyRequest extends TeamRequest {
  const TaskApplyRequest(this.id);
  final String id;
  @override
  String get cmd => 'task_apply';
  @override
  Json get fields => {'id': id};
}
