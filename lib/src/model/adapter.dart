import '../run/cancellation.dart';
import '../tools/tool.dart';
import 'messages.dart';

class ModelRequest {
  ModelRequest({
    required this.system,
    required Iterable<AgentMessage> messages,
    required Iterable<AgentTool> tools,
    required this.maxOutputTokens,
  }) : messages = List.unmodifiable(messages),
       tools = List.unmodifiable(tools);
  final String system;
  final List<AgentMessage> messages;
  final List<AgentTool> tools;
  final int maxOutputTokens;
}

sealed class ModelEvent {
  const ModelEvent();
}

class TextDelta extends ModelEvent {
  const TextDelta(this.text);
  final String text;
}

/// Exactly one final response is required; deltas are observational only.
class ModelResponse extends ModelEvent {
  ModelResponse({
    this.text = '',
    this.usage,
    Iterable<ToolCall> calls = const [],
    Map<String, Object?> providerData = const {},
  }) : providerData = freezeJson(providerData)! as Map<String, Object?>,
       calls = List.unmodifiable(calls);
  final TokenUsage? usage;
  final Map<String, Object?> providerData;
  final String text;
  final List<ToolCall> calls;
}

abstract interface class ModelAdapter {
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  );
}

class ModelHttpException implements Exception {
  const ModelHttpException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Model endpoint returned HTTP $statusCode';
}

class ModelProtocolException implements Exception {
  const ModelProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ModelProtocolException: $message';
}

enum ModelConnectionKind { socket, tls, http, timeout, unknown }

enum ModelConnectionStage { connecting, sending, receiving }

class ModelConnectionException implements Exception {
  const ModelConnectionException({
    this.kind = ModelConnectionKind.unknown,
    this.stage = ModelConnectionStage.connecting,
    this.osErrorCode,
  });
  final ModelConnectionKind kind;
  final ModelConnectionStage stage;
  final int? osErrorCode;
  @override
  String toString() =>
      'ModelConnectionException(kind: ${kind.name}, stage: ${stage.name}, osCode: $osErrorCode)';
}
