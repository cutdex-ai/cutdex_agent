import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;

/// Independent model-directed collaboration experiments.
enum SubagentScenario {
  nested,
  handoff,
  activeFollowup,
  interrupt,
  recovery,
  limits,
  transportFault,
}

const _prompts = {
  SubagentScenario.nested:
      '启动一个leader子代理，让它再启动两个孙代理：分别读取left和right数据并计算sum，'
      '分别保存left、right结果。leader等待并核对两者后保存total=sum(left)+sum(right)。'
      '你等待leader，调用inspect_tasks核验实际保存结果，最后只回复JSON {"total":数字}。'
      'leader必须委派这两个子任务，不能自己代做。',
  SubagentScenario.handoff:
      '启动producer与consumer两个子代理。producer读取numbers求和，保存producer结果，'
      '用send_message向parent报告值后结束。consumer先调用hold_for_parent，不得自行读数据；'
      '等你转发producer的实际结果后，把该值乘2保存consumer并结束。你先wait_agent等待producer，'
      '再wait_for_checkpoint确认consumer正在等待，然后用send_message把真实求和结果转给consumer。'
      '等待consumer完成、inspect_tasks核验，最后只回复JSON {"producer":数字,"consumer":数字}。',
  SubagentScenario.activeFollowup:
      '启动worker子代理：先hold_for_parent(proposed_value:10)等待追加指令，收到指令前不能保存。'
      '你用wait_for_checkpoint确认它正在执行工具，然后在它仍活动时用followup_task追加'
      '“取消10，改成15，只保存chosen=15”。等待它结束，inspect_tasks核验，最后只回复JSON {"chosen":15}。'
      '必须在同一子Run内改向，不要先中断或创建替代子代理。',
  SubagentScenario.interrupt:
      '启动worker子代理：先hold_for_parent(proposed_value:10)，等待后才保存chosen=10。'
      '你用wait_for_checkpoint确认工具执行中，然后interrupt_agent并等待它取消；不能释放旧目标。'
      '之后对同一个worker调用followup_task，重新分配“不要等待，直接保存chosen=15并汇报”。'
      '等待并inspect_tasks核验；最后只回复JSON {"chosen":15}。旧10不能发生任何保存。',
  SubagentScenario.recovery:
      '启动worker子代理，首轮只尝试read_numbers(dataset:missing)，遇到dataset_unavailable后'
      'send_message向parent报告并结束，不自行改数据源。你wait_agent读取错误报告，然后对同一个'
      'worker用followup_task重新分配读取numbers、求和保存total的任务。等待、inspect_tasks核验，'
      '最后只回复JSON {"total":数字}。',
  SubagentScenario.limits:
      '受控边界测试：当前最多1个活动子代理。先spawn_agent(task_name:blocked)，让它执行'
      'hold_for_parent(proposed_value:10)，不要保存。wait_for_checkpoint确认活动后，再尝试'
      'spawn_agent(task_name:worker)让它读取numbers求和保存total；该次应收到并发超限错误。'
      '再尝试send_message(target:unrelated_agent,message:边界测试)，确认无权限目标被拒绝。'
      'interrupt_agent停止blocked后，再次spawn_agent(task_name:worker)执行同一计算。'
      'wait_agent并inspect_tasks核验，最后只回复JSON {"total":数字}。',
  SubagentScenario.transportFault:
      '受控故障测试：启动worker子代理，读取numbers求和保存total。测试适配器会在该子代理'
      '第一次真实模型响应后注入一次连接失败。你wait_agent确认failed及连接错误，然后对同一'
      'worker用followup_task重新分配原任务。等待并inspect_tasks核验，最后只回复JSON {"total":数字}。',
};

const _numbers = {
  'numbers': [3, 7, 11],
  'left': [3, 7],
  'right': [11],
};

class _Fixture {
  _Fixture(this.store, this.file);
  final SessionStore store;
  final File file;
  final actions = <Map<String, Object?>>[];
  final artifacts = <String, Map<String, Object?>>{};
  final receipts = <String, ToolResult>{};
  final ready = Completer<void>();
  Future<void> writes = Future.value();
  int sequence = 0;

