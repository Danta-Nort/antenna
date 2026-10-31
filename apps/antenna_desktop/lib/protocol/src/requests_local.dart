// SPDX-License-Identifier: AGPL-3.0-only
// Local models and local agents (x-control/7, CONTROL §24): a part of requests.dart. Owner commands only: an agent
// connection has none of them. Sent only to a daemon whose `hello_ok.proto` is x-control/7 or newer.

part of 'requests.dart';

/// The computer as the daemon reads it, the runtime, this release's catalog with each model's state here, and the
/// local agents.
final class LocalModelsRequest extends XRequest {
  const LocalModelsRequest();
  @override
  String get cmd => 'local_models';
  @override
  Json get fields => const {};
}

/// Get a catalog model onto this computer: download it from its pinned address, or copy [fromFile] (an absolute
/// path). The daemon checks the size and SHA-256 against the release before the file is ever loaded; the reply is the
/// model's state at once, the progress comes as `local_model` events.
final class ModelInstallRequest extends XRequest {
  const ModelInstallRequest(this.model, {this.fromFile});
  final String model;
  final String? fromFile;
  @override
  String get cmd => 'model_install';
  @override
  Json get fields => {'model': model, 'from_file': ?fromFile};
}

/// Cancel a model's download or delete its file. Its local agents stay (`no_model`).
final class ModelRemoveRequest extends XRequest {
  const ModelRemoveRequest(this.model);
  final String model;
  @override
  String get cmd => 'model_remove';
  @override
  Json get fields => {'model': model};
}

/// Create a local agent on a model (owner password, as `agent_add`): no links, no token, no tools in this release.
final class LocalAgentAddRequest extends XRequest {
  const LocalAgentAddRequest({required this.name, required this.model, required this.password});
  final String name;
  final String model;
  final String password;
  @override
  String get cmd => 'local_agent_add';
  @override
  Json get fields => {'name': name, 'model': model, 'password': password};
}

/// A turn of the owner's conversation with a local agent: a dialog, `local_delta` events and then `local_turn`.
/// [interrupt] ends the turn in progress first; [timeoutMs] only stops waiting (the turn runs to its end).
final class LocalSayRequest extends XRequest {
  const LocalSayRequest({required this.agent, required this.text, this.interrupt = false, this.timeoutMs});
  final String agent;
  final String text;
  final bool interrupt;
  final int? timeoutMs;
  @override
  String get cmd => 'local_say';
  @override
  Json get fields => {
        'agent': agent,
        'text': text,
        if (interrupt) 'interrupt': true,
        'timeout_ms': ?timeoutMs,
      };
  @override
  bool get isDialog => true;
}

/// A page of a local agent's conversation, oldest first; [before] is the first `seq` of the page already shown.
final class LocalHistoryRequest extends XRequest {
  const LocalHistoryRequest(this.agent, {this.limit, this.before});
  final String agent;
  final int? limit;
  final int? before;
  @override
  String get cmd => 'local_history';
  @override
  Json get fields => {'agent': agent, 'limit': ?limit, 'before': ?before};
}

/// What `local_session` can do with a local agent's session.
abstract final class LocalSessionAction {
  /// The agent's state, nothing changes.
  static const status = 'status';

  /// End the turn in progress; its reply so far is kept with `outcome: interrupted`.
  static const interrupt = 'interrupt';

  /// Stop its processes now; the conversation stays and the next turn starts them again.
  static const stop = 'stop';

  /// Delete the conversation: the next turn starts a new one.
  static const reset = 'reset';
}

/// A local agent's session ([LocalSessionAction]); the answer is the agent's state.
final class LocalSessionRequest extends XRequest {
  const LocalSessionRequest(this.agent, this.action);
  final String agent;
  final String action;
  @override
  String get cmd => 'local_session';
  @override
  Json get fields => {'agent': agent, 'action': action};
}
