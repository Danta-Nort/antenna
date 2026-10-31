// SPDX-License-Identifier: AGPL-3.0-only
// The agent terminal's SGR filter (lib/state/terminal_sgr.dart): what the pinned xterm 4.0.0 misreads, how each such
// sequence comes out (checked on the terminal's cells), that everything else passes byte for byte and that a sequence
// split between two reads gives the same result; then the same through Code mode's real output path.

import 'dart:math';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/state/terminal_sgr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

/// Row [y] as runs of text with one look each: `text<flags>`, flags b bold, d dim, i italic, u underline, k blink,
/// r inverse, s strikethrough, then the colors (`fg:n1` named, `fg:p196` palette, `fg:#0a141e` RGB).
String look(Terminal t, int y) {
  final l = t.buffer.lines[y];
  final out = StringBuffer();
  String? current;
  for (var x = 0; x < l.length; x++) {
    final cp = l.getCodePoint(x);
    if (cp == 0) break;
    final key = _style(l.getAttributes(x), l.getForeground(x), l.getBackground(x));
    if (current != null && key != current) out.write('<$current>');
    current = key;
    out.writeCharCode(cp);
  }
  if (current != null) out.write('<$current>');
  return out.toString();
}

String _style(int attrs, int fg, int bg) {
  const flags = {
    CellAttr.bold: 'b',
    CellAttr.faint: 'd',
    CellAttr.italic: 'i',
    CellAttr.underline: 'u',
    CellAttr.blink: 'k',
    CellAttr.inverse: 'r',
    CellAttr.strikethrough: 's',
  };
  final s = StringBuffer();
  for (final f in flags.entries) {
    if (attrs & f.key != 0) s.write(f.value);
  }
  for (final (name, c) in [('fg', fg), ('bg', bg)]) {
    final v = c & CellColor.valueMask;
    switch (c & CellColor.typeMask) {
      case CellColor.named:
        s.write(' $name:n$v');
      case CellColor.palette:
        s.write(' $name:p$v');
      case CellColor.rgb:
        s.write(' $name:#${v.toRadixString(16).padLeft(6, '0')}');
    }
  }
  return s.toString().trim();
}

/// A terminal fed [text] through a fresh filter (or directly with `filter: false`).
Terminal term(String text, {bool filter = true}) {
  final t = Terminal();
  t.write(filter ? SgrFilter().add(text) : text);
  return t;
}

String filtered(String text) => SgrFilter().add(text);

