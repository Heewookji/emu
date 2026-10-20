/// Dashboard pages declared in `emu.yaml` (`pages:`) — project tools such as a
/// template previewer or a remote-config differ, run from the dashboard and
/// from the CLI (`emu run`). emu knows nothing about them: a page is a toolbar
/// of toggles and actions plus blocks, and the contract is "a command, and
/// what it prints" (JSON for a toggle's state, text for output).
///
/// Commands come only from the config. A request names an item by id and
/// never carries a command, so the dashboard can run exactly what the project
/// declared — the same trust as the `onDeviceReady`/`onAppStarted` hooks.
///
/// Parsing is pure and collects every problem instead of failing: one typo
/// hides one item, not the whole page.
library;

/// Page and item ids: they appear in URLs and in `emu run <page>.<item>`.
final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

bool isPageId(String s) => _id.hasMatch(s);

/// The built-in page the dashboard always shows first.
const debugPageId = 'debug';

/// A command from the config: an argv list, started directly, or a string,
/// run with `sh -c` (like the hooks).
class PageCommand {
  const PageCommand.argv(List<String> this.argv) : shell = null;
  const PageCommand.shell(String this.shell) : argv = null;

  final List<String>? argv;
  final String? shell;

  /// Executable and arguments to start.
  (String, List<String>) get invocation {
    final a = argv;
    return a != null ? (a.first, a.sublist(1)) : ('sh', ['-c', shell!]);
  }

  /// What runs, for people (confirm dialog, `emu pages`): argv shell-quoted.
  String get display => argv?.map(shellQuote).join(' ') ?? shell!;
}

final _plainArg = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// [s] quoted for `sh` when it needs to be.
String shellQuote(String s) => _plainArg.hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";

/// What to do after an item's command succeeds.
enum Then {
  none,
  reload,
  restart;

  static Then? fromWire(Object? v) => v == null ? none : values.where((t) => t.name == '$v').firstOrNull;
}

/// A button or switch in a page's toolbar.
sealed class ToolbarItem {
  const ToolbarItem({required this.id, required this.label, required this.then, required this.timeout});

  final String id;
  final String label;
  final Then then;

  /// Upper bound for the item's command; it is killed after this.
  final Duration timeout;

  Map<String, dynamic> toJson();
}

/// Runs [run] when pressed. With [confirm], the dashboard shows the command
/// and asks first, and `emu run` needs `--yes`.
class PageAction extends ToolbarItem {
  const PageAction({
    required super.id,
    required super.label,
    required this.run,
    super.then = Then.none,
    super.timeout = defaultTimeout,
    this.confirm = false,
  });

  final PageCommand run;
  final bool confirm;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'action',
        'id': id,
        'label': label,
        'command': run.display,
        'then': then.name,
        'confirm': confirm,
      };
}

/// A switch: [state] prints `{"on": bool, "detail"?: string}`; flipping it
/// runs [on] or [off].
class PageToggle extends ToolbarItem {
  const PageToggle({
    required super.id,
    required super.label,
    required this.state,
    required this.on,
    required this.off,
    super.then = Then.none,
    super.timeout = defaultTimeout,
  });

  final PageCommand state;
  final PageCommand on;
  final PageCommand off;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'toggle',
        'id': id,
        'label': label,
        'on': on.display,
        'off': off.display,
        'then': then.name,
      };
}

const defaultTimeout = Duration(seconds: 60);

/// Where a block sits: a column on the left, the main area, or under it.
const blockAreas = {'left', 'main', 'bottom'};

/// A panel in a page's body.
sealed class PageBlock {
  const PageBlock({required this.id, required this.area});

  final String id;
  final String area;

  Map<String, dynamic> toJson();
}

/// The last toolbar run on this page: command, exit code, output.
class OutputBlock extends PageBlock {
  const OutputBlock({required super.id, super.area = 'bottom'});

  @override
  Map<String, dynamic> toJson() => {'kind': 'output', 'id': id, 'area': area, 'source': 'lastAction'};
}

class DashboardPage {
  const DashboardPage({required this.id, required this.title, this.toolbar = const [], this.blocks = const []});

  final String id;
  final String title;
  final List<ToolbarItem> toolbar;
  final List<PageBlock> blocks;

  ToolbarItem? item(String id) => toolbar.where((i) => i.id == id).firstOrNull;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'toolbar': [for (final i in toolbar) i.toJson()],
        'blocks': [for (final b in blocks) b.toJson()],
      };
}

/// Parsed `pages:` plus everything wrong with it, in reading order.
class PagesConfig {
  const PagesConfig(this.pages, this.problems);

  static const empty = PagesConfig([], []);

  final List<DashboardPage> pages;
  final List<String> problems;

  DashboardPage? page(String id) => pages.where((p) => p.id == id).firstOrNull;
}

/// Parse the raw `pages:` value of the merged config (see `project_config.dart`).
PagesConfig parsePages(Object? raw) {
  if (raw == null) return PagesConfig.empty;
  final problems = <String>[];
  if (raw is! List) return const PagesConfig([], ['pages: expected a list of pages']);
  final pages = <DashboardPage>[];
  for (var i = 0; i < raw.length; i++) {
    final page = _parsePage(raw[i], 'pages[$i]', problems);
    if (page == null) continue;
    if (pages.any((p) => p.id == page.id)) {
      problems.add('pages[$i]: page id "${page.id}" is used twice');
      continue;
    }
    pages.add(page);
  }
  return PagesConfig(pages, problems);
}

