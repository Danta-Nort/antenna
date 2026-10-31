// SPDX-License-Identifier: AGPL-3.0-only
// x-control/7 (D-103, CONTROL §23 and §14) against a stand-in daemon on a real unix socket (no antennad needed): the
// requests go on the wire exactly as the contract shows them (the password only in `update_auto_set`, never in a
// request's printout); the replies and events parse (`update_auto`, `file_name`, `status.updated`, `file.duplicate`,
// the `update_auto` and `message_fact` events); `agent_watch` is a subscription dialog; a v6 daemon refuses the v7
// hello once and keeps working on v6.

// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// A daemon that speaks [versions]; [reply] answers each request with `{ok:…}`, or with a list of lines to send
/// (events, then `{ok}` or `{err}`).
class _StandIn {
  _StandIn(this.versions, this.reply);
  final Set<String> versions;
  final Object Function(Map<String, Object?> req) reply;
  final hellos = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];
  late final Directory dir;
  late final ServerSocket server;

  String get path => '${dir.path}/antennad.sock';

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('antenna-v7-');
    server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    server.listen((s) {
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final j = jsonDecode(line) as Map<String, Object?>;
        if (j['hello'] case final Map<String, Object?> h) {
          hellos.add(h);
          final proto = h['proto']! as String;
          if (!versions.contains(proto)) {
            s.write('${jsonEncode({
              'err': {'code': 'bad_request', 'message': 'unsupported control protocol $proto'},
            })}\n');
            unawaited(s.close());
            return;
          }
          s.write('${jsonEncode({
            'hello_ok': {
              'daemon': 'antennad 0.1.2 (test)',
              'protocol': 'x/1',
              'state': 'unlocked',
              'role': 'owner',
              'proto': proto,
              'session': h['session'] == null ? 'none' : 'held',
            },
          })}\n');
        } else if (j['req'] case final Map<String, Object?> r) {
          requests.add(r);
          final out = reply(r);
          for (final m in out is List ? out : [{'ok': out}]) {
            s.write('${jsonEncode(m)}\n');
          }
        }
      });
    });
  }

  Future<void> stop() async {
    await server.close();
    await dir.delete(recursive: true);
  }
}

const _auto = {
  'type': 'update_auto',
  'enabled': true,
  'supported': true,
  'keys_kept': true,
  'staged': {
    'version': '0.1.3',
    'source': 'link',
    'contact': 'Mac',
    'staged_ms': 1791000000000,
    'state': 'soon',
    'at_ms': 1791000300000,
  },
  'last': {
    'version': '0.1.2',
    'result': 'installed',
    'source': 'link',
    'contact': 'Mac',
    'from': '0.1.0-preview.7',
    'unlocked': true,
    'at_ms': 1790000000000,
  },
  'failed': ['0.1.0-preview.6'],
  'history': [
    {'version': '0.1.2', 'result': 'installed', 'source': 'link', 'at_ms': 1790000000000},
    {'version': '0.1.0-preview.6', 'result': 'failed', 'reason': 'install_failed: no answer in 30 s', 'source': 'url', 'at_ms': 1},
  ],
  'url': 'https://example.com/releases/latest.json',
  'last_check_ms': 1791000000000,
};

Object _reply(Map<String, Object?> r) => switch (r['cmd']) {
      'status' => {
          'type': 'status',
          'state': 'unlocked',
          'daemon': 'antennad 0.1.3 (test)',
          'protocol': 'x/0',
          'relay': 'n0',
          'links': 2,
          'updated': {'from': '0.1.2', 'to': '0.1.3', 'at_ms': 1791000400000, 'unlocked': true},
        },
      'update_auto_status' || 'update_auto_set' || 'update_auto_now' || 'update_auto_later' => _auto,
      'file_name_check' => {
          'type': 'file_name',
          'name': r['name'] ?? 'report.pdf',
          'state': 'taken',
          'suggestion': 'report (2).pdf',
          'message': 'a file with this name (ignoring case) already exists',
        },
      'file_save_dir' => {
          'type': 'file_save_dirs',
          'contact': 'Mac',
          'link_id': 'cd' * 32,
          'dirs': [
            {'path': '/Users/owner/Desktop/Volna'},
            {'agent': 'volna', 'path': '/Users/owner/Desktop/Volna/agent'},
          ],
        },
      'file_allow' || 'file_disallow' => {
          'type': 'file_allow',
          'contact': 'Mac',
          'link_id': 'cd' * 32,
          'entries': r['cmd'] == 'file_allow' ? ['executables', '.dmg'] : <String>[],
        },
      'file_accept' => {
          'type': 'file',
          'id': 'ab' * 16,
          'contact': 'Mac',
          'link_id': 'cd' * 32,
          'direction': 'in',
          'name': 'antenna-0.1.3-macos-arm64.dmg',
          'size': 1,
          'blake3': 'ef' * 32,
          'state': 'accepted',
          'dest': 'shared',
          'saved_as': 'antenna-0.1.3-macos-arm64.dmg',
          'saved_path': '/Users/owner/Antenna/links/Mac/shared/antenna-0.1.3-macos-arm64.dmg',
          'duplicate': true,
          'created_ms': 1,
        },
      'agent_watch' => [
          {
            'event': {'kind': 'subscribed', 'proto': 'x-control/7', 'role': 'agent'},
          },
          {
            'event': {'kind': 'message_fact', 'contact': 'Jordan Lee', 'id': '9a' * 16, 'trust': 5, 'chars': 42, 'received_ms': 7},
          },
          {
            'event': {
              'kind': 'update_auto',
              'state': 'soon',
              'version': '0.1.3',
              'source': 'url',
              'at_ms': 5,
            },
          },
          {
            'err': {'code': 'forbidden', 'message': 'the agent\'s binding ended'},
          },
        ],
      final c => throw StateError('unexpected $c'),
    };

