import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

const multiAgentPrompt =
    '请开启两个子代理，一个读取 sales 数据并计算 total 和 mean，另一个读取 latency 数据按 nearest-rank 规则计算 p50 和 p95（单位毫秒），各自保存分析结果，然后由你汇总为 JSON，字段严格使用 sales.total、sales.mean、latency.p50、latency.p95，不在字段名里添加单位。';

const _datasets = {
  'sales': [120, 80, 150, 90, 160],
  'latency': [
    12,
    18,
    21,
    25,
    31,
    35,
    44,
    55,
    80,
    110,
    160,
    240,
    320,
    450,
    680,
    900,
    1200,
    1500,
    1900,
    2500,
  ],
};
const _expected = {
  'sales': {'total': 600, 'mean': 120},
  'latency': {'p50': 110, 'p95': 1900},
};

/// Records model calls by agent identity for live validation reports.
class LiveTraceModel implements ModelAdapter {
  LiveTraceModel(this.model, this.trace);
  final ModelAdapter model;
  final List<Map<String, Object?>> trace;

  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final agent =
        RegExp(
          r'Multi-agent collaboration: You are ([^\s]+)\. ',
        ).firstMatch(request.system)?.group(1) ??
        'unknown';
    final entry = <String, Object?>{
      'agent': agent,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'calls': <Object?>[],
    };
    trace.add(entry);
    stdout.writeln('MODEL $agent request ${trace.length}');
    await for (final event in model.stream(request, token)) {
      if (event is ModelResponse) {
        entry['calls'] = event.calls.map((c) => c.toJson()).toList();
        entry['text'] = event.text;
        entry['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        for (final call in event.calls) {
          stdout.writeln('CALL $agent ${call.name}');
        }
      }
      yield event;
    }
  }
}

bool _matches(Object? value, Map<String, int> expected) =>
    value is Map &&
    value.length == expected.length &&
    expected.entries.every((entry) => value[entry.key] == entry.value);

/// Verifies a single user message through real or injected model collaboration.
///
/// Business tools use fixed test data. The returned report contains each
/// agent's actual calls, stored analyses and the main agent's final answer.
Future<Map<String, Object?>> validateMultiAgent(ModelAdapter model) async {
  final directory = await Directory.systemTemp.createTemp('cutdex-multi-live-');
  final store = FileSessionStore(directory);
  final trace = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  final analyses = <String, Map<String, Object?>>{};
  final owners = <String, String>{};
  AgentRun? run;
  Timer? deadline;
  var timedOut = false;
  try {
    final manager = SessionManager(
      model: LiveTraceModel(model, trace),
      store: store,
      contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
      multiAgent: MultiAgentConfig(
        maxChildren: 2,
        maxDepth: 1,
        childMaxTurns: 8,
        maxDelegatedTurns: 16,
      ),
      tools: [
        AgentTool(
          name: 'read_dataset',
          description:
              'Read the named test dataset to calculate statistics. '
              'latency is in milliseconds. nearest-rank quantile uses the '
              'sorted value at ceil(p * count), counting from one.',
          parameters: {
            'type': 'object',
            'properties': {
              'dataset': {
                'type': 'string',
                'enum': ['sales', 'latency'],
              },
            },
            'required': ['dataset'],
            'additionalProperties': false,
          },
          validate: (args) =>
              args.length == 1 && _datasets.containsKey(args['dataset'])
              ? null
              : 'Supply dataset sales or latency',
          execute: (call, context) async {
            context.cancellation.throwIfCancelled();
            final name = call.arguments['dataset'] as String;
            actions.add({
              'sessionId': context.sessionId,
              'tool': call.name,
              'dataset': name,
              'operationId': context.operationId,
            });
            return ToolResult(
              'Dataset values',
              data: {'dataset': name, 'values': _datasets[name]},
            );
          },
        ),
        AgentTool(
          name: 'save_analysis',
          description:
              'Save a child agent analysis: sales needs total and mean; '
              'latency needs p50 and p95 in milliseconds. Read the dataset first. '
              'A root agent must delegate the writes to its children.',
          parameters: {
            'type': 'object',
            'properties': {
              'dataset': {
                'type': 'string',
                'enum': ['sales', 'latency'],
              },
              'analysis': {
                'type': 'object',
                'properties': {
                  for (final field in ['total', 'mean', 'p50', 'p95'])
                    field: {'type': 'number'},
                },
                'additionalProperties': false,
              },
            },
            'required': ['dataset', 'analysis'],
            'additionalProperties': false,
          },
          validate: (args) =>
              args.length == 2 &&
                  _datasets.containsKey(args['dataset']) &&
                  args['analysis'] is Map
              ? null
              : 'Supply dataset and numerical analysis object',
          execute: (call, context) async {
            context.cancellation.throwIfCancelled();
            final snapshot = (await store.read(context.sessionId))!;
            final name = call.arguments['dataset'] as String;
            if (snapshot.parentSessionId == null) {
              return ToolResult(
                'Delegate analysis writes to child agents',
                isError: true,
              );
            }
            if (!actions.any(
              (a) =>
                  a['sessionId'] == context.sessionId &&
                  a['tool'] == 'read_dataset' &&
                  a['dataset'] == name,
            )) {
              return ToolResult(
                'Read this dataset before saving analysis',
                isError: true,
              );
            }
            final analysis = (call.arguments['analysis'] as Map)
                .cast<String, Object?>();
            if (!_matches(analysis, _expected[name]!)) {
              return ToolResult(
                'Statistics are incorrect; recalculate from the dataset',
                isError: true,
              );
            }
            analyses[name] = analysis;
            owners[name] = context.sessionId;
            actions.add({
              'sessionId': context.sessionId,
              'tool': call.name,
              'dataset': name,
              'operationId': context.operationId,
            });
            return ToolResult(
              'Analysis saved',
              data: {'dataset': name, 'analysis': analysis},
            );
          },
        ),
      ],
    );
    final session = await manager.create(
      system:
          'Complete the user task using tools and report only verified results. '
          'Use concise Chinese answers.',
    );
    run = await manager.prompt(session.id, multiAgentPrompt, maxTurns: 12);
    final activeRun = run;
    deadline = Timer(const Duration(minutes: 5), () {
      timedOut = true;
      unawaited(activeRun.cancel());
    });
    final result = await run.done;
    final children = <SessionSnapshot>[
      for (final id in result.childSessionIds) ?await store.read(id),
    ];
    Object? summary;
    final answer = result.history.last.text;
    final first = answer.indexOf('{');
    final last = answer.lastIndexOf('}');
    if (first >= 0 && last > first) {
      try {
        summary = jsonDecode(answer.substring(first, last + 1));
      } on FormatException {
        /* Report malformed JSON as a failed check. */
      }
    }
    final checks = <String, bool>{
      'completed': result.status == RunStatus.completed && !timedOut,
      'singleUserMessage':
          result.history
              .where((m) => m.role == MessageRole.user && !m.runtimeNotice)
              .length ==
          1,
      'modelSpawnedTwoChildren':
          children.length == 2 &&
          trace
                  .where((e) => e['agent'] == '/root')
                  .expand((e) => e['calls'] as List)
                  .where((c) => (c as Map)['name'] == 'spawn_agent')
                  .length ==
              2,
      'childrenCompleted':
          children.length == 2 &&
          children.every((c) => c.status == RunStatus.completed),
      'childrenReadAndSavedResults':
          _expected.keys.every(
            (name) =>
                _matches(analyses[name], _expected[name]!) &&
                children.any((c) => c.id == owners[name]),
          ) &&
          owners.values.toSet().length == 2,
      'mainAgentSummaryMatches':
          summary is Map &&
          _expected.entries.every(
            (e) => _matches((summary as Map)[e.key], e.value),
          ),
    };
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'prompt': multiAgentPrompt,
      'parentStatus': result.status.name,
      'parentTurns': result.turns,
      'finalAnswer': answer,
      if (result.error != null) 'parentError': result.error,
      'savedAnalyses': analyses,
      'businessActions': actions,
      'children': [
        for (final child in children)
          {
            'id': child.id,
            'name': child.agentState['name'],
            'status': child.status.name,
            'turns': child.turns,
            if (child.error != null) 'error': child.error,
            'messages': child.history.map((m) => m.toJson()).toList(),
          },
      ],
      'modelTrace': trace,
    };
  } finally {
    deadline?.cancel();
    if (run != null && !run.isSettled) await run.cancel();
    await directory.delete(recursive: true);
  }
}

