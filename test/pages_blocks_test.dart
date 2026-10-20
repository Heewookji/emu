import 'dart:convert';
import 'dart:io';

import 'package:emu/src/pages_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// List rows and diffs from a real script; row buttons and the toolbar fed
/// with the selected row.
const _emuYaml = r'''
pages:
  - id: tpl
    toolbar:
      - action: { id: publish, run: [./tool/t.sh, args, publish, "{{selected.name}}"], confirm: true }
    blocks:
      - list:
          id: items
          run: [./tool/t.sh, list]
          key: name
          columns: [name, local:chip]
          rowActions:
            - action: { id: check, run: [./tool/t.sh, args, check, "{{row.name}}"] }
          watch: [templates/**]
      - diff:
          id: changes
          run: [./tool/t.sh, diff, "{{selected.name}}", "{{seg}}"]
          segments: [base, prod]
      - list:
          id: broken
          run: [./tool/t.sh, notjson]
''';

const _script = r'''#!/bin/sh
case "$1" in
  list) echo "loading…" >&2; echo '[{"name": "home banner", "local": true}, {"name": "card", "local": false}]' ;;
  diff) printf -- '--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old %s\n+new %s\n' "$2" "$2" "$3" "$3" ;;
  args) shift; for a in "$@"; do echo "[$a]"; done ;;
  notjson) echo "rows: 2" ;;
esac
''';

void main() {
  late Directory root;
  late PagesApi api;

  setUp(() {
    root = Directory.systemTemp.createTempSync('emu_blocks_');
    File('${root.path}/emu.yaml').writeAsStringSync(_emuYaml);
    final script = File('${root.path}/tool/t.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(_script);
    Process.runSync('chmod', ['+x', script.path]);
    api = PagesApi(
      projectRoot: root.path,
      home: root.path,
      environment: () => {},
      followUp: (_) async => {'ok': true},
      broadcast: (_) {},
      log: (_, _) {},
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, Map<String, dynamic>)> call(String method, String pathAndQuery, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('http://127.0.0.1:4577$pathAndQuery');
    final res = await api.handle(Request(method, uri, body: body == null ? null : jsonEncode(body)), uri.path);
    return (res.statusCode, jsonDecode(await res.readAsString()) as Map<String, dynamic>);
  }

  test('a list block returns the rows its command prints (stdout only)', () async {
    final (code, j) = await call('GET', '/api/pages/tpl/blocks/items');
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['kind'], 'list');
    expect(j['rows'], [
      {'name': 'home banner', 'local': true},
      {'name': 'card', 'local': false},
    ]);
  });

  test('a list that prints something else says so', () async {
    final (_, j) = await call('GET', '/api/pages/tpl/blocks/broken');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('JSON array of objects'));
  });

  test('a diff waits for a selection, then fills it and the segment', () async {
    var (code, j) = await call('GET', '/api/pages/tpl/blocks/changes');
    expect(code, 200);
    expect(j['ok'], isFalse);
    expect(j['needs'], 'selected');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card');
    expect(j['ok'], isTrue);
    expect(j['seg'], 'base'); // the first segment unless one is picked
    expect(j['patch'], contains('+new base'));

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card&seg=prod');
    expect(j['patch'], contains('+new prod'));
    expect(j['command'], './tool/t.sh diff card prod');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card&seg=staging');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('base, prod'));
  });

  test('a row button gets its row, as one argument however it is spelled', () async {
    const nasty = r'x"; touch pwned; echo $(id) `id` ;';
    final (code, j) = await call('POST', '/api/pages/tpl/rows/items/check', {
      'row': {'name': nasty, 'local': true},
    });
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['item'], 'items.check');
    expect(j['output'], '[check]\n[$nasty]\n');
    expect(File('${root.path}/pwned').existsSync(), isFalse);
  });

  test('a toolbar action reads the selection; confirm shows the filled command', () async {
    var (code, j) = await call('POST', '/api/pages/tpl/run/publish', {});
    expect(code, 400);
    expect(j['needs'], 'selected');

    (code, j) = await call('POST', '/api/pages/tpl/run/publish', {
      'selected': {'name': 'home banner'},
    });
    expect(code, 428);
    expect(j['command'], "./tool/t.sh args publish 'home banner'");

    (code, j) = await call('POST', '/api/pages/tpl/run/publish', {
      'selected': {'name': 'home banner'},
      'confirmed': true,
    });
    expect(j['output'], '[publish]\n[home banner]\n');
  });

  test('unknown blocks and row actions say what exists', () async {
    var (code, j) = await call('GET', '/api/pages/tpl/blocks/nope');
    expect(code, 404);
    expect(j['error'], contains('items, changes, broken'));
    (code, _) = await call('POST', '/api/pages/tpl/rows/items/nope', {});
    expect(code, 404);
    (code, _) = await call('POST', '/api/pages/tpl/rows/changes/check', {});
    expect(code, 404); // a diff has no row buttons
  });

  test('watching maps changed paths to the blocks to fetch again', () {
    expect(api.watching(['templates/home.json', 'lib/main.dart']), {
      'tpl': {'items'},
    });
    expect(api.watching(['lib/main.dart']), isEmpty);
  });

  test('placeholderValues reads bodies and queries', () {
    expect(
      placeholderValues(body: {
        'selected': {'name': 'a', 'n': 3, 'tags': ['x']},
        'row': {'id': true},
        'seg': 'prod',
      }),
      {'selected.name': 'a', 'selected.n': '3', 'selected.tags': '["x"]', 'row.id': 'true', 'seg': 'prod'},
    );
    expect(placeholderValues(query: {'selected.name': 'a', 'seg': 'b', 'token': 't'}), {'selected.name': 'a', 'seg': 'b'});
  });
}