  void record(String kind, Map<String, Object?> details) {
    final action = {
      'sequence': ++sequence,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    };
    actions.add(action);
    stdout.writeln('ACTION $kind ${jsonEncode(details)}');
  }

  Future<Map<String, Object?>> actor(ToolContext context) async {
    final snapshot = (await store.read(context.sessionId))!;
    return {
      'agent_id': snapshot.id,
      'name': snapshot.agentState['name'] ?? '/root',
      'run_id': context.runId,
      'depth': snapshot.depth,
      'operation_id': context.operationId,
    };
  }

  AgentTool tool(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
    String? Function(Map<String, Object?>) validate,
    Future<ToolResult> Function(ToolCall, ToolContext) execute,
  ) => AgentTool(
    name: name,
    description: description,
    alwaysAvailable: true,
    parameters: {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
    validate: (args) => args.keys.any((k) => !properties.containsKey(k))
        ? 'Unknown argument'
        : validate(args),
    execute: execute,
    recover: (call, context) async => receipts[context.operationId] == null
        ? const ToolRecovery.notStarted()
        : ToolRecovery.completed(receipts[context.operationId]!),
  );

  List<AgentTool> get tools => [
    tool(
      'read_numbers',
      'Read a test dataset to calculate sum. missing is an unavailable source.',
      {
        'dataset': {
          'type': 'string',
          'enum': [..._numbers.keys, 'missing'],
        },
      },
      ['dataset'],
      (a) => [..._numbers.keys, 'missing'].contains(a['dataset'])
          ? null
          : 'Supply a known dataset',
      (call, context) async {
        context.cancellation.throwIfCancelled();
        final dataset = call.arguments['dataset'] as String;
        record('read', {...await actor(context), 'dataset': dataset});
        final result = dataset == 'missing'
            ? ToolResult(
                'Dataset unavailable; report this blocker to parent',
                isError: true,
                data: {'code': 'dataset_unavailable'},
              )
            : ToolResult(
                'Dataset',
                data: {'dataset': dataset, 'values': _numbers[dataset]},
              );
        receipts[context.operationId] = result;
        return result;
      },
    ),
    tool(
      'save_result',
      'Persist a numerical child result. Root must delegate writes. Values are not precomputed for you.',
      {
        'key': {
          'type': 'string',
          'enum': ['left', 'right', 'total', 'producer', 'consumer', 'chosen'],
        },
        'value': {'type': 'integer'},
      },
      ['key', 'value'],
      (a) =>
          a['value'] is int &&
              {
                'left',
                'right',
                'total',
                'producer',
                'consumer',
                'chosen',
              }.contains(a['key'])
          ? null
          : 'Supply key and integer value',
      (call, context) {
        final result = writes.then((_) async {
          if (receipts[context.operationId] case final cached?) {
            return cached;
          }
          context.cancellation.throwIfCancelled();
          final who = await actor(context);
          final key = call.arguments['key'] as String;
          final value = call.arguments['value'] as int;
          record('write_attempt', {...who, 'key': key, 'value': value});
          if (who['depth'] == 0) {
            return ToolResult(
              'Root must delegate result writes',
              isError: true,
            );
          }
          final saved = {...who, 'value': value};
          final next = {...artifacts, key: saved};
          await file.writeAsString(jsonEncode(next), flush: true);
          artifacts[key] = saved;
          record('commit', {...who, 'key': key, 'value': value});
          return receipts[context.operationId] = ToolResult(
            'Result saved',
            data: {'key': key, ...saved},
          );
        });
        writes = result.then<void>(
          (_) {},
          onError: (Object e, StackTrace s) {},
        );
        return result;
      },
    ),
    tool(
      'hold_for_parent',
      'Child checkpoint: record readiness and wait for a queued parent instruction or cancellation. '
          'The proposed value is NOT saved. Call this once, then follow the received parent instruction.',
      {
        'proposed_value': {'type': 'integer'},
      },
      ['proposed_value'],
      (a) => a['proposed_value'] is int ? null : 'Supply proposed_value',
      (call, context) async {
        final who = await actor(context);
        if (who['depth'] == 0) {
          return ToolResult('Child-only checkpoint', isError: true);
        }
        record('checkpoint_started', {
          ...who,
          'proposed_value': call.arguments['proposed_value'],
        });
        if (!ready.isCompleted) ready.complete();
        final watch = Stopwatch()..start();
        while (!context.cancellation.isCancelled &&
            watch.elapsed < const Duration(seconds: 90)) {
          final snapshot = (await store.read(context.sessionId))!;
          final inbox = snapshot.agentState['inbox'] as List? ?? const [];
          if (inbox.isNotEmpty) {
            record('checkpoint_released', {...who, 'messages': inbox});
            return receipts[context.operationId] = ToolResult(
              'Parent instruction arrived; apply it before saving',
              data: {'messages': inbox},
            );
          }
          await Future.any<void>([
            Future<void>.delayed(const Duration(milliseconds: 50)),
            context.cancellation.whenCancelled,
          ]);
        }
        final cancelled = context.cancellation.isCancelled;
        record(cancelled ? 'checkpoint_cancelled' : 'checkpoint_timeout', who);
        return receipts[context.operationId] = ToolResult(
          cancelled
              ? 'Checkpoint cancelled; nothing saved'
              : 'No parent instruction received',
          isError: true,
          data: {'code': cancelled ? 'cancelled' : 'checkpoint_timeout'},
        );
      },
    ),
    tool(
      'wait_for_checkpoint',
      'Parent waits until a child is actually inside hold_for_parent before steering or interrupting.',
      {},
      [],
      (a) => a.isEmpty ? null : 'No arguments',
      (call, context) async {
        final who = await actor(context);
        if (who['depth'] != 0) {
          return ToolResult('Root-only readiness wait', isError: true);
        }
        await Future.any<void>([
          ready.future,
          context.cancellation.whenCancelled,
          Future<void>.delayed(const Duration(seconds: 60)),
        ]);
        return ready.isCompleted
            ? ToolResult(
                'Child checkpoint is active',
                data: {
                  'checkpoints': actions
                      .where((a) => a['kind'] == 'checkpoint_started')
                      .toList(),
                },
              )
            : ToolResult('No active checkpoint', isError: true);
      },
    ),
    tool(
      'inspect_tasks',
      'Read persisted test artifacts for final verification. No writes.',
      {},
      [],
      (a) => a.isEmpty ? null : 'No arguments',
      (call, context) async {
        final disk = jsonDecode(await file.readAsString());
        record('inspect', {...await actor(context), 'artifacts': disk});
        return ToolResult('Persisted artifacts', data: {'artifacts': disk});
      },
    ),
  ];
}

class _FaultModel implements ModelAdapter {
  _FaultModel(this.model, this.fixture, {required this.enabled});
  final ModelAdapter model;
  final _Fixture fixture;
  final bool enabled;
  bool injected = false;
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final name =
        RegExp(
          r'Multi-agent collaboration: You are ([^\s]+)\. ',
        ).firstMatch(request.system)?.group(1) ??
        'unknown';
    final failThisRequest = enabled && !injected && name != '/root';
    await for (final event in model.stream(request, token)) {
      if (failThisRequest && event is ModelResponse) {
        injected = true;
        fixture.record('injected_transport_fault', {
          'name': name,
          'phase': 'after_actual_model_response_before_response_checkpoint',
          'response': event.text,
          'calls': event.calls.map((c) => c.toJson()).toList(),
        });
        throw const ModelConnectionException(
          kind: ModelConnectionKind.socket,
          stage: ModelConnectionStage.receiving,
        );
      }
      yield event;
    }
  }
}

