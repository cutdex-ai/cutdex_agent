import 'dart:convert';
import 'dart:math';

import '../context/context.dart';
import '../context/harness_context.dart';
import '../context/model_summarizer.dart';
import '../context/summary.dart';
import '../run/cancellation.dart';
import '../run/completion_check.dart';
import '../model/adapter.dart';
import '../model/messages.dart';
import '../run/agent_run.dart';
import '../storage/store.dart';
import '../tools/tool.dart';
import 'snapshot.dart';

class SessionManager {
  SessionManager({
    required this.model,
    required this.store,
    this.completionCheck,
    ContextBuilder? contextBuilder,
    Iterable<AgentTool> tools = const [],
    String Function()? newId,
  }) : contextBuilder =
           contextBuilder ??
           HarnessContextBuilder(
             summarizer: ModelContextSummarizer(
               model: model,
               budget: ContextBuilder(),
             ),
           ),
       tools = List.unmodifiable(tools),
       _newId = newId ?? _randomId {
    if (this.tools.map((t) => t.name).toSet().length != this.tools.length) {
      throw ArgumentError('Duplicate tool names');
    }
  }
  final ModelAdapter model;
  final SessionStore store;
  final CompletionCheck? completionCheck;
  final ContextBuilder contextBuilder;
  final List<AgentTool> tools;
  final String Function() _newId;
  static String _randomId() {
    final random = Random.secure();
    return base64Url.encode(List.generate(18, (_) => random.nextInt(256)));
  }

  Future<SessionSnapshot> create({
    String? id,
    String system = '',
    String? memoryScope,
    List<String> skillIds = const [],
    String? parentSessionId,
    String? parentRunId,
    int depth = 0,
  }) async {
    final sessionId = id ?? _newId();
    if (sessionId.isEmpty || depth < 0) {
      throw ArgumentError('Invalid session identity or depth');
    }
    final snapshot = SessionSnapshot(
      id: sessionId,
      system: system,
      memoryScope: memoryScope,
      skillIds: skillIds,
      parentSessionId: parentSessionId,
      parentRunId: parentRunId,
      depth: depth,
    );
    await store.save(snapshot, expectedRevision: null);
    return snapshot;
  }

  /// Appends a summary over completed earlier turns while retaining history.
  /// Requires an idle session; a summary never splits tool calls/results.
  Future<SessionSnapshot> compact(
    String sessionId,
    ContextSummarizer summarizer, {
    CancellationToken? cancellation,
  }) async {
    final token = cancellation ?? CancellationToken();
    final lease = await store.acquire(sessionId);
    try {
      final snapshot = await store.read(sessionId);
      if (snapshot == null) throw StateError('Session not found');
      if (snapshot.pending.isNotEmpty) {
        throw StateError('Reconcile pending tools before compaction');
      }
      final boundary = snapshot.history.lastIndexWhere(
        (m) => m.role == MessageRole.user,
      );
      if (boundary <= 0 ||
          boundary <= (snapshot.summaries.lastOrNull?.coveredMessages ?? 0)) {
        return snapshot;
      }
      token.throwIfCancelled();
      final text = await summarizer.summarize(
        List.unmodifiable(snapshot.history.take(boundary)),
        token,
      );
      token.throwIfCancelled();
      if (text.trim().isEmpty) throw StateError('Empty summary');
      final summary = ContextSummary(
        text: text,
        coveredMessages: boundary,
        source: summarizer.source,
      );
      final updated = snapshot.update({
        'revision': snapshot.revision + 1,
        'summaries': [
          ...snapshot.summaries.map((s) => s.toJson()),
          summary.toJson(),
        ],
      });
      await store.save(updated, expectedRevision: snapshot.revision);
      return updated;
    } finally {
      await store.release(sessionId, lease);
    }
  }

  /// Updates host instructions atomically with a new turn when supplied.
  Future<AgentRun> prompt(
    String sessionId,
    String text, {
    int maxTurns = 20,
    String? system,
  }) => _open(sessionId, text: text, maxTurns: maxTurns, system: system);

  /// Reconciles pending operations before another model call. Tool availability
  /// and semantics must remain compatible with the stored calls.
  Future<AgentRun> resume(String sessionId, {int? maxTurns}) =>
      _open(sessionId, maxTurns: maxTurns);

  Future<AgentRun> _open(
    String sessionId, {
    String? text,
    int? maxTurns,
    String? system,
  }) async {
    if (maxTurns != null && maxTurns <= 0) {
      throw ArgumentError('maxTurns must be positive');
    }
    if (text != null && text.trim().isEmpty) {
      throw ArgumentError('Empty prompt');
    }
    final lease = await store.acquire(sessionId);
    try {
      var snapshot = await store.read(sessionId);
      if (snapshot == null) throw StateError('Session not found: $sessionId');
      if (text != null) {
        if (snapshot.pending.isNotEmpty ||
            snapshot.queued.isNotEmpty ||
            snapshot.status == RunStatus.paused ||
            snapshot.status == RunStatus.waiting ||
            snapshot.status == RunStatus.running) {
          throw StateError('Resume the unfinished run before starting another');
        }
        snapshot = snapshot.update({
          'runId': _newId(),
          'system': ?system,
          'runStart': snapshot.history.length,
          'turns': 0,
          'stopRequested': false,
          'childSessionIds': <String>[],
          'delegatedTurns': 0,
          'maxTurns': maxTurns!,
          'error': null,
          'failure': null,
          'history': [
            ...snapshot.history.map((m) => m.toJson()),
            AgentMessage(role: MessageRole.user, text: text).toJson(),
          ],
        });
      } else {
        if (snapshot.runId == null || snapshot.status == RunStatus.completed) {
          throw StateError('No unfinished execution');
        }
        if (maxTurns != null) {
          snapshot = snapshot.update({'maxTurns': maxTurns});
        }
      }
      final previousRevision = snapshot.revision;
      snapshot = snapshot.update({
        'revision': previousRevision + 1,
        'status': RunStatus.running.name,
        'completionEvidence': null,
        if (text == null && snapshot.status == RunStatus.cancelled)
          'stopRequested': true,
      });
      await store.save(snapshot, expectedRevision: previousRevision);
      final run = AgentRun(
        snapshot: snapshot,
        model: model,
        contextBuilder: contextBuilder,
        completionCheck: completionCheck,
        store: store,
        tools: tools,
        release: () => store.release(sessionId, lease),
      );
      run.start();
      return run;
    } catch (_) {
      await store.release(sessionId, lease);
      rethrow;
    }
  }
}
