/// Runs the toolbar items of dashboard pages (`pages.dart`) and serves them
/// under `/api/pages` — for the dashboard and for `emu pages`/`emu run`.
///
/// - `GET  /api/pages`                      pages, config problems, last run per page
/// - `GET  /api/pages/<page>/state/<item>`  a toggle's state (runs its `state` command)
/// - `POST /api/pages/<page>/run/<item>`    run an item; body `{"confirmed": bool, "on": bool}`
///
/// The config is re-read on every request, so editing `emu.yaml` needs no
/// restart. Every run is reported to dashboards over the WebSocket
/// (`{"type": "ext", ...}`) and logged with an `[ext]` prefix.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'models.dart';
import 'pages.dart';
import 'project_config.dart';

/// Output kept per run (the tail, if a command prints more).
const _outputLimit = 256 * 1024;

/// One finished run of a page command.
class PageRun {
  PageRun({
    required this.page,
    required this.item,
    required this.command,
    required this.at,
    this.exitCode = -1,
    this.output = '',
    this.elapsed = Duration.zero,
    this.timedOut = false,
    this.startError,
  });

  final String page;
  final String item;
  final String command;
  final DateTime at;
  final int exitCode;
  final String output;
  final Duration elapsed;
  final bool timedOut;

  /// The command could not be started (missing program, not executable).
  final String? startError;

  /// The follow-up reload/restart (`then:`), if it ran.
  Map<String, dynamic>? then;

  /// A toggle's state after the run.
  Map<String, dynamic>? state;

  bool get commandOk => exitCode == 0 && !timedOut && startError == null;

  /// The command and its follow-up both succeeded.
  bool get ok => commandOk && (then == null || then!['ok'] == true);

  String? get error => startError != null
      ? 'could not start: $startError'
      : timedOut
          ? 'timed out after ${elapsed.inSeconds}s'
          : exitCode != 0
              ? 'exit $exitCode'
              : null;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'page': page,
        'item': item,
        'command': command,
        'exitCode': exitCode,
        if (timedOut) 'timedOut': true,
        'error': ?error,
        'output': output,
        'ms': elapsed.inMilliseconds,
        'at': at.toIso8601String(),
        'then': ?then,
        'state': ?state,
      };
}

/// A toggle's `state` output → `{on, detail?}`, or null when it isn't
/// `{"on": bool, "detail"?: …}`. The whole output is tried first, then its
/// last line, so a tool may log before printing the JSON.
Map<String, dynamic>? parseToggleState(String output) {
  final lines = output.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  for (final candidate in [output.trim(), if (lines.isNotEmpty) lines.last.trim()]) {
    try {
      final v = jsonDecode(candidate);
      if (v is Map && v['on'] is bool) {
        return {'on': v['on'], if (v['detail'] != null) 'detail': '${v['detail']}'};
      }
    } on FormatException {
      continue;
    }
  }
  return null;
}

class PagesApi {
  PagesApi({
    required this.projectRoot,
    this.profile,
    this.home,
    required this.environment,
    required this.followUp,
    required this.broadcast,
    required this.log,
  });

  final String projectRoot;

  /// The `emu up --profile` in effect, so a profile's `pages:` apply.
  final String? profile;

  /// Home for `~/.emu/config.yaml` (tests point it elsewhere).
  final String? home;

  /// Variables for every command (`EMU_PROJECT`, `EMU_DEVICE`, …).
  final Map<String, String> Function() environment;

  /// Runs an item's `then:` and reports `{ok, message, …}`.
  final Future<Map<String, dynamic>> Function(Then then) followUp;

  final void Function(Map<String, dynamic> message) broadcast;
  final void Function(String text, LogLevel level) log;

  final Set<String> _running = {};
  final Map<String, PageRun> _last = {};

  /// The current `pages:` of the merged config, with config-file warnings first.
  PagesConfig load() {
    final warnings = <String>[];
    final config = loadProjectConfig(projectRoot, home: home, profile: profile, onWarn: warnings.add);
    final parsed = parsePages(config.pages);
    return PagesConfig(parsed.pages, [...warnings, ...parsed.problems]);
  }

  Future<Response> handle(Request req, String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList(); // api, pages, …
    final config = load();
    if (parts.length == 2) {
      return _json({
        'pages': [for (final page in config.pages) page.toJson()],
        'problems': config.problems,
        'last': {for (final e in _last.entries) e.key: e.value.toJson()},
      });
    }
    if (parts.length != 5) return _json({'ok': false, 'error': 'not found'}, status: 404);
    final page = config.page(parts[2]);
    if (page == null) {
      return _json({
        'ok': false,
        'error': 'no page "${parts[2]}" in emu.yaml (pages: ${config.pages.map((p) => p.id).join(', ')})',
      }, status: 404);
    }
    final item = page.item(parts[4]);
    if (item == null) {
      return _json({
        'ok': false,
        'error': 'no item "${parts[4]}" on page ${page.id} (${page.toolbar.map((i) => i.id).join(', ')})',
      }, status: 404);
    }
    switch (parts[3]) {
      case 'state':
        if (item is! PageToggle) return _json({'ok': false, 'error': '${page.id}.${item.id} is not a toggle'}, status: 400);
        return _json(await _state(page, item));
      case 'run':
        if (req.method != 'POST') return _json({'ok': false, 'error': 'use POST'}, status: 405);
        Map body;
        try {
          final text = await req.readAsString();
          body = text.trim().isEmpty ? const {} : jsonDecode(text) as Map;
        } catch (_) {
          return _json({'ok': false, 'error': 'invalid request body'}, status: 400);
        }
        return _run(page, item, confirmed: body['confirmed'] == true, on: body['on'] as bool?);
      default:
        return _json({'ok': false, 'error': 'not found'}, status: 404);
    }
  }

