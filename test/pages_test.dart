import 'package:emu/src/pages.dart';
import 'package:emu/src/pages_api.dart';
import 'package:test/test.dart';

void main() {
  group('parsePages', () {
    test('a page with a toggle, actions and an output block', () {
      final c = parsePages([
        {
          'id': 'templates',
          'title': 'Templates',
          'toolbar': [
            {
              'toggle': {
                'id': 'local',
                'label': 'local templates',
                'state': ['./tool/templates', 'status', '--json'],
                'on': ['./tool/templates', 'on'],
                'off': ['./tool/templates', 'off'],
                'then': 'reload',
              },
            },
            {'action': {'id': 'sync', 'run': ['./tool/templates', 'sync'], 'then': 'reload'}},
            {'action': {'id': 'publish', 'label': 'publish…', 'run': 'tool/publish.sh --all', 'confirm': true, 'timeout': 300}},
          ],
          'blocks': [
            {'output': {'area': 'bottom'}},
          ],
        },
      ]);
      expect(c.problems, isEmpty);
      final page = c.page('templates')!;
      expect(page.title, 'Templates');
      final toggle = page.item('local') as PageToggle;
      expect(toggle.state.argv, ['./tool/templates', 'status', '--json']);
      expect(toggle.then, Then.reload);
      final sync = page.item('sync') as PageAction;
      expect(sync.label, 'sync'); // defaults to the id
      expect(sync.confirm, isFalse);
      expect(sync.timeout, defaultTimeout);
      final publish = page.item('publish') as PageAction;
      expect(publish.run.shell, 'tool/publish.sh --all');
      expect(publish.run.invocation.$1, 'sh');
      expect(publish.run.invocation.$2, ['-c', 'tool/publish.sh --all']);
      expect(publish.confirm, isTrue);
      expect(publish.timeout, const Duration(seconds: 300));
      expect(page.blocks.single, isA<OutputBlock>().having((b) => b.id, 'id', 'output'));
    });

    test('argv entries may be numbers; the title defaults to the id', () {
      final c = parsePages([
        {'id': 'p', 'toolbar': [{'action': {'id': 'a', 'run': ['sleep', 1]}}]},
      ]);
      expect(c.page('p')!.title, 'p');
      expect((c.page('p')!.item('a') as PageAction).run.argv, ['sleep', '1']);
    });

    test('problems name where they are, and only the broken item is dropped', () {
      final c = parsePages([
        {
          'id': 'p',
          'toolbar': [
            {'action': {'id': 'ok', 'run': ['true']}},
            {'action': {'id': 'norun'}},
            {'action': {'id': 'badthen', 'run': ['true'], 'then': 'deploy'}},
            {'action': {'id': 'badtimeout', 'run': ['true'], 'timeout': -1}},
            {'toggle': {'id': 'half', 'state': ['x'], 'on': ['y']}},
            {'button': {'id': 'x'}},
            {'action': {'id': 'ok', 'run': ['true']}},
            {'action': {'id': 'bad id!', 'run': ['true']}},
            'not a map',
          ],
          'blocks': [
            {'output': {'id': 'o', 'area': 'side'}},
            {'chart': {'id': 'c'}},
          ],
        },
        {'id': 'debug'},
        {'title': 'no id'},
        {'id': 'p'},
      ]);
      expect(c.page('p')!.toolbar.map((i) => i.id), ['ok']);
      expect(c.page('p')!.blocks, isEmpty);
      final all = c.problems.join('\n');
      for (final expected in [
        'p.norun.run: missing',
        'p.badthen: then must be none, reload or restart',
        'p.badtimeout: timeout must be a positive number',
        'p.half.off: missing',
        'unknown toolbar item "button"',
        'p.ok: id is used twice',
        'needs an id of letters, digits, - or _ (got "bad id!")',
        'p.toolbar[8]: expected one entry',
        'p.o: area must be left, main or bottom',
        'unknown block "chart"',
        '"debug" is the built-in page',
        'pages[2]: needs an id',
        'pages[3]: page id "p" is used twice',
      ]) {
        expect(all, contains(expected));
      }
    });

    test('a non-list is one problem, absence is none', () {
      expect(parsePages(null).problems, isEmpty);
      expect(parsePages({'id': 'p'}).problems.single, contains('expected a list'));
    });
  });

  group('lists, diffs and placeholders', () {
    PagesConfig parse(List<Map<String, dynamic>> blocks, {List<Map<String, dynamic>> toolbar = const []}) =>
        parsePages([
          {'id': 'p', 'toolbar': toolbar, 'blocks': blocks},
        ]);

    test('a list and a diff with their defaults', () {
      final c = parse([
        {
          'list': {
            'id': 'items',
            'run': ['./tool/t', 'list', '--json'],
            'columns': ['name', 'local:chip', 'changes:count'],
            'rowActions': [
              {'action': {'id': 'check', 'run': ['./tool/t', 'check', '{{row.name}}']}},
            ],
            'watch': 'templates/**',
          },
        },
        {
          'diff': {
            'id': 'changes',
            'run': ['./tool/t', 'diff', '{{selected.name}}', '--against', '{{seg}}'],
            'segments': ['base', 'prod'],
          },
        },
      ]);
      expect(c.problems, isEmpty);
      final page = c.page('p')!;
      final list = page.block('items') as ListBlock;
      expect(list.area, 'left');
      expect(list.title, 'items');
      expect([for (final col in list.columns) '${col.key}:${col.format}'], ['name:text', 'local:chip', 'changes:count']);
      expect(list.rowAction('check')!.run.placeholders, {'row.name'});
      expect(list.watch, ['templates/**']);
      expect(page.selectionList, same(list));
      final diff = page.block('changes') as DiffBlock;
      expect(diff.area, 'main');
      expect(diff.run.placeholders, {'selected.name', 'seg'});
      expect(page.toJson()['selection'], 'items');
    });

    test('fill puts each value inside its own argument', () {
      const cmd = PageCommand.argv(['./tool/t', 'diff', '--name={{selected.name}}', '{{seg}}']);
      final filled = cmd.fill({'selected.name': r'a b; rm -rf ~ $(id)', 'seg': 'prod'});
      expect(filled.argv, ['./tool/t', 'diff', r'--name=a b; rm -rf ~ $(id)', 'prod']);
      expect(filled.display, r"./tool/t diff '--name=a b; rm -rf ~ $(id)' prod");
      expect(() => cmd.fill({'seg': 'prod'}),
          throwsA(isA<MissingValue>().having((e) => e.kind, 'kind', 'selected')));
    });

    test('placeholders are refused where they could run as code or have no value', () {
      final c = parse(
        [
          {'list': {'id': 'items', 'run': ['./tool/t', 'list', '{{selected.name}}']}},
          {'list': {'id': 'other', 'run': ['./tool/t', '{{row.name}}']}},
          {'diff': {'id': 'd1', 'run': ['./tool/t', 'diff', '{{seg}}']}},
          {'diff': {'id': 'd2', 'run': ['./tool/t', '{{selected}}']}},
          {'diff': {'id': 'd3', 'run': ['./tool/t', '{{env.HOME}}']}},
          {'diff': {'id': 'd4', 'run': ['./tool/t', '{{seg.x}}'], 'segments': ['a']}},
          {'list': {'id': 'bad', 'run': ['./tool/t'], 'columns': ['name:bold']}},
          {'list': {'id': 'w', 'run': ['./tool/t'], 'watch': ['../outside/**']}},
        ],
        toolbar: [
          {'action': {'id': 'sh', 'run': './tool/t publish {{selected.name}}'}},
          {'action': {'id': 'ok', 'run': ['./tool/t', 'publish', '{{selected.name}}']}},
        ],
      );
      final all = c.problems.join('\n');
      for (final expected in [
        'p.sh.run: placeholders work only in the [program, arg, …] form',
        "p.items.run: {{selected.*}} can't be used by the list that makes the selection",
        "p.other.run: {{row.*}} only works in a list's rowActions",
        'p.d1.run: {{seg}} only works in a diff block with segments',
        'p.d2.run: {{selected}} needs a column',
        'p.d3.run: unknown placeholder {{env.HOME}}',
        'p.d4.run: {{seg}} takes no column',
        'p.bad.columns: "name:bold" should be name or name:text|chip|count',
        'p.w.watch: expected project-relative globs',
      ]) {
        expect(all, contains(expected));
      }
      expect(c.page('p')!.toolbar.map((i) => i.id), ['ok']);
      expect(c.page('p')!.blocks, isEmpty);
    });

    test('watch globs match project-relative paths', () {
      bool m(String glob, String path) => globToRegExp(glob).hasMatch(path);
      expect(m('templates/**', 'templates/home.json'), isTrue);
      expect(m('templates/**', 'templates/a/b.json'), isTrue);
      expect(m('templates/**', 'lib/main.dart'), isFalse);
      expect(m('**/*.json', 'a.json'), isTrue);
      expect(m('**/*.json', 'x/y/a.json'), isTrue);
      expect(m('templates/*.json', 'templates/a/b.json'), isFalse);
      expect(m('./.local/**', '.local/x'), isTrue);
      expect(m('config?.yaml', 'config1.yaml'), isTrue);
      expect(m('a.b', 'aXb'), isFalse);

      final c = parse([
        {'list': {'id': 'items', 'run': ['./tool/t'], 'watch': ['templates/**']}},
        {'diff': {'id': 'changes', 'run': ['./tool/t'], 'watch': ['templates/*.json', 'base/**']}},
      ]);
      expect(c.watching('templates/home.json'), {'p': ['items', 'changes']});
      expect(c.watching('base/x'), {'p': ['changes']});
      expect(c.watching('lib/main.dart'), isEmpty);
    });
  });

  test('shellQuote quotes only what sh would split or expand', () {
    expect(shellQuote('./tool/x'), './tool/x');
    expect(shellQuote('--target=../cdn'), '--target=../cdn');
    expect(shellQuote('two words'), "'two words'");
    expect(shellQuote(r"it's $HOME"), r"'it'\''s $HOME'");
    expect(const PageCommand.argv(['echo', 'a b']).display, "echo 'a b'");
  });

  group('parseToggleState', () {
    test('reads {"on": bool, "detail"?}', () {
      expect(parseToggleState('{"on": true, "detail": 2}'), {'on': true, 'detail': '2'});
      expect(parseToggleState('{"on":false}\n'), {'on': false});
    });

    test('takes the last line when the tool logs first', () {
      expect(parseToggleState('syncing…\nok\n{"on": true}\n'), {'on': true});
    });

    test('anything else is null', () {
      expect(parseToggleState(''), isNull);
      expect(parseToggleState('on'), isNull);
      expect(parseToggleState('{"on": "yes"}'), isNull);
      expect(parseToggleState('[true]'), isNull);
    });
  });
}
