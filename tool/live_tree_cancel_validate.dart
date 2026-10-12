import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;

const treeCancelPrompt =
    '这是主代理取消的受控测试。你先创建一个leader子代理；leader必须再创建writer_a和writer_b'
    '两个孙代理，分别调用gated_write(key:a,value:10)和gated_write(key:b,value:20)，'
    '写工具会等待测试宿主放行，调用成功后再用append_extra给同一key追加一次写入。'
    'leader必须启动两个孙代理后再wait_agent，你等待leader。不要自己写资源，不要主动中断。'
    '测试宿主会在两个孙代理的写工具都已启动、尚未提交时取消你的根Run；届时响应取消即可。';

/// Shared cancellable file resource for tree cancellation validation scenarios.
class TreeCancelResource {
  TreeCancelResource(this.store, this.file, {required this.honorsCancellation});
  final SessionStore store;
  final File file;
  final bool honorsCancellation;
  final bothReady = Completer<void>();
  final release = Completer<void>();
  final active = <String, Map<String, Object?>>{};
  final actions = <Map<String, Object?>>[];
  final receipts = <String, ToolResult>{};
  final entries = <Map<String, Object?>>[
    {'key': 'existing', 'value': 99},
  ];
  int sequence = 0;
  int revision = 1;

  Map<String, Object?> get state => {'revision': revision, 'entries': entries};
  void record(String kind, Map<String, Object?> details) {
    actions.add({
      'sequence': ++sequence,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    stdout.writeln('TREE_CANCEL $kind ${jsonEncode(details)}');
  }

  Future<Map<String, Object?>> actor(ToolContext context) async {
    final snapshot = (await store.read(context.sessionId))!;
    return {
      'agent_id': snapshot.id,
      'name': snapshot.agentState['name'] ?? '/root',
      'depth': snapshot.depth,
      'run_id': context.runId,
      'operation_id': context.operationId,
    };
  }

  ToolResult commit(
    Map<String, Object?> who,
    ToolCall call,
    ToolContext context,
  ) {
    record('write_attempt', {
      ...who,
      'key': call.arguments['key'],
      'tool': call.name,
      'token_cancelled': context.cancellation.isCancelled,
    });
    // No global cancellation flag or ancestry check: cancellation must arrive
    // through this operation's actual token before the final commit boundary.
    if (honorsCancellation && context.cancellation.isCancelled) {
      record('write_cancelled', who);
      return receipts[context.operationId] = ToolResult(
        'Cancelled before commit; no write',
        isError: true,
        data: {'code': 'cancelled', 'executed': false},
      );
    }
    final entry = {
      'key': call.arguments['key'],
      'value': call.arguments['value'],
      'tool': call.name,
      'agent_id': who['agent_id'],
      'run_id': who['run_id'],
    };
    // Small synchronous test commit makes the precommit cancellation race
    // observable without an unrelated async filesystem read hiding the window.
    file.writeAsStringSync(
      jsonEncode({
        'revision': revision + 1,
        'entries': [...entries, entry],
      }),
      flush: true,
    );
    revision++;
    entries.add(entry);
    record('commit', {...who, ...entry, 'revision': revision});
    return receipts[context.operationId] = ToolResult('Committed', data: entry);
  }

  AgentTool tool(
    String name,
    Future<ToolResult> Function(ToolCall, ToolContext) execute,
  ) => AgentTool(
    name: name,
    alwaysAvailable: true,
    description: name == 'gated_write'
        ? 'Prepare an actual grandchild write, then wait for test host release or cancellation. '
              'No value is committed before release. Do not wait before creating both writer grandchildren.'
        : 'Append another grandchild write only after gated_write succeeded.',
    parameters: {
      'type': 'object',
      'properties': {
        'key': {
          'type': 'string',
          'enum': ['a', 'b'],
        },
        'value': {'type': 'integer'},
      },
      'required': ['key', 'value'],
      'additionalProperties': false,
    },
    validate: (a) =>
        a.length == 2 && {'a', 'b'}.contains(a['key']) && a['value'] is int
        ? null
        : 'Supply key a/b and integer value',
    execute: execute,
    recover: (call, context) async => receipts[context.operationId] == null
        ? const ToolRecovery.notStarted()
        : ToolRecovery.completed(receipts[context.operationId]!),
  );

  List<AgentTool> get tools => [
    tool('gated_write', (call, context) async {
      final who = await actor(context);
      if (who['depth'] != 2) {
        return ToolResult('Grandchild-only write', isError: true);
      }
      active[context.sessionId] = who;
      record('write_started', {...who, 'key': call.arguments['key']});
      unawaited(
        context.cancellation.whenCancelled.then(
          (_) => record('token_cancelled', who),
        ),
      );
      if (active.length == 2 && !bothReady.isCompleted) bothReady.complete();
      if (honorsCancellation) {
        await Future.any<void>([
          release.future,
          context.cancellation.whenCancelled,
        ]);
      } else {
        await release.future;
      }
      final result = commit(who, call, context);
      active.remove(context.sessionId);
      return result;
    }),
    tool('append_extra', (call, context) async {
      final who = await actor(context);
      if (who['depth'] != 2) {
        return ToolResult('Grandchild-only write', isError: true);
      }
      return commit(who, call, context);
    }),
  ];
}

/// Reads the current snapshots for a root and its recorded descendants.
Future<List<SessionSnapshot>> readCancellationTree(
  SessionStore store,
  SessionSnapshot parent,
) async => [
  parent,
  for (final id in parent.childSessionIds)
    if (await store.read(id) case final child?)
      ...await readCancellationTree(store, child),
];

/// Cancels only the root after two actual grandchild write operations start.
///
/// [releaseWithCancel] also releases the commit gate in the cancellation turn.
/// [honorsCancellation] can disable tool cooperation for a negative control;
/// neither mode adds an artificial root-level write guard.
Future<Map<String, Object?>> validateTreeCancellation(
  ModelAdapter model, {
  bool releaseWithCancel = false,
  bool honorsCancellation = true,
  Duration observation = const Duration(seconds: 3),
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-tree-cancel-',
  );
  final sessions = Directory('${directory.path}/sessions');
  final store = FileSessionStore(sessions);
  final fixture = TreeCancelResource(
    store,
    File('${directory.path}/resource.json'),
    honorsCancellation: honorsCancellation,
  );
  final trace = <Map<String, Object?>>[];
  final traced = LiveTraceModel(model, trace);
  SessionManager managerFor(SessionStore storage) => SessionManager(
    model: traced,
    store: storage,
    tools: fixture.tools,
    contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
    multiAgent: MultiAgentConfig(
      maxConcurrent: 3,
      maxDepth: 2,
      maxChildren: 4,
      childMaxTurns: 12,
      maxDelegatedTurns: 80,
    ),
  );
  AgentRun? run;
  var setupTimedOut = false;
  Timer? setupDeadline;
  final timeout = Completer<void>();
  try {
    await fixture.file.writeAsString(jsonEncode(fixture.state), flush: true);
    final initialDisk = jsonDecode(await fixture.file.readAsString());
    final manager = managerFor(store);
    final session = await manager.create(
      system:
          'Use model-directed delegation for this controlled root-cancellation experiment. '
          'The leader must spawn both grandchildren before waiting. All writes belong '
          'to grandchildren. Do not interrupt or create substitute tasks.',
    );
    run = await manager.prompt(session.id, treeCancelPrompt, maxTurns: 30);
    setupDeadline = Timer(const Duration(seconds: 120), () {
      setupTimedOut = true;
      timeout.complete();
    });
    await Future.any<void>([
      fixture.bothReady.future,
      run.done.then<void>((_) {}),
      timeout.future,
    ]);
    setupDeadline.cancel();
    final before = await readCancellationTree(
      store,
      (await store.read(session.id))!,
    );
    final leaves = before.where((s) => s.depth == 2).toList();
    final leaders = before.where((s) => s.depth == 1).toList();
    final diskAtCancel = jsonDecode(await fixture.file.readAsString());
    final checks = <String, bool>{
      'modelCreatedFullTree':
          before.length == 4 &&
          leaders.length == 1 &&
          leaves.length == 2 &&
          leaders.single.parentSessionId == session.id &&
          leaves.every(
            (s) =>
                s.parentSessionId == leaders.single.id &&
                s.parentRunId == leaders.single.runId,
          ),
      'allAgentsActiveAtCancel':
          !run.isSettled && before.every((s) => s.status == RunStatus.running),
      'bothGrandchildWritesActuallyStarted':
          fixture.active.length == 2 &&
          leaves.length == 2 &&
          leaves.every(
            (s) => s.pending.any(
              (c) =>
                  c.call.name == 'gated_write' &&
                  c.status == CallStatus.started,
            ),
          ),
      'noCommitBeforeCancellation':
          jsonEncode(initialDisk) == jsonEncode(diskAtCancel),
    };
    fixture.record('root_cancel_requested', {
      'agent_id': session.id,
      'release_with_cancel': releaseWithCancel,
    });
    final cancelSequence = fixture.sequence;
    final callsAtCancel = trace.length;
    final stopWatch = Stopwatch()..start();
    final cancelled = run.cancel();
    if (releaseWithCancel || !honorsCancellation) fixture.release.complete();
    final result = await cancelled.timeout(const Duration(seconds: 30));
    final cancellationMs = stopWatch.elapsedMilliseconds;
    fixture.record('root_cancel_settled', {
      'agent_id': session.id,
      'elapsed_ms': cancellationMs,
    });
    final settledSequence = fixture.sequence;
    if (!fixture.release.isCompleted) fixture.release.complete();
    final after = await readCancellationTree(store, result);
    final diskAfter = jsonDecode(await fixture.file.readAsString());
    final callsAfterCancel = trace.length;
    final observed = <Map<String, Object?>>[];
    final watch = Stopwatch()..start();
    while (watch.elapsed < observation) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      observed.add({
        'elapsed_ms': watch.elapsedMilliseconds,
        'resource': jsonDecode(await fixture.file.readAsString()),
        'model_requests': trace.length,
      });
    }
    final reopened = managerFor(FileSessionStore(sessions));
    final resumed = await reopened.resume(session.id);
    final reconciled = await resumed.done;
    final restoredTree = await readCancellationTree(store, reconciled);
    final finalDisk = jsonDecode(await fixture.file.readAsString());
    checks.addAll({
      'entireTreeCancelled':
          after.length == 4 &&
          after.every((s) => s.status == RunStatus.cancelled),
      'bothGrandchildTokensCancelled':
          fixture.actions
              .where((a) => a['kind'] == 'token_cancelled')
              .map((a) => a['agent_id'])
              .toSet()
              .length ==
          2,
      'allPendingCallsReconciled': after.every((s) => s.pending.isEmpty),
      'noCommitsAfterCancelRequested': !fixture.actions.any(
        (a) => a['kind'] == 'commit' && (a['sequence'] as int) > cancelSequence,
      ),
      'noCommitsAfterCancellationSettled': !fixture.actions.any(
        (a) =>
            a['kind'] == 'commit' && (a['sequence'] as int) > settledSequence,
      ),
      'resourceUnchangedAfterCancellation':
          jsonEncode(diskAfter) == jsonEncode(diskAtCancel),
      'stableDuringObservation': observed.every(
        (s) =>
            jsonEncode(s['resource']) == jsonEncode(diskAfter) &&
            s['model_requests'] == callsAfterCancel,
      ),
      'noNewModelRequestsAfterCancel': trace.length == callsAtCancel,
      'restartResumeRemainsCancelled':
          restoredTree.length == 4 &&
          restoredTree.every((s) => s.status == RunStatus.cancelled),
      'restartResumeDoesNoWrites':
          jsonEncode(finalDisk) == jsonEncode(diskAfter),
      'originalResourcePreserved':
          ((finalDisk as Map)['entries'] as List).first['key'] == 'existing' &&
          ((finalDisk['entries'] as List).first as Map)['value'] == 99,
      'setupCompletedWithoutTimeout': !setupTimedOut,
    });
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'releaseWithCancel': releaseWithCancel,
      'toolHonorsCancellation': honorsCancellation,
      'prompt': treeCancelPrompt,
      'parentStatus': result.status.name,
      'cancellationMs': cancellationMs,
      'modelCallsAtCancel': callsAtCancel,
      'modelCallsAfterCancel': trace.length,
      'observationMs': watch.elapsedMilliseconds,
      'observationSamples': observed,
      'initialResource': initialDisk,
      'resourceAtCancel': diskAtCancel,
      'finalResource': finalDisk,
      'resourceActions': fixture.actions,
      'modelTrace': trace,
      'sessionsBeforeCancel': [
        for (final s in before)
          {
            'id': s.id,
            'name': s.agentState['name'] ?? '/root',
            'status': s.status.name,
            'depth': s.depth,
            'pending': s.pending.map((c) => c.toJson()).toList(),
          },
      ],
      'sessionsAfterCancel': [
        for (final s in restoredTree)
          {
            'id': s.id,
            'name': s.agentState['name'] ?? '/root',
            'status': s.status.name,
            'stopRequested': s.stopRequested,
            'depth': s.depth,
            'parentSessionId': s.parentSessionId,
            'parentRunId': s.parentRunId,
            'runId': s.runId,
            'pending': s.pending.map((c) => c.toJson()).toList(),
            'messages': s.history.map((m) => m.toJson()).toList(),
          },
      ],
      'finalAnswer':
          'Root ${result.status.name}; tree=${after.map((s) => s.status.name).join(',')}; resource=${jsonEncode(finalDisk)}',
    };
  } finally {
    setupDeadline?.cancel();
    if (!fixture.release.isCompleted) fixture.release.complete();
    if (run != null && !run.isSettled) await run.cancel();
    await directory.delete(recursive: true);
  }
}

/// Tests ordinary cancellation and simultaneous release of a precommit gate.
Future<Map<String, Object?>> validateTreeCancellationModes(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final race in [false, true]) {
    stdout.writeln(
      'TREE_CANCEL_MODE ${race ? 'simultaneous_release' : 'normal'}',
    );
    reports.add(await validateTreeCancellation(model, releaseWithCancel: race));
  }
  return {
    'passed': reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports)
        r['releaseWithCancel'] == true ? 'simultaneousRelease' : 'normal':
            r['passed'] == true,
    },
    'cases': reports,
    'finalAnswer': reports
        .map(
          (r) =>
              '${r['releaseWithCancel'] == true ? 'race' : 'normal'}: ${r['passed']}',
        )
        .join(', '),
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateTreeCancellationModes,
  label: 'LIVE_TREE_CANCEL',
);
