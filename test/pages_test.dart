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
