// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for local models (x-control/7, CONTROL §24): Agents → Local models on a Mac (one model ready with two
// agents on it, another downloading, the rest behind the disclosure with their fit), and a local agent's conversation
// in Chats, under "On this computer" above the contacts, with a reply streaming in.

part of 'scenarios.dart';

const _mb = 1024 * 1024;

/// A Mac with Qwen3.5 2B ready (helper and summarizer run on it) and Qwen3.5 4B downloading.
FakeDaemon _localDemo() {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..protoVersion = 7
    ..localModelsEnabled = true;
  final catalog = demoCatalog(smallState: LocalModelState.ready, smallAgents: const ['helper', 'summarizer']);
  d.localModelList = [
    catalog[0],
    modelInState(catalog[1], LocalModelState.downloading, doneBytes: 1130 * _mb, speed: 18 * _mb),
    ...catalog.skip(2),
  ];
  // The conversations first: storing a turn marks its agent ready, and summarizer is asleep by now.
  d.localReply('helper', 'Rewrite this more politely: "Send me the report today."',
      'Could you please send me the report by the end of today? Thank you!',
      at: ago(minutes: 4));
  d.localReply('summarizer', 'Summarize these meeting notes in three bullets.',
      '- The launch moves to Thursday.\n- Emily owns the release notes.\n- Jordan checks the build on Wednesday.',
      at: ago(hours: 5));
  d.localAgentList = [
    LocalAgentInfo(
      name: 'helper',
      model: 'qwen3.5-2b',
      runtime: 'local',
      state: LocalAgentState.idle,
      turns: 1,
      lastTurnMs: ms(ago(minutes: 3)),
      createdMs: ms(ago(days: 1)),
    ),
    LocalAgentInfo(
      name: 'summarizer',
      model: 'qwen3.5-2b',
      runtime: 'local',
      state: LocalAgentState.sleeping,
      turns: 4,
      lastTurnMs: ms(ago(hours: 5)),
      createdMs: ms(ago(days: 1)),
    ),
  ];
  d.agentList = [
    AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 4, links: [jordanName, buildBotName], everyone: true),
    const AgentInfo(name: 'helper', createdMs: 0, links: [], localModel: 'qwen3.5-2b'),
    const AgentInfo(name: 'summarizer', createdMs: 0, links: [], localModel: 'qwen3.5-2b'),
  ];
  return d;
}

Future<void> _localModelsFrame(WidgetTester t, Widget app) async {
  await _frame(t, app);
  await t.tap(find.byKey(const Key('agents-button')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('local-other-models')));
  await t.pump(const Duration(milliseconds: 400));
}

/// The helper's conversation open, the next reply streaming in.
Future<AppModel> _localChatModel() async {
  final d = _localDemo();
  final m = await _model(d);
  await m.selectLocalAgent('helper');
  await m.loadLocalHistory('summarizer');
  unawaited(m.sayLocal('helper', 'Now a short version for a chat message.'));
  final say = d.localSays.last.$3;
  say
    ..emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: 'Hi! Could you send'))
    ..emit(const LocalDeltaEvent(agent: 'helper', turn: 2, delta: ' the report today, please?'));
  // The daemon's word that a turn is running.
  m.handleEvent(LocalAgentEvent(LocalAgentInfo(
    name: 'helper',
    model: 'qwen3.5-2b',
    runtime: 'local',
    state: LocalAgentState.busy,
    turns: 1,
    createdMs: ms(ago(days: 1)),
  )));
  return m;
}

Future<void> _localChatFrame(WidgetTester t, Widget app) async {
  await _frame(t, app);
  await t.pump(const Duration(milliseconds: 400));
}

void _defineLocalScenarios() {
  _s('65_local_models', (t) async {
    const name = '65_local_models';
    final m = await _model(_localDemo());
    await _localModelsFrame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('65_local_models_dark', (t) async {
    const name = '65_local_models_dark';
    final m = await _model(_localDemo());
    await _localModelsFrame(t, _dark(m));
    await _snap(t, name);
  });

  _s('66_local_chat', (t) async {
    const name = '66_local_chat';
    final m = await _localChatModel();
    await _localChatFrame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('66_local_chat_dark', (t) async {
    const name = '66_local_chat_dark';
    final m = await _localChatModel();
    await _localChatFrame(t, _dark(m));
    await _snap(t, name);
  });
}
