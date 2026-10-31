// SPDX-License-Identifier: AGPL-3.0-only
// The owner's team commands on the wire and their replies and events parsed (x-control/7, CONTROL §25; the shapes of
// crates/antenna-proto/src/control/teams.rs): every reply type and the `team` and `worker_output` events become typed
// values instead of UnknownReply/UnknownEvent; requests carry exactly their fields, empty ones left out; a password
// never reaches toString; an older daemon's team without the newer fields still parses.

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _worker(String name, {String state = 'idle', String? task, int? queued}) => {
      'name': name,
      'team': 'web',
      'role': 'coder',
      'kind': 'claude',
      'machine': 'this computer',
      'state': state,
      'task': ?task,
      'spawned_by': 'lead',
      'turns': 3,
      'queued': ?queued,
      'input_tokens': 1200,
      'output_tokens': 80,
      'detail': 'turn done',
      'created_ms': 1,
    };

final _task = <String, Object?>{
  'id': 'a1f3c95e1d000001',
  'team': 'web',
  'title': 'Fix the parser',
  'brief': 'Make 2026-W53 parse.',
  'check': ['cargo', 'test'],
  'assignee': 'web.coder-1',
  'state': 'submitted',
  'created_by': 'lead',
  'ceiling': 2,
  'round': 2,
  'notes': 'state: done',
  'reviews': [
    {'by': 'daemon', 'verdict': 'changes', 'comments': 'The check failed.', 'at_ms': 5},
  ],
  'report': {'by': 'web.coder-1', 'state': 'submitted', 'summary': 'Fixed.', 'at_ms': 6},
  'result': {
    'branch': 'team/a1f3c95e1d000001',
    'base': 'b' * 40,
    'commit': 'c' * 40,
    'files': 2,
    'insertions': 10,
    'deletions': 3,
    'ceiling': 2,
    'at_ms': 6,
  },
  'check_run': {
    'task': 'a1f3c95e1d000001',
    'commit': 'c' * 40,
    'argv': ['cargo', 'test'],
    'outcome': 'passed',
    'exit_code': 0,
    'output': 'ok',
    'blocked_hosts': ['example.com'],
    'sandbox': 'bwrap',
    'duration_ms': 940,
    'by': 'daemon',
    'at_ms': 7,
  },
  'tokens': 1280,
  'created_ms': 1,
  'updated_ms': 7,
};

Map<String, Object?> _team({bool newer = true}) => {
      'name': 'web',
      'project': '/home/jordan/code/web',
      'target': 'main',
      'integration': 'antenna/web',
      'integration_commit': 'd' * 40,
      'lead': 'lead',
      'state': 'active',
      'slots': [
        {'role': 'coder', 'kind': 'claude', 'max': 2, 'argv': ['claude', '--model', 'haiku']},
        {'role': 'docs', 'kind': 'local', 'model': 'qwen3.5-9b', 'max': 1},
      ],
      'max_workers': 3,
      'template': {
        'commands': true,
        'checks': [
          ['cargo', 'test'],
        ],
        'check_hosts': ['index.crates.io'],
        'check_timeout_secs': 600,
        'check_retries': 3,
        'turn_timeout_secs': 1800,
        'max_task_tokens': 0,
        'apply': 'owner',
      },
      'workers': [_worker('web.coder-1', state: 'busy', task: 'a1f3c95e1d000001', queued: newer ? 1 : null)],
      'tasks': [_task],
      'apply_request': {'by': 'lead', 'commit': 'd' * 40, 'at_ms': 9},
      'created_ms': 1,
    };

