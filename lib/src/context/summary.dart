import '../model/messages.dart';
import '../run/cancellation.dart';

/// Covers history [0, coveredMessages). Original messages are never removed.
class ContextSummary {
  const ContextSummary({
    required this.text,
    required this.coveredMessages,
    required this.source,
  });
  final String text;
  final int coveredMessages;

  /// Identifies the summarizer model/configuration used by the host.
  final String source;
  Map<String, Object?> toJson() => {
    'text': text,
    'coveredMessages': coveredMessages,
    'source': source,
  };
  factory ContextSummary.fromJson(Map<String, Object?> json) => ContextSummary(
    text: json['text']! as String,
    coveredMessages: json['coveredMessages']! as int,
    source: json['source']! as String,
  );
}

abstract interface class ContextSummarizer {
  String get source;
  Future<String> summarize(
    List<AgentMessage> messages,
    CancellationToken cancellation,
  );
}

/// A boundary may follow a complete tool batch, never a pending call.
bool isSafeSummaryBoundary(List<AgentMessage> history, int boundary) {
  if (boundary < 0 || boundary > history.length) return false;
  final pending = <String>{};
  for (final message in history.take(boundary)) {
    pending.addAll(message.calls.map((call) => call.id));
    if (message.role == MessageRole.tool && !pending.remove(message.callId)) {
      return false;
    }
  }
  return pending.isEmpty &&
      (boundary == history.length ||
          history[boundary].role != MessageRole.tool);
}
