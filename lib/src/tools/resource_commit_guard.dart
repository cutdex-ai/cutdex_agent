import '../run/cancellation.dart';
import '../session/snapshot.dart';
import 'tool.dart';

/// An immutable write credential for one agent in one root task generation.
///
/// Capture this before starting background work. A credential cannot be renewed
/// by a cancelled or settled agent. It is local to its issuing guard.
class ResourceWritePermit {
  ResourceWritePermit._(this._guard, this._scope);
  final ResourceCommitGuard _guard;
  final _WriteScope _scope;

  /// The root session that owns the resource operation.
  String get rootSessionId => _scope.generation.rootSessionId;

  /// The root execution that owns the resource operation.
  String get rootRunId => _scope.generation.rootRunId;

  /// The issuing guard's root activation number.
  int get generation => _scope.generation.number;

  /// The agent session that issued this credential.
  String get sessionId => _scope.sessionId;

  /// The agent execution that issued this credential.
  String get runId => _scope.runId;
}

/// Rejects commits from cancelled, settled, or superseded task trees.
///
/// Pass the same instance to the session managers and resource submission tools.
/// [commit] checks the root generation and every ancestor immediately before a
/// synchronous mutation, without yielding between validation and submission.
/// This protects a local Dart isolate. Database transactions, remote jobs and
/// other processes must enforce equivalent fencing at their actual write end.
class ResourceCommitGuard {
  final Map<String, _TaskGeneration> _generations = {};
  final Map<String, _WriteScope> _active = {};
  int _number = 0;

  /// Registers a runtime activation and returns an idempotent revocation hook.
  ///
  /// SessionManager calls this before starting model or tool work. Children
  /// inherit their active parent's root generation. Missing parents fail closed.
  void Function() registerRun(
    SessionSnapshot snapshot,
    CancellationToken token,
  ) {
    final parent = snapshot.parentSessionId == null
        ? null
        : _active[snapshot.parentSessionId];
    final isRoot = snapshot.parentSessionId == null;
    final generation = isRoot
        ? _TaskGeneration(snapshot.id, snapshot.runId!, ++_number)
        : parent?.generation;
    if (isRoot) _generations[snapshot.id] = generation!;
    if (generation == null ||
        (!isRoot && parent!.runId != snapshot.parentRunId)) {
      return () {};
    }
    final scope = _WriteScope(
      snapshot.id,
      snapshot.runId!,
      generation,
      token,
      parent,
    );
    _active[snapshot.id]?.active = false;
    scope.active = !snapshot.stopRequested;
    _active[snapshot.id] = scope;
    return () {
      scope.active = false;
      if (identical(_active[snapshot.id], scope)) _active.remove(snapshot.id);
    };
  }

  /// Issues a credential for the currently active tool execution.
  ///
  /// Throws a StateError if the context is stale, cancelled or unregistered.
  ResourceWritePermit issue(ToolContext context) {
    final scope = _active[context.sessionId];
    if (scope == null ||
        scope.runId != context.runId ||
        !identical(scope.token, context.cancellation) ||
        _rejection(scope) != null) {
      throw StateError('No active resource write authority for this task');
    }
    return ResourceWritePermit._(this, scope);
  }

  String? _rejection(_WriteScope scope) {
    if (!identical(
      _generations[scope.generation.rootSessionId],
      scope.generation,
    )) {
      return 'stale_task_generation';
    }
    for (
      _WriteScope? current = scope;
      current != null;
      current = current.parent
    ) {
      if (!current.active ||
          current.token.isCancelled ||
          !identical(_active[current.sessionId], current)) {
        return 'task_write_revoked';
      }
    }
    return null;
  }

  /// Validates a credential and immediately performs the resource mutation.
  ///
  /// A rejected write returns an error with `executed: false`; [write] is never
  /// called. The callback must commit synchronously, without launching delayed
  /// side effects. For asynchronous storage, check an equivalent generation
  /// inside its transaction rather than checking here and writing later.
  ToolResult commit(ResourceWritePermit permit, ToolResult Function() write) {
    final reason = identical(permit._guard, this)
        ? _rejection(permit._scope)
        : 'foreign_write_permit';
    if (reason != null) {
      return ToolResult(
        'Resource write rejected: $reason',
        isError: true,
        data: {
          'code': reason,
          'executed': false,
          'root_session_id': permit.rootSessionId,
          'root_run_id': permit.rootRunId,
          'generation': permit.generation,
          'agent_session_id': permit.sessionId,
          'agent_run_id': permit.runId,
        },
      );
    }
    return write();
  }
}

class _TaskGeneration {
  _TaskGeneration(this.rootSessionId, this.rootRunId, this.number);
  final String rootSessionId;
  final String rootRunId;
  final int number;
}

class _WriteScope {
  _WriteScope(
    this.sessionId,
    this.runId,
    this.generation,
    this.token,
    this.parent,
  );
  final String sessionId;
  final String runId;
  final _TaskGeneration generation;
  final CancellationToken token;
  final _WriteScope? parent;
  bool active = true;
}
