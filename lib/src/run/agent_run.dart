import 'dart:async';
import 'dart:convert';

import '../context/context.dart';
import '../context/summary.dart';
import '../events/events.dart';
import '../model/adapter.dart';
import '../model/messages.dart';
import '../session/snapshot.dart';
import '../storage/store.dart';
import '../tools/tool.dart';
import '../tools/schema.dart';
import '../tools/resource_commit_guard.dart';
import '../tools/resource_task_authority.dart';
import 'cancellation.dart';
import 'completion_check.dart';
import 'diagnostics.dart';
import 'user_input.dart';

class DelegationLimit implements Exception {
  const DelegationLimit();
  @override
  String toString() => 'Delegation budget exceeded';
}

/// A single logical execution. Use SessionManager to obtain a run.
class AgentRun {
  AgentRun({
    required SessionSnapshot snapshot,
    required this.model,
    required this.contextBuilder,
    required this.store,
    this.completionCheck,
    required Iterable<AgentTool> tools,
    required this._release,
    Iterable<AgentTool> Function(AgentRun)? collaborationTools,
    this.prepareRun,
    this.prepareCompletion,
    this.beforeUserInput,
    this.collaborationInstructions,
  }) : _snapshot = snapshot,
       _tools = {for (final tool in tools) tool.name: tool},
       _sequence = snapshot.sequence {
    for (final tool in contextBuilder.runtimeTools(
      () => _snapshot,
      tools.toList(),
    )) {
      if (_tools.containsKey(tool.name)) {
        throw ArgumentError('Reserved runtime tool name: ${tool.name}');
      }
      _tools[tool.name] = tool;
    }
    for (final tool in collaborationTools?.call(this) ?? <AgentTool>[]) {
      if (_tools.containsKey(tool.name)) {
        throw ArgumentError('Reserved collaboration tool name: ${tool.name}');
      }
      _tools[tool.name] = tool;
    }
  }

  final RunDiagnostics diagnostics = RunDiagnostics();
  final ModelAdapter model;
  final ContextBuilder contextBuilder;
  final SessionStore store;
  final CompletionCheck? completionCheck;
  final Map<String, AgentTool> _tools;
  final Future<void> Function() _release;

  /// The optional hook that restores runtime dependencies before execution.
  final Future<void> Function(AgentRun)? prepareRun;

  /// The optional hook that returns whether completion added more work.
  final Future<bool> Function(AgentRun)? prepareCompletion;

  /// The optional hook that stops owned work before awaiting a user decision.
  final Future<void> Function(AgentRun)? beforeUserInput;

  /// The optional runtime instructions included in model requests.
  final String Function(AgentRun)? collaborationInstructions;
  SessionSnapshot _snapshot;
  final CancellationToken cancellation = CancellationToken();

  void Function()? _revokeResourceWrites;
  ResourceTaskLease? _resourceTaskLease;
  Future<void>? _remoteRevocation;

  /// Binds an acknowledged resource lease before this activation starts.
  void bindResourceTaskLease(ResourceTaskLease lease) {
    if (_started || _resourceTaskLease != null) {
      throw StateError(
        'Remote resource authority already bound or run started',
      );
    }
    _resourceTaskLease = lease;
  }

  Future<void> _revokeRemoteWrites() => _remoteRevocation ??=
      _resourceTaskLease?.revoke() ?? Future<void>.value();

  /// Binds resource submission authority before this activation starts.
  void bindResourceCommitGuard(ResourceCommitGuard guard) {
    if (_started || _revokeResourceWrites != null) {
      throw StateError('Resource write authority already bound or run started');
    }
    _revokeResourceWrites = guard.registerRun(_snapshot, cancellation);
  }

  final StreamController<AgentEvent> _events = StreamController.broadcast();
  final Completer<SessionSnapshot> _done = Completer();
  Future<void> _writes = Future.value();
  Object? _writeFailure;
  StackTrace? _writeFailureTrace;
  bool _pause = false;
  bool _started = false;
  bool _settling = false;
  bool _verifying = false;
  int _sequence;
  final Set<Future<void>> _children = {};

  AgentRunPhase _phase = AgentRunPhase.responding;
  AgentRunPhase get phase => _phase;