  Future<Response> _run(DashboardPage page, ToolbarItem item, {required bool confirmed, bool? on}) async {
    final key = '${page.id}.${item.id}';
    final PageCommand command;
    switch (item) {
      case PageAction():
        if (item.confirm && !confirmed) {
          return _json({
            'ok': false,
            'needsConfirm': true,
            'command': item.run.display,
            'error': '$key asks for confirmation first — it runs: ${item.run.display}',
          }, status: 428);
        }
        command = item.run;
      case PageToggle():
        if (on == null) return _json({'ok': false, 'error': '$key is a toggle — say on or off'}, status: 400);
        command = on ? item.on : item.off;
    }
    if (!_running.add(key)) {
      return _json({'ok': false, 'busy': true, 'error': '$key is already running'}, status: 409);
    }
    final PageRun run;
    try {
      broadcast({'type': 'ext', 'event': 'started', 'page': page.id, 'item': item.id});
      log('[ext] $key ▸ ${command.display}', LogLevel.system);
      run = await execute(page.id, item.id, command, item.timeout);
      if (run.commandOk && item.then != Then.none) run.then = await followUp(item.then);
      if (item is PageToggle) run.state = await _state(page, item);
    } finally {
      _running.remove(key);
    }
    _last[page.id] = run;
    _logResult(key, run);
    broadcast({'type': 'ext', 'event': 'finished', 'page': page.id, 'item': item.id, 'run': run.toJson()});
    return _json(run.toJson());
  }

  Future<Map<String, dynamic>> _state(DashboardPage page, PageToggle toggle) async {
    final run = await execute(page.id, toggle.id, toggle.state, const Duration(seconds: 10));
    if (!run.commandOk) {
      return {'ok': false, 'error': 'state command failed (${run.error}): ${_clip(run.output)}'};
    }
    final state = parseToggleState(run.output);
    if (state == null) {
      return {'ok': false, 'error': 'state command should print {"on": true|false}: ${_clip(run.output)}'};
    }
    return {'ok': true, ...state};
  }

  /// Run [command] in the project root, output captured (stdout and stderr
  /// interleaved), killed after [timeout]. Never throws.
  Future<PageRun> execute(String page, String item, PageCommand command, Duration timeout) async {
    var (exe, args) = command.invocation;
    // A project script (`./tool/x`, `tool/x`) resolves against the project
    // root, not against wherever the server was started.
    if (exe.contains('/') && !p.isAbsolute(exe)) exe = p.normalize(p.join(projectRoot, exe));
    final at = DateTime.now();
    final clock = Stopwatch()..start();
    final Process proc;
    try {
      proc = await Process.start(exe, args, workingDirectory: projectRoot, environment: environment());
    } on ProcessException catch (e) {
      return PageRun(page: page, item: item, command: command.display, at: at, startError: e.message);
    }
    unawaited(proc.stdin.close()); // EOF for anything that prompts
    final out = StringBuffer();
    void add(String chunk) {
      out.write(chunk);
      if (out.length > _outputLimit * 2) {
        final keep = out.toString().substring(out.length - _outputLimit);
        out
          ..clear()
          ..write(keep);
      }
    }

    const decoder = Utf8Decoder(allowMalformed: true);
    final drained = Future.wait([
      proc.stdout.transform(decoder).forEach(add),
      proc.stderr.transform(decoder).forEach(add),
    ]);
    var timedOut = false;
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    await drained.timeout(const Duration(seconds: 2), onTimeout: () => const []);
    final text = out.length > _outputLimit ? out.toString().substring(out.length - _outputLimit) : '$out';
    return PageRun(
      page: page,
      item: item,
      command: command.display,
      at: at,
      exitCode: code,
      output: text,
      elapsed: clock.elapsed,
      timedOut: timedOut,
    );
  }

  void _logResult(String key, PageRun run) {
    final secs = (run.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final then = run.then;
    final follow = then == null ? '' : ' · ${then['action']}: ${then['message'] ?? (then['ok'] == true ? 'ok' : 'failed')}';
    if (run.ok) {
      log('[ext] $key ✓ exit 0 · ${secs}s$follow', LogLevel.system);
      return;
    }
    final tail = run.output.trimRight().split('\n');
    final last = tail.length > 20 ? tail.sublist(tail.length - 20) : tail;
    log('[ext] $key ✗ ${run.error ?? 'exit 0'} · ${secs}s$follow${last.join().isEmpty ? '' : '\n${last.join('\n')}'}',
        LogLevel.error);
  }
}

String _clip(String s) {
  final t = s.trim();
  return t.length > 200 ? '${t.substring(0, 200)}…' : t;
}

Response _json(Object data, {int status = 200}) =>
    Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});
