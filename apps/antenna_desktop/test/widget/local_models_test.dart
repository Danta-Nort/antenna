// SPDX-License-Identifier: AGPL-3.0-only
// Local models and local agents in the window (x-control/7, CONTROL §24; docs/LOCAL-ASSISTANT.md §7): the Local
// models card in every state of a model (available, downloading, verifying, ready, failed with a hash mismatch, a
// download refused for space, the runtime missing, a computer that runs no model), the other models with their fit,
// the local agents with the Local badge only where the daemon says `runtime: "local"`, Create agent (name check,
// password), the conversations in "On this computer" above the contacts, a reply streaming from `local_delta`, Stop,
// New conversation, a failed turn, plain model text; and a v6 daemon, which gets none of it.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/local_models.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/experimental_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_local.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

const _mib = 1024 * 1024;

Future<(AppModel, FakeDaemon)> _model({int proto = 7, void Function(FakeDaemon d)? setup}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..protoVersion = proto
    ..localModelsEnabled = true;
  setup?.call(d);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _pump(WidgetTester t, [int times = 2]) async {
  for (var i = 0; i < times; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _pump(t);
}

Future<void> _agents(WidgetTester t) async {
  await t.tap(find.byKey(const Key('agents-button')));
  await _pump(t);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _pump(t);
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

/// [s] in the open local conversation (the chat list shows the last message too).
Finder _inChat(String s) => find.descendant(of: find.byKey(const Key('local-chat-view-helper')), matching: find.text(s));

LocalModelInfo _small(FakeDaemon d) => d.localModelList.first;

void _event(AppModel m, XEvent e) => m.handleEvent(e);

/// helper on a ready Qwen3.5 2B, with an earlier turn in its conversation.
void _helper(FakeDaemon d, {bool history = true}) {
  d.localModelList = demoCatalog(smallState: LocalModelState.ready, smallAgents: const ['helper']);
  d.setLocalAgent(demoLocalAgent('helper'));
  d.agentList = [AgentInfo(name: 'helper', createdMs: 0, links: const [], localModel: 'qwen3.5-2b')];
  if (history) d.localReply('helper', 'What can you do?', 'I can answer questions while you work.');
}

void main() {
  test('names: prefilled from the model ID and free, checked as the daemon checks them', () {
    expect(suggestLocalAgentName('qwen3.5-2b', const []), 'qwen3.5-2b');
    expect(suggestLocalAgentName('qwen3.5-2b', const ['qwen3.5-2b', 'qwen3.5-2b-2']), 'qwen3.5-2b-3');
    expect(suggestLocalAgentName('Gemma 3/12B', const []), 'Gemma-3-12B');
    expect(suggestLocalAgentName('***', const []), 'local');
    expect(suggestLocalAgentName('a' * 80, const []).length, 60);
    expect(validLocalAgentName('helper.v2_x-1'), isTrue);
    for (final bad in ['', 'my agent', '\u00e9t\u00e9', 'a/b', 'x' * 65]) {
      expect(validLocalAgentName(bad), isFalse, reason: bad);
    }
  });

  test('model text is plain: control characters and direction overrides are removed, lines kept', () {
    expect(plainModelText('a\u202Eevil\u202C b\x07\x1b[31mred\r\nnext\tcol'), 'aevil b[31mred\nnext\tcol');
    expect(plainModelText('\u2066x\u2069\u200E'), 'x');
  });

  testWidgets('a v6 daemon: no Local models card, no local section, no local command', (t) async {
    final (m, d) = await _model(proto: 6, setup: _helper);
    await _app(t, m);
    expect(find.byKey(const Key('list-on-this-computer')), findsNothing);
    await _agents(t);
    expect(find.byKey(const Key('local-models')), findsNothing);
    expect(d.calls.where((c) => c.startsWith('local_') || c.startsWith('model_')), isEmpty);
    expect(m.localModelsSupported, isFalse);
  });

  testWidgets('a v7 daemon without local models: it refuses local_models once, and the window shows none of them',
      (t) async {
    final (m, d) = await _model(setup: (d) => d.localModelsEnabled = false);
    await _app(t, m);
    expect(find.byKey(const Key('list-on-this-computer')), findsNothing);
    await _agents(t);
    expect(find.byKey(const Key('local-models')), findsNothing);
    expect(m.localModelsAbsent, isTrue);
    expect(m.localError, isNull, reason: 'not an error: a daemon without the feature');
    expect(d.calls.where((c) => c == 'local_models').length, 1, reason: 'asked once, not again on every screen');
  });

  testWidgets('available: the computer, the recommended model, Download asks first and then installs', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _agents(t);
    expect(find.byKey(const Key('local-models')), findsOneWidget);
    expect(t.widget(find.byKey(const Key('experimental-local-models'))), isA<ExperimentalTag>());
    expect(find.text('This computer: Apple M2 Pro · 16 GB memory · 210 GB free'), findsOneWidget);
    expect(find.byKey(const Key('local-runtime-missing')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('local-fit-qwen3.5-2b')), matching: find.text(en.localFitRecommended)),
        findsOneWidget);
    expect(_text('Qwen (Alibaba Cloud) · 1.2 GB download · needs 2.0 GB of memory · about 18 words a second here'),
        findsOneWidget);
    expect(_text('License: Apache-2.0'), findsWidgets);
    // The others wait behind the disclosure; nothing about local agents yet but one line.
    expect(find.byKey(const Key('local-model-qwen3.5-4b')), findsNothing);
    expect(find.byKey(const Key('local-agents-empty')), findsOneWidget);
    expect(find.text(en.localComingNext), findsOneWidget);

    await _tap(t, find.byKey(const Key('local-download-qwen3.5-2b')));
    expect(_text(en.localDownloadTitle('Qwen3.5 2B')), findsOneWidget);
    expect(_text('1.2 GB from huggingface.co'), findsOneWidget);
    expect(d.installCalls, isEmpty, reason: 'nothing is downloaded before the owner confirms');
    await _tap(t, find.byKey(const Key('local-download-confirm')));
    expect(d.installCalls, [('qwen3.5-2b', null)]);
    expect(find.byKey(const Key('local-progress-qwen3.5-2b')), findsOneWidget);
    expect(find.byKey(const Key('local-cancel-qwen3.5-2b')), findsOneWidget);
  });

  testWidgets('a download moves by events: progress, checking, ready; Cancel removes the part', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _agents(t);
    final small = _small(d);
    _event(m, LocalModelEvent(modelInState(small, LocalModelState.downloading, doneBytes: 640 * _mib, speed: 12 * _mib)));
    await _pump(t, 1);
    expect(_text('640 MB of 1.2 GB · 12.0 MB/s · 00:49 left'), findsOneWidget);
    final bar = t.widget<LinearProgressIndicator>(
        find.descendant(of: find.byKey(const Key('local-progress-qwen3.5-2b')), matching: find.byType(LinearProgressIndicator)));
    expect(bar.value, closeTo(640 * _mib / small.sizeBytes, 1e-9));

    await _tap(t, find.byKey(const Key('local-cancel-qwen3.5-2b')));
    expect(d.removeCalls, ['qwen3.5-2b'], reason: 'Cancel is model_remove, with no confirmation');
    expect(find.byKey(const Key('local-download-qwen3.5-2b')), findsOneWidget);

    _event(m, LocalModelEvent(modelInState(small, LocalModelState.verifying, doneBytes: small.sizeBytes)));
    await t.pump();
    expect(find.text(en.localVerifying), findsOneWidget);
    expect(find.byKey(const Key('local-cancel-qwen3.5-2b')), findsNothing);

    _event(m, LocalModelEvent(modelInState(small, LocalModelState.ready, doneBytes: small.sizeBytes)));
    await _pump(t, 1);
    expect(find.byKey(const Key('local-ready-qwen3.5-2b')), findsOneWidget);
    expect(find.byKey(const Key('local-create-qwen3.5-2b')), findsOneWidget);
    expect(find.byKey(const Key('local-remove-qwen3.5-2b')), findsOneWidget);

    // Remove asks first (the file goes; agents would stay).
    await _tap(t, find.byKey(const Key('local-remove-qwen3.5-2b')));
    expect(_text(en.localRemoveTitle('Qwen3.5 2B')), findsOneWidget);
    await _tap(t, find.byKey(const Key('local-remove-confirm')));
    expect(d.removeCalls, ['qwen3.5-2b', 'qwen3.5-2b']);
  });

  testWidgets('failed with a hash mismatch: the file was deleted, Try again downloads again', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _agents(t);
    _event(m, LocalModelEvent(modelInState(_small(d), LocalModelState.failed, errorCode: XErrorCode.hashMismatch)));
    await _pump(t, 1);
    expect(find.text('The file does not match what this version of Antenna expects. It was deleted.'), findsOneWidget);
    await _tap(t, find.byKey(const Key('local-retry-qwen3.5-2b')));
    await _tap(t, find.byKey(const Key('local-download-confirm')));
    expect(d.installCalls, [('qwen3.5-2b', null)]);
  });

  testWidgets('no space: the daemon refuses the download before it starts, and the card says why', (t) async {
    final (m, d) = await _model(
        setup: (d) => d.installError = const XControlException(XErrorCode.noSpace, 'needs 2.4 GB, 1.1 GB free'));
    await _app(t, m);
    await _agents(t);
    await _tap(t, find.byKey(const Key('local-download-qwen3.5-2b')));
    await _tap(t, find.byKey(const Key('local-download-confirm')));
    expect(find.text('${en.localErrNoSpace} needs 2.4 GB, 1.1 GB free'), findsOneWidget);
    expect(find.byKey(const Key('local-download-qwen3.5-2b')), findsOneWidget, reason: 'still available');
    // A no_space failure reported by an event (the disk filled up during the download).
    _event(m, LocalModelEvent(modelInState(_small(d), LocalModelState.failed, errorCode: XErrorCode.noSpace)));
    await _pump(t, 1);
    expect(find.byKey(const Key('local-failed-qwen3.5-2b')), findsOneWidget);
  });

  testWidgets('the runtime is missing: one line why, and models can still be downloaded', (t) async {
    final (m, _) = await _model(
        setup: (d) => d.localRuntime =
            const LocalRuntimeInfo(available: false, sandbox: 'none', detail: 'no llama-server next to antennad'));
    await _app(t, m);
    await _agents(t);
    expect(find.descendant(of: find.byKey(const Key('local-runtime-missing')), matching: find.text(en.localNoRuntime)),
        findsOneWidget);
    expect(find.text('no llama-server next to antennad'), findsOneWidget);
    expect(find.byKey(const Key('local-download-qwen3.5-2b')), findsOneWidget);
  });

  testWidgets('a computer that runs no local model: one line, every model "not for this computer", no Download',
      (t) async {
    final (m, _) = await _model(setup: (d) {
      d.localHardware = demoSmallLaptop;
      d.localModelList = demoCatalog(
          smallFit: LocalFit.unsupported,
          mediumFit: LocalFit.unsupported,
          largeFit: LocalFit.unsupported,
          hugeFit: LocalFit.unsupported);
    });
    await _app(t, m);
    await _agents(t);
    expect(find.byKey(const Key('local-unsupported')), findsOneWidget);
    expect(find.text('This computer: Intel Celeron N4020 · 4 GB memory · 40 GB free'), findsOneWidget);
    await _tap(t, find.byKey(const Key('local-other-models')));
    expect(find.text(en.localFitUnsupported), findsNWidgets(4));
    expect(
        find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('local-download-')),
        findsNothing);
  });

  testWidgets('other models: behind a disclosure, each with its fit in plain words', (t) async {
    final (m, _) = await _model();
    await _app(t, m);
    await _agents(t);
    expect(find.text(en.localOtherModels(3)), findsOneWidget);
    await _tap(t, find.byKey(const Key('local-other-models')));
    expect(find.text(en.localFitFits), findsOneWidget);
    expect(find.text(en.localFitSlow), findsOneWidget);
    expect(find.text(en.localFitTooBig('18.4 GB')), findsOneWidget);
    expect(find.byKey(const Key('local-download-qwen3.5-27b')), findsOneWidget, reason: 'too big now is not forever');
  });

  testWidgets('Create agent: a free valid name, the owner password once; the conversation opens', (t) async {
    final (m, d) = await _model(setup: (d) {
      d.localModelList = demoCatalog(smallState: LocalModelState.ready);
      d.agentList = [const AgentInfo(name: 'qwen3.5-2b', createdMs: 0, localLevel: 3)];
    });
    await _app(t, m);
    await _agents(t);
    await _tap(t, find.byKey(const Key('local-create-qwen3.5-2b')));
    final name = find.byKey(const Key('local-agent-name'));
    expect(t.widget<TextField>(name).controller!.text, 'qwen3.5-2b-2', reason: 'qwen3.5-2b is taken by another agent');
    Finder create() => find.byKey(const Key('local-agent-create'));
    bool enabled() => t.widget<FilledButton>(create()).onPressed != null;
    expect(enabled(), isFalse, reason: 'no password yet');

    await t.enterText(name, 'my agent');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.pump();
    expect(find.text(en.localCreateNameInvalid), findsOneWidget);
    expect(enabled(), isFalse);
    await t.enterText(name, 'qwen3.5-2b');
    await t.pump();
    expect(find.text(en.localCreateNameTaken), findsOneWidget);

    await t.enterText(name, 'helper');
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await t.pump();
    expect(enabled(), isTrue);
    await _tap(t, create());
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(d.localAgentAdds, isEmpty);

    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await _tap(t, create());
    expect(d.localAgentAdds, [('helper', 'qwen3.5-2b')]);
    expect(d.passwords['local_agent_add'], d.password);
    expect(find.byKey(const Key('local-agent-name')), findsNothing, reason: 'the dialog closed');
    // The conversation opens in Chats, with the agent in "On this computer".
    expect(find.byKey(const Key('local-chat-view-helper')), findsOneWidget);
    expect(find.byKey(const Key('local-tile-helper')), findsOneWidget);
    expect(find.byKey(const Key('local-intro')), findsOneWidget);
  });

  testWidgets('local agents: the Local badge only for runtime "local", the state in plain words, Chat, Remove',
      (t) async {
    final (m, d) = await _model(setup: (d) {
      _helper(d, history: false);
      // An agent whose model the daemon does not say it runs here: no badge, whatever its name.
      d.setLocalAgent(const LocalAgentInfo(name: 'local-helper', model: 'qwen3.5-4b', runtime: '', state: 'no_model'));
      d.agentList = [
        ...d.agentList,
        const AgentInfo(name: 'claude-code', createdMs: 0, localLevel: 4),
      ];
    });
    await _app(t, m);
    await _agents(t);
    expect(find.byKey(const Key('local-badge-helper')), findsWidgets);
    expect(find.byKey(const Key('local-badge-local-helper')), findsNothing);
    expect(find.text(en.localBadgeMac), findsWidgets, reason: 'the daemon says this computer is a Mac');
    expect(t.widget<Tooltip>(find.ancestor(of: find.text(en.localBadgeMac).first, matching: find.byType(Tooltip)).first)
        .message, en.localBadgeTip);
    expect(find.text('Qwen3.5 2B · ready'), findsOneWidget);
    expect(find.text('Qwen3.5 4B · model missing'), findsOneWidget);
    // Local agents are with their models, not among the agents that connect themselves.
    expect(find.byKey(const Key('agent-row-helper')), findsNothing);
    expect(find.byKey(const Key('agent-row-claude-code')), findsOneWidget);

    // Remove: the owner password, then agent_remove.
    await _tap(t, find.byKey(const Key('local-agent-menu-helper')));
    await _tap(t, find.byKey(const Key('local-agent-remove-helper')));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await _tap(t, find.byKey(const Key('password-ok')));
    expect(d.passwords['agent_remove'], d.password);
    expect(find.byKey(const Key('local-agent-helper')), findsNothing);
  });

  testWidgets('on Linux the badge says "this computer"', (t) async {
    final (m, _) = await _model(setup: (d) {
      _helper(d);
      d.localHardware = demoLinux;
    });
    await _app(t, m);
    await _agents(t);
    expect(find.text(en.localBadgeComputer), findsWidgets);
    expect(find.text(en.localBadgeMac), findsNothing);
  });

  testWidgets('the chat list: local agents in "On this computer" above the contacts; Chat opens the conversation',
      (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    final section = find.byKey(const Key('list-on-this-computer'));
    final tile = find.byKey(const Key('local-tile-helper'));
    expect(section, findsOneWidget);
    expect(t.getTopLeft(tile).dy, lessThan(t.getTopLeft(find.byKey(Key('contact-$emilyName'))).dy));
    expect(find.descendant(of: tile, matching: find.text(en.localBadgeShort)), findsOneWidget);
    await _tap(t, tile);
    expect(find.byKey(const Key('local-chat-view-helper')), findsOneWidget);
    expect(d.calls, contains('local_history'));
    expect(_inChat('I can answer questions while you work.'), findsOneWidget);
    expect(find.text(en.localStandingLine), findsOneWidget);
    expect(find.byKey(const Key('card-toggle')), findsNothing, reason: 'no contact card for a local agent');
    // Back to a contact: its conversation replaces the local one.
    await _tap(t, find.byKey(Key('contact-$emilyName')));
    expect(find.byKey(const Key('local-chat-view-helper')), findsNothing);
    expect(m.selectedLocalAgent, isNull);
    // From the Agents section, Chat opens it again.
    await _agents(t);
    await _tap(t, find.byKey(const Key('local-chat-helper')));
    expect(find.byKey(const Key('local-chat-view-helper')), findsOneWidget);
  });

  testWidgets('a reply streams: loading, waiting, the words, then both messages from the history', (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    await t.enterText(find.byKey(const Key('local-composer')), 'Hi there');
    await t.tap(find.byKey(const Key('local-send')));
    await t.pump();
    final (agent, said, dialog) = d.localSays.single;
    expect((agent, said), ('helper', 'Hi there'));
    expect(_inChat('Hi there'), findsOneWidget, reason: 'the owner sees their message at once');
    expect(find.byKey(const Key('local-stop')), findsOneWidget);
    dialog.emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: '', activity: 'waiting'));
    await t.pump();
    await t.pump();
    expect(find.text(en.localActivityWaiting), findsOneWidget);
    dialog.emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: '', activity: 'loading'));
    await t.pump();
    await t.pump();
    expect(find.text(en.localActivityLoading), findsOneWidget);
    dialog
      ..emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: 'Echo:'))
      ..emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: ' Hi there'));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('local-live')), findsOneWidget);
    expect(_text('Echo: Hi there'), findsOneWidget);
    expect(find.text(en.localActivityLoading), findsNothing);

    d.localReply('helper', 'Hi there', 'Echo: Hi there');
    dialog.finish(const LocalTurnReply(agent: 'helper', turn: 2, outcome: 'done', text: 'Echo: Hi there'));
    await _pump(t);
    expect(find.byKey(const Key('local-live')), findsNothing);
    expect(_inChat('Echo: Hi there'), findsOneWidget);
    expect(_inChat('Hi there'), findsOneWidget, reason: 'the pending message is replaced by the stored one');
    expect(find.byKey(const Key('local-send')), findsOneWidget);
    expect(d.calls.where((c) => c == 'local_history').length, 2, reason: 'on opening and after the turn');
  });

  testWidgets('Stop interrupts the turn; the reply so far stays, marked interrupted', (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    await t.enterText(find.byKey(const Key('local-composer')), 'Write a long story');
    await t.tap(find.byKey(const Key('local-send')));
    await t.pump();
    final dialog = d.localSays.single.$3;
    dialog.emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: 'Once upon'));
    await t.pump();
    await t.tap(find.byKey(const Key('local-stop')));
    await t.pump();
    await t.pump();
    expect(d.sessionCalls, [('helper', LocalSessionAction.interrupt)]);
    expect(find.text(en.localStopping), findsOneWidget);
    d.localReply('helper', 'Write a long story', 'Once upon', outcome: 'interrupted');
    dialog.finish(const LocalTurnReply(agent: 'helper', turn: 2, outcome: 'interrupted', text: 'Once upon'));
    await _pump(t);
    expect(_inChat('Once upon'), findsOneWidget);
    expect(_text('${en.streamInterruptedTag} · '), findsOneWidget);
  });

  testWidgets('a failed turn says why; a refused say gives the text back', (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    await t.enterText(find.byKey(const Key('local-composer')), 'Hello');
    await t.tap(find.byKey(const Key('local-send')));
    await t.pump();
    d.localReply('helper', 'Hello', '', outcome: 'failed');
    d.localSays.single.$3.finish(
        const LocalTurnReply(agent: 'helper', turn: 2, outcome: 'failed', text: '', detail: 'the runtime did not start'));
    await _pump(t);
    expect(find.text(en.localTurnFailedDetail('the runtime did not start')), findsOneWidget);

    await t.enterText(find.byKey(const Key('local-composer')), 'Again');
    await t.tap(find.byKey(const Key('local-send')));
    await t.pump();
    d.localSays.last.$3.fail(const XControlException(XErrorCode.loginRequired, 'login required'));
    await _pump(t);
    expect(find.byKey(const Key('local-say-error')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('local-composer'))).controller!.text, 'Again');
  });

  testWidgets('after a restart a failed turn still says why, from the history; an interrupted one in its tooltip',
      (t) async {
    final (m, _) = await _model(setup: (d) {
      _helper(d, history: false);
      d.localReply('helper', 'Hello', '', outcome: 'failed', detail: 'the runtime did not start');
      d.localReply('helper', 'Tell me more', 'Well', outcome: 'interrupted', detail: 'the time limit of the turn');
      d.localReply('helper', 'Older daemon', '', outcome: 'failed');
    });
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    expect(find.text(en.localTurnFailedDetail('the runtime did not start')), findsOneWidget);
    expect(find.text(en.localTurnFailed), findsOneWidget, reason: 'no detail from an older daemon');
    final tag = find.ancestor(of: _text('${en.streamInterruptedTag} · '), matching: find.byType(Tooltip));
    expect(t.widget<Tooltip>(tag.first).message, 'the time limit of the turn');
  });

  testWidgets('New conversation asks first, then the daemon deletes the conversation', (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    await _tap(t, find.byKey(const Key('local-reset')));
    expect(find.text(en.localResetTitle), findsOneWidget);
    await _tap(t, find.text(en.commonCancel));
    expect(d.sessionCalls, isEmpty);
    await _tap(t, find.byKey(const Key('local-reset')));
    await _tap(t, find.byKey(const Key('local-reset-confirm')));
    expect(d.sessionCalls, [('helper', LocalSessionAction.reset)]);
    expect(_inChat('I can answer questions while you work.'), findsNothing);
    expect(find.byKey(const Key('local-intro')), findsOneWidget);
  });

  testWidgets('a turn that ended elsewhere: the open conversation reads its history on the local_agent event',
      (t) async {
    final (m, d) = await _model(setup: _helper);
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    d.localReply('helper', 'From the CLI', 'Echo: From the CLI');
    _event(m, LocalAgentEvent(d.localAgentList.single));
    await _pump(t);
    expect(_inChat('Echo: From the CLI'), findsOneWidget);
    // A model that is not on this computer: a banner, and the input waits.
    _event(m, LocalAgentEvent(demoLocalAgent('helper', state: LocalAgentState.noModel, turns: 2)));
    await _pump(t, 1);
    expect(find.byKey(const Key('local-no-model')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('local-composer'))).enabled, isFalse);
  });

  testWidgets('the conversation shows the model text as plain text', (t) async {
    final (m, d) = await _model(setup: (d) {
      _helper(d, history: false);
      d.localReply('helper', 'Show me', 'Visit \u202Ehttps://example.com\u202C now\x07 \x1b]52;c;ZXZpbA==\x07');
    });
    await _app(t, m);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    expect(_inChat('Visit https://example.com now ]52;c;ZXZpbA=='), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Russian: the card, the badge and the standing line', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final (m, _) = await _model(setup: _helper);
    await _app(t, m);
    expect(find.text(ru.listOnThisComputer.toUpperCase()), findsOneWidget);
    await _tap(t, find.byKey(const Key('local-tile-helper')));
    expect(find.text(ru.localStandingLine), findsOneWidget);
    expect(find.text(ru.localBadgeMac), findsWidgets);
    await _agents(t);
    expect(find.text(ru.localTitle), findsOneWidget);
    expect(find.text(ru.localThisComputer('Apple M2 Pro', '16 GB', '210 GB')), findsOneWidget);
  });
}
