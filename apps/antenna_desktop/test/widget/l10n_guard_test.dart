// SPDX-License-Identifier: AGPL-3.0-only
// Localization guard (docs/DESIGN.md, "Languages"):
// (a) app_en.arb (template) and app_ru.arb have the same keys and placeholders, nothing is untranslated, and the
//     generated AppLocalizations knows every key (the ARB was regenerated);
// (b) lib/ (outside lib/l10n/) has no string literals with Cyrillic: visible text goes only through the ARB;
// (c) Russian text lives only in the Russian localization (app_ru.arb and its generated file).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files where Cyrillic literals are temporarily allowed, each with a reason. The test asks to remove an entry that is
/// no longer needed, so the list does not collect stale entries.
const _allow = <String, String>{};

final _cyrillic = RegExp(r'[\u0400-\u04FF]');

/// The only files where Russian text belongs.
const _russianOk = {'lib/l10n/app_ru.arb', 'lib/l10n/app_localizations_ru.dart'};

Map<String, Object?> _arb(String name) =>
    (json.decode(File('lib/l10n/$name').readAsStringSync()) as Map<String, Object?>);

Set<String> _messageKeys(Map<String, Object?> arb) => {for (final k in arb.keys) if (!k.startsWith('@')) k};

/// Placeholder names in an ICU message: `{name}` and `{name, plural, …}`. The `=1{…}` / `other{…}` / `fox{Fox}`
/// variants are not names: a variant's body follows its selector without a space, an argument never does.
Set<String> _placeholders(String message) =>
    {for (final m in RegExp(r'(?<![\w=])\{([A-Za-z_]\w*)(?=[,}])').allMatches(message)) m.group(1)!};

void main() {
  test('ARB: the same keys and placeholders in en and ru, nothing untranslated, generated code is fresh', () {
    final en = _arb('app_en.arb');
    final ru = _arb('app_ru.arb');
    expect(en['@@locale'], 'en');
    expect(ru['@@locale'], 'ru');
    final keys = _messageKeys(en);
    expect(keys.length, greaterThan(500), reason: 'all window strings live in the ARB');
    expect(_messageKeys(ru).difference(keys), isEmpty, reason: 'keys only in app_ru.arb');
    expect(keys.difference(_messageKeys(ru)), isEmpty, reason: 'keys missing from app_ru.arb');
    for (final k in keys) {
      final meta = en['@$k'] as Map<String, Object?>?;
      final declared = ((meta?['placeholders'] as Map<String, Object?>?) ?? const {}).keys.toSet();
      expect(_placeholders(en[k]! as String), declared, reason: '$k: en placeholders vs @$k.placeholders');
      expect(_placeholders(ru[k]! as String), declared, reason: '$k: ru placeholders');
      expect((ru[k]! as String).trim(), isNotEmpty, reason: '$k: empty translation');
    }
    // The gen-l10n untranslated messages file (l10n.yaml → untranslated-messages-file) is empty.
    expect(json.decode(File('lib/l10n/untranslated.json').readAsStringSync()), isEmpty);
    // The generated class knows every key.
    final generated = File('lib/l10n/app_localizations.dart').readAsStringSync();
    final missing = [
      for (final k in keys)
        if (!generated.contains(RegExp('String (get )?$k\\b'))) k,
    ];
    expect(missing, isEmpty, reason: 'run `flutter gen-l10n` (or `flutter pub get`) and commit lib/l10n');
  });

  test('the literal scanner sees strings in interpolations and skips comments', () {
    // Cyrillic is written as \u escapes so that this file itself stays free of Russian text.
    const sample = '''
// comment: '\u043d\u0435'
/* block '\u0442\u043e\u0436\u0435' /* nested */ */
final a = 'one \${b ? '\u0434\u0432\u0430' : "three"} \$c';
final r = r'raw \\ \${x}';
final t = """
\u043c\u043d\u043e\u0433\u043e""";
''';
    final texts = [for (final (_, s) in dartStringLiterals(sample)) s];
    expect(texts.where((s) => _cyrillic.hasMatch(s)), ['\u0434\u0432\u0430', '\n\u043c\u043d\u043e\u0433\u043e']);
    expect(texts, contains(r'raw \ ${x}'));
  });

  test('no Cyrillic string literals in lib/ outside lib/l10n/ (visible text goes through the ARB)', () {
    final hits = <String>[];
    final allowedHit = <String>{};
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.startsWith('lib/l10n/'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, greaterThan(40));
    for (final f in files) {
      final src = f.readAsStringSync();
      for (final (at, text) in dartStringLiterals(src)) {
        if (!_cyrillic.hasMatch(text)) continue;
        if (_allow.containsKey(f.path)) {
          allowedHit.add(f.path);
          continue;
        }
        final line = '\n'.allMatches(src.substring(0, at)).length + 1;
        hits.add('${f.path}:$line  ${text.replaceAll('\n', r'\n')}');
      }
    }
    expect(hits, isEmpty, reason: 'move these strings to lib/l10n/app_en.arb + app_ru.arb:\n${hits.join('\n')}');
    expect(_allow.keys.toSet().difference(allowedHit), isEmpty,
        reason: 'these files no longer need the exception — remove them from _allow');
  });

  test('Russian text lives only in the Russian localization (lib/ and test/)', () {
    final files = [
      for (final dir in ['lib', 'test'])
        ...Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') || f.path.endsWith('.arb')),
    ];
    expect(files.length, greaterThan(80));
    final hits = [
      for (final f in files)
        if (!_russianOk.contains(f.path) && _cyrillic.hasMatch(f.readAsStringSync())) f.path,
    ]..sort();
    expect(hits, isEmpty, reason: 'translate these files to English (Russian belongs only in app_ru.arb)');
  });
}