  void _setPhase(AgentRunPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _emit(AgentEventKind.phase, phase.name);
  }

  SessionSnapshot get snapshot => _snapshot;
  Stream<AgentEvent> get events => _events.stream;
  Future<SessionSnapshot> get done => _done.future;
  bool get isSettled => _done.isCompleted;
  bool get acceptsChildren =>
      !_settling && !isSettled && !cancellation.isCancelled;
  Set<String> get toolNames => Set.unmodifiable(_tools.keys);

  /// Keeps owned children within the parent's settlement boundary.
  void trackChild(Future<SessionSnapshot> child) {
    if (_settling || isSettled) throw StateError('Parent is settling');
    final settled = child.then<void>(
      (_) {},
      onError: (Object error, StackTrace trace) {},
    );
    _children.add(settled);
    unawaited(
      settled.then((_) {
        _children.remove(settled);
      }),
    );
  }

  Future<void> _joinChildren() async {
    while (_children.isNotEmpty) {
      await Future.wait(_children.toList());
    }
  }

  /// Durably reserves child identity and budget before a child is started.
  Future<void> reserveChild(
    String sessionId, {
    required int turns,
    required int maxChildren,
    required int maxDelegatedTurns,
    String? reservationKey,
    Map<String, Object?> reservation = const {},
    bool reuseChild = false,
  }) {
    if (_settling || isSettled || cancellation.isCancelled) {
      throw StateError('Parent is not active');
    }
    return _save((s) {
      final reservations = Map<String, Object?>.from(
        s.agentState['reservations'] as Map? ?? const {},
      );
      if (reservationKey != null && reservations.containsKey(reservationKey)) {
        return {};
      }
      final exists = s.childSessionIds.contains(sessionId);
      if ((exists && !reuseChild) ||
          (!exists && s.childSessionIds.length >= maxChildren) ||
          turns <= 0 ||
          s.delegatedTurns + turns > maxDelegatedTurns) {
        throw const DelegationLimit();
      }
      return {
        'childSessionIds': [...s.childSessionIds, if (!exists) sessionId],
        'delegatedTurns': s.delegatedTurns + turns,
        if (reservationKey != null)
          'agentState': {
            ...s.agentState,
            'reservations': {...reservations, reservationKey: reservation},
          },
      };
    });
  }

  /// Commits collaboration metadata and an optional runtime notice atomically.
  Future<void> checkpointAgentState(
    Map<String, Object?> Function(Map<String, Object?>) change, {
    String? notice,
  }) => _save(
    (s) => {
      'agentState': change(s.agentState),
      if (notice != null)
        'history': [
          ...s.history.map((m) => m.toJson()),
          AgentMessage(
            role: MessageRole.user,
            text: notice,
            runtimeNotice: true,
          ).toJson(),
        ],
    },
  );

  Future<void> _flushAgentInbox() async {
    if ((_snapshot.agentState['inbox'] as List? ?? const []).isEmpty) return;
    await _save(
      (s) => {
        'agentState': {...s.agentState, 'inbox': <Object?>[]},
        'history': [
          ...s.history.map((m) => m.toJson()),
          for (final text in s.agentState['inbox'] as List)
            AgentMessage(
              role: MessageRole.user,
              text: text as String,
              runtimeNotice: true,
            ).toJson(),
        ],
      },
    );
  }

  /// Persists a question and suspends the current tool batch without a result.
  Future<Never> requestUserInput(UserInputRequest request) async {
    if (_snapshot.parentSessionId != null) {
      throw StateError('Only the primary agent may request user input');
    }
    await _save(
      (s) => {
        'pendingUserInput': request.toJson(),
        'status': RunStatus.waitingUser.name,
      },
    );
    await beforeUserInput?.call(this);
    _emit(AgentEventKind.userInputRequested, jsonEncode(request.toJson()));
    throw const UserInputPending();
  }

  String get _requestSystem =>
      '${_snapshot.system}${collaborationInstructions?.call(this) ?? ''}';

  /// Called by SessionManager after the checkpoint and writer lease exist.
  void start() {
    if (_started) throw StateError('Run already started');
    _started = true;
    unawaited(diagnostics.scope(_drive));
  }

