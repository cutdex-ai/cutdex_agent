import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;
import 'live_tree_cancel_validate.dart' show readCancellationTree;

const uncooperativeOldMarker = 'UNCOOPERATIVE_OLD_TASK';
const uncooperativeNewMarker = 'UNCOOPERATIVE_NEW_TASK';
const delayedResultMarker = 'OLD_DELAYED_TOOL_RESULT';

/// Distinguishes tracked pending tool work from detached external side effects.
enum UncooperativeMode { pendingResult, pendingWrite, detachedWrite }

/// Runs real delegation while deliberately making an old tool ignore its token.
///
/// Without [guarded], a detached write is an intentional negative control.
/// With [guarded], the same write attempts use the library's generation guard.
/// A passing experiment means the outcome matches the actual file.
Future<Map<String, Object?>> validateUncooperativeCancellation(
  ModelAdapter model, {
  required UncooperativeMode mode,
  bool guarded = false,
  int oldWriterDepth = 2,
}) async {
  if (oldWriterDepth != 1 && oldWriterDepth != 2) {
    throw ArgumentError('Old writer depth must be 1 or 2');
  }
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-uncooperative-',
  );
  final store = FileSessionStore(Directory('${directory.path}/sessions'));
  final file = File('${directory.path}/shared.json');
  final ready = Completer<void>();
  final rootHeld = Completer<void>();
  final delayed = Completer<void>();
  final detached = Completer<void>();
  final actions = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];
  final guard = guarded ? ResourceCommitGuard() : null;
  var phase = 'old';
  var sequence = 0;
  var value = 99;
  var revision = 1;
  var detachedScheduled = false;
  Future<void>? background;
  AgentRun? old;
  AgentRun? fresh;
  Timer? deadline;
  var timedOut = false;
  void record(String kind, [Map<String, Object?> details = const {}]) {
    actions.add({
      'sequence': ++sequence,
      'at': DateTime.now().toUtc().toIso8601String(),
      'phase': phase,
      'kind': kind,
      ...details,
    });
    stdout.writeln('UNCOOPERATIVE $kind ${jsonEncode(details)}');
  }

  Map<String, Object?> disk() =>
      (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  Future<Map<String, Object?>> actor(ToolContext ctx) async {
    final s = (await store.read(ctx.sessionId))!;
    return {
      'agent_id': s.id,
      'name': s.agentState['name'] ?? '/root',
      'depth': s.depth,
      'run_id': ctx.runId,
      'operation_id': ctx.operationId,
    };
  }

  void write(int next, Map<String, Object?> who, ToolContext ctx) {
    value = next;
    revision++;
    file.writeAsStringSync(
      jsonEncode({'a': value, 'revision': revision, 'writer': who}),
      flush: true,
    );
    record('commit', {
      ...who,
      'a': value,
      'token_cancelled': ctx.cancellation.isCancelled,
      'new_task_running': fresh != null && !fresh.isSettled,
    });
  }

  ToolResult submit(
    int next,
    Map<String, Object?> who,
    ToolContext ctx,
    ResourceWritePermit? permit,
  ) {
    ToolResult commit() {
      write(next, who, ctx);
      return ToolResult('Value saved', data: disk());
    }

    final result = guard == null ? commit() : guard.commit(permit!, commit);
    if (result.isError) {
      record('commit_rejected', {
        ...who,
        'a': next,
        'token_cancelled': ctx.cancellation.isCancelled,
        'new_task_running': fresh != null && !fresh.isSettled,
        'result': result.toJson(),
      });
    }
    return result;
  }

  AgentTool tool(
    String name,
    String description,
    Future<ToolResult> Function(ToolCall, ToolContext) execute, {
    bool takesValue = false,
  }) => AgentTool(
    name: name,
    alwaysAvailable: true,
    description: description,
    parameters: {
      'type': 'object',
      'properties': takesValue
          ? {
              'value': {'type': 'integer'},
            }
          : <String, Object?>{},
      if (takesValue) 'required': ['value'],
      'additionalProperties': false,
    },
    validate: (a) => takesValue
        ? (a.length == 1 && a['value'] is int ? null : 'Supply integer value')
        : (a.isEmpty ? null : 'No arguments'),
    execute: execute,
  );

  final audited = _AuditModel(model, () => phase, requests);
  final manager = SessionManager(
    model: LiveTraceModel(audited, trace),
    store: store,
    resourceCommitGuard: guard,
    contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
    multiAgent: MultiAgentConfig(
      maxConcurrent: 2,
      maxDepth: 2,
      maxChildren: 3,
      childMaxTurns: 10,
      maxDelegatedTurns: 60,
    ),
    tools: [
      tool('hold_old_root', 'Old root waits for host cancellation.', (
        _,
        ctx,
      ) async {
        final who = await actor(ctx);
        if (who['depth'] != 0) return ToolResult('Root only', isError: true);
        record('root_held', who);
        if (!rootHeld.isCompleted) rootHeld.complete();
        await ctx.cancellation.whenCancelled;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return ToolResult('Cancelled root hold', isError: true);
      }),
      tool(
        'uncooperative_old_tool',
        'Assigned old writer starts a controlled delayed operation. Host releases it; do not call from root or leader.',
        (_, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != oldWriterDepth) {
            return ToolResult('Assigned old writer only', isError: true);
          }
          final permit = guard?.issue(ctx);
          record('old_tool_started', who);
          if (!ready.isCompleted) ready.complete();
          if (mode == UncooperativeMode.detachedWrite) {
            // Return after cancellation but leave an explicitly tracked-by-test
            // background callback outside the runtime's tool Future.
            await ctx.cancellation.whenCancelled;
            detachedScheduled = true;
            background = () async {
              await delayed.future;
              submit(10, who, ctx, permit);
              detached.complete();
            }();
            record('detached_scheduled', who);
          } else {
            // Intentionally do not race this gate against cancellation.
            await delayed.future;
            if (mode == UncooperativeMode.pendingWrite) {
              submit(10, who, ctx, permit);
            }
          }
          record('old_tool_returned', {
            ...who,
            'token_cancelled': ctx.cancellation.isCancelled,
          });
          return ToolResult(delayedResultMarker, data: {'old_goal': 10});
        },
      ),
      tool(
        'write_new_value',
        'New direct child writes the current target value.',
        (call, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != 1) {
            return ToolResult('New child only', isError: true);
          }
          return submit(
            call.arguments['value'] as int,
            who,
            ctx,
            guard?.issue(ctx),
          );
        },
        takesValue: true,
      ),
      tool(
        'inspect_current_value',
        'Root verifies actual shared file. Controlled delayed external work, if any, is released at this read.',
        (_, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != 0) return ToolResult('Root only', isError: true);
          record('new_value_before_late_write', {...who, 'resource': disk()});
          if (mode == UncooperativeMode.detachedWrite) {
            if (!delayed.isCompleted) delayed.complete();
            await detached.future;
          }
          record('inspected', {...who, 'resource': disk()});
          return ToolResult(
            'Actual shared file',
            data: {...disk(), 'polluted': value != 15, 'do_not_repair': true},
          );
        },
      ),
    ],
  );
  try {
    file.writeAsStringSync(jsonEncode({'a': value, 'revision': revision}));
    final session = await manager.create(
      system:
          'Use actual tools and follow current assigned tasks. '
          'For this controlled experiment report the actual inspected value and do not repair external writes.',
    );
    old = await manager.prompt(
      session.id,
      oldWriterDepth == 1
          ? '$uncooperativeOldMarker：当前初始化任务尚未取消。主代理创建writer子代理，'
                '让writer调用uncooperative_old_tool一次；随后主代理必须hold_old_root，'
                '不要wait_agent。spawn_agent使用fork_turns=none。主代理不能直接调用旧工具。'
          : '$uncooperativeOldMarker：当前初始化任务尚未取消。主代理创建leader子代理，'
                '然后必须调用hold_old_root等待宿主取消，不要wait_agent。给leader完整指令：'
                '创建writer孙代理，让writer调用uncooperative_old_tool一次，然后leader用wait_agent等它。'
                '所有spawn_agent使用fork_turns=none。主代理、leader都不能直接调用旧工具。',
      maxTurns: 20,
    );
    deadline = Timer(const Duration(minutes: 2), () {
      timedOut = true;
      if (!ready.isCompleted) ready.complete();
      if (!rootHeld.isCompleted) rootHeld.complete();
    });
    await Future.any<void>([
      Future.wait([ready.future, rootHeld.future]),
      old.done.then<void>((_) {}),
    ]);
    deadline.cancel();
    final before = await readCancellationTree(store, old.snapshot);
    final oldIds = before.skip(1).map((s) => s.id).toSet();
    final checks = <String, bool>{
      'actualOldRootChildGrandchildActive':
          !timedOut &&
          before.length == oldWriterDepth + 1 &&
          before.every((s) => s.status == RunStatus.running) &&
          ready.isCompleted &&
          rootHeld.isCompleted,
    };
    if (!checks.values.every((v) => v)) {
      return {
        'passed': false,
        'mode': mode.name,
        'checks': checks,
        'modelTrace': trace,
      };
    }
    phase = 'cancelling';
    record('cancel_requested', {'run_id': old.snapshot.runId});
    final cancelSequence = sequence;
    var cancelFinished = false;
    final cancellation = old.cancel().then((s) {
      cancelFinished = true;
      record('cancel_settled');
      return s;
    });
    String? earlyError;
    AgentRun? premature;
    try {
      premature = await manager.prompt(
        session.id,
        'PREMATURE_NEW_PROBE',
        maxTurns: 1,
      );
    } catch (error) {
      earlyError = error.toString();
    }
    if (premature != null) await premature.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final pendingBlocked = !cancelFinished;
    final beforeRelease = disk();
    if (mode != UncooperativeMode.detachedWrite) {
      record('pending_tool_released_after_cancel');
      delayed.complete();
    }
    final cancelled = await cancellation.timeout(const Duration(seconds: 30));
    final oldTree = [
      cancelled,
      for (final s in before.skip(1)) (await store.read(s.id))!,
    ];
    final oldBaseline = oldTree
        .skip(1)
        .map((s) => jsonEncode(s.toJson()))
        .toList();
    final settledSequence = sequence;
    phase = 'new';
    fresh = await manager.prompt(
      session.id,
      '$uncooperativeNewMarker：全新任务，创建一个新writer子代理，fork_turns=none，'
      '让它调用write_new_value(value:15)一次并报告，message包含$uncooperativeNewMarker。'
      '主代理wait_agent后必须调用inspect_current_value，读取测试实际文件。'
      '如果旧后台操作覆盖了15，不要修复，按inspect返回值如实汇总。最后只回复JSON '
      '{"a":实际整数,"polluted":实际布尔值}。不要继续旧目标。',
      maxTurns: 20,
    );
    record('new_started', {'run_id': fresh.snapshot.runId});
    final newSequence = sequence;
    final current = fresh;
    deadline = Timer(const Duration(minutes: 2), () {
      timedOut = true;
      if (!delayed.isCompleted) delayed.complete();
      unawaited(current.cancel());
    });
    final result = await fresh.done;
    deadline.cancel();
    // Drain detached work even when the model omits the required inspection.
    // Such a run still fails verification below.
    if (!delayed.isCompleted) delayed.complete();
    if (background != null) await background;
    final newTree = await readCancellationTree(store, result);
    final oldAfter = [
      for (final s in before.skip(1)) (await store.read(s.id))!,
    ];
    final oldCommits = actions
        .where((a) => a['kind'] == 'commit' && oldIds.contains(a['agent_id']))
        .toList();
    final duringNew = oldCommits
        .where(
          (a) =>
              (a['sequence'] as int) > newSequence &&
              a['new_task_running'] == true,
        )
        .toList();
    final expectedPollution =
        !guarded && mode == UncooperativeMode.detachedWrite;
    final rejected = actions
        .where(
          (a) =>
              a['kind'] == 'commit_rejected' && oldIds.contains(a['agent_id']),
        )
        .toList();
    final inspected = actions.where((a) => a['kind'] == 'inspected').lastOrNull;
    final beforeLate = actions
        .where((a) => a['kind'] == 'new_value_before_late_write')
        .lastOrNull;
    Map? answer;
    try {
      final text = result.history.last.text;
      answer =
          jsonDecode(
                text.substring(text.indexOf('{'), text.lastIndexOf('}') + 1),
              )
              as Map;
    } catch (_) {
      answer = null;
    }
    bool noNewNotice(Map<String, Object?> request) {
      final messages = (request['messages'] as List).cast<Map>();
      final boundary = messages.lastIndexWhere(
        (m) =>
            m['role'] == 'user' &&
            m['runtimeNotice'] != true &&
            (m['text'] as String).contains(uncooperativeNewMarker),
      );
      return boundary >= 0 &&
          !messages
              .skip(boundary + 1)
              .any((m) => (m['text'] as String).contains(delayedResultMarker));
    }

    checks.addAll({
      'prematureSameSessionStartRejected':
          earlyError != null && earlyError.contains('writer'),
      'pendingCancellationWaitsForIgnoredTokenTool':
          mode == UncooperativeMode.detachedWrite || pendingBlocked,
      'pendingToolDidNotReturnBeforeGate':
          mode == UncooperativeMode.detachedWrite ||
          !actions.any(
            (a) =>
                a['kind'] == 'old_tool_returned' &&
                (a['sequence'] as int) < cancelSequence,
          ),
      'oldToolReallyReturnedAfterCancellation': actions.any(
        (a) =>
            a['kind'] == 'old_tool_returned' &&
            a['token_cancelled'] == true &&
            (a['sequence'] as int) > cancelSequence,
      ),
      'oldDelayedResultSavedOnlyInOldGrandchild':
          oldTree
              .where((s) => s.depth == oldWriterDepth)
              .any(
                (s) => s.history.any(
                  (m) =>
                      m.role == MessageRole.tool &&
                      m.text.contains(delayedResultMarker),
                ),
              ) &&
          newTree
              .skip(1)
              .every(
                (s) =>
                    !s.history.any((m) => m.text.contains(delayedResultMarker)),
              ),
      'cancelJoinedEntireOldTree': oldTree.every(
        (s) => s.status == RunStatus.cancelled && s.pending.isEmpty,
      ),
      'newRunCompletedWithIndependentIdentity':
          !timedOut &&
          result.status == RunStatus.completed &&
          result.runId != cancelled.runId &&
          !fresh.cancellation.isCancelled,
      'newChildActuallyWrote15': actions.any(
        (a) =>
            a['kind'] == 'commit' &&
            a['a'] == 15 &&
            (a['sequence'] as int) > newSequence &&
            !oldIds.contains(a['agent_id']),
      ),
      'newValueWas15BeforeDelayedExternalWrite':
          beforeLate != null && (beforeLate['resource'] as Map)['a'] == 15,
      'lateOldToolResultNotInjectedIntoNewTask':
          requests.where((r) => r['phase'] == 'new').isNotEmpty &&
          requests.where((r) => r['phase'] == 'new').every(noNewNotice),
      'noOldModelContinuationInNewTask': !requests.any(
        (r) => r['phase'] == 'new' && r['logicalTask'] == 'old',
      ),
      'oldSnapshotsStableDuringNewTask': List.generate(
        oldAfter.length,
        (i) => jsonEncode(oldAfter[i].toJson()) == oldBaseline[i],
      ).every((v) => v),
      'newTreeUsesFreshChildIds':
          newTree.length == 2 && newTree.every((s) => !oldIds.contains(s.id)),
      'oldWritesMatchMode':
          oldCommits.length ==
          (guarded || mode == UncooperativeMode.pendingResult ? 0 : 1),
      'revokedOldSubmissionRejectedWithoutMutation':
          !guarded ||
          mode == UncooperativeMode.pendingResult ||
          (rejected.length == 1 &&
              ((rejected.single['result'] as Map)['data'] as Map)['executed'] ==
                  false),
      'oldBackgroundGenerationRejectedWhileNewTaskRuns':
          !guarded ||
          mode != UncooperativeMode.detachedWrite ||
          (rejected.length == 1 &&
              rejected.single['new_task_running'] == true &&
              ((rejected.single['result'] as Map)['data'] as Map)['code'] ==
                  'stale_task_generation'),
      'pendingOldWriteFinishesBeforeNewRun':
          mode != UncooperativeMode.pendingWrite ||
          oldCommits.every((a) => (a['sequence'] as int) < settledSequence),
      'actualOverlapMatchesDetachedMode':
          duringNew.isNotEmpty == expectedPollution,
      'actualFileMatchesExpectedOutcome':
          value == (expectedPollution ? 10 : 15),
      'rootVerifiedActualFile':
          inspected != null && (inspected['resource'] as Map)['a'] == value,
      'rootSummaryReportsActualOutcome':
          answer?['a'] == value && answer?['polluted'] == expectedPollution,
    });
    return {
      'passed': checks.values.every((v) => v),
      'experimentPassedMeaning': guarded
          ? 'Guarded submissions reject obsolete tasks; model summary and actual file must remain 15.'
          : 'Observed behavior and model summary match actual file; detachedWrite intentionally demonstrates contamination.',
      'mode': mode.name,
      'guarded': guarded,
      'oldWriterDepth': oldWriterDepth,
      'checks': checks,
      'newTaskPolluted': duringNew.isNotEmpty && value != 15,
      'cancelWasPendingBeforeRelease': pendingBlocked,
      'prematureStartError': earlyError,
      'resourceBeforeOldRelease': beforeRelease,
      'finalResource': disk(),
      'oldWritesAfterCancelRequest': oldCommits
          .where((a) => (a['sequence'] as int) > cancelSequence)
          .length,
      'oldWritesDuringNewTask': duringNew.length,
      'oldSubmissionsRejected': rejected.length,
      'finalAnswer': result.history.last.text,
      'resourceActions': actions,
      'modelTrace': trace,
      'requestAudit': requests,
      'oldSessions': oldTree.map((s) => s.toJson()).toList(),
      'newSessions': newTree.map((s) => s.toJson()).toList(),
    };
  } finally {
    deadline?.cancel();
    if (!delayed.isCompleted) delayed.complete();
    if (fresh != null && !fresh.isSettled) await fresh.cancel();
    if (old != null && !old.isSettled) await old.cancel();
    if (detachedScheduled && background != null) await background;
    await directory.delete(recursive: true);
  }
}

class _AuditModel implements ModelAdapter {
  _AuditModel(this.model, this.phase, this.requests);
  final ModelAdapter model;
  final String Function() phase;
  final List<Map<String, Object?>> requests;
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final user = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    requests.add({
      'phase': phase(),
      'logicalTask': user.contains(uncooperativeNewMarker) ? 'new' : 'old',
      'messages': request.messages.map((m) => m.toJson()).toList(),
    });
    yield* model.stream(request, token);
  }
}

/// Runs delayed result, tracked delayed write, and detached delayed write cases.
Future<Map<String, Object?>> validateUncooperativeModes(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final mode in UncooperativeMode.values) {
    stdout.writeln('UNCOOPERATIVE_MODE ${mode.name}');
    reports.add(await validateUncooperativeCancellation(model, mode: mode));
  }
  return {
    'passed': reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports) r['mode'] as String: r['passed'] == true,
    },
    'cases': reports,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateUncooperativeModes,
  label: 'UNCOOPERATIVE_CANCEL',
);