void main() {
  test('v7 on the wire: update_auto_*, file_name_check, status.updated, file.duplicate', () async {
    final d = _StandIn({'x-control/6', 'x-control/7'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      expect((await c.hello()).proto, 'x-control/7');

      final st = await c.status();
      expect((st.updated?.from, st.updated?.to, st.updated?.atMs, st.updated?.unlocked),
          ('0.1.2', '0.1.3', 1791000400000, true));

      final a = await c.updateAutoStatus();
      expect(d.requests.last, {'cmd': 'update_auto_status'});
      expect((a.enabled, a.supported, a.keysKept, a.url, a.lastCheckMs), (true, true, true, _auto['url'], 1791000000000));
      expect((a.staged?.version, a.staged?.source, a.staged?.contact, a.staged?.state, a.staged?.atMs),
          ('0.1.3', 'link', 'Mac', 'soon', 1791000300000));
      expect((a.last?.result, a.last?.from, a.last?.unlocked), ('installed', '0.1.0-preview.7', true));
      expect(a.failed, ['0.1.0-preview.6']);
      expect(a.history.map((r) => r.result), ['installed', 'failed']);
      expect(a.history.last.reason, 'install_failed: no answer in 30 s');

      await c.updateAutoSet(enabled: true, password: 'hunter2');
      expect(d.requests.last, {'cmd': 'update_auto_set', 'enabled': true, 'password': 'hunter2'});
      await c.updateAutoSet(enabled: false, password: 'hunter2');
      expect(d.requests.last, {'cmd': 'update_auto_set', 'enabled': false, 'password': 'hunter2'},
          reason: 'the password both ways');
      expect('${const UpdateAutoSetRequest(enabled: true, password: 'hunter2')}', isNot(contains('hunter2')));
      await c.updateAutoNow();
      expect(d.requests.last, {'cmd': 'update_auto_now'});
      await c.updateAutoLater();
      expect(d.requests.last, {'cmd': 'update_auto_later'});

      final n = await c.fileNameCheck('7cdaead1', name: 'report.pdf');
      expect(d.requests.last, {'cmd': 'file_name_check', 'id': '7cdaead1', 'name': 'report.pdf'});
      expect((n.state, n.taken, n.suggestion, n.message),
          ('taken', true, 'report (2).pdf', 'a file with this name (ignoring case) already exists'));
      await c.fileNameCheck('7cdaead1');
      expect(d.requests.last, {'cmd': 'file_name_check', 'id': '7cdaead1'}, reason: 'no name: the contact\'s name');

      // Save folders and the allowlist (D-130): the requests as CONTROL §14 shows them, the password never printed.
      final dirs = await c.fileSaveDir('Mac', agent: 'volna', path: '/Users/owner/Desktop/Volna/agent', password: 'pw');
      expect(d.requests.last, {
        'cmd': 'file_save_dir',
        'contact': 'Mac',
        'agent': 'volna',
        'path': '/Users/owner/Desktop/Volna/agent',
        'password': 'pw',
      });
      expect([for (final x in dirs.dirs) (x.agent, x.path)],
          [(null, '/Users/owner/Desktop/Volna'), ('volna', '/Users/owner/Desktop/Volna/agent')]);
      await c.fileSaveDir('Mac');
      expect(d.requests.last, {'cmd': 'file_save_dir', 'contact': 'Mac'}, reason: 'clearing: no path, no password');
      expect((await c.fileAllow('Mac', ['executables', '.dmg'], password: 'pw')).entries, ['executables', '.dmg']);
      expect(d.requests.last, {
        'cmd': 'file_allow',
        'contact': 'Mac',
        'entries': ['executables', '.dmg'],
        'password': 'pw',
      });
      expect((await c.fileDisallow('Mac')).entries, isEmpty);
      expect(d.requests.last, {'cmd': 'file_disallow', 'contact': 'Mac'}, reason: 'no entries: all of them');
      expect('${const FileAllowRequest('Mac', ['x'], password: 'pw')}', isNot(contains('pw')));
      expect('${const FileSaveDirRequest('Mac', path: '/p', password: 'pw')}', isNot(contains('pw')));
      final contact = ContactInfo.fromJson({
        'label': 'Mac',
        'link_id': 'cd' * 32,
        'trust': 5,
        'net_mode': 'direct',
        'role': 'joiner',
        'created_ms': 1,
        'peer_endpoint': 'ab' * 32,
        'local_endpoint': 'ef' * 32,
        'e2e': <String, Object?>{},
        'transport': <String, Object?>{},
        'file_allow': ['installers'],
        'save_dirs': [
          {'agent': 'volna', 'path': '/Users/owner/Desktop/Volna'},
        ],
      });
      expect(contact.fileAllow, ['installers']);
      expect((contact.saveDirs.single.agent, contact.saveDirs.single.path), ('volna', '/Users/owner/Desktop/Volna'));

      final f = await c.fileAccept('abababab');
      expect((f.state, f.duplicate, f.savedAs), ('accepted', true, 'antenna-0.1.3-macos-arm64.dmg'));
    } finally {
      await d.stop();
    }
  });

  // A picture's safe preview comes inline as base64 in one reply line, and the PNG of one screenshot or a 1024-pixel
  // logo is more than 256 KiB. Up to preview.8 the window refused any line over 256 KiB ("line too long"), so every
  // such picture showed "Couldn't show the preview image" while the CLI, which reads any line, showed it.
  test('a file_preview reply longer than 256 KiB: the picture arrives whole', () async {
    final png = Uint8List.fromList(List.generate(900 * 1024, (i) => (i * 7919) & 0xff));
    final d = _StandIn({'x-control/7'}, (r) {
      expect(r, {'cmd': 'file_preview', 'id': 'ab' * 16});
      return {
        'type': 'file_preview',
        'file': {
          'id': 'ab' * 16,
          'contact': 'Mac',
          'link_id': 'cd' * 32,
          'direction': 'in',
          'name': 'volna-logo-1024.png',
          'size': png.length,
          'blake3': 'ef' * 32,
          'state': 'accepted',
          'verdict': 'clean',
          'mime': 'image/png',
          'dest': 'shared',
          'created_ms': 1,
        },
        'preview': {
          'kind': 'image',
          'images_png_base64': [base64.encode(png)],
          'truncated': false,
        },
      };
    });
    await d.start();
    try {
      final c = XControlClient(d.path);
      final r = await c.filePreview('ab' * 16);
      expect(base64.encode(png).length, greaterThan(maxLine), reason: 'the reply line is longer than a request may be');
      expect(r.file.state, 'accepted');
      expect(r.preview?.imagesPng.single, png);
      // The connection is still usable after the long line.
      expect((await c.filePreview('ab' * 16)).preview?.imagesPng.single.length, png.length);
    } finally {
      await d.stop();
    }
  });

  test('agent_watch is a subscription without a session: subscribed as the agent, facts, then the end', () async {
    final d = _StandIn({'x-control/7'}, _reply);
    await d.start();
    try {
      final c = XControlClient(d.path);
      final w = c.agentWatch('claude-backend');
      final events = <XEvent>[];
      w.events.listen(events.add);
      await expectLater(w.result, throwsA(isA<XControlException>().having((e) => e.code, 'code', 'forbidden')));
      expect(d.requests.single, {'cmd': 'agent_watch', 'agent': 'claude-backend'});
      expect(d.hellos.last.containsKey('session'), isFalse, reason: 'no owner session in the hello');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events[0], isA<Subscribed>().having((e) => e.role, 'role', 'agent'));
      final fact = events[1] as MessageFactEvent;
      expect((fact.contact, fact.trust, fact.chars, fact.receivedMs), ('Jordan Lee', 5, 42, 7));
      final u = events[2] as UpdateAutoEvent;
      expect((u.state, u.version, u.source, u.atMs), ('soon', '0.1.3', 'url', 5));
    } finally {
      await d.stop();
    }
  });

  test('a v6 daemon: one refused v7 hello, then everything on v6; a v7 command answers unknown_command', () async {
    final d = _StandIn({'x-control/5', 'x-control/6'}, (r) {
      if ((r['cmd']! as String).startsWith('update_auto') || r['cmd'] == 'file_name_check') {
        return [
          {
            'err': {'code': 'unknown_command', 'message': 'unknown command "${r['cmd']}"'},
          },
        ];
      }
      return {'type': 'status', 'state': 'locked', 'daemon': 'antennad 0.1.0-preview.7', 'protocol': 'x/0', 'relay': 'n0'};
    });
    await d.start();
    try {
      final c = XControlClient(d.path);
      expect((await c.hello()).proto, 'x-control/6');
      final st = await c.status();
      expect(st.updated, isNull, reason: 'a preview.7 status has no `updated`');
      await expectLater(
          c.updateAutoStatus(), throwsA(isA<XControlException>().having((e) => e.code, 'code', 'unknown_command')));
      expect(d.hellos.map((h) => h['proto']), ['x-control/7', 'x-control/6', 'x-control/6', 'x-control/6']);
    } finally {
      await d.stop();
    }
  });
}