  Future<SessionSnapshot> pause() {
    _pause = true;
    return done;
  }

  Future<void>? _stopCheckpoint;

  Future<SessionSnapshot> cancel() async {
    if (_resourceTaskLease case ResourceTaskAdmissionLease lease) {
      lease.stopAdmission();
    }
    if (_resourceTaskLease case RenewableResourceTaskLease lease) {
      lease.stopRenewal();
    }
    _revokeResourceWrites?.call();
    if ((_settling && !_verifying && _children.isEmpty) || isSettled) {
      return done;
    }
    final checkpoint = _stopCheckpoint ??= _save(
      (s) => {'stopRequested': true, 'queued': <String>[]},
    );
    cancellation.cancel();
    await checkpoint;
    await _revokeRemoteWrites();
    return done;
  }

  Future<void> steer(String message) {
    if (_settling || isSettled || cancellation.isCancelled) {
      throw StateError('Run is not accepting instructions');
    }
    if (message.trim().isEmpty) throw ArgumentError('Empty instruction');
    return _save(
      (s) => {
        'queued': [...s.queued, message],
      },
    );
  }

  void _emit(AgentEventKind kind, String text, {String? callId}) {
    if (_events.isClosed) return;
    _events.add(
      AgentEvent(
        sessionId: _snapshot.id,
        runId: _snapshot.runId!,
        sequence: ++_sequence,
        kind: kind,
        text: text,
        callId: callId,
      ),
    );
  }

