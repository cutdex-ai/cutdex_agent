import '../session/snapshot.dart';

abstract interface class SessionStore {
  Future<SessionSnapshot?> read(String sessionId);

  /// Compare-and-set: expectedRevision null means the session must not exist.
  Future<void> save(SessionSnapshot snapshot, {required int? expectedRevision});

  /// Exclusive writer lease, held through all model/tool I/O. Persistent hosts
  /// must reclaim only leases whose owner is confirmed dead, never just slow.
  Future<Object> acquire(String sessionId);
  Future<void> release(String sessionId, Object lease);
}

class InMemorySessionStore implements SessionStore {
  final Map<String, SessionSnapshot> _sessions = {};
  final Map<String, Object> _leases = {};
  @override
  Future<SessionSnapshot?> read(String sessionId) async => _sessions[sessionId];
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    final current = _sessions[snapshot.id];
    if (current?.revision != expectedRevision ||
        snapshot.revision != (expectedRevision ?? -1) + 1) {
      throw StateError('Session revision conflict: ${snapshot.id}');
    }
    _sessions[snapshot.id] = snapshot;
  }

  @override
  Future<Object> acquire(String sessionId) async {
    if (_leases.containsKey(sessionId)) {
      throw StateError('Session already has a writer: $sessionId');
    }
    final lease = Object();
    _leases[sessionId] = lease;
    return lease;
  }

  @override
  Future<void> release(String sessionId, Object lease) async {
    if (!identical(_leases[sessionId], lease)) {
      throw StateError('Invalid session lease');
    }
    _leases.remove(sessionId);
  }
}
