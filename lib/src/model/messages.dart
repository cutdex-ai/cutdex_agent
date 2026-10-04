import 'dart:convert';

/// Copies and freezes JSON data at the API boundary.
Object? freezeJson(Object? value) => switch (value) {
  null || String() || bool() || int() => value,
  double() when value.isFinite => value,
  List() => List<Object?>.unmodifiable(value.map(freezeJson)),
  Map<String, Object?>() => Map<String, Object?>.unmodifiable(
    value.map((key, value) => MapEntry(key, freezeJson(value))),
  ),
  _ => throw ArgumentError.value(value, 'value', 'Expected finite JSON data'),
};

class ToolCall {
  ToolCall({
    required this.id,
    required this.name,
    Map<String, Object?> arguments = const {},
  }) : arguments = freezeJson(arguments)! as Map<String, Object?> {
    if (id.isEmpty || name.isEmpty) {
      throw ArgumentError('Tool identity is empty');
    }
  }
  final String id;
  final String name;
  final Map<String, Object?> arguments;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };
  factory ToolCall.fromJson(Map<String, Object?> json) => ToolCall(
    id: json['id']! as String,
    name: json['name']! as String,
    arguments: (json['arguments']! as Map).cast<String, Object?>(),
  );
}

enum MessageRole { user, assistant, tool }

/// Provider-reported counts for one request, not a cumulative session total.
/// Cached input and reasoning output are subsets, never additional tokens.
class TokenUsage {
  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.cachedInputTokens,
    this.reasoningOutputTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final int? cachedInputTokens;
  final int? reasoningOutputTokens;

  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'totalTokens': totalTokens,
    if (cachedInputTokens != null) 'cachedInputTokens': cachedInputTokens,
    if (reasoningOutputTokens != null)
      'reasoningOutputTokens': reasoningOutputTokens,
  };

  /// Missing or invalid telemetry must not invalidate an otherwise valid turn.
  static TokenUsage? fromJson(Object? value) {
    if (value is! Map) return null;
    final input = value['inputTokens'];
    final output = value['outputTokens'];
    final total = value['totalTokens'];
    if (input is! int ||
        input < 0 ||
        output is! int ||
        output < 0 ||
        total is! int ||
        total < 0) {
      return null;
    }
    int? detail(Object? value, int maximum) =>
        value is int && value >= 0 && value <= maximum ? value : null;
    return TokenUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      cachedInputTokens: detail(value['cachedInputTokens'], input),
      reasoningOutputTokens: detail(value['reasoningOutputTokens'], output),
    );
  }
}

class AgentMessage {
  AgentMessage({
    required this.role,
    this.text = '',
    this.usage,
    Iterable<ToolCall> calls = const [],
    this.callId,
    this.resultId,
    this.runtimeNotice = false,
    this.isError = false,
    Map<String, Object?> providerData = const {},
  }) : providerData = freezeJson(providerData)! as Map<String, Object?>,
       calls = List.unmodifiable(calls) {
    if (role != MessageRole.assistant && this.calls.isNotEmpty) {
      throw ArgumentError('Only assistant messages contain calls');
    }
    if ((role == MessageRole.tool) != (callId != null)) {
      throw ArgumentError('Tool results require a call ID');
    }
  }
  final TokenUsage? usage;
  final MessageRole role;
  final String text;
  final List<ToolCall> calls;
  final String? callId;

  /// Stable across runs in the same session, independent of provider call IDs.
  final String? resultId;

  /// Runtime continuation messages are not user-authored chat messages.
  final bool runtimeNotice;
  final bool isError;

  /// Opaque protocol history (for example encrypted reasoning items).
  final Map<String, Object?> providerData;
  Map<String, Object?> toJson() => {
    if (usage != null) 'usage': usage!.toJson(),
    'role': role.name,
    'text': text,
    'calls': calls.map((c) => c.toJson()).toList(),
    'callId': callId,
    if (resultId != null) 'resultId': resultId,
    if (runtimeNotice) 'runtimeNotice': true,
    'isError': isError,
    if (providerData.isNotEmpty) 'providerData': providerData,
  };
  factory AgentMessage.fromJson(Map<String, Object?> json) => AgentMessage(
    usage: TokenUsage.fromJson(json['usage']),
    role: MessageRole.values.byName(json['role']! as String),
    text: json['text']! as String,
    calls: (json['calls']! as List).map(
      (c) => ToolCall.fromJson((c as Map).cast<String, Object?>()),
    ),
    callId: json['callId'] as String?,
    resultId: json['resultId'] as String?,
    runtimeNotice: json['runtimeNotice'] == true,
    isError: json['isError']! as bool,
    providerData:
        (json['providerData'] as Map?)?.cast<String, Object?>() ?? const {},
  );
  int get estimatedTokens =>
      utf8.encode(jsonEncode(toJson()..remove('usage'))).length;
}