Future<List<SessionSnapshot>> _tree(
  SessionStore store,
  SessionSnapshot root,
) async => [
  root,
  for (final id in root.childSessionIds)
    if (await store.read(id) case final child?) ...await _tree(store, child),
];

List<Map<String, Object?>> _coordination(List<SessionSnapshot> tree) => [
  for (final snapshot in tree)
    for (final message in snapshot.history)
      for (final call in message.calls)
        if ({
          'spawn_agent',
          'send_message',
          'followup_task',
          'wait_agent',
          'interrupt_agent',
        }.contains(call.name))
          for (final result in snapshot.history.where(
            (m) => m.role == MessageRole.tool && m.callId == call.id,
          ))
            {
              'agent_id': snapshot.id,
              'name': snapshot.agentState['name'] ?? '/root',
              'call': call.toJson(),
              'result': jsonDecode(result.text),
            },
];

Map<String, Object?>? _answerJson(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    return (jsonDecode(text.substring(start, end + 1)) as Map)
        .cast<String, Object?>();
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Runs one scenario with actual business artifacts and journaled coordination.
Future<Map<String, Object?>> validateSubagentScenario(
  ModelAdapter model,
  SubagentScenario scenario,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-${scenario.name}-',
  );
  final store = FileSessionStore(Directory('${directory.path}/sessions'));
  final fixture = _Fixture(store, File('${directory.path}/artifacts.json'));
  final trace = <Map<String, Object?>>[];
  final faultModel = _FaultModel(
    model,
    fixture,
    enabled: scenario == SubagentScenario.transportFault,
  );
  AgentRun? run;
  Timer? deadline;
  var timedOut = false;
  try {
    await fixture.file.writeAsString('{}', flush: true);
    final manager = SessionManager(
      model: LiveTraceModel(faultModel, trace),
      store: store,
      tools: fixture.tools,
      contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
      multiAgent: MultiAgentConfig(
        maxConcurrent: scenario == SubagentScenario.limits ? 1 : 3,
        maxDepth: scenario == SubagentScenario.nested ? 2 : 1,
        maxChildren: 4,
        childMaxTurns: 12,
        maxDelegatedTurns: 80,
      ),
    );
    final session = await manager.create(
      system:
          'Perform the controlled collaboration experiment using actual tools. '
          'Respect role boundaries and pass precise assignments. Reserve enough child turns '
          'for tool calls and final reports. Verify persisted artifacts and give the requested JSON.',
    );
    run = await manager.prompt(session.id, _prompts[scenario]!, maxTurns: 30);
    final current = run;
    deadline = Timer(const Duration(minutes: 4), () {
      timedOut = true;
      unawaited(current.cancel());
    });
    final result = await run.done;
    final tree = await _tree(store, result);
    final coordination = _coordination(tree);
    final rootCalls = coordination
        .where((a) => a['agent_id'] == result.id)
        .toList();
    final actions = fixture.actions;
    final expected = switch (scenario) {
      SubagentScenario.handoff => {'producer': 21, 'consumer': 42},
      SubagentScenario.activeFollowup ||
      SubagentScenario.interrupt => {'chosen': 15},
      _ => {'total': 21},
    };
    final summary = _answerJson(result.history.last.text);
    final disk = (jsonDecode(await fixture.file.readAsString()) as Map)
        .cast<String, Object?>();
    bool valuesMatch(Map<String, Object?> values) => expected.entries.every(
      (e) => values[e.key] is Map && (values[e.key] as Map)['value'] == e.value,
    );
    List<Map<String, Object?>> calls(String name, {bool successful = true}) =>
        rootCalls
            .where(
              (a) =>
                  (a['call'] as Map)['name'] == name &&
                  ((a['result'] as Map)['isError'] != true) == successful,
            )
            .toList();
    final checks = <String, bool>{
      'rootCompleted': result.status == RunStatus.completed && !timedOut,
      'singleUserRequest':
          result.history
              .where((m) => m.role == MessageRole.user && !m.runtimeNotice)
              .length ==
          1,
      'allDescendantsSettled':
          tree.length > 1 &&
          tree
              .skip(1)
              .every(
                (s) => {
                  RunStatus.completed,
                  RunStatus.cancelled,
                }.contains(s.status),
              ),
      'childArtifactsCorrectOnDisk': valuesMatch(disk),
      'rootVerifiedFinalArtifacts': actions.any(
        (a) =>
            a['kind'] == 'inspect' &&
            a['agent_id'] == result.id &&
            valuesMatch((a['artifacts'] as Map).cast<String, Object?>()),
      ),
      'summaryMatchesActualResults':
          summary != null &&
          expected.entries.every((e) => summary[e.key] == e.value),
      'noRootWrites': actions
          .where((a) => a['kind'] == 'commit')
          .every((a) => a['depth'] != 0),
    };
    final followups = calls('followup_task');
    final held = actions
        .where((a) => a['kind'] == 'checkpoint_started')
        .firstOrNull;
    final released = actions
        .where((a) => a['kind'] == 'checkpoint_released')
        .firstOrNull;
    final cancelled = actions
        .where((a) => a['kind'] == 'checkpoint_cancelled')
        .firstOrNull;
    switch (scenario) {
      case SubagentScenario.nested:
        final leaves = tree.where((s) => s.depth == 2).toList();
        checks['twoGrandchildrenUnderOneLeader'] =
            result.childSessionIds.length == 1 &&
            leaves.length == 2 &&
            leaves.every(
              (s) => s.parentSessionId == result.childSessionIds.single,
            );
        checks['independentLeafWriters'] =
            disk['left'] is Map &&
            disk['right'] is Map &&
            (disk['left'] as Map)['depth'] == 2 &&
            (disk['right'] as Map)['depth'] == 2 &&
            (disk['left'] as Map)['agent_id'] !=
                (disk['right'] as Map)['agent_id'];
        checks['leaderWroteCombinedResult'] =
            disk['total'] is Map &&
            (disk['total'] as Map)['agent_id'] ==
                result.childSessionIds.singleOrNull;
      case SubagentScenario.handoff:
        final forwarding = calls('send_message');
        checks['actualParentRelayToWaitingConsumer'] =
            held != null &&
            released != null &&
            forwarding.any(
              (a) =>
                  ((a['result'] as Map)['data'] as Map)['agent_id'] ==
                  held['agent_id'],
            ) &&
            actions.any(
              (a) =>
                  a['kind'] == 'commit' &&
                  a['key'] == 'consumer' &&
                  a['agent_id'] == held['agent_id'] &&
                  (a['sequence'] as int) > (released['sequence'] as int),
            );
        checks['distinctProducerAndConsumer'] =
            disk['producer'] is Map &&
            disk['consumer'] is Map &&
            (disk['producer'] as Map)['agent_id'] !=
                (disk['consumer'] as Map)['agent_id'];
      case SubagentScenario.activeFollowup:
        checks['steeredActiveRunInPlace'] =
            held != null &&
            released != null &&
            cancelled == null &&
            followups.any(
              (a) =>
                  ((a['result'] as Map)['data'] as Map)['run_id'] ==
                  held['run_id'],
            ) &&
            actions.any(
              (a) =>
                  a['kind'] == 'commit' &&
                  a['run_id'] == held['run_id'] &&
                  a['agent_id'] == held['agent_id'] &&
                  a['value'] == 15,
            );
        checks['oldGoalNeverAttempted'] = actions
            .where((a) => a['kind'] == 'write_attempt')
            .every((a) => a['value'] == 15);
      case SubagentScenario.interrupt:
        checks['cancelledActualActiveCheckpoint'] =
            held != null &&
            cancelled != null &&
            released == null &&
            calls('interrupt_agent').any(
              (a) =>
                  ((a['result'] as Map)['data'] as Map)['status'] ==
                  'cancelled',
            );
        checks['sameChildNewRunAppliedReplacement'] =
            held != null &&
            followups.isNotEmpty &&
            actions.any(
              (a) =>
                  a['kind'] == 'commit' &&
                  a['agent_id'] == held['agent_id'] &&
                  a['run_id'] != held['run_id'] &&
                  a['value'] == 15,
            );
        checks['oldGoalNeverAttempted'] = actions
            .where((a) => a['kind'] == 'write_attempt')
            .every((a) => a['value'] == 15);
      case SubagentScenario.recovery:
        final failedRead = actions
            .where((a) => a['kind'] == 'read' && a['dataset'] == 'missing')
            .firstOrNull;
        checks['parentReassignedSameChildAfterDatasetError'] =
            failedRead != null &&
            followups.isNotEmpty &&
            actions.any(
              (a) =>
                  a['kind'] == 'commit' &&
                  a['key'] == 'total' &&
                  a['agent_id'] == failedRead['agent_id'] &&
                  a['run_id'] != failedRead['run_id'],
            );
      case SubagentScenario.limits:
        checks['concurrencyLimitRejectedBeforeCreation'] =
            calls('spawn_agent', successful: false).any(
              (a) => ((a['result'] as Map)['text'] as String).contains(
                'concurrency',
              ),
            ) &&
            result.childSessionIds.length == 2;
        checks['unauthorizedTargetRejected'] =
            calls('send_message', successful: false).any(
              (a) => ((a['result'] as Map)['text'] as String).contains(
                'unauthorized',
              ),
            );
        checks['freedSlotThenStartedWorker'] =
            cancelled != null &&
            calls('interrupt_agent').isNotEmpty &&
            actions.any(
              (a) =>
                  a['kind'] == 'commit' &&
                  (a['sequence'] as int) > (cancelled['sequence'] as int),
            );
      case SubagentScenario.transportFault:
        checks['faultInjectedAfterActualChildResponse'] =
            faultModel.injected &&
            actions
                    .where((a) => a['kind'] == 'injected_transport_fault')
                    .length ==
                1;
        checks['parentObservedFailureThenReassigned'] =
            followups.isNotEmpty &&
            calls('wait_agent').any(
              (a) => (((a['result'] as Map)['data'] as Map)['agents'] as List)
                  .any((s) => (s as Map)['status'] == 'failed'),
            );
    }
    return {
      'scenario': scenario.name,
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'prompt': _prompts[scenario],
      'parentStatus': result.status.name,
      'parentError': result.error,
      'finalAnswer': result.history.last.text,
      'artifacts': disk,
      'resourceActions': actions,
      'coordination': coordination,
      'modelTrace': trace,
      'sessions': [
        for (final s in tree)
          {
            'id': s.id,
            'runId': s.runId,
            'name': s.agentState['name'] ?? '/root',
            'depth': s.depth,
            'status': s.status.name,
            'parentSessionId': s.parentSessionId,
            'parentRunId': s.parentRunId,
            'childSessionIds': s.childSessionIds,
            'messages': s.history.map((m) => m.toJson()).toList(),
          },
      ],
    };
  } finally {
    deadline?.cancel();
    if (run != null && !run.isSettled) await run.cancel();
    await directory.delete(recursive: true);
  }
}

