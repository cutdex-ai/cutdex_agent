import '../model/messages.dart';
import '../context/summary.dart';
import '../tools/tool.dart';

enum RunStatus { running, waiting, paused, completed, cancelled, failed }

enum RunFailure { contextBudget, authentication, connection, protocol, request }

enum CallStatus { planned, started, finished }

class CallRecord {
  const CallRecord({
    required this.call,
    required this.operationId,
    this.status = CallStatus.planned,
    this.result,
  });
  final ToolCall call;
  final String operationId;
  final CallStatus status;
  final ToolResult? result;
  CallRecord started() => CallRecord(
    call: call,
    operationId: operationId,
    status: CallStatus.started,
  );
  CallRecord finished(ToolResult result) => CallRecord(
    call: call,
    operationId: operationId,
    status: CallStatus.finished,
    result: result,
  );
  Map<String, Object?> toJson() => {
    'call': call.toJson(),
    'operationId': operationId,
    'status': status.name,
    'result': result?.toJson(),
  };
  factory CallRecord.fromJson(Map<String, Object?> json) => CallRecord(
    call: ToolCall.fromJson((json['call']! as Map).cast<String, Object?>()),
    operationId: json['operationId']! as String,
    status: CallStatus.values.byName(json['status']! as String),
    result: json['result'] == null
        ? null
        : ToolResult.fromJson((json['result']! as Map).cast<String, Object?>()),
  );
}

/// Immutable, JSON-serializable checkpoint. History remains complete even when
/// model input is pruned. Storage implementations must persist atomically.
class SessionSnapshot {
  SessionSnapshot({
    required this.id,
    this.revision = 0,
    this.sequence = 0,
    this.runId,
    this.parentSessionId,
    this.parentRunId,
    this.runStart = 0,
    this.depth = 0,
    this.status = RunStatus.completed,
    this.turns = 0,
    this.stopRequested = false,
    this.maxTurns = 20,
    this.system = '',
    this.memoryScope,
    Iterable<String> skillIds = const [],
    Iterable<AgentMessage> history = const [],
    Iterable<CallRecord> pending = const [],
    Iterable<String> queued = const [],
    this.error,
    this.failure,
    Iterable<ContextSummary> summaries = const [],
    Iterable<String> childSessionIds = const [],
    this.delegatedTurns = 0,
    Map<String, Object?>? completionEvidence,
  }) : completionEvidence =
           freezeJson(completionEvidence) as Map<String, Object?>?,
       skillIds = List.unmodifiable(skillIds),
       history = List.unmodifiable(history),
       pending = List.unmodifiable(pending),
       queued = List.unmodifiable(queued),
       summaries = List.unmodifiable(summaries),
       childSessionIds = List.unmodifiable(childSessionIds);
  final String id;
  final int revision;
  final int sequence;
  final String? runId;
  final String? parentSessionId;
  final String? parentRunId;
  final int runStart;
  final int depth;
  final RunStatus status;
  final int turns;
  final bool stopRequested;
  final int maxTurns;
  final String system;
  final String? memoryScope;
  final List<String> skillIds;
  final List<AgentMessage> history;
  final List<CallRecord> pending;
  final List<String> queued;
  final String? error;
  final RunFailure? failure;
  final List<ContextSummary> summaries;
  final List<String> childSessionIds;
  final int delegatedTurns;
  final Map<String, Object?>? completionEvidence;
  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'revision': revision,
    'sequence': sequence,
    'runId': runId,
    'parentSessionId': parentSessionId,
    'parentRunId': parentRunId,
    'runStart': runStart,
    'depth': depth,
    'status': status.name,
    'turns': turns,
    'stopRequested': stopRequested,
    'maxTurns': maxTurns,
    'system': system,
    'memoryScope': memoryScope,
    'skillIds': skillIds,
    'history': history.map((m) => m.toJson()).toList(),
    'pending': pending.map((c) => c.toJson()).toList(),
    'queued': queued,
    'error': error,
    'failure': failure?.name,
    'summaries': summaries.map((s) => s.toJson()).toList(),
    'childSessionIds': childSessionIds,
    'delegatedTurns': delegatedTurns,
    'completionEvidence': completionEvidence,
  };
  factory SessionSnapshot.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported snapshot version');
    }
    return SessionSnapshot(
      id: json['id']! as String,
      revision: json['revision']! as int,
      sequence: json['sequence']! as int,
      runId: json['runId'] as String?,
      parentSessionId: json['parentSessionId'] as String?,
      parentRunId: json['parentRunId'] as String?,
      runStart: json['runStart']! as int,
      depth: json['depth']! as int,
      status: RunStatus.values.byName(json['status']! as String),
      turns: json['turns']! as int,
      stopRequested: json['stopRequested'] as bool? ?? false,
      maxTurns: json['maxTurns']! as int,
      system: json['system']! as String,
      memoryScope: json['memoryScope'] as String?,
      skillIds: (json['skillIds']! as List).cast<String>(),
      queued: (json['queued']! as List).cast<String>(),
      history: (json['history']! as List).map(
        (m) => AgentMessage.fromJson((m as Map).cast<String, Object?>()),
      ),
      pending: (json['pending']! as List).map(
        (c) => CallRecord.fromJson((c as Map).cast<String, Object?>()),
      ),
      error: json['error'] as String?,
      failure: json['failure'] == null
          ? null
          : RunFailure.values.byName(json['failure'] as String),
      summaries: (json['summaries']! as List).map(
        (s) => ContextSummary.fromJson((s as Map).cast<String, Object?>()),
      ),
      childSessionIds: (json['childSessionIds']! as List).cast<String>(),
      delegatedTurns: json['delegatedTurns']! as int,
      completionEvidence: (json['completionEvidence'] as Map?)
          ?.cast<String, Object?>(),
    );
  }
  SessionSnapshot update(Map<String, Object?> fields) =>
      SessionSnapshot.fromJson({...toJson(), ...fields});
}
