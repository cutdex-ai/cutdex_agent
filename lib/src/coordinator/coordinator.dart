import 'dart:convert';
import 'dart:math';
import '../run/agent_run.dart';
import '../session/manager.dart';
import '../session/snapshot.dart';

/// Bounded, explicit child delegation. Every child uses SessionManager/AgentRun.
/// Hosts expose delegation to models only when desired; it is not a media tool.
class AgentCoordinator {
  AgentCoordinator({
    required this.manager,
    this.maxConcurrent = 4,
    this.maxDepth = 3,
    this.maxChildren = 16,
    this.maxDelegatedTurns = 80,
  }) {
    if (maxConcurrent <= 0 ||
        maxDepth < 0 ||
        maxChildren <= 0 ||
        maxDelegatedTurns <= 0) {
      throw ArgumentError('Invalid delegation limits');
    }
  }
  final SessionManager manager;
  final int maxConcurrent;
  final int maxDepth;
  final int maxChildren;
  int _active = 0;
  final int maxDelegatedTurns;

  Future<SessionSnapshot> delegate({
    required AgentRun parent,
    required String prompt,
    int maxTurns = 10,
  }) {
    if (!parent.acceptsChildren) {
      throw StateError('Parent is not active');
    }
    final child = _delegate(parent: parent, prompt: prompt, maxTurns: maxTurns);
    parent.trackChild(child);
    return child;
  }

  Future<SessionSnapshot> _delegate({
    required AgentRun parent,
    required String prompt,
    required int maxTurns,
  }) async {
    if (!parent.acceptsChildren) {
      throw StateError('Parent is not active');
    }
    if (parent.snapshot.depth >= maxDepth) {
      throw StateError('Delegation depth exceeded');
    }
    if (_active >= maxConcurrent) {
      throw StateError('Delegation concurrency exceeded');
    }
    if (manager.tools.any((t) => !parent.toolNames.contains(t.name))) {
      throw StateError('Child tools exceed parent capabilities');
    }
    final random = Random.secure();
    final childId = base64Url.encode(
      List.generate(18, (_) => random.nextInt(256)),
    );
    _active++;
    try {
      await parent.reserveChild(
        childId,
        turns: maxTurns,
        maxChildren: maxChildren,
        maxDelegatedTurns: maxDelegatedTurns,
      );
      final session = await manager.create(
        id: childId,
        system: parent.snapshot.system,
        memoryScope: parent.snapshot.memoryScope,
        skillIds: parent.snapshot.skillIds,
        parentSessionId: parent.snapshot.id,
        parentRunId: parent.snapshot.runId,
        depth: parent.snapshot.depth + 1,
      );
      parent.cancellation.throwIfCancelled();
      final child = await manager.prompt(
        session.id,
        prompt,
        maxTurns: maxTurns,
      );
      // Parent cancellation is cooperative, including the active child.
      await Future.any<void>([
        child.done.then((_) {}),
        parent.cancellation.whenCancelled,
      ]);
      if (parent.cancellation.isCancelled && !child.isSettled) {
        await child.cancel();
      }
      return await child.done;
    } finally {
      _active--;
    }
  }
}
