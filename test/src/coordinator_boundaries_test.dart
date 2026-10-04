import 'dart:async';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show ScriptedModel;

class ControlledModel implements ModelAdapter {
  final entered = StreamController<String>.broadcast();
  final Map<String, Completer<void>> gates = {};
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final prompt = request.messages.last.text;
    final gate = gates.putIfAbsent(prompt, Completer<void>.new);
    entered.add(prompt);
    await Future.any([gate.future, token.whenCancelled]);
    token.throwIfCancelled();
    if (prompt == 'fail') throw StateError('child model failure');
    yield ModelResponse(text: '$prompt done');
  }

  Future<void> waitFor(String prompt) async {
    if (gates.containsKey(prompt)) return;
    await entered.stream
        .firstWhere((p) => p == prompt)
        .timeout(const Duration(seconds: 5));
  }

  void finish(String prompt) {
    gates[prompt]!.complete();
  }
}

void main() {
  late ControlledModel model;
  late SessionStore store;
  late SessionManager manager;
  late AgentRun parent;
  setUp(() async {
    model = ControlledModel();
    store = InMemorySessionStore();
    manager = SessionManager(model: model, store: store);
    final session = await manager.create();
    parent = await manager.prompt(session.id, 'parent');
    await model.waitFor('parent');
  });
  tearDown(() async {
    if (!parent.isSettled) await parent.cancel();
    await model.entered.close();
  });

  test(
    'concurrency limit rejects excess children and capacity is reusable',
    () async {
      final coordinator = AgentCoordinator(manager: manager, maxConcurrent: 1);
      final first = coordinator.delegate(parent: parent, prompt: 'first');
      await model.waitFor('first');
      await expectLater(
        coordinator.delegate(parent: parent, prompt: 'excess'),
        throwsStateError,
      );
      expect(parent.snapshot.childSessionIds.length, 1);
      model.finish('first');
      await first;
      final second = coordinator.delegate(parent: parent, prompt: 'second');
      await model.waitFor('second');
      model.finish('second');
      expect((await second).status, RunStatus.completed);
    },
  );

  test('depth zero disallows children without creating reservations', () async {
    final coordinator = AgentCoordinator(manager: manager, maxDepth: 0);
    await expectLater(
      coordinator.delegate(parent: parent, prompt: 'child'),
      throwsStateError,
    );
    expect(parent.snapshot.childSessionIds, isEmpty);
  });

  test('child-count limit survives coordinator reconstruction', () async {
    final firstCoordinator = AgentCoordinator(manager: manager, maxChildren: 1);
    final child = firstCoordinator.delegate(parent: parent, prompt: 'first');
    await model.waitFor('first');
    model.finish('first');
    await child;
    await expectLater(
      AgentCoordinator(
        manager: manager,
        maxChildren: 1,
      ).delegate(parent: parent, prompt: 'excess'),
      throwsA(isA<DelegationLimit>()),
    );
    expect(parent.snapshot.childSessionIds.length, 1);
  });

  test(
    'one child failure does not erase a sibling success or fail parent',
    () async {
      final coordinator = AgentCoordinator(manager: manager);
      final failed = coordinator.delegate(parent: parent, prompt: 'fail');
      final success = coordinator.delegate(parent: parent, prompt: 'success');
      await model.waitFor('fail');
      await model.waitFor('success');
      model.finish('fail');
      model.finish('success');
      expect((await failed).status, RunStatus.failed);
      expect((await success).status, RunStatus.completed);
      model.finish('parent');
      expect((await parent.done).status, RunStatus.completed);
    },
  );

  test('simultaneous parent cancellation settles all children', () async {
    final coordinator = AgentCoordinator(manager: manager);
    final a = coordinator.delegate(parent: parent, prompt: 'a');
    final b = coordinator.delegate(parent: parent, prompt: 'b');
    await model.waitFor('a');
    await model.waitFor('b');
    final cancelled = parent.cancel();
    expect((await a).status, RunStatus.cancelled);
    expect((await b).status, RunStatus.cancelled);
    expect((await cancelled).status, RunStatus.cancelled);
  });

  test('parent settling cannot launch untracked children', () async {
    final coordinator = AgentCoordinator(manager: manager);
    final child = coordinator.delegate(parent: parent, prompt: 'child');
    await model.waitFor('child');
    model.finish('parent');
    // Wait for the parent to enter its completion barrier while child is active.
    for (var i = 0; i < 100 && parent.acceptsChildren; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(parent.acceptsChildren, isFalse);
    expect(
      () => coordinator.delegate(parent: parent, prompt: 'late'),
      throwsStateError,
    );
    model.finish('child');
    await child;
    await parent.done;
    expect(parent.snapshot.childSessionIds.length, 1);
  });

  test('child cannot obtain a tool absent from the parent', () async {
    final tool = AgentTool(
      name: 'extra',
      description: 'extra',
      parameters: {},
      validate: (_) => null,
      execute: (_, _) async => ToolResult('ok'),
    );
    final childManager = SessionManager(
      model: model,
      store: store,
      tools: [tool],
    );
    await expectLater(
      AgentCoordinator(
        manager: childManager,
      ).delegate(parent: parent, prompt: 'child'),
      throwsStateError,
    );
    expect(parent.snapshot.childSessionIds, isEmpty);
  });

  test('disk reload preserves child relationship and explicit stop', () async {
    final directory = await Directory.systemTemp.createTemp('agent-children-');
    addTearDown(() => directory.delete(recursive: true));
    final disk = FileSessionStore(directory);
    final diskManager = SessionManager(model: model, store: disk);
    final session = await diskManager.create();
    final diskParent = await diskManager.prompt(session.id, 'disk-parent');
    await model.waitFor('disk-parent');
    final childFuture = AgentCoordinator(
      manager: diskManager,
    ).delegate(parent: diskParent, prompt: 'disk-child');
    await model.waitFor('disk-child');
    await diskParent.cancel();
    final child = await childFuture;
    final reloaded = FileSessionStore(directory);
    final parentRecord = (await reloaded.read(session.id))!;
    final childRecord = (await reloaded.read(child.id))!;
    expect(parentRecord.childSessionIds, [child.id]);
    expect(parentRecord.delegatedTurns, 10);
    expect(childRecord.parentSessionId, parentRecord.id);
    expect(childRecord.parentRunId, parentRecord.runId);
    expect(childRecord.depth, 1);
    final readyModel = ScriptedModel((_, _) async* {
      yield ModelResponse(text: 'resumed');
    });
    final resumedManager = SessionManager(model: readyModel, store: reloaded);
    final childResult = await (await resumedManager.resume(child.id)).done;
    final parentResult = await (await resumedManager.resume(session.id)).done;
    expect(childResult.status, RunStatus.cancelled);
    expect(parentResult.status, RunStatus.cancelled);
    expect(childResult.runId, childRecord.runId);
    expect(parentResult.childSessionIds, [child.id]);
  });
}
