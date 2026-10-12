import 'dart:convert';
import 'dart:math';

import '../context/context.dart';
import '../context/harness_context.dart';
import '../context/model_summarizer.dart';
import '../context/summary.dart';
import '../coordinator/multi_agent.dart';
import '../run/cancellation.dart';
import '../run/completion_check.dart';
import '../model/adapter.dart';
import '../model/messages.dart';
import '../run/agent_run.dart';
import '../storage/store.dart';
import '../tools/tool.dart';
import '../tools/resource_commit_guard.dart';
import '../tools/resource_task_authority.dart';
import 'snapshot.dart';

class SessionManager {
  SessionManager({
    required this.model,
    required this.store,
    this.completionCheck,
    this.multiAgent,
    this.resourceCommitGuard,
    this.resourceTaskAuthority,
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
    if (multiAgent != null &&
        this.tools.any((t) => MultiAgentRuntime.toolNames.contains(t.name))) {
      throw ArgumentError('Host tool conflicts with a collaboration tool');
    }
  }

  /// The optional model-directed collaboration limits.
  final MultiAgentConfig? multiAgent;

  /// The optional write authority shared with resource submission tools.
  final ResourceCommitGuard? resourceCommitGuard;

  /// The optional external authority acknowledged before work and after stopping.
  final ResourceTaskAuthority? resourceTaskAuthority;
  late final MultiAgentRuntime _team = MultiAgentRuntime(this, multiAgent!);
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
    Iterable<AgentMessage> history = const [],
    Map<String, Object?> agentState = const {},
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
      history: history,
      agentState: agentState,
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
    String? agentInputOperationId,
  }) => _open(
    sessionId,
    text: text,
    maxTurns: maxTurns,
    system: system,
    agentInputOperationId: agentInputOperationId,
  );

  /// Reconciles pending operations before another model call. Tool availability
  /// and semantics must remain compatible with the stored calls.
  Future<AgentRun> resume(String sessionId, {int? maxTurns}) =>
      _open(sessionId, maxTurns: maxTurns);

  /// Answers the current question and resumes the same logical execution.
  ///
  /// Supply a listed option ID or free text. Stale or duplicate answers are
  /// rejected before changing the checkpoint. Later calls from the question's
  /// tool batch are discarded so the model can reconsider them with the answer.
  Future<AgentRun> answerUserInput(
    String sessionId, {
    required String requestId,
    String? optionId,
    String? text,
    int? maxTurns,
  }) => _open(
    sessionId,
    maxTurns: maxTurns,
    answer: {'requestId': requestId, 'optionId': optionId, 'text': text},
  );

  SessionSnapshot _answer(
    SessionSnapshot snapshot,
    Map<String, Object?> answer,
  ) {
    final question = snapshot.pendingUserInput;
    if (question == null || question.id != answer['requestId']) {
      throw StateError('No matching pending user question');
    }
    final optionId = answer['optionId'] as String?;
    final text = answer['text'] as String?;
    final option = question.options.where((o) => o.id == optionId).firstOrNull;
    if ((optionId == null) == (text == null) ||
        (optionId != null && option == null) ||
        (text != null && text.trim().isEmpty)) {
      throw ArgumentError('Supply one listed optionId or nonempty text');
    }
    final index = snapshot.pending.indexWhere(
      (c) =>
          c.operationId == question.id && c.call.name == 'request_user_input',
    );
    if (index < 0 ||
        snapshot.pending[index].status != CallStatus.started ||
        snapshot.pending
            .take(index)
            .any((c) => c.status != CallStatus.finished) ||
        snapshot.pending
            .skip(index + 1)
            .any((c) => c.status != CallStatus.planned)) {
      throw StateError('User question has an inconsistent tool checkpoint');
    }
    final result = ToolResult(
      'User answered; continue with this decision',
      data: {
        'request_id': question.id,
        if (option != null) 'option_id': option.id,
        if (option != null) 'label': option.label,
        'text': ?text,
      },
    );
    final history = [...snapshot.history.map((m) => m.toJson())];
    for (final record in snapshot.pending.skip(index)) {
      final response = record.operationId == question.id
          ? result
          : ToolResult(
              'Not executed: superseded by user input. Re-evaluate with the user decision.',
              isError: true,
              data: {'code': 'superseded_by_user_input', 'executed': false},
            );
      history.add(
        AgentMessage(
          role: MessageRole.tool,
          callId: record.call.id,
          resultId: record.operationId,
          text: jsonEncode(response.toJson()),
          isError: response.isError,
        ).toJson(),
      );
    }
    for (final queued in snapshot.queued) {
      history.add(AgentMessage(role: MessageRole.user, text: queued).toJson());
    }
    history.add(
      AgentMessage(
        role: MessageRole.user,
        text:
            'User decision for question: ${question.question}\n'
            '${option == null ? text : '${option.id}: ${option.label}'}\n'
            'Continue this task according to this choice; superseded goals must not be executed.',
      ).toJson(),
    );
    return snapshot.update({
      'history': history,
      'pending': <Object?>[],
      'pendingUserInput': null,
      'queued': <String>[],
      'error': null,
      'agentState': {
        ...snapshot.agentState,
        'operations': {
          ...(snapshot.agentState['operations'] as Map? ?? const {})
              .cast<String, Object?>(),
          question.id: result.toJson(),
        },
      },
    });
  }

  Future<AgentRun> _open(
    String sessionId, {
    String? text,
    int? maxTurns,
    String? system,
    String? agentInputOperationId,
    Map<String, Object?>? answer,
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
      if (answer != null) snapshot = _answer(snapshot, answer);
      if (text != null) {
        if (snapshot.pending.isNotEmpty ||
            snapshot.queued.isNotEmpty ||
            snapshot.status == RunStatus.paused ||
            snapshot.status == RunStatus.waiting ||
            snapshot.pendingUserInput != null ||
            snapshot.status == RunStatus.running) {
          throw StateError('Resume the unfinished run before starting another');
        }
        // A root's mailbox belongs to its previous run. Preserve late child
        // reports as earlier history rather than delivering them after the new
        // user task. Child followup turns keep their parent's queued messages.
        final archiveRootInbox =
            snapshot.parentSessionId == null && snapshot.runId != null;
        final archivedInbox = archiveRootInbox
            ? (snapshot.agentState['inbox'] as List? ?? const [])
            : const <Object?>[];
        snapshot = snapshot.update({
          'runId': _newId(),
          'system': ?system,
          'runStart': snapshot.history.length + archivedInbox.length,
          'turns': 0,
          'stopRequested': false,
          'childSessionIds': <String>[],
          'delegatedTurns': 0,
          'maxTurns': maxTurns!,
          'error': null,
          'failure': null,
          'agentState': {
            if (snapshot.agentState['name'] != null)
              'name': snapshot.agentState['name'],
            'inbox': archiveRootInbox
                ? <Object?>[]
                : snapshot.agentState['inbox'] ?? <Object?>[],
            'inputs': {
              ...(snapshot.agentState['inputs'] as Map? ?? const {})
                  .cast<String, Object?>(),
              ?agentInputOperationId: true,
            },
          },
          'history': [
            ...snapshot.history.map((m) => m.toJson()),
            for (final message in archivedInbox)
              AgentMessage(
                role: MessageRole.user,
                text: message as String,
                runtimeNotice: true,
              ).toJson(),
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
        collaborationTools: multiAgent == null ? null : _team.toolsFor,
        prepareRun: multiAgent == null ? null : _team.restore,
        prepareCompletion: multiAgent == null ? null : _team.prepareCompletion,
        beforeUserInput: multiAgent == null ? null : _team.stopForUserInput,
        collaborationInstructions: multiAgent == null
            ? null
            : _team.instructions,
      );
      if (resourceCommitGuard case final guard?) {
        run.bindResourceCommitGuard(guard);
      }
      if (resourceTaskAuthority case final authority?) {
        run.bindResourceTaskLease(await authority.activate(snapshot));
      }
      run.start();
      return run;
    } catch (_) {
      await store.release(sessionId, lease);
      rethrow;
    }
  }
}
