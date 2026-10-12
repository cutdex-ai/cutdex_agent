import 'dart:async';

class AgentCancelled implements Exception {
  const AgentCancelled();
}

/// Cooperative cancellation. Adapters must stop and settle their own I/O.
class CancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  final Map<CancellationToken, int> _children =
      Map<CancellationToken, int>.identity();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void throwIfCancelled() {
    if (isCancelled) throw const AgentCancelled();
  }

  /// Links a child token for synchronous, one-way cancellation propagation.
  ///
  /// The returned function removes this link and is safe to call repeatedly.
  /// Owners should unlink settled children to avoid retaining completed runs.
  void Function() linkChild(CancellationToken child) {
    if (identical(child, this)) {
      throw ArgumentError('Cannot link a token to itself');
    }
    if (isCancelled) {
      child.cancel();
      return () {};
    }
    if (child.isCancelled) return () {};
    _children.update(child, (count) => count + 1, ifAbsent: () => 1);
    var linked = true;
    return () {
      if (!linked) return;
      linked = false;
      final count = _children[child];
      if (count == null) return;
      if (count == 1) {
        _children.remove(child);
      } else {
        _children[child] = count - 1;
      }
    };
  }

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    final children = _children.keys.toList();
    _children.clear();
    for (final child in children) {
      child.cancel();
    }
  }
}