/// String literals of a Dart source: (start offset, text without interpolations). Handles `//` and nested `/* */`,
/// single/double/triple quotes, raw strings, escapes and `${…}` with nested strings.
List<(int, String)> dartStringLiterals(String src) => (_Lexer(src)..code()).found;

final class _Lexer {
  _Lexer(this.s);
  final String s;
  int i = 0;
  final found = <(int, String)>[];

  bool _at(String p) => s.startsWith(p, i);

  bool get _identBefore => i > 0 && RegExp(r'[A-Za-z0-9_$]').hasMatch(s[i - 1]);

  /// Code up to the end of the file or (inside an interpolation) up to its closing `}`.
  void code({bool interpolation = false}) {
    var depth = 0;
    while (i < s.length) {
      final c = s[i];
      if (_at('//')) {
        final e = s.indexOf('\n', i);
        i = e < 0 ? s.length : e;
      } else if (_at('/*')) {
        _blockComment();
      } else if (c == '{') {
        depth++;
        i++;
      } else if (c == '}') {
        i++;
        if (interpolation && depth == 0) return;
        depth--;
      } else if ((c == 'r' || c == 'R') && i + 1 < s.length && (s[i + 1] == "'" || s[i + 1] == '"') && !_identBefore) {
        i++;
        _string(raw: true);
      } else if (c == "'" || c == '"') {
        _string(raw: false);
      } else {
        i++;
      }
    }
  }

  void _blockComment() {
    var depth = 0;
    while (i < s.length) {
      if (_at('/*')) {
        depth++;
        i += 2;
      } else if (_at('*/')) {
        depth--;
        i += 2;
        if (depth == 0) return;
      } else {
        i++;
      }
    }
  }

  void _string({required bool raw}) {
    final start = i;
    final q = s[i];
    final close = _at(q * 3) ? q * 3 : q;
    i += close.length;
    final buf = StringBuffer();
    while (i < s.length && !_at(close)) {
      final c = s[i];
      if (close.length == 1 && c == '\n') break;
      if (!raw && c == r'\') {
        buf.write(s.substring(i + 1, (i + 2).clamp(0, s.length)));
        i += 2;
      } else if (!raw && c == r'$' && i + 1 < s.length && s[i + 1] == '{') {
        i += 2;
        code(interpolation: true);
      } else {
        buf.write(c);
        i++;
      }
    }
    i += close.length;
    found.add((start, buf.toString()));
  }
}