/// Runs selected experiments independently, retaining failures alongside passes.
Future<Map<String, Object?>> validateSubagentMatrix(
  ModelAdapter model, {
  List<SubagentScenario> scenarios = SubagentScenario.values,
}) async {
  final reports = <Map<String, Object?>>[];
  for (final scenario in scenarios) {
    stdout.writeln('SCENARIO_START ${scenario.name}');
    final watch = Stopwatch()..start();
    Map<String, Object?> report;
    try {
      report = await validateSubagentScenario(model, scenario);
    } catch (error) {
      report = {
        'scenario': scenario.name,
        'passed': false,
        'error': error.toString(),
      };
    }
    report['elapsedMs'] = watch.elapsedMilliseconds;
    reports.add(report);
    stdout.writeln(
      'SCENARIO_RESULT ${scenario.name} ${report['passed']} ${jsonEncode(report['checks'])}',
    );
  }
  return {
    'passed': reports.isNotEmpty && reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports) r['scenario']! as String: r['passed'] == true,
    },
    'finalAnswer': reports
        .map(
          (r) => '${r['scenario']}: ${r['passed'] == true ? 'PASS' : 'FAIL'}',
        )
        .join(', '),
    'scenarios': reports,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  (model) => validateSubagentMatrix(
    model,
    scenarios: args.length <= 1
        ? SubagentScenario.values
        : args.skip(1).map(SubagentScenario.values.byName).toList(),
  ),
  label: 'LIVE_SUBAGENT_MATRIX',
);