void main() {
  test('the pinned xterm misreads these sequences (why the filter exists; revisit it if this test fails)', () {
    // modifyOtherKeys (XTMODKEYS) as Claude Code writes it: read as SGR 4 (underline) and 2 (dim).
    expect(look(term('\x1b[>4mA', filter: false), 0), 'A<u>');
    expect(look(term('\x1b[>4;2mA', filter: false), 0), 'A<du>');
    expect(look(term('\x1b[?4mA', filter: false), 0), 'A<u>');
    // `22` (normal intensity) does not end bold.
    expect(look(term('\x1b[1mA\x1b[22mB', filter: false), 0), 'AB<b>');
    // Colon sub-parameters: `4:3` becomes 43 (yellow background), `4:0` becomes 40.
    expect(look(term('\x1b[4:3mA\x1b[4:0mB', filter: false), 0), 'A<bg:n3>B<bg:n0>');
    // The underline color's arguments run as codes of their own (5 blink, 1 bold), and 59 does not undo them.
    expect(look(term('\x1b[58;5;1mA\x1b[59mB', filter: false), 0), 'AB<bk>');
    // A color without its index throws inside the parser.
    expect(() => term('\x1b[38;5mA', filter: false), throwsRangeError);
  });

  test('underline: on and off, plain and with a style', () {
    expect(look(term('\x1b[4:3mcurly\x1b[4:0m plain\r\n'), 0), 'curly<u> plain<>');
    expect(look(term('\x1b[4mu\x1b[24m plain'), 0), 'u<u> plain<>');
    for (final style in [1, 2, 3, 4, 5]) {
      expect(look(term('\x1b[4:${style}mon\x1b[24m off'), 0), 'on<u> off<>', reason: '4:$style');
    }
    expect(look(term('\x1b[4mon\x1b[4:0m off'), 0), 'on<u> off<>');
    expect(look(term('\x1b[4:mA'), 0), 'A<>', reason: 'an empty style is the default 0, no underline');
    expect(filtered('\x1b[4:3m'), '\x1b[4m');
    expect(filtered('\x1b[4:0m'), '\x1b[24m');
    expect(filtered('\x1b[1;4:3;31m'), '\x1b[1;4;31m');
  });

  test('the underline color is dropped and takes nothing else with it', () {
    expect(look(term('\x1b[58;5;1mA\x1b[59mB'), 0), 'AB<>');
    expect(look(term('\x1b[58;2;4;5;6mA\x1b[59mB'), 0), 'AB<>');
    expect(look(term('\x1b[58:5:1mA\x1b[58:2::1:2:3mB\x1b[58:2:1:2:3mC\x1b[59mD'), 0), 'ABCD<>');
    expect(look(term('\x1b[4;58;5;196;1mU\x1b[59;24;22mV'), 0), 'U<bu>V<>');
    expect(filtered('\x1b[58;5;1m'), '');
    expect(filtered('\x1b[59m'), '');
    expect(filtered('\x1b[4;58;2;1;2;3m'), '\x1b[4m');
  });

  test('modifyOtherKeys and other private sequences ending in m are dropped', () {
    for (final seq in ['\x1b[>4m', '\x1b[>4;2m', '\x1b[>4;1m', '\x1b[>4;0m', '\x1b[?4m', '\x1b[<1m', '\x1b[=1m']) {
      expect(filtered('${seq}A'), 'A', reason: seq.substring(1));
      expect(look(term('${seq}A'), 0), 'A<>', reason: seq.substring(1));
    }
    // What Claude Code writes at start in iTerm2 (kitty keyboard, modifyOtherKeys): only the `m` one was misread.
    expect(filtered('\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?2026h'), '\x1b[<u\x1b[>1u\x1b[?2026h');
  });

  test('bold, dim, italic, inverse: on and off', () {
    expect(look(term('\x1b[1mbold\x1b[22m normal'), 0), 'bold<b> normal<>');
    expect(look(term('\x1b[2mdim\x1b[22m normal'), 0), 'dim<d> normal<>');
    expect(look(term('\x1b[1;2mboth\x1b[22m normal'), 0), 'both<bd> normal<>');
    expect(look(term('\x1b[3mitalic\x1b[23m normal'), 0), 'italic<i> normal<>');
    expect(look(term('\x1b[7minverse\x1b[27m normal'), 0), 'inverse<r> normal<>');
    expect(look(term('\x1b[9mstruck\x1b[29m normal'), 0), 'struck<s> normal<>');
    expect(look(term('\x1b[1;3;4;7mall\x1b[0m none'), 0), 'all<biur> none<>');
    expect(filtered('\x1b[22m'), '\x1b[21;22m');
    expect(filtered('\x1b[22;39m'), '\x1b[21;22;39m');
  });

  test('colors: 16, 256 and truecolor, with semicolons or colons', () {
    expect(look(term('\x1b[31mr\x1b[92mg\x1b[44mb\x1b[39;49m.'), 0), 'r<fg:n1>g<fg:n10>b<fg:n10 bg:n4>.<>');
    expect(look(term('\x1b[38;5;196ma\x1b[48;5;21mb\x1b[39;49m.'), 0), 'a<fg:p196>b<fg:p196 bg:p21>.<>');
    expect(look(term('\x1b[38:5:196ma\x1b[48:5:21mb\x1b[0m.'), 0), 'a<fg:p196>b<fg:p196 bg:p21>.<>');
    expect(look(term('\x1b[38;2;10;20;30mt\x1b[0m.'), 0), 't<fg:#0a141e>.<>');
    expect(look(term('\x1b[38:2::10:20:30mt\x1b[0m.'), 0), 't<fg:#0a141e>.<>');
    expect(look(term('\x1b[38:2:10:20:30mt\x1b[48:2::1:2:3mu\x1b[0m.'), 0), 't<fg:#0a141e>u<fg:#0a141e bg:#010203>.<>');
    expect(filtered('\x1b[38:2::10:20:30m'), '\x1b[38;2;10;20;30m');
    expect(filtered('\x1b[38:5:196;1m'), '\x1b[38;5;196;1m');
  });

  test('a color with missing or impossible values is dropped instead of breaking the terminal', () {
    for (final seq in ['38;5', '38', '38;2;1;2', '48;5', '38;5;256', '38;2;1;2;300', '38:2:1:2', '38:5']) {
      expect(look(term('\x1b[${seq}mA'), 0), 'A<>', reason: seq);
    }
    expect(look(term('\x1b[38;5;1mA'), 0), 'A<fg:p1>');
    expect(look(term('\x1b[1;38;5mA'), 0), 'A<b>');
  });

  test('a leading empty parameter is the default 0', () {
    expect(look(term('\x1b[1m\x1b[;4mA'), 0), 'A<u>');
    expect(filtered('\x1b[;4m'), '\x1b[0;4m');
  });

  test('everything else passes byte for byte', () {
    const sample = 'plain text, ünïcödé, 中文, emoji 🙂\r\n'
        '\x1b[0m\x1b[m\x1b[1m\x1b[2m\x1b[3m\x1b[4m\x1b[5m\x1b[7m\x1b[8m\x1b[9m'
        '\x1b[21m\x1b[23m\x1b[24m\x1b[25m\x1b[27m\x1b[28m\x1b[29m'
        '\x1b[30m\x1b[37m\x1b[39m\x1b[40m\x1b[47m\x1b[49m\x1b[90m\x1b[97m\x1b[100m\x1b[107m'
        '\x1b[38;5;196m\x1b[48;5;21m\x1b[38;2;215;119;87m\x1b[48;2;0;0;0m\x1b[1;4;31;48;5;236m\x1b[4;m'
        '\x1b[2K\x1b[1A\x1b[12G\x1b[3;7H\x1b[H\x1b[J\x1b[r\x1b[2 q\x1b[?25l\x1b[?25h\x1b[?2004h\x1b[?1004h'
        '\x1b[?2026h\x1b[?2031h\x1b[?1049h\x1b[?1000l\x1b[>0q\x1b[c\x1b[>c\x1b[<u\x1b[>1u\x1b[?u\x1b[6n'
        '\x1b7\x1b8\x1b(B\x0f\x1bM\x1b]0;✳ Claude Code\x07\x1b]8;id=1;https://example.com\x07link\x1b]8;;\x07'
        '\x1b]6973;0\x07\x1b]2;title\x1b\\\x07\t\b\r\n';
    expect(filtered(sample), sample);
    // Also in pieces of every size.
    for (final size in [1, 2, 3, 7, 64]) {
      final f = SgrFilter();
      final out = StringBuffer();
      for (var i = 0; i < sample.length; i += size) {
        out.write(f.add(sample.substring(i, min(i + size, sample.length))));
      }
      expect(out.toString(), sample, reason: 'pieces of $size');
    }
  });

  test('a sequence split between two reads waits for its end', () {
    final f = SgrFilter();
    expect(f.add('A\x1b'), 'A');
    expect(f.add('['), '');
    expect(f.add('>4'), '');
    expect(f.add(';2mB\x1b[4'), 'B');
    expect(f.add(':3mC'), '\x1b[4mC');
    expect(f.add('\x1b[1'), '');
    expect(f.add('mD'), '\x1b[1mD');

    // Every split point of a sample with every kind of rewrite gives what the whole sample gives.
    const sample = '\x1b[>4;2m\x1b[1mbold\x1b[22m \x1b[4:3mcurly\x1b[4:0m \x1b[58;5;1mx\x1b[59m '
        '\x1b[38:2::1:2:3mrgb\x1b[39m \x1b[>4mend\x1b[0m';
    final whole = filtered(sample);
    for (var i = 0; i <= sample.length; i++) {
      final f = SgrFilter();
      expect(f.add(sample.substring(0, i)) + f.add(sample.substring(i)), whole, reason: 'split at $i');
    }
  });

  test('a sequence that never ends is passed on, not held forever', () {
    final f = SgrFilter();
    final long = '\x1b[${'1;' * SgrFilter.maxSequence}';
    expect(f.add(long), long);
    expect(f.add('mA'), 'mA');
  });

  testWidgets('Code mode: Claude Code-like output is drawn with the attributes it asked for', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..agentList = [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)];
    final pc = FakeAgentComputer();
    final m = AppModel(
      connector: (_) => d,
      socketPath: d.socketPath,
      live: false,
      clock: () => fixedNow,
      binaries: const CoreBinaries(daemon: '/opt/antenna/antennad', cli: '/opt/antenna/antenna', bundled: true),
      agentHost: pc.host,
      defaultSocket: d.socketPath,
    );
    await m.connect();
    expect(await m.startAgent(const AgentRunSpec(agent: 'jarvis', cli: AgentCli.claude, workDir: '/home/owner/app'),
        auth: PasswordAuth(d.password)), isNull);
    final run = m.runOf('jarvis')!;
    addTearDown(run.kill);
    // As Claude Code 2.1.233 writes it in iTerm2: modifyOtherKeys on at start, bold ended with 22, and modifyOtherKeys
    // reset when it leaves the alternate screen. Split mid-sequence, as reads from a pseudo-terminal are.
    for (final piece in [
      '\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?2026h\x1b[38;2;215;119;87m╭─ \x1b[1mClaude Code\x1b[22m ─╮\x1b[39m\r\n',
      'Welcome \x1b[4mback\x1b[24m!\r\n\x1b[',
      '>4m\x1b[?1004h> \x1b[7m \x1b[27m\r\n',
    ]) {
      pc.last.emit(piece);
      await t.pump();
    }
    expect(look(run.terminal, 0), '╭─ <fg:#d77757>Claude Code<b fg:#d77757> ─╮<fg:#d77757>');
    expect(look(run.terminal, 1), 'Welcome <>back<u>!<>');
    expect(look(run.terminal, 2), '> <> <r>');
  });
}