/// Runs a model validation using explicit configuration and a private key input.
Future<void> runLiveValidation(
  List<String> args,
  Future<Map<String, Object?>> Function(ModelAdapter) validate, {
  required String label,
}) async {
  final baseUrl = Platform.environment['CUTDEX_LIVE_BASE_URL']?.trim();
  final modelId = Platform.environment['CUTDEX_LIVE_MODEL']?.trim();
  if (baseUrl == null ||
      baseUrl.isEmpty ||
      modelId == null ||
      modelId.isEmpty) {
    throw ArgumentError(
      'CUTDEX_LIVE_BASE_URL and CUTDEX_LIVE_MODEL are required',
    );
  }
  var key = Platform.environment['CUTDEX_LIVE_API_KEY']?.trim();
  if (key == null || key.isEmpty) {
    bool? previousEcho;
    try {
      if (stdin.hasTerminal) {
        try {
          previousEcho = stdin.echoMode;
          stdin.echoMode = false;
        } on StdinException {
          // Some process runners report a terminal without terminal ioctls.
          previousEcho = null;
        }
      }
      key = stdin.readLineSync()?.trim();
    } finally {
      if (previousEcho != null) stdin.echoMode = previousEcho;
    }
  }
  if (key == null || key.isEmpty) {
    throw ArgumentError('API key required on stdin or CUTDEX_LIVE_API_KEY');
  }
  Map<String, Object?> report;
  final watch = Stopwatch()..start();
  try {
    report = await validate(
      OpenAiChatAdapter(
        baseUrl: Uri.parse(baseUrl),
        model: modelId,
        apiKey: key,
        requestTimeout: const Duration(seconds: 90),
      ),
    );
  } catch (error) {
    report = {'passed': false, 'error': error.toString()};
  }
  report['model'] = modelId;
  report['elapsedMs'] = watch.elapsedMilliseconds;
  final json = const JsonEncoder.withIndent('  ')
      .convert(report)
      .replaceAll(baseUrl, '[REDACTED_ENDPOINT]')
      .replaceAll(key, '[REDACTED]');
  if (args.isNotEmpty) await File(args.first).writeAsString(json);
  stdout.writeln('CHECKS ${jsonEncode(report['checks'])}');
  stdout.writeln('ANSWER ${report['finalAnswer']}');
  stdout.writeln(report['passed'] == true ? '${label}_PASS' : '${label}_FAIL');
  if (report['passed'] != true) exitCode = 1;
}

Future<void> main(List<String> args) =>
    runLiveValidation(args, validateMultiAgent, label: 'LIVE_MULTI_AGENT');
