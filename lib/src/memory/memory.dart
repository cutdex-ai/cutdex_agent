import '../run/cancellation.dart';

class AgentMemory {
  const AgentMemory({
    required this.id,
    required this.scope,
    required this.text,
    required this.source,
    required this.updatedAt,
  });
  final String id;
  final String scope;
  final String text;
  final String source;
  final DateTime updatedAt;
}

/// Scope comes from the host, not from model arguments.
abstract interface class MemoryProvider {
  Future<List<AgentMemory>> search({
    required String scope,
    required String query,
    required int limit,
    required CancellationToken cancellation,
  });
  Future<void> put(AgentMemory memory);
  Future<void> delete({required String scope, required String id});
}

/// Deliberately no automatic write-back of model output into long-term memory.
class InMemoryMemoryProvider implements MemoryProvider {
  final Map<(String, String), AgentMemory> _items = {};
  @override
  Future<void> put(AgentMemory memory) async {
    _items[(memory.scope, memory.id)] = memory;
  }

  @override
  Future<void> delete({required String scope, required String id}) async {
    _items.remove((scope, id));
  }

  @override
  Future<List<AgentMemory>> search({
    required String scope,
    required String query,
    required int limit,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    final matches =
        _items.values
            .where(
              (m) =>
                  m.scope == scope &&
                  (words.isEmpty ||
                      words.any((w) => m.text.toLowerCase().contains(w))),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(matches.take(limit));
  }
}
