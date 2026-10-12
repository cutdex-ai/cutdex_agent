import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;
import 'live_tree_cancel_validate.dart'
    show TreeCancelResource, readCancellationTree;

const oldTaskMarker = 'OLD_TASK_TOKEN';
const oldNoticeMarker = 'OLD_RUN_NOTICE';
const newTaskMarker = 'NEW_TASK_TOKEN';
const _oldPrompt =
    '$oldTaskMarker：受控任务切换测试。当前第一任务尚未取消，先执行以下初始化。主代理先创建一个leader子代理，然后必须调用'
    'hold_root_until_cancel保持等待，不要调用wait_agent。leader创建writer_a和writer_b'
    '两个孙代理，分别gated_write(key:a,value:10)、gated_write(key:b,value:20)，'
    '成功后再append_extra同一key。leader在启动两个孙代理后，必须send_message给parent，'
    '消息包含$oldNoticeMarker并说明旧目标10和20，然后wait_agent。全部子任务使用fork_turns=none。'
    '给leader的message必须完整列出两个孙代理的创建和gated_write参数，不能只让它报告或等待。'
    '主代理保持在hold_root_until_cancel中，测试宿主将在写工具已启动且邮箱存在旧消息时取消根Run。';

class _RequestAudit implements ModelAdapter {
  _RequestAudit(this.model, this.phase);
  final ModelAdapter model;
  final String Function() phase;
  final requests = <Map<String, Object?>>[];
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final latestUser = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    final entry = <String, Object?>{
      'phase': phase(),
      'logicalTask': latestUser.contains(newTaskMarker) ? 'new' : 'old',
      'agent': RegExp(
        r'Multi-agent collaboration: You are ([^\s]+)\. ',
      ).firstMatch(request.system)?.group(1),
      'at': DateTime.now().toUtc().toIso8601String(),
      'messages': request.messages.map((m) => m.toJson()).toList(),
    };
    requests.add(entry);
    try {
      yield* model.stream(request, token);
    } catch (error) {
      entry['error'] = error.toString();
      rethrow;
    }
  }
}