void main() {
  test('team, teams, team_worker: every field, a pending apply request, an older daemon without queued', () {
    final r = Reply.fromJson({'type': 'team', ..._team()}) as TeamReply;
    final t = r.team;
    expect((t.name, t.target, t.integration, t.lead, t.active, t.ownerLeads), ('web', 'main', 'antenna/web', 'lead', true, false));
    expect(t.slots.first.argv, ['claude', '--model', 'haiku']);
    expect(t.slots.last.model, 'qwen3.5-9b');
    expect(t.template.checks, [
      ['cargo', 'test'],
    ]);
    expect(t.template.ownerApplies, isTrue);
    expect(t.applyRequest!.commit, 'd' * 40);
    expect(t.worker('web.coder-1')!.queued, 1);
    expect(t.worker('web.coder-1')!.busy, isTrue);
    final older = Reply.fromJson({'type': 'team', ..._team(newer: false)}) as TeamReply;
    expect(older.team.workers.single.queued, 0);
    final list = Reply.fromJson({
      'type': 'teams',
      'teams': [
        {..._team(), 'tasks': <Object?>[]},
      ],
    }) as TeamsReply;
    expect(list.teams.single.tasks, isEmpty);
    final w = Reply.fromJson({'type': 'team_worker', ..._worker('web.coder-2')}) as TeamWorkerReply;
    expect((w.worker.name, w.worker.state, w.worker.task), ('web.coder-2', 'idle', null));
  });

  test('task, tasks, task_diff: the full view and a summary', () {
    final t = (Reply.fromJson({'type': 'task', ..._task}) as TaskReply).task;
    expect((t.shortId, t.state, t.ceiling, t.round), ('a1f3c9', TaskState.submitted, 2, 2));
    expect(t.reviews.single.by, 'daemon');
    expect(t.report!.summary, 'Fixed.');
    expect(t.result!.textOnly, isFalse);
    expect(t.checkRun!.passed, isTrue);
    expect(t.checkRun!.blockedHosts, ['example.com']);
    expect('$t', isNot(contains('Fixed')), reason: 'a worker\'s text never reaches toString');
    final summary = (Reply.fromJson({
      'type': 'tasks',
      'tasks': [
        {
          'id': 'a1f3c95e1d000001',
          'team': 'web',
          'title': 'Fix the parser',
          'state': 'open',
          'created_by': 'owner',
          'tokens': 0,
          'created_ms': 1,
          'updated_ms': 1,
        },
      ],
    }) as TasksReply)
        .tasks
        .single;
    expect((summary.brief, summary.report, summary.result), ('', null, null));
    final d = Reply.fromJson({
      'type': 'task_diff',
      'task': 'a1f3c95e1d000001',
      'base': 'b' * 40,
      'stat': ' calc.py | 2 +-',
      'diff': '-a\n+b',
      'truncated': true,
    }) as TaskDiffReply;
    expect((d.commit, d.truncated), (null, true), reason: 'a worker\'s folder not submitted yet');
    expect('$d', isNot(contains('+b')));
  });

  test('capacity and team_log', () {
    final c = Reply.fromJson({
      'type': 'capacity',
      'team': 'web',
      'workers': 1,
      'max_workers': 3,
      'machines': [
        {
          'name': 'this computer',
          'sandbox': 'bwrap',
          'workers': 2,
          'max_workers': 8,
          'slots': [
            {'role': 'coder', 'kind': 'claude', 'used': 1, 'max': 2},
            {'role': 'docs', 'kind': 'local', 'used': 0, 'max': 1, 'unavailable': 'qwen3.5-9b is not installed'},
          ],
          'local_models': ['qwen3.5-2b'],
        },
      ],
    }) as CapacityReply;
    expect(c.machines.single.slots.last.unavailable, 'qwen3.5-9b is not installed');
    expect(c.machines.single.localModels, ['qwen3.5-2b']);
    final log = Reply.fromJson({
      'type': 'team_log',
      'entries': [
        {'ts': 1, 'actor': 'lead', 'action': 'apply_result', 'decision': 'approval_required'},
        {'ts': 2, 'actor': 'daemon', 'action': 'run_check', 'task': 'a1f3c95e1d000001', 'decision': 'passed', 'detail': 'exit 0'},
      ],
    }) as TeamLogReply;
    expect(log.entries.map((e) => (e.actor, e.decision)), [('lead', 'approval_required'), ('daemon', 'passed')]);
  });

  test('the team and worker_output events, with and without who acted', () {
    final e = XEvent.fromJson({
      'kind': 'team',
      'team': 'web',
      'change': 'task',
      'task': 'a1f3c95e1d000001',
      'state': 'submitted',
      'by': 'web.coder-1',
    }) as TeamEvent;
    expect((e.change, e.state, e.by), ('task', 'submitted', 'web.coder-1'));
    final old = XEvent.fromJson({'kind': 'team', 'team': 'web', 'change': 'worker', 'worker': 'web.coder-1'}) as TeamEvent;
    expect(old.by, isNull, reason: 'a daemon that does not say who acted');
    final o = XEvent.fromJson({
      'kind': 'worker_output',
      'team': 'web',
      'worker': 'web.coder-1',
      'task': 'a1f3c95e1d000001',
      'turn': 4,
      'part': 'text',
      'text': 'secret words',
    }) as WorkerOutputEvent;
    expect((o.worker, o.turn, o.part, o.text), ('web.coder-1', 4, 'text', 'secret words'));
    expect('$o', isNot(contains('secret')), reason: 'a worker\'s text never reaches toString');
  });

  test('requests: exactly their fields, empty ones left out, the password never printed', () {
    final create = TeamCreateRequest(
      name: 'web',
      project: '/home/jordan/code/web',
      slots: const [TeamSlot(role: 'coder', kind: 'claude', max: 2)],
      template: const TeamTemplate(checks: [
        ['cargo', 'test'],
      ]),
      password: 'secret',
    );
    expect(create.toJson(), {
      'cmd': 'team_create',
      'name': 'web',
      'project': '/home/jordan/code/web',
      'slots': [
        {'role': 'coder', 'kind': 'claude', 'max': 2},
      ],
      'template': {
        'commands': true,
        'checks': [
          ['cargo', 'test'],
        ],
        'check_timeout_secs': 600,
        'check_retries': 3,
        'turn_timeout_secs': 1800,
        'max_task_tokens': 0,
        'apply': 'owner',
      },
      'password': 'secret',
    });
    expect('$create', isNot(contains('secret')));
    expect(const TeamApplyOwnerRequest(team: 'web', password: 'pw').toJson(), {'cmd': 'team_apply', 'team': 'web', 'password': 'pw'});
    expect('${const TeamApplyOwnerRequest(team: 'web', password: 'pw')}', isNot(contains('pw')));
    expect(const TaskNewRequest(team: 'web', title: 'T').toJson(), {'cmd': 'task_new', 'team': 'web', 'title': 'T'});
    expect(const TaskReviewRequest(id: 'a1', verdict: TaskVerdict.accept).toJson(),
        {'cmd': 'task_review', 'id': 'a1', 'verdict': 'accept'});
    expect(const TaskAssignRequest(id: 'a1', worker: 'web.coder-1').toJson(),
        {'cmd': 'task_assign', 'id': 'a1', 'worker': 'web.coder-1'});
    expect(const TeamStopRequest('web').toJson(), {'cmd': 'team_stop', 'team': 'web'});
    expect(const TeamWatchRequest('web').isDialog, isTrue);
    expect(const TeamCapacityRequest('web').toJson(), {'cmd': 'team_capacity', 'team': 'web'});
  });
}