DashboardPage? _parsePage(Object? raw, String at, List<String> problems) {
  if (raw is! Map) {
    problems.add('$at: expected a map with id, title, toolbar, blocks');
    return null;
  }
  final id = '${raw['id'] ?? ''}';
  if (!isPageId(id)) {
    problems.add('$at: needs an id of letters, digits, - or _ (got "$id")');
    return null;
  }
  if (id == debugPageId) {
    problems.add('$at: "$debugPageId" is the built-in page — pick another id');
    return null;
  }
  final ids = <String>{};
  String? claim(Object? raw, String where) {
    final itemId = raw?.toString();
    if (itemId == null || !isPageId(itemId)) {
      problems.add('$where: needs an id of letters, digits, - or _ (got "${itemId ?? ''}")');
      return null;
    }
    if (!ids.add(itemId)) {
      problems.add('$id.$itemId: id is used twice in this page');
      return null;
    }
    return itemId;
  }

  final toolbar = <ToolbarItem>[];
  for (final (j, entry) in _entries(raw['toolbar'], '$id.toolbar', problems).indexed) {
    final item = _parseToolbarItem(entry, '$id.toolbar[$j]', claim, problems);
    if (item != null) toolbar.add(item);
  }
  final blocks = <PageBlock>[];
  for (final (j, entry) in _entries(raw['blocks'], '$id.blocks', problems).indexed) {
    final block = _parseBlock(entry, '$id.blocks[$j]', claim, problems);
    if (block != null) blocks.add(block);
  }
  return DashboardPage(id: id, title: '${raw['title'] ?? id}', toolbar: toolbar, blocks: blocks);
}

/// The single-key maps of a `toolbar:`/`blocks:` list, as (kind, body).
List<(String, Map)> _entries(Object? raw, String at, List<String> problems) {
  if (raw == null) return const [];
  if (raw is! List) {
    problems.add('$at: expected a list');
    return const [];
  }
  final out = <(String, Map)>[];
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is Map && e.length == 1 && e.values.first is Map) {
      out.add(('${e.keys.first}', e.values.first as Map));
    } else {
      problems.add('$at[$i]: expected one entry like `- action: {id: …}`');
    }
  }
  return out;
}

ToolbarItem? _parseToolbarItem((String, Map) entry, String at,
    String? Function(Object?, String) claim, List<String> problems) {
  final (kind, m) = entry;
  if (kind != 'action' && kind != 'toggle') {
    problems.add('$at: unknown toolbar item "$kind" (action, toggle)');
    return null;
  }
  final id = claim(m['id'], at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  final then = Then.fromWire(m['then']);
  if (then == null) {
    problems.add('$where: then must be none, reload or restart (got "${m['then']}")');
    return null;
  }
  final timeout = _timeout(m['timeout'], where, problems);
  if (timeout == null) return null;
  final label = '${m['label'] ?? id}';
  if (kind == 'action') {
    final run = _command(m['run'], '$where.run', problems);
    if (run == null) return null;
    return PageAction(id: id, label: label, run: run, then: then, timeout: timeout, confirm: m['confirm'] == true);
  }
  final state = _command(m['state'], '$where.state', problems);
  final on = _command(m['on'], '$where.on', problems);
  final off = _command(m['off'], '$where.off', problems);
  if (state == null || on == null || off == null) return null;
  return PageToggle(id: id, label: label, state: state, on: on, off: off, then: then, timeout: timeout);
}

PageBlock? _parseBlock((String, Map) entry, String at,
    String? Function(Object?, String) claim, List<String> problems) {
  final (kind, m) = entry;
  if (kind != 'output') {
    problems.add('$at: unknown block "$kind" (output)');
    return null;
  }
  final id = claim(m['id'] ?? kind, at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  final area = '${m['area'] ?? 'bottom'}';
  if (!blockAreas.contains(area)) {
    problems.add('$where: area must be left, main or bottom (got "$area")');
    return null;
  }
  final source = m['source'] ?? 'lastAction';
  if (source != 'lastAction') {
    problems.add('$where: source must be lastAction (got "$source")');
    return null;
  }
  return OutputBlock(id: id, area: area);
}

PageCommand? _command(Object? v, String at, List<String> problems) {
  if (v is String && v.trim().isNotEmpty) return PageCommand.shell(v);
  if (v is List && v.isNotEmpty && v.every((e) => e is String || e is num || e is bool)) {
    final argv = [for (final e in v) '$e'];
    if (argv.first.isNotEmpty) return PageCommand.argv(argv);
  }
  problems.add(v == null
      ? '$at: missing — give a command as [program, arg, …] or a shell string'
      : '$at: expected [program, arg, …] or a shell string');
  return null;
}

Duration? _timeout(Object? v, String at, List<String> problems) {
  if (v == null) return defaultTimeout;
  final s = v is int ? v : int.tryParse('$v');
  if (s == null || s <= 0) {
    problems.add('$at: timeout must be a positive number of seconds (got "$v")');
    return null;
  }
  return Duration(seconds: s);
}