Map<String, Object?>? _jsonAnswer(String text) {
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

/// Tests immediate replacement of a cancelled root task in the same session.
///
/// Old grandchildren and the new child share one file, and the child name is
/// reused. The host also probes premature start and repeats the settled old
/// cancellation while the new task runs; no artificial generation write fence
/// is installed in the business tools.
Future<Map<String, Object?>> validateCancelThenNewTask(
  ModelAdapter model, {
  bool reopenManager = false,
  Duration observation = const Duration(seconds: 3),
}) async {
  final directory = await Directory.systemTemp.createTemp('cutdex-cancel-new-');
  final sessions = Directory('${directory.path}/sessions');
  final store = FileSessionStore(sessions);
  final resource = TreeCancelResource(
    store,
    File('${directory.path}/shared.json'),
    honorsCancellation: true,
  );
  final heldRoot = Completer<void>();
  var phase = 'old';
  final audit = _RequestAudit(model, () => phase);
  final trace = <Map<String, Object?>>[];
  final traced = LiveTraceModel(audit, trace);
  final newTools = [
    AgentTool(
      name: 'hold_root_until_cancel',
      alwaysAvailable: true,
      description:
          'Keep the old root tool active until host cancellation. Child messages remain queued until this tool returns.',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (a) => a.isEmpty ? null : 'No arguments',
      execute: (call, ctx) async {
        final who = await resource.actor(ctx);
        if (who['depth'] != 0) {
          return ToolResult('Root-only hold', isError: true);
        }
        resource.record('root_hold_started', who);
        if (!heldRoot.isCompleted) heldRoot.complete();
        await ctx.cancellation.whenCancelled;
        // Deliberate cleanup interval makes the early-start lease probe occur
        // before cancellation settlement, rather than depending on disk speed.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        resource.record('root_hold_cancelled', who);
        return ToolResult(
          'Root hold cancelled',
          isError: true,
          data: {'code': 'cancelled'},
        );
      },
      recover: (_, _) async => const ToolRecovery.notStarted(),
    ),
    AgentTool(
      name: 'write_new_goal',
      alwaysAvailable: true,
      description:
          'New task child writes the shared resource. Use this instead of old gated_write. Root must delegate.',
      parameters: {
        'type': 'object',
        'properties': {
          'key': {
            'type': 'string',
            'enum': ['a'],
          },
          'value': {'type': 'integer'},
        },
        'required': ['key', 'value'],
        'additionalProperties': false,
      },
      validate: (a) => a.length == 2 && a['key'] == 'a' && a['value'] is int
          ? null
          : 'Supply key a and integer value',
      execute: (call, ctx) async {
        final who = await resource.actor(ctx);
        if (who['depth'] != 1) {
          return ToolResult('New child-only write', isError: true);
        }
        return resource.commit(who, call, ctx);
      },
      recover: (call, ctx) async => resource.receipts[ctx.operationId] == null
          ? const ToolRecovery.notStarted()
          : ToolRecovery.completed(resource.receipts[ctx.operationId]!),
    ),
    AgentTool(
      name: 'inspect_shared_resource',
      alwaysAvailable: true,
      description: 'Read the actual shared file for final verification.',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (a) => a.isEmpty ? null : 'No arguments',
      execute: (call, ctx) async {
        final disk = jsonDecode(await resource.file.readAsString());
        resource.record('inspect', {
          ...await resource.actor(ctx),
          'resource': disk,
        });
        return ToolResult(
          'Shared file',
          data: (disk as Map).cast<String, Object?>(),
        );
      },
    ),
  ];
  SessionManager managerFor(SessionStore storage) => SessionManager(
    model: traced,
    store: storage,
    tools: [...resource.tools, ...newTools],
    contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
    multiAgent: MultiAgentConfig(
      maxConcurrent: 3,
      maxDepth: 2,
      maxChildren: 4,
      childMaxTurns: 12,
      maxDelegatedTurns: 80,
    ),
  );
  AgentRun? old;
  AgentRun? fresh;
  Timer? setupDeadline;
  Timer? newDeadline;
  var setupTimedOut = false;
  var newTimedOut = false;
  try {
    await resource.file.writeAsString(jsonEncode(resource.state), flush: true);
    final initial = jsonDecode(await resource.file.readAsString());
    final manager = managerFor(store);
    final session = await manager.create(
      system:
          'Use actual tools, follow the current assigned task, and verify resource state. '
          'Task replacements are supplied by later user messages.',
    );
    old = await manager.prompt(session.id, _oldPrompt, maxTurns: 30);
    final timeout = Completer<void>();
    setupDeadline = Timer(const Duration(seconds: 120), () {
      setupTimedOut = true;
      timeout.complete();
    });
    await Future.any<void>([
      resource.bothReady.future,
      old.done.then<void>((_) {}),
      timeout.future,
    ]);
    var mailboxReady = false;
    while (!setupTimedOut && !old.isSettled) {
      final s = (await store.read(session.id))!;
      mailboxReady = (s.agentState['inbox'] as List? ?? const []).any(
        (m) => m.toString().contains(oldNoticeMarker),
      );
      if (mailboxReady && heldRoot.isCompleted && resource.active.length == 2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    setupDeadline.cancel();
    final before = await readCancellationTree(
      store,
      (await store.read(session.id))!,
    );
    final oldDescendants = before.skip(1).toList();
    final oldIds = oldDescendants.map((s) => s.id).toSet();
    final oldLeader = before.where((s) => s.depth == 1).firstOrNull;
    final oldRunId = old.snapshot.runId;
    final reusedName =
        (oldLeader?.agentState['name'] as String? ?? '/root/leader')
            .split('/')
            .last;
    final oldInbox = List<Object?>.from(
      old.snapshot.agentState['inbox'] as List? ?? const [],
    );
    final newPrompt =
        '$newTaskMarker：旧任务已取消，这是全新任务，只处理共享资源a=15。'
        '先list_agents确认当前任务没有旧子代理，再故意send_message(target:${oldLeader?.id ?? 'missing_old_leader'},'
        'message:OLD_CONTROL_PROBE)验证旧代理不可控制；这次应被拒绝。'
        '随后创建一个新子代理，task_name必须用$reusedName，与旧子代理完全同名，fork_turns=none，message必须包含$newTaskMarker，'
        '让它只调用write_new_goal(key:a,value:15)并报告，不要创建孙代理或重试旧10/20目标。'
        '你wait_agent后inspect_shared_resource核验，最后只回复JSON {"a":15}。';
    final checks = <String, bool>{
      'oldTreeActuallyActive':
          before.length == 4 &&
          before.every((s) => s.status == RunStatus.running) &&
          resource.active.length == 2,
      'oldMailboxActuallyPending':
          mailboxReady &&
          oldInbox.any((s) => s.toString().contains(oldNoticeMarker)),
      'rootHeldBeforeCancel': heldRoot.isCompleted,
      'setupCompletedWithoutTimeout': !setupTimedOut,
    };
    phase = 'cancelling';
    resource.record('old_root_cancel_requested', {
      'agent_id': session.id,
      'run_id': oldRunId,
    });
    final cancelSequence = resource.sequence;
    final cancelled = old.cancel();
    resource.release.complete();
    var prematureRejected = false;
    String? prematureError;
    AgentRun? premature;
    try {
      premature = await manager.prompt(
        session.id,
        'EARLY_START_PROBE: start a new task before cancellation settled',
        maxTurns: 3,
      );
    } catch (error) {
      prematureError = error.toString();
      prematureRejected =
          error is StateError &&
          RegExp(r'writer|unfinished|lease').hasMatch(prematureError);
    }
    if (premature != null) await premature.cancel();
    final cancelledRoot = await cancelled.timeout(const Duration(seconds: 30));
    resource.record('old_root_cancel_settled', {
      'agent_id': session.id,
      'run_id': oldRunId,
    });
    phase = 'new';
    final activeManager = reopenManager
        ? managerFor(FileSessionStore(sessions))
        : manager;
    resource.record('new_task_requested', {
      'agent_id': session.id,
      'reopened_manager': reopenManager,
    });
    final newStartSequence = resource.sequence;
    fresh = await activeManager.prompt(session.id, newPrompt, maxTurns: 24);
    resource.record('new_task_opened', {
      'agent_id': session.id,
      'run_id': fresh.snapshot.runId,
    });
    final current = fresh;
    newDeadline = Timer(const Duration(minutes: 3), () {
      newTimedOut = true;
      unawaited(current.cancel());
    });
    final settledOld = [
      for (final s in oldDescendants) (await store.read(s.id))!,
    ];
    final oldSnapshots = settledOld.map((s) => jsonEncode(s.toJson())).toList();
    final oldRequestsAtNewTask = audit.requests
        .where((r) => r['phase'] != 'new')
        .length;
    resource.record('repeat_old_cancel_during_new_task', {
      'old_run_id': oldRunId,
      'new_run_id': fresh.snapshot.runId,
    });
    await old.cancel();
    final result = await fresh.done;
    newDeadline.cancel();
    phase = 'observation';
    final newTree = await readCancellationTree(store, result);
    final child = newTree.where((s) => s.depth == 1).firstOrNull;
    final disk = jsonDecode(await resource.file.readAsString());
    final requestsAtDone = trace.length;
    final observations = <Map<String, Object?>>[];
    final watch = Stopwatch()..start();
    while (watch.elapsed < observation) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      observations.add({
        'elapsed_ms': watch.elapsedMilliseconds,
        'resource': jsonDecode(await resource.file.readAsString()),
        'requests': trace.length,
      });
    }
    final oldAfter = [
      for (final s in oldDescendants) (await store.read(s.id))!,
    ];
    final newMessages = result.history.skip(result.runStart).toList();
    final firstLists = newMessages
        .expand((m) => m.calls)
        .where((c) => c.name == 'list_agents')
        .toList();
    final firstListResult = firstLists.isEmpty
        ? null
        : newMessages
              .where(
                (m) =>
                    m.role == MessageRole.tool &&
                    m.callId == firstLists.first.id,
              )
              .firstOrNull;
    final probes = newMessages
        .expand((m) => m.calls)
        .where(
          (c) =>
              c.name == 'send_message' &&
              c.arguments['target'] == oldLeader?.id,
        )
        .toList();
    final probeResults = [
      for (final p in probes)
        ...newMessages.where(
          (m) => m.role == MessageRole.tool && m.callId == p.id,
        ),
    ];
    final newRequests = audit.requests
        .where((r) => r['phase'] == 'new' && r['agent'] == '/root')
        .toList();
    bool noLateOldNotice(Map<String, Object?> request) {
      final messages = (request['messages'] as List).cast<Map>();
      final boundary = messages.lastIndexWhere(
        (m) =>
            m['role'] == 'user' &&
            m['runtimeNotice'] != true &&
            (m['text'] as String).contains(newTaskMarker),
      );
      return boundary >= 0 &&
          !messages
              .skip(boundary + 1)
              .any(
                (m) =>
                    m['runtimeNotice'] == true &&
                    (m['text'] as String).contains(oldNoticeMarker),
              );
    }

    final commits = resource.actions
        .where(
          (a) =>
              a['kind'] == 'commit' &&
              (a['sequence'] as int) > newStartSequence,
        )
        .toList();
    final entries = (disk as Map)['entries'] as List;
    checks.addAll({
      'prematureStartRejected': prematureRejected,
      'noPrematureModelRequest': !audit.requests.any(
        (r) => (r['messages'] as List).any(
          (m) =>
              (m as Map)['role'] == 'user' &&
              (m['text'] as String).contains('EARLY_START_PROBE'),
        ),
      ),
      'oldTreeCancelledBeforeNewTask':
          cancelledRoot.status == RunStatus.cancelled &&
          settledOld.length == 3 &&
          settledOld.every(
            (s) => s.status == RunStatus.cancelled && s.pending.isEmpty,
          ),
      'newRootHasDistinctRunAndClearCancellation':
          result.id == session.id &&
          result.runId != oldRunId &&
          result.status == RunStatus.completed &&
          !result.stopRequested &&
          !fresh.cancellation.isCancelled &&
          !newTimedOut,
      'noOldCommitsAfterCancel': !resource.actions.any(
        (a) =>
            a['kind'] == 'commit' &&
            oldIds.contains(a['agent_id']) &&
            (a['sequence'] as int) > cancelSequence,
      ),
      'newChildNameReusedWithNewIdentity':
          child != null &&
          oldLeader != null &&
          child.agentState['name'] == oldLeader.agentState['name'] &&
          child.id != oldLeader.id &&
          child.parentRunId == result.runId,
      'newTreeContainsNoOldAgents':
          newTree.length == 2 && newTree.every((s) => !oldIds.contains(s.id)),
      'oldTargetControlRejected': probeResults.any(
        (m) => m.isError && m.text.contains('unauthorized'),
      ),
      'initialNewAgentListEmpty':
          firstListResult != null &&
          (((jsonDecode(firstListResult.text) as Map)['data'] as Map)['agents']
                  as List)
              .isEmpty,
      'oldMailboxNotDeliveredAsCurrentTaskNotice':
          newRequests.isNotEmpty && newRequests.every(noLateOldNotice),
      'onlyNewChildCommittedNewGoal':
          commits.length == 1 &&
          child != null &&
          commits.single['agent_id'] == child.id &&
          commits.single['key'] == 'a' &&
          commits.single['value'] == 15 &&
          commits.single['tool'] == 'write_new_goal',
      'sameResourceHasOnlyExpectedNewWrite':
          entries.length == 2 &&
          (entries.first as Map)['key'] == 'existing' &&
          (entries.first as Map)['value'] == 99 &&
          (entries.last as Map)['key'] == 'a' &&
          (entries.last as Map)['value'] == 15,
      'parentVerifiedNewState': resource.actions.any(
        (a) =>
            a['kind'] == 'inspect' &&
            a['agent_id'] == session.id &&
            a['run_id'] == result.runId &&
            jsonEncode(a['resource']) == jsonEncode(disk),
      ),
      'newSummaryCorrect': _jsonAnswer(result.history.last.text)?['a'] == 15,
      'oldDescendantsUnchangedDuringNewTask':
          oldAfter.length == oldSnapshots.length &&
          List.generate(
            oldAfter.length,
            (i) => jsonEncode(oldAfter[i].toJson()) == oldSnapshots[i],
          ).every((v) => v),
      'noModelRequestsAfterNewTaskSettles': trace.length == requestsAtDone,
      'resourceStableDuringObservation': observations.every(
        (s) => jsonEncode(s['resource']) == jsonEncode(disk),
      ),
      'noLateOldPhaseRequests':
          audit.requests
              .where((r) => r['phase'] == 'old' || r['phase'] == 'cancelling')
              .length ==
          oldRequestsAtNewTask,
      'noOldModelRequestsAfterNewTaskStart': !audit.requests.any(
        (r) =>
            {'new', 'observation'}.contains(r['phase']) &&
            r['logicalTask'] == 'old',
      ),
    });
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'reopenManager': reopenManager,
      'prematureStartError': prematureError,
      'oldRunId': oldRunId,
      'newRunId': result.runId,
      'oldPendingInbox': oldInbox,
      'newPrompt': newPrompt,
      'initialResource': initial,
      'finalResource': disk,
      'newStatus': result.status.name,
      'finalAnswer': result.history.last.text,
      'resourceActions': resource.actions,
      'modelTrace': trace,
      'requestAudit': audit.requests,
      'observationMs': watch.elapsedMilliseconds,
      'observationSamples': observations,
      'oldDescendants': [
        for (final s in oldAfter)
          {
            'id': s.id,
            'name': s.agentState['name'],
            'status': s.status.name,
            'error': s.error,
            'runId': s.runId,
            'parentRunId': s.parentRunId,
            'messages': s.history.map((m) => m.toJson()).toList(),
          },
      ],
      'newSessions': [
        for (final s in newTree)
          {
            'id': s.id,
            'name': s.agentState['name'] ?? '/root',
            'status': s.status.name,
            'runId': s.runId,
            'runStart': s.runStart,
            'parentRunId': s.parentRunId,
            'messages': s.history.map((m) => m.toJson()).toList(),
          },
      ],
    };
  } finally {
    setupDeadline?.cancel();
    newDeadline?.cancel();
    if (!resource.release.isCompleted) resource.release.complete();
    if (fresh != null && !fresh.isSettled) await fresh.cancel();
    if (old != null && !old.isSettled) await old.cancel();
    await directory.delete(recursive: true);
  }
}

/// Tests immediate replacement with the existing and a reopened session manager.
Future<Map<String, Object?>> validateCancelNewTaskModes(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final reopen in [false, true]) {
    stdout.writeln(
      'CANCEL_NEW_TASK_MODE ${reopen ? 'reopened_manager' : 'same_manager'}',
    );
    reports.add(await validateCancelThenNewTask(model, reopenManager: reopen));
  }
  return {
    'passed': reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports)
        r['reopenManager'] == true ? 'reopenedManager' : 'sameManager':
            r['passed'] == true,
    },
    'cases': reports,
    'finalAnswer': reports
        .map(
          (r) =>
              '${r['reopenManager'] == true ? 'reopened' : 'same'}: ${r['passed']}',
        )
        .join(', '),
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateCancelNewTaskModes,
  label: 'LIVE_CANCEL_NEW_TASK',
);
