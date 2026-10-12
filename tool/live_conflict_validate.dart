import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;

const conflictPrompt =
    '请同时启动两个子代理修改同一个 shared-plan 资源：一个保留原内容并追加 color，另一个保留原内容并追加 audio；都先读取再按读取到的版本提交，发生版本冲突的子代理先向你报告并结束本轮，由你安排它重新读取最新版本、保留已有修改后重试，最后你读取验证并输出最终 resource_id、revision、entries 的 JSON。';

class _SharedResource {
  _SharedResource(this.file, this.store, this.actions);
  final File file;
  final SessionStore store;
  final List<Map<String, Object?>> actions;
  final Map<String, int> _lastRead = {};
  final Map<String, int> _initialReads = {};
  final Map<String, ToolResult> _receipts = {};
  final Completer<void> _readBarrier = Completer<void>();
  Future<void> _writes = Future.value();
  int _revision = 1;
  List<String> _entries = ['base'];
  int _sequence = 0;

  Map<String, Object?> get state => {
    'resource_id': 'shared-plan',
    'revision': _revision,
    'entries': [..._entries],
  };

  void record(String kind, Map<String, Object?> details) {
    final entry = <String, Object?>{
      'sequence': ++_sequence,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    };
    actions.add(entry);
    stdout.writeln('RESOURCE $kind ${jsonEncode(details)}');
  }

  Future<ToolResult> read(ToolCall call, ToolContext context) async {
    final actor = (await store.read(context.sessionId))!;
    final captured = state;
    _lastRead[actor.id] = captured['revision'] as int;
    record('read', {
      'agent_id': actor.id,
      'name': actor.agentState['name'] ?? '/root',
      'revision': captured['revision'],
      'entries': captured['entries'],
    });
    if (actor.parentSessionId != null && !_initialReads.containsKey(actor.id)) {
      _initialReads[actor.id] = captured['revision'] as int;
      if (_initialReads.length == 2) _readBarrier.complete();
      await Future.any<void>([
        _readBarrier.future,
        context.cancellation.whenCancelled,
      ]).timeout(const Duration(seconds: 60));
      context.cancellation.throwIfCancelled();
    }
    return ToolResult('Shared resource snapshot', data: captured);
  }

