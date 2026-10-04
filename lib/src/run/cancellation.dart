import 'dart:async';

class AgentCancelled implements Exception {
  const AgentCancelled();
}

/// Cooperative cancellation. Adapters must stop and settle their own I/O.
class CancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void throwIfCancelled() {
    if (isCancelled) throw const AgentCancelled();
  }

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}
