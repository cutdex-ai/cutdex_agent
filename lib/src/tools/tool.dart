import '../model/messages.dart';
import 'schema.dart';
import '../run/cancellation.dart';

class ToolResult {
  ToolResult(
    this.text, {
    this.isError = false,
    Map<String, Object?> data = const {},
  }) : data = freezeJson(data)! as Map<String, Object?>;
  final String text;
  final bool isError;
  final Map<String, Object?> data;
  Map<String, Object?> toJson() => {
    'text': text,
    'isError': isError,
    'data': data,
  };
  factory ToolResult.fromJson(Map<String, Object?> json) => ToolResult(
    json['text']! as String,
    isError: json['isError']! as bool,
    data: (json['data']! as Map).cast<String, Object?>(),
  );
}

class ToolContext {
  const ToolContext({
    required this.sessionId,
    required this.runId,
    required this.operationId,
    required this.cancellation,
    required this.onProgress,
  });
  final String sessionId;
  final String runId;

  /// Stable across recovery; a tool host can use this for deduplication.
  final String operationId;
  final CancellationToken cancellation;
  final void Function(String) onProgress;
}

enum RecoveryStatus { completed, notStarted, running, unknown }

class ToolRecovery {
  const ToolRecovery.completed(ToolResult this.result)
    : status = RecoveryStatus.completed;
  const ToolRecovery.notStarted()
    : status = RecoveryStatus.notStarted,
      result = null;
  const ToolRecovery.running() : status = RecoveryStatus.running, result = null;
  const ToolRecovery.unknown() : status = RecoveryStatus.unknown, result = null;
  final RecoveryStatus status;
  final ToolResult? result;
}

/// Host-injected tool definition, execution and recovery contract.
///
/// Return a definite failure as ToolResult(isError: true). Throwing means the
/// outcome may be unknown and causes the run to await recovery, never a replay.
class AgentTool {
  AgentTool({
    required this.name,
    required this.description,
    required Map<String, Object?> parameters,
    required this.validate,
    required this.execute,
    this.recover,
  }) : parameters = freezeJson(parameters)! as Map<String, Object?> {
    if (name.isEmpty) throw ArgumentError('Tool name is empty');
  }
  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// Returns null when valid, otherwise a model-visible validation error.
  final String? Function(Map<String, Object?> arguments) validate;
  final Future<ToolResult> Function(ToolCall call, ToolContext context) execute;
  final Future<ToolRecovery> Function(ToolCall call, ToolContext context)?
  recover;
  Map<String, Object?> get declaration => {
    'name': name,
    'description': description,
    'parameters': modelToolSchema(parameters),
  };
}