  Future<ToolResult> write(ToolCall call, ToolContext context) {
    final result = _writes.then((_) async {
      final cached = _receipts[context.operationId];
      if (cached != null) return cached;
      context.cancellation.throwIfCancelled();
      final actor = (await store.read(context.sessionId))!;
      if (actor.parentSessionId == null) {
        return ToolResult(
          'Delegate writes to child agents; the parent verifies and coordinates',
          isError: true,
        );
      }
      final expected = call.arguments['expected_revision'] as int;
      final proposed = (call.arguments['entries'] as List).cast<String>();
      if (expected != _revision) {
        final before = jsonDecode(await file.readAsString());
        record('conflict', {
          'agent_id': actor.id,
          'name': actor.agentState['name'],
          'expected_revision': expected,
          'current_revision': _revision,
          'proposed_entries': proposed,
          'state_before': before,
          'state_after': jsonDecode(await file.readAsString()),
        });
        final failure = ToolResult(
          'Resource version conflict; no changes were written',
          isError: true,
          data: {
            'code': 'resource_conflict',
            'resource_id': 'shared-plan',
            'expected_revision': expected,
            'current_revision': _revision,
          },
        );
        _receipts[context.operationId] = failure;
        return failure;
      }
      if (_lastRead[actor.id] != _revision) {
        return ToolResult(
          'Read the latest resource before committing; do not guess a revision',
          isError: true,
        );
      }
      final additions = proposed.where((e) => !_entries.contains(e)).toList();
      if (!_entries.every(proposed.contains) ||
          additions.length != 1 ||
          !{'color', 'audio'}.contains(additions.single)) {
        return ToolResult(
          'Preserve every existing entry and append exactly one missing change',
          isError: true,
        );
      }
      final from = _revision;
      await file.writeAsString(
        jsonEncode({
          'resource_id': 'shared-plan',
          'revision': from + 1,
          'entries': proposed,
        }),
        flush: true,
      );
      _revision = from + 1;
      _entries = [...proposed];
      record('commit', {
        'agent_id': actor.id,
        'name': actor.agentState['name'],
        'from_revision': from,
        'to_revision': _revision,
        'entries': [..._entries],
        'added': additions.single,
        'operation_id': context.operationId,
      });
      final success = ToolResult('Resource committed', data: state);
      _receipts[context.operationId] = success;
      return success;
    });
    _writes = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  List<AgentTool> get tools => [
    AgentTool(
      name: 'read_shared_resource',
      alwaysAvailable: true,
      description:
          'Read the shared-plan resource revision and entries. '
          'The first reads by two children synchronize so both observe the '
          'same initial revision. The parent must start both before waiting.',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (args) => args.isEmpty ? null : 'No arguments',
      execute: read,
    ),
    AgentTool(
      name: 'write_shared_resource',
      alwaysAvailable: true,
      description:
          'Compare-and-set replacement of shared-plan entries. '
          'Supply expected_revision from your last read and retain existing '
          'entries, appending exactly one change. Stale revisions return '
          'resource_conflict without writing. Report conflict to the parent '
          'and finish this turn; the parent coordinates a followup retry.',
      parameters: {
        'type': 'object',
        'properties': {
          'expected_revision': {'type': 'integer', 'minimum': 1},
          'entries': {
            'type': 'array',
            'items': {'type': 'string'},
            'uniqueItems': true,
          },
        },
        'required': ['expected_revision', 'entries'],
        'additionalProperties': false,
      },
      validate: (args) =>
          args.length == 2 &&
              args['expected_revision'] is int &&
              (args['expected_revision'] as int) > 0 &&
              args['entries'] is List &&
              (args['entries'] as List).every(
                (e) => e is String && {'base', 'color', 'audio'}.contains(e),
              ) &&
              (args['entries'] as List).toSet().length ==
                  (args['entries'] as List).length
          ? null
          : 'Supply expected_revision and unique base/color/audio entries',
      execute: write,
      recover: (call, context) async {
        final receipt = _receipts[context.operationId];
        return receipt == null
            ? const ToolRecovery.unknown()
            : ToolRecovery.completed(receipt);
      },
    ),
  ];
}

bool _sameResource(Object? value) =>
    value is Map &&
    value['resource_id'] == 'shared-plan' &&
    value['revision'] == 3 &&
    value['entries'] is List &&
    (value['entries'] as List).length == 3 &&
    (value['entries'] as List).toSet().containsAll({'base', 'color', 'audio'});

/// Verifies a forced stale-write conflict and subsequent parent coordination.
Future<Map<String, Object?>> validateConflict(ModelAdapter model) async {
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-conflict-live-',
  );
  final store = FileSessionStore(Directory('${directory.path}/sessions'));
  final resourceFile = File('${directory.path}/shared-plan.json');
  final actions = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  final resource = _SharedResource(resourceFile, store, actions);
  AgentRun? run;
  Timer? deadline;
  StreamSubscription<AgentEvent>? events;
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
          'Complete the user task using actual tools. Coordinate shared-resource '
          'conflicts through child reports and followup tasks. A child encountering '
          'resource_conflict must send_message to target parent and finish its turn '
          'without autonomous retries; the parent schedules the reread and retry. '
          'Verify the final resource with a read. Use concise Chinese answers.',
    );
    run = await manager.prompt(session.id, conflictPrompt, maxTurns: 24);
    final parent = run;
    events = run.events.listen((event) {
      if (event.kind != AgentEventKind.toolStarted) return;
      final call = parent.snapshot.history
          .expand((m) => m.calls)
          .where((c) => c.id == event.callId)
          .firstOrNull;
      if (call == null ||
          !{'followup_task', 'send_message'}.contains(call.name)) {
        return;
      }
      resource.record('parent_coordination', {
        'call_id': call.id,
        'tool': call.name,
        'target': call.arguments['target'],
        'message': call.arguments['message'],
      });
    });
    deadline = Timer(const Duration(minutes: 5), () {
      timedOut = true;
      unawaited(parent.cancel());
    });
    final result = await run.done;
    await events.cancel();
    final children = [
      for (final id in result.childSessionIds) ?await store.read(id),
    ];
    final conflicts = actions.where((a) => a['kind'] == 'conflict').toList();
    final commits = actions.where((a) => a['kind'] == 'commit').toList();
    bool reportedToParent(Map<String, Object?> conflict) {
      final child = children
          .where((c) => c.id == conflict['agent_id'])
          .firstOrNull;
      if (child == null) return false;
      final failed = child.history.indexWhere(
        (m) =>
            m.role == MessageRole.tool &&
            m.isError &&
            ((jsonDecode(m.text) as Map)['data'] as Map)['code'] ==
                'resource_conflict',
      );
      if (failed < 0) return false;
      final sends = child.history
          .skip(failed + 1)
          .expand((m) => m.calls)
          .where(
            (c) =>
                c.name == 'send_message' && c.arguments['target'] == 'parent',
          );
      return sends.any(
            (c) => child.history.any(
              (m) =>
                  m.role == MessageRole.tool && m.callId == c.id && !m.isError,
            ),
          ) &&
          result.history.any(
            (m) =>
                m.runtimeNotice &&
                m.text.contains(
                  '[Agent message from ${child.agentState['name']}',
                ),
          );
    }

    final coordination = actions
        .where((a) => a['kind'] == 'parent_coordination')
        .toList();
    for (final order in coordination) {
      final receipt = result.history
          .where(
            (m) =>
                m.role == MessageRole.tool &&
                m.callId == order['call_id'] &&
                !m.isError,
          )
          .firstOrNull;
      if (receipt != null) {
        order['agent_id'] =
            ((jsonDecode(receipt.text) as Map)['data'] as Map)['agent_id'];
      }
    }
    final coordinatedRetries = <Map<String, Object?>>[];
    for (final conflict in conflicts) {
      final actor = conflict['agent_id'];
      for (final order in coordination.where(
        (a) =>
            a['agent_id'] == actor &&
            (a['sequence'] as int) > (conflict['sequence'] as int),
      )) {
        final reread = actions
            .where(
              (a) =>
                  a['kind'] == 'read' &&
                  a['agent_id'] == actor &&
                  (a['sequence'] as int) > (order['sequence'] as int) &&
                  a['revision'] == 2,
            )
            .firstOrNull;
        if (reread == null) continue;
        final committed = commits
            .where(
              (a) =>
                  a['agent_id'] == actor &&
                  (a['sequence'] as int) > (reread['sequence'] as int) &&
                  a['from_revision'] == 2 &&
                  a['to_revision'] == 3,
            )
            .firstOrNull;
        if (committed != null) {
          coordinatedRetries.add({
            'conflictSequence': conflict['sequence'],
            'coordinationSequence': order['sequence'],
            'rereadSequence': reread['sequence'],
            'commitSequence': committed['sequence'],
            'agent_id': actor,
          });
        }
      }
    }
    final diskState = jsonDecode(await resourceFile.readAsString());
    final answer = result.history.last.text;
    Object? summary;
    if (answer.contains('{') && answer.lastIndexOf('}') > answer.indexOf('{')) {
      try {
        summary = jsonDecode(
          answer.substring(answer.indexOf('{'), answer.lastIndexOf('}') + 1),
        );
      } on FormatException {
        /* Preserve the answer and record the failed check. */
      }
    }
    final checks = <String, bool>{
      'completed': result.status == RunStatus.completed && !timedOut,
      'singleUserMessage':
          result.history
              .where((m) => m.role == MessageRole.user && !m.runtimeNotice)
              .length ==
          1,
      'twoChildrenReadSameVersion':
          children.length == 2 &&
          resource._initialReads.length == 2 &&
          resource._initialReads.values.every((v) => v == 1),
      'realConflictRejectedWithoutWrite':
          conflicts.isNotEmpty &&
          conflicts.every(
            (c) =>
                c['expected_revision'] == 1 &&
                c['current_revision'] == 2 &&
                jsonEncode(c['state_before']) == jsonEncode(c['state_after']),
          ),
      'parentCoordinatedRereadAndRetry': coordinatedRetries.isNotEmpty,
      'childReportedConflictToParent':
          conflicts.isNotEmpty && conflicts.every(reportedToParent),
      'bothChildChangesCommitted':
          commits.length == 2 &&
          commits.map((c) => c['agent_id']).toSet().length == 2 &&
          commits.map((c) => c['added']).toSet().containsAll({
            'color',
            'audio',
          }),
      'childrenCompleted':
          children.length == 2 &&
          children.every((c) => c.status == RunStatus.completed),
      'finalResourcePreservesBothChanges': _sameResource(diskState),
      'parentVerifiedFinalResource': actions.any(
        (a) =>
            a['kind'] == 'read' &&
            a['agent_id'] == result.id &&
            a['revision'] == 3,
      ),
      'mainAgentSummaryMatches': _sameResource(summary),
    };
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'prompt': conflictPrompt,
      'resourceProtection': 'Tool-owned compare-and-set transaction',
      'parentStatus': result.status.name,
      'parentTurns': result.turns,
      if (result.error != null) 'parentError': result.error,
      'finalAnswer': answer,
      'finalResource': diskState,
      'conflictCount': conflicts.length,
      'coordinatedRetries': coordinatedRetries,
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
    await events?.cancel();
    if (run != null && !run.isSettled) await run.cancel();
    await directory.delete(recursive: true);
  }
}

Future<void> main(List<String> args) =>
    runLiveValidation(args, validateConflict, label: 'LIVE_CONFLICT');
