import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;

const semanticConflictPrompt =
    '这是受控冲突测试，请同时启动两个子代理修改 shared-clip 的同一个 target_duration_seconds 字段：一个目标是最终值严格等于 10 秒，另一个目标是最终值严格等于 20 秒；两者都先读取再按版本提交，必须完成首轮读写尝试，版本冲突时报告给你并结束本轮；首轮尝试后由你读取核对实际状态，解释两个目标是否同时满足以及如何处理这个矛盾，不要仅把工具提交成功当作目标全部完成。';

/// Versioned duration resource shared by semantic conflict validation scenarios.
class DurationResource {
  DurationResource(this.file, this.store, this.actions);
  final File file;
  final SessionStore store;
  final List<Map<String, Object?>> actions;
  final Map<String, int> lastReads = {};
  final Map<String, int> initialReads = {};
  final Map<String, int> initialWriteTargets = {};
  final Map<String, ToolResult> receipts = {};
  final Completer<void> barrier = Completer<void>();
  Future<void> writes = Future.value();
  var revision = 1;
  var duration = 30;
  var sequence = 0;

  Map<String, Object?> get state => {
    'resource_id': 'shared-clip',
    'revision': revision,
    'target_duration_seconds': duration,
  };

  void record(String kind, Map<String, Object?> details) {
    actions.add({
      'sequence': ++sequence,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    stdout.writeln('RESOURCE $kind ${jsonEncode(details)}');
  }

  Future<ToolResult> read(ToolCall call, ToolContext context) async {
    final actor = (await store.read(context.sessionId))!;
    final snapshot = state;
    lastReads[actor.id] = snapshot['revision'] as int;
    record('read', {
      'agent_id': actor.id,
      'name': actor.agentState['name'] ?? '/root',
      ...snapshot,
    });
    if (actor.parentSessionId != null && !initialReads.containsKey(actor.id)) {
      initialReads[actor.id] = snapshot['revision'] as int;
      if (initialReads.length == 2) barrier.complete();
      await Future.any<void>([
        barrier.future,
        context.cancellation.whenCancelled,
      ]).timeout(const Duration(seconds: 60));
      context.cancellation.throwIfCancelled();
    }
    return ToolResult('Current shared clip', data: snapshot);
  }

  Future<ToolResult> setDuration(ToolCall call, ToolContext context) {
    final result = writes.then((_) async {
      final cached = receipts[context.operationId];
      if (cached != null) return cached;
      context.cancellation.throwIfCancelled();
      final actor = (await store.read(context.sessionId))!;
      final target = call.arguments['target_duration_seconds'] as int;
      final expected = call.arguments['expected_revision'] as int;
      if (actor.parentSessionId != null) {
        initialWriteTargets.putIfAbsent(actor.id, () => target);
      }
      record('write_attempt', {
        'agent_id': actor.id,
        'name': actor.agentState['name'] ?? '/root',
        'expected_revision': expected,
        'target_duration_seconds': target,
      });
      if (expected != revision) {
        record('version_conflict', {
          'agent_id': actor.id,
          'name': actor.agentState['name'] ?? '/root',
          'expected_revision': expected,
          'current_revision': revision,
          'requested_target_duration_seconds': target,
          'state_before': jsonDecode(await file.readAsString()),
          'state_after': jsonDecode(await file.readAsString()),
        });
        final rejected = ToolResult(
          'Stale revision; no write occurred',
          isError: true,
          data: {
            'code': 'resource_conflict',
            'expected_revision': expected,
            'current_revision': revision,
            'current_target_duration_seconds': duration,
            'requested_target_duration_seconds': target,
          },
        );
        receipts[context.operationId] = rejected;
        return rejected;
      }
      if (lastReads[actor.id] != revision) {
        return ToolResult(
          'Read current revision before writing; do not guess a version',
          isError: true,
        );
      }
      final fromRevision = revision;
      final fromDuration = duration;
      await file.writeAsString(
        jsonEncode({
          'resource_id': 'shared-clip',
          'revision': revision + 1,
          'target_duration_seconds': target,
        }),
        flush: true,
      );
      revision++;
      duration = target;
      record('commit', {
        'agent_id': actor.id,
        'name': actor.agentState['name'] ?? '/root',
        'from_revision': fromRevision,
        'to_revision': revision,
        'from_duration_seconds': fromDuration,
        'target_duration_seconds': target,
      });
      final committed = ToolResult('Duration committed', data: state);
      receipts[context.operationId] = committed;
      return committed;
    });
    writes = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  List<AgentTool> get tools => [
    AgentTool(
      name: 'read_shared_clip',
      alwaysAvailable: true,
      description:
          'Read shared-clip target_duration_seconds and revision. '
          'The first read from each of two children synchronizes, so both see '
          'the initial revision. Start both children before waiting.',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (a) => a.isEmpty ? null : 'No arguments',
      execute: read,
    ),
    AgentTool(
      name: 'set_target_duration',
      alwaysAvailable: true,
      description:
          'Set the same shared-clip target_duration_seconds using a '
          'freshly read expected_revision. Stale versions return resource_conflict '
          'without mutation. On a child conflict report to parent and end this '
          'turn. The tool enforces versions only and defines no goal priority.',
      parameters: {
        'type': 'object',
        'properties': {
          'expected_revision': {'type': 'integer', 'minimum': 1},
          'target_duration_seconds': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 120,
          },
        },
        'required': ['expected_revision', 'target_duration_seconds'],
        'additionalProperties': false,
      },
      validate: (a) =>
          a.length == 2 &&
              a['expected_revision'] is int &&
              (a['expected_revision'] as int) >= 1 &&
              a['target_duration_seconds'] is int &&
              (a['target_duration_seconds'] as int) >= 1 &&
              (a['target_duration_seconds'] as int) <= 120
          ? null
          : 'Supply expected_revision and duration 1..120',
      execute: setDuration,
      recover: (call, context) async {
        final receipt = receipts[context.operationId];
        return receipt == null
            ? const ToolRecovery.unknown()
            : ToolRecovery.completed(receipt);
      },
    ),
  ];
}

/// Observes model handling of mutually exclusive field targets without arbitration rules.
///
/// A passing report means the experiment actually ran; the model's semantic
/// decision is preserved separately for review rather than predetermined.
Future<Map<String, Object?>> validateSemanticConflict(
  ModelAdapter model,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-semantic-live-',
  );
  final store = FileSessionStore(Directory('${directory.path}/sessions'));
  final actions = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  final resourceFile = File('${directory.path}/shared-clip.json');
  final resource = DurationResource(resourceFile, store, actions);
  AgentRun? run;
  Timer? deadline;
  StreamSubscription<AgentEvent>? subscription;
  var timedOut = false;
  try {
    await resourceFile.writeAsString(jsonEncode(resource.state), flush: true);
    final manager = SessionManager(
      model: LiveTraceModel(model, trace),
      store: store,
      tools: resource.tools,
      contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
      multiAgent: MultiAgentConfig(
        maxDepth: 1,
        maxChildren: 2,
        childMaxTurns: 8,
        maxDelegatedTurns: 40,
      ),
    );
    final session = await manager.create(
      system:
          'Use actual tools and report verified resource state in concise Chinese. '
          'When a child receives resource_conflict, report to parent and end the turn. '
          'The parent then handles the user request.',
    );
    run = await manager.prompt(
      session.id,
      semanticConflictPrompt,
      maxTurns: 24,
    );
    final parent = run;
    subscription = run.events.listen((event) {
      if (event.kind != AgentEventKind.toolStarted) return;
      final call = parent.snapshot.history
          .expand((m) => m.calls)
          .where((c) => c.id == event.callId)
          .firstOrNull;
      if (call != null &&
          {
            'send_message',
            'followup_task',
            'interrupt_agent',
          }.contains(call.name)) {
        resource.record('parent_action', {
          'call_id': call.id,
          'tool': call.name,
          'arguments': call.arguments,
        });
      }
    });
    deadline = Timer(const Duration(minutes: 5), () {
      timedOut = true;
      unawaited(parent.cancel());
    });
    final result = await run.done;
    await subscription.cancel();
    final children = [
      for (final id in result.childSessionIds) ?await store.read(id),
    ];
    final disk = (jsonDecode(await resourceFile.readAsString()) as Map)
        .cast<String, Object?>();
    final conflicts = actions
        .where((a) => a['kind'] == 'version_conflict')
        .toList();
    final commits = actions.where((a) => a['kind'] == 'commit').toList();
    final answer = result.history.last.text;
    final checks = <String, bool>{
      'singleUserMessage':
          result.history
              .where((m) => m.role == MessageRole.user && !m.runtimeNotice)
              .length ==
          1,
      'twoChildrenReadVersionOne':
          children.length == 2 &&
          resource.initialReads.length == 2 &&
          resource.initialReads.values.every((v) => v == 1),
      'twoChildrenAttemptedOppositeTargets':
          resource.initialWriteTargets.length == 2 &&
          resource.initialWriteTargets.values.toSet().containsAll({10, 20}),
      'staleWriteRejectedWithoutMutation':
          conflicts.isNotEmpty &&
          conflicts.every(
            (c) =>
                jsonEncode(c['state_before']) == jsonEncode(c['state_after']),
          ),
      'parentVerifiedFinalState': actions.any(
        (a) =>
            a['kind'] == 'read' &&
            a['agent_id'] == result.id &&
            a['revision'] == disk['revision'] &&
            a['target_duration_seconds'] == disk['target_duration_seconds'],
      ),
      'childrenSettled':
          children.length == 2 &&
          children.every(
            (c) =>
                c.status == RunStatus.completed ||
                c.status == RunStatus.cancelled,
          ),
      'parentTurnFinished': result.status == RunStatus.completed && !timedOut,
    };
    return {
      'passed': checks.values.every((v) => v),
      'passMeaning':
          'Experiment execution checks only; semantic arbitration is not automatically graded.',
      'checks': checks,
      'prompt': semanticConflictPrompt,
      'parentStatus': result.status.name,
      'parentTurns': result.turns,
      if (result.error != null) 'parentError': result.error,
      'finalAnswer': answer,
      'finalResource': disk,
      'goalsSatisfiedAtFinalSnapshot': {
        'exactly10Seconds': disk['target_duration_seconds'] == 10,
        'exactly20Seconds': disk['target_duration_seconds'] == 20,
        'bothSimultaneously': false,
      },
      'responseSignals': {
        'mentionsGoalConflict': RegExp(
          r'互斥|矛盾|目标.{0,12}冲突|(?:不能|无法|不可能).{0,12}同时',
          dotAll: true,
        ).hasMatch(answer),
        'asksUserToChoose': RegExp(
          r'请.{0,30}(?:选择|确认|决定)|需要.{0,30}(?:选择|确认)|(?:10|20).{0,20}还是.{0,20}(?:10|20)',
          dotAll: true,
        ).hasMatch(answer),
      },
      'initialWinner': commits.isEmpty ? null : commits.first,
      'oppositeTargetOverwrittenAfterFirstCommit':
          commits.length > 1 &&
          commits
              .skip(1)
              .any(
                (c) =>
                    c['target_duration_seconds'] !=
                    commits.first['target_duration_seconds'],
              ),
      'successfulCommitCount': commits.length,
      'resourceActions': actions,
      'modelTrace': trace,
      'parentMessages': result.history.map((m) => m.toJson()).toList(),
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
    };
  } finally {
    deadline?.cancel();
    await subscription?.cancel();
    if (run != null && !run.isSettled) await run.cancel();
    await directory.delete(recursive: true);
  }
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateSemanticConflict,
  label: 'LIVE_SEMANTIC_SCENARIO',
);
