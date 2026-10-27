// The Logs tab's fold runs, run in node: functions are cut out of web/app.js by name.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// `function <name>(…) {…}` at the top level of [src]: up to the first `}`
/// alone on a line.
String _fn(String src, String name) {
  final start = src.indexOf('\nfunction $name(');
  if (start < 0) throw StateError('no function $name in web/app.js');
  final end = src.indexOf('\n}\n', start);
  return src.substring(start + 1, end + 2);
}

final _node = () {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Runs [body] (a JS function body) after [prelude]; returns what it returns, as JSON.
Future<Object?> _js(String prelude, String body) async {
  final dir = Directory.systemTemp.createTempSync('emu_web_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/t.js')
    ..writeAsStringSync('$prelude\nprocess.stdout.write(JSON.stringify((() => { $body })() ?? null));');
  final r = await Process.run('node', [file.path], environment: {'TZ': 'UTC'});
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return jsonDecode(r.stdout as String);
}

void main() {
  final src = File('web/app.js').readAsStringSync();

  group('Logs fold', skip: _node ? false : 'node is not installed', () {
    final prelude = '''
const state = { search: '', regex: false, fold: true, foldOpenAll: false };
const TAG = { error: 'E', warn: 'W', debug: 'D', system: '•', info: 'I' };
const URL_RE = /https?:\\/\\/[^\\s<>"'`]+/g;
const folds = new Map();
const foldState = new Map();
let tail = null;
${['escapeHtml', 'highlight', 'linkify', 'clock', 'foldKey', 'foldLabel', 'rowHtml', 'rowsHtml'].map((n) => _fn(src, n)).join('\n')}
let seq = 0;
const line = (text, o = {}) => ({ seq: ++seq, ts: '2026-10-27T10:00:00.100Z', level: 'info', source: 'app', text, ...o });
// Each row as "<head|cont|shut|plain> <text> [badge]".
const rows = (html) => [...html.matchAll(/<div class="row (\\w+)([^"]*)"[^>]*>.*?<span class="txt">(.*?)<\\/span>(?:<span class="fold"[^>]*?( hidden)?>(.*?)<\\/span>)?<\\/div>/g)]
  .map((m) => [m[2].includes('shut') ? 'shut' : m[2].includes('cont') ? 'cont' : m[2].includes('head') ? 'head' : 'plain', m[3], m[4] ? '' : (m[5] || '')].join(' ').trim());
''';

    test('folds consecutive lines of the same second, level and source', () async {
      final r = await _js(prelude, '''
        return rows(rowsHtml([
          line('a1'), line('a2'), line('a3'),
          line('b1', { source: 'ext' }),
          line('c1', { level: 'warn' }), line('c2', { level: 'warn' }),
          line('d1', { level: 'warn', ts: '2026-10-27T10:00:01.000Z' }),
        ]));
      ''');
      expect(r, [
        'head a1 ▸ 3 lines', 'shut a2', 'shut a3',
        'head b1',
        'head c1 ▸ 2 lines', 'shut c2',
        'head d1',
      ]);
    });

    test('the next batch goes on with the last run', () async {
      final r = await _js(prelude, '''
        rowsHtml([line('a1'), line('a2')]);
        const first = tail;
        const next = rows(rowsHtml([line('a3'), line('b1', { level: 'error' })]));
        return { next, n: first.n, runs: folds.size };
      ''');
      expect(r, {
        'next': ['shut a3', 'head b1'],
        'n': 3,
        'runs': 2,
      });
    });

    test('runs open as foldOpenAll says, unless flipped one by one', () async {
      final r = await _js(prelude, '''
        state.foldOpenAll = true;
        foldState.set(3, false); // the run starting at seq 3, shut by hand
        return rows(rowsHtml([line('a1'), line('a2'), line('b1', { level: 'warn' }), line('b2', { level: 'warn' })]));
      ''');
      expect(r, ['head a1 ▾ 2 lines', 'cont a2', 'head b1 ▸ 2 lines', 'shut b2']);
    });

    test('fold off draws plain rows', () async {
      final r = await _js(prelude, '''
        state.fold = false;
        return { rows: rows(rowsHtml([line('a1'), line('a2')])), runs: folds.size };
      ''');
      expect(r, {
        'rows': ['plain a1', 'plain a2'],
        'runs': 0,
      });
    });
  });
}