  Future<void> _save(Map<String, Object?> Function(SessionSnapshot) change) {
    final next = _writes.then(
      (_) => diagnostics.measure('save', () async {
        if (_writeFailure != null) {
          Error.throwWithStackTrace(_writeFailure!, _writeFailureTrace!);
        }
        final updated = _snapshot.update({
          ...change(_snapshot),
          'revision': _snapshot.revision + 1,
          'sequence': _sequence,
        });
        await store.save(updated, expectedRevision: _snapshot.revision);
        _snapshot = updated;
      }),
    );
    // A failed write remains a barrier: no later side effect can cross it.
    _writes = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace trace) {
        if (error is! DelegationLimit) {
          _writeFailure ??= error;
          _writeFailureTrace ??= trace;
        }
      },
    );
    return next;
  }

  Future<void> _drainWrites() async {
    while (true) {
      final tail = _writes;
      await tail;
      if (_writeFailure != null) {
        Error.throwWithStackTrace(_writeFailure!, _writeFailureTrace!);
      }
      if (identical(tail, _writes)) return;
    }
  }

  Future<void> _state(
    RunStatus status, [
    String? error,
    RunFailure? failure,
  ]) async {
    final sequence = ++_sequence;
    await _save(
      (s) => {'status': status.name, 'error': error, 'failure': failure?.name},
    );
    _events.add(
      AgentEvent(
        sessionId: _snapshot.id,
        runId: _snapshot.runId!,
        sequence: sequence,
        kind: AgentEventKind.state,
        text: status.name,
      ),
    );
  }

  ToolContext _toolContext(CallRecord record) => ToolContext(
    sessionId: _snapshot.id,
    runId: _snapshot.runId!,
    operationId: record.operationId,
    cancellation: cancellation,
    onProgress: (text) =>
        _emit(AgentEventKind.toolProgress, text, callId: record.call.id),
  );

  Future<void> _replace(int index, CallRecord record) => _save(
    (s) => {
      'pending': [
        for (var i = 0; i < s.pending.length; i++)
          (i == index ? record : s.pending[i]).toJson(),
      ],
    },
  );

  Future<void> _finish(int index, ToolResult result) async {
    final record = _snapshot.pending[index];
    result = await contextBuilder.prepareToolResult(
      call: record.call,
      result: result,
      snapshot: _snapshot,
      system: _requestSystem,
      tools: _tools.values.toList(),
      cancellation: cancellation,
    );
    await _save(
      (s) => {
        'pending': [
          for (var i = 0; i < s.pending.length; i++)
            (i == index ? record.finished(result) : s.pending[i]).toJson(),
        ],
        'history': [
          ...s.history.map((m) => m.toJson()),
          AgentMessage(
            role: MessageRole.tool,
            callId: record.call.id,
            resultId: record.operationId,
            text: jsonEncode(result.toJson()),
            isError: result.isError,
          ).toJson(),
        ],
      },
    );
    _emit(AgentEventKind.toolFinished, result.text, callId: record.call.id);
  }

  Future<bool> _executePending() async {
    for (var i = 0; i < _snapshot.pending.length; i++) {
      var record = _snapshot.pending[i];
      if (record.status == CallStatus.finished) continue;
      final tool = _tools[record.call.name];
      if (record.status == CallStatus.started) {
        final recover = tool?.recover;
        if (recover == null) {
          await _state(
            RunStatus.waiting,
            'Cannot establish outcome: ${record.operationId}',
          );
          return false;
        }
        ToolRecovery recovery;
        try {
          recovery = await recover(record.call, _toolContext(record));
        } on UserInputPending {
          await _state(RunStatus.waitingUser);
          return false;
        } catch (error) {
          await _state(RunStatus.waiting, 'Recovery failed: $error');
          return false;
        }
        switch (recovery.status) {
          case RecoveryStatus.completed:
            await _finish(i, recovery.result!);
            continue;
          case RecoveryStatus.running:
          case RecoveryStatus.unknown:
            await _state(
              RunStatus.waiting,
              'Tool outcome: ${recovery.status.name}',
            );
            return false;
          case RecoveryStatus.notStarted:
            record = CallRecord(
              call: record.call,
              operationId: record.operationId,
            );
            await _replace(i, record);
        }
      }
      if (cancellation.isCancelled) {
        await _finish(
          i,
          ToolResult(
            'Cancelled before execution by user',
            isError: true,
            data: {'code': 'cancelled', 'executed': false},
          ),
        );
        continue;
      }
      if (_pause) return true;
      if (tool == null) {
        await _finish(
          i,
          ToolResult('Unknown tool: ${record.call.name}', isError: true),
        );
        continue;
      }
      String? validation;
      try {
        validation = tool.validate(record.call.arguments);
      } catch (error) {
        validation = 'Invalid arguments: $error';
      }
      if (validation != null) {
        await _finish(i, ToolResult(validation, isError: true));
        continue;
      }
      record = record.started();
      await _replace(i, record);
      if (cancellation.isCancelled || _pause) {
        // The checkpoint reserved execution, but no tool has been invoked.
        if (cancellation.isCancelled) {
          await _finish(
            i,
            ToolResult(
              'Cancelled before execution by user',
              isError: true,
              data: {'code': 'cancelled', 'executed': false},
            ),
          );
          continue;
        }
        await _replace(
          i,
          CallRecord(call: record.call, operationId: record.operationId),
        );
        return true;
      }
      _emit(
        AgentEventKind.toolStarted,
        record.call.name,
        callId: record.call.id,
      );
      ToolResult result;
      try {
        result = await diagnostics.measure(
          'tool',
          () => tool.execute(record.call, _toolContext(record)),
        );
      } on UserInputPending {
        await _state(RunStatus.waitingUser);
        return false;
      } catch (error) {
        await _state(
          RunStatus.waiting,
          'Tool outcome requires reconciliation: $error',
        );
        return false;
      }
      await _finish(i, result);
    }
    if (_snapshot.pending.every((c) => c.status == CallStatus.finished)) {
      await _save((s) => {'pending': <Object?>[]});
    }
    return true;
  }

  Future<void> _loop() async {
    if (_snapshot.stopRequested) cancellation.cancel();
    if (_snapshot.pendingUserInput != null) {
      await _state(RunStatus.waitingUser);
      return;
    }
    await _state(RunStatus.running);
    while (true) {
      if (_snapshot.pending.isNotEmpty && !await _executePending()) return;
      if (cancellation.isCancelled) {
        await _state(RunStatus.cancelled);
        return;
      }
      if (_pause) {
        await _state(RunStatus.paused);
        return;
      }
      // Flush already accepted steering writes before deciding to finish.
      await _writes;
      await _flushAgentInbox();
      if (_snapshot.queued.isNotEmpty) {
        await _save(
          (s) => {
            'history': [
              ...s.history.map((m) => m.toJson()),
              for (final text in s.queued)
                AgentMessage(role: MessageRole.user, text: text).toJson(),
            ],
            'queued': <String>[],
          },
        );
      }
      if (_snapshot.history.lastOrNull case final last?
          when last.role == MessageRole.assistant && last.calls.isEmpty) {
        if (await prepareCompletion?.call(this) ?? false) continue;
        final reminder = contextBuilder.completionReminder(
          _snapshot.history.sublist(_snapshot.runStart),
        );
        if (reminder != null && _snapshot.turns < _snapshot.maxTurns) {
          await _save(
            (s) => {
              'history': [
                ...s.history.map((m) => m.toJson()),
                AgentMessage(
                  role: MessageRole.user,
                  text: reminder,
                  runtimeNotice: true,
                ).toJson(),
              ],
            },
          );
          continue;
        }
        if (reminder != null) {
          await _state(
            RunStatus.paused,
            'Unfinished plan; model turn budget exhausted',
          );
          return;
        }
        _settling = true;
        await _writes;
        if (_snapshot.queued.isNotEmpty ||
            (_snapshot.agentState['inbox'] as List? ?? const []).isNotEmpty) {
          _settling = false;
          continue;
        }
        await _joinChildren();
        if (completionCheck case final check?) {
          cancellation.throwIfCancelled();
          _emit(AgentEventKind.toolStarted, 'completion_check');
          _verifying = true;
          final ToolResult evidence;
          try {
            evidence = await check(_snapshot, cancellation);
          } finally {
            _verifying = false;
          }
          cancellation.throwIfCancelled();
          await _writes;
          if (_snapshot.queued.isNotEmpty || _pause) {
            _settling = false;
            continue;
          }
          await _save(
            (s) => {
              'completionEvidence': {
                'runId': s.runId,
                'result': evidence.toJson(),
              },
            },
          );
          if (evidence.isError) {
            _settling = false;
            if (_snapshot.turns >= _snapshot.maxTurns) {
              await _state(
                RunStatus.paused,
                'Artifact verification has unresolved differences',
              );
              return;
            }
            await _save(
              (s) => {
                'history': [
                  ...s.history.map((m) => m.toJson()),
                  AgentMessage(
                    role: MessageRole.user,
                    runtimeNotice: true,
                    text:
                        '[Runtime artifact verification, not a new user request] '
                        '${jsonEncode(evidence.toJson())} '
                        'Inspect current state and resolve these differences before declaring completion. '
                        'Do not change the acceptance criteria merely to match incorrect output.',
                  ).toJson(),
                ],
                'completionEvidence': null,
              },
            );
            continue;
          }
        }
        await _state(
          cancellation.isCancelled
              ? RunStatus.cancelled
              : (_pause ? RunStatus.paused : RunStatus.completed),
        );
        return;
      }
      if (_snapshot.turns >= _snapshot.maxTurns) {
        await _state(RunStatus.paused, 'Model turn budget exhausted');
        return;
      }
      await _compactContext();
      final request = await diagnostics.measure(
        'prepare',
        () => contextBuilder.build(
          system: _requestSystem,
          history: _snapshot.history,
          tools: _tools.values.toList(),
          cancellation: cancellation,
          skillIds: _snapshot.skillIds,
          memoryScope: _snapshot.memoryScope,
          summary: _snapshot.summaries.lastOrNull,
          requiredHistoryStart: _snapshot.runStart,
          taskStart: _snapshot.runStart,
        ),
      );
      await _drainWrites();
      cancellation.throwIfCancelled();
      if (_pause ||
          _snapshot.queued.isNotEmpty ||
          (_snapshot.agentState['inbox'] as List? ?? const []).isNotEmpty) {
        continue;
      }
      await _save((s) => {'turns': s.turns + 1});
      await _drainWrites();
      if (cancellation.isCancelled ||
          _pause ||
          _snapshot.queued.isNotEmpty ||
          (_snapshot.agentState['inbox'] as List? ?? const []).isNotEmpty) {
        // No provider request was dispatched: release the reserved turn.
        await _save((s) => {'turns': s.turns - 1});
        continue;
      }
      ModelResponse? response;
      await for (final event in diagnostics.modelEvents(
        model,
        request,
        cancellation,
        summary: false,
      )) {
        cancellation.throwIfCancelled();
        if (response != null) {
          throw StateError('Model emitted an event after its final response');
        }
        switch (event) {
          case TextDelta():
            _emit(AgentEventKind.textDelta, event.text);
          case ModelResponse():
            response = event;
        }
      }
      cancellation.throwIfCancelled();
      if (response == null) {
        throw StateError('Model stream ended without a final response');
      }
      if (response.text.trim().isEmpty && response.calls.isEmpty) {
        throw const ModelProtocolException('Empty model response');
      }
      final seen = _snapshot.history
          .skip(_snapshot.runStart)
          .expand((m) => m.calls)
          .map((c) => c.id)
          .toSet();
      for (final call in response.calls) {
        if (!seen.add(call.id)) {
          throw StateError('Duplicate tool call ID: ${call.id}');
        }
      }
      final message = AgentMessage(
        role: MessageRole.assistant,
        text: response.text,
        calls: [
          for (final call in response.calls)
            ToolCall(
              id: call.id,
              name: call.name,
              arguments: _tools[call.name] == null
                  ? call.arguments
                  : normalizeToolArguments(
                      call.arguments,
                      _tools[call.name]!.parameters,
                    ),
            ),
        ],
        providerData: response.providerData,
        usage: response.usage,
      );
      await _save(
        (s) => {
          'history': [...s.history.map((m) => m.toJson()), message.toJson()],
          'pending': [
            for (final call in message.calls)
              CallRecord(
                call: call,
                operationId: jsonEncode([s.id, s.runId, call.id]),
              ).toJson(),
          ],
        },
      );
      _emit(AgentEventKind.message, message.text);
    }
  }

  /// Runs under the existing writer lease, after pending tools have settled.
  Future<void> _compactContext() async {
    try {
      await diagnostics.measure('compactionCheck', _compactContextInner);
    } finally {
      _setPhase(AgentRunPhase.responding);
    }
  }

  Future<void> _compactContextInner() async {
    final summarizer = contextBuilder.summarizer;
    if (summarizer == null || _snapshot.pending.isNotEmpty) return;
    final history = _snapshot.history;
    final previous = _snapshot.summaries.lastOrNull;
    final covered = previous?.coveredMessages ?? 0;
    var before = contextBuilder.maxInputTokens + 1;
    try {
      // Retain the full uncovered span when measuring: ordinary construction
      // may prune older turns, which would hide the need to summarize them.
      final projected = await contextBuilder.build(
        system: _requestSystem,
        history: history,
        tools: _tools.values.toList(),
        cancellation: cancellation,
        skillIds: _snapshot.skillIds,
        memoryScope: _snapshot.memoryScope,
        summary: previous,
        requiredHistoryStart: covered,
        taskStart: _snapshot.runStart,
      );
      before = contextBuilder.measureInput(
        system: projected.system,
        history: projected.messages,
        tools: projected.tools,
      );
    } on ContextOverflow {
      // Full projected context does not fit; summarize before pruning.
    }
    // Fixed instructions/tool schemas cannot be summarized. Reserve headroom
    // from the remaining message capacity, otherwise a large catalog alone
    // can trigger compaction after every small query.
    final fixed = contextBuilder.measureInput(
      system: contextBuilder.prepareSystem(
        _requestSystem,
        history,
        taskStart: _snapshot.runStart,
      ),
      tools: contextBuilder.selectTools(history, _tools.values.toList()),
    );
    if (fixed >= contextBuilder.maxInputTokens) return;
    final messageCapacity = (contextBuilder.maxInputTokens - fixed).clamp(
      0,
      contextBuilder.maxInputTokens,
    );
    final threshold = fixed + messageCapacity * .8;
    if (before < threshold && before <= contextBuilder.maxInputTokens) return;
    // Retain recent complete batches. A single oversized batch can be folded
    // once every result is durable, leaving a summary as continuation context.
    var boundary = history.length;
    final recentBudget = (contextBuilder.maxInputTokens * .25).floor();
    for (var i = history.length - 1; i > covered; i--) {
      if (!isSafeSummaryBoundary(history, i)) continue;
      final size = contextBuilder.measureInput(
        system: '',
        history: contextBuilder.projectHistory(history.sublist(i)),
      );
      if (size > recentBudget) break;
      boundary = i;
    }
    if (boundary <= covered) return;
    String text;
    _setPhase(AgentRunPhase.compacting);
    try {
      text = await diagnostics.measure(
        'summary',
        () => summarizer.summarize([
          if (previous != null)
            AgentMessage(
              role: MessageRole.user,
              text: 'Previous continuation summary: ${previous.text}',
            ),
          ...contextBuilder.projectHistory(history.sublist(covered, boundary)),
        ], cancellation),
      );
    } on AgentCancelled {
      rethrow;
    } catch (_) {
      // No checkpoint is changed on failure. Normal request construction still
      // enforces the hard budget, so an oversized request is never dispatched.
      return;
    }
    cancellation.throwIfCancelled();
    if (text.trim().isEmpty) return;
    final after = contextBuilder.measureInput(
      system:
          '${contextBuilder.prepareSystem(_requestSystem, history, taskStart: _snapshot.runStart)}\n$text',
      history: contextBuilder.projectHistory(history.sublist(boundary)),
      tools: contextBuilder.selectTools(history, _tools.values.toList()),
    );
    if (after >= before || after > contextBuilder.maxInputTokens) return;
    final summary = ContextSummary(
      text: text,
      coveredMessages: boundary,
      source: summarizer.source,
    );
    // Validate the actual request, including required skills and framing,
    // before publishing a checkpoint. Never replace history with an unusable
    // summary merely because a rough size estimate looked smaller.
    try {
      await contextBuilder.build(
        system: _requestSystem,
        history: history,
        tools: _tools.values.toList(),
        cancellation: cancellation,
        skillIds: _snapshot.skillIds,
        memoryScope: _snapshot.memoryScope,
        summary: summary,
        requiredHistoryStart: _snapshot.runStart,
        taskStart: _snapshot.runStart,
      );
    } on ContextOverflow {
      return;
    }
    await _save(
      (s) => {
        'summaries': [
          ...s.summaries.map((item) => item.toJson()),
          summary.toJson(),
        ],
      },
    );
  }

  Future<void> _drive() async {
    Object? failure;
    StackTrace? trace;
    try {
      await prepareRun?.call(this);
      await _loop();
    } catch (error) {
      try {
        await _state(
          error is AgentCancelled ? RunStatus.cancelled : RunStatus.failed,
          error.toString(),
          switch (error) {
            ContextOverflow() => RunFailure.contextBudget,
            ModelHttpException(statusCode: 401 || 403) =>
              RunFailure.authentication,
            ModelHttpException() ||
            ModelConnectionException() ||
            TimeoutException() => RunFailure.connection,
            ModelProtocolException() ||
            FormatException() => RunFailure.protocol,
            AgentCancelled() => null,
            _ => RunFailure.request,
          },
        );
      } catch (storageError, storageTrace) {
        failure = storageError;
        trace = storageTrace;
      }
    } finally {
      _settling = true;
      if (_snapshot.status == RunStatus.failed || _writeFailure != null) {
        cancellation.cancel();
      }
      if (cancellation.isCancelled &&
          _resourceTaskLease is ResourceTaskAdmissionLease) {
        (_resourceTaskLease as ResourceTaskAdmissionLease).stopAdmission();
      }
      if (cancellation.isCancelled &&
          _resourceTaskLease is RenewableResourceTaskLease) {
        (_resourceTaskLease as RenewableResourceTaskLease).stopRenewal();
      }
      await _joinChildren();
      try {
        await _writes;
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
      failure ??= _writeFailure;
      trace ??= _writeFailureTrace;
      if (_resourceTaskLease case ResourceTaskAdmissionLease lease) {
        lease.stopAdmission();
      }
      if (_resourceTaskLease case RenewableResourceTaskLease lease) {
        lease.stopRenewal();
      }
      try {
        _revokeResourceWrites?.call();
        await _revokeRemoteWrites();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
      try {
        await _release();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
      // Closing a broadcast stream must not block settlement on a paused UI.
      unawaited(_events.close());
      if (failure != null) {
        _done.completeError(failure, trace);
      } else {
        _done.complete(_snapshot);
      }
    }
  }
}
