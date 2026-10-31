// SPDX-License-Identifier: AGPL-3.0-only
// How the owner arranged the agent map, in the window's settings file (state/agent_map_prefs.dart, D-UI-47): it
// round-trips through window.json with the other settings, a malformed entry is dropped rather than refusing the file,
// the zoom stays within 0.4–2.0, and an untouched map writes nothing.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/state/agent_map_prefs.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the arrangement round-trips through the settings file, next to the other settings', () {
    final dir = Directory.systemTemp.createTempSync('agent-map-prefs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    final look = Appearance.load(store)..choice = ThemeChoice.dark;
    expect(look.agentMap.isEmpty, isTrue);
    expect((json.decode(File(store.path).readAsStringSync()) as Map).containsKey('agent_map'), isFalse,
        reason: 'an untouched map writes nothing');
    look.agentMap = AgentMapPrefs(
      clusters: const {'here': Offset(400, 0), 'c/Mac mini': Offset(-120.04, 360.5)},
      order: const {
        'here': ['here/docs-bot', 'here/volna'],
      },
      view: (scale: 0.8125, pan: const Offset(12.5, -30)),
      recent: true,
    );
    final file = json.decode(File(store.path).readAsStringSync()) as Map;
    expect(file['theme'], 'dark', reason: 'the other settings stay');
    expect(file['agent_map'], {
      'clusters': {
        'here': [400.0, 0.0],
        'c/Mac mini': [-120.0, 360.5],
      },
      'order': {
        'here': ['here/docs-bot', 'here/volna'],
      },
      'view': [0.813, 12.5, -30.0],
      'recent': true,
    });
    final again = Appearance.load(store).agentMap;
    expect(again.clusters, {'here': const Offset(400, 0), 'c/Mac mini': const Offset(-120, 360.5)});
    expect(again.order, {
      'here': ['here/docs-bot', 'here/volna'],
    });
    expect((again.view?.scale, again.view?.pan), (0.813, const Offset(12.5, -30)));
    expect(again.recent, isTrue);
  });

  test('read leniently: malformed entries are dropped, the zoom is clamped, anything else gives the defaults', () {
    final p = AgentMapPrefs.fromJson({
      'clusters': {
        'here': [1, 2],
        'bad': [1],
        'nan': ['x', 2],
        'huge': [1e9, 0],
        'c/Bob': [3.5, -4],
      },
      'order': {
        'here': ['a', 3, null, 'b'],
        'x': 'not a list',
      },
      'view': [9, 1, 2],
      'recent': 'yes',
    });
    expect(p.clusters, {'here': const Offset(1, 2), 'c/Bob': const Offset(3.5, -4)});
    expect(p.order, {
      'here': ['a', 'b'],
    });
    expect(p.view?.scale, mapMaxScale);
    expect(p.recent, isFalse, reason: 'only true is true');
    expect(AgentMapPrefs.fromJson({'view': [0.01, 0, 0]}).view?.scale, mapMinScale);
    expect(AgentMapPrefs.fromJson({'view': [0, 0, 0]}).view, isNull);
    expect(AgentMapPrefs.fromJson({'view': 'x'}).view, isNull);
    for (final junk in [null, 3, 'x', <Object?>[]]) {
      expect(AgentMapPrefs.fromJson(junk).isEmpty, isTrue, reason: '$junk');
    }
    final dir = Directory.systemTemp.createTempSync('agent-map-prefs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    File(store.path).writeAsStringSync('{"theme": "light", "agent_map": {"clusters": "nope", "recent": true}}');
    final look = Appearance.load(store);
    expect((look.choice, look.agentMap.clusters.isEmpty, look.agentMap.recent), (ThemeChoice.light, true, true));
  });
}
