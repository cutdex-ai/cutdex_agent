enum AgentRunPhase { responding, compacting }

enum AgentEventKind {
  phase,
  state,
  textDelta,
  toolStarted,
  toolProgress,
  toolFinished,
  message,
}

class AgentEvent {
  const AgentEvent({
    required this.sessionId,
    required this.runId,
    required this.sequence,
    required this.kind,
    required this.text,
    this.callId,
  });
  final String sessionId;
  final String runId;

  /// Monotonic within a session; transient events may leave gaps after restart.
  final int sequence;
  final AgentEventKind kind;
  final String text;
  final String? callId;
}
