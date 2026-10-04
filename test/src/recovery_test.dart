import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show callThenAnswer, tool, start, ScriptedModel;

class FailAfterCommitStore extends InMemorySessionStore {
  bool fail = true;
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    if (fail && snapshot.pending.any((c) => c.status == CallStatus.finished)) {
      throw StateError('result record was not saved');
    }
    await super.save(snapshot, expectedRevision: expectedRevision);
  }
}

void main() {
  test('provider call IDs may repeat across independent runs', () async {
    var edits = 0;
    final manager = SessionManager(
      model: callThenAnswer(),
      store: InMemorySessionStore(),
      tools: [
        tool(
          execute: (_, _) async {
            edits++;
            return ToolResult('ok');
          },
        ),
      ],
    );
    final first = await (await start(manager)).done;
    final second = await (await manager.prompt(first.id, 'another edit')).done;
    expect(second.status, RunStatus.completed);
    expect(edits, 2);
    expect(second.runId, isNot(first.runId));
  });

  test(
    'result storage failure recovers committed operation without reexecution',
    () async {
      var executions = 0;
      final store = FailAfterCommitStore();
      final tools = [
        tool(
          execute: (_, _) async {
            executions++;
            return ToolResult('committed');
          },
          recover: (_, _) async =>
              ToolRecovery.completed(ToolResult('committed')),
        ),
      ];
      final manager = SessionManager(
        model: callThenAnswer(),
        store: store,
        tools: tools,
      );
      final run = await start(manager);
      await expectLater(run.done, throwsStateError);
      expect(executions, 1);
      store.fail = false;
      final restored = SessionManager(
        model: callThenAnswer(),
        store: store,
        tools: tools,
      );
      expect(
        (await (await restored.resume(run.snapshot.id)).done).status,
        RunStatus.completed,
      );
      expect(executions, 1);
    },
  );

  test(
    'pause during model stream persists calls but does not start them',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var executions = 0;
      final model = ScriptedModel((request, _) async* {
        if (request.messages.last.role == MessageRole.tool) {
          yield ModelResponse(text: 'done');
          return;
        }
        entered.complete();
        await release.future;
        yield ModelResponse(
          calls: [ToolCall(id: 'a', name: 'edit')],
        );
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        tools: [
          tool(
            execute: (_, _) async {
              executions++;
              return ToolResult('ok');
            },
          ),
        ],
      );
      final run = await start(manager);
      await entered.future;
      final paused = run.pause();
      release.complete();
      final state = await paused;
      expect(state.status, RunStatus.paused);
      expect(state.pending.single.status, CallStatus.planned);
      expect(executions, 0);
      expect(
        (await (await manager.resume(state.id)).done).status,
        RunStatus.completed,
      );
      expect(executions, 1);
    },
  );

  test('parent completion waits for its owned child', () async {
    final entered = Completer<void>();
    final parentRelease = Completer<void>();
    final childRelease = Completer<void>();
    final childEntered = Completer<void>();
    final store = InMemorySessionStore();
    final parentModel = ScriptedModel((_, _) async* {
      entered.complete();
      await parentRelease.future;
      yield ModelResponse(text: 'parent');
    });
    final parent = await start(
      SessionManager(model: parentModel, store: store),
    );
    await entered.future;
    final childModel = ScriptedModel((_, _) async* {
      childEntered.complete();
      await childRelease.future;
      yield ModelResponse(text: 'child');
    });
    final coordinator = AgentCoordinator(
      manager: SessionManager(model: childModel, store: store),
    );
    final child = coordinator.delegate(parent: parent, prompt: 'child task');
    await childEntered.future;
    parentRelease.complete();
    await Future<void>.delayed(Duration.zero);
    expect(parent.isSettled, isFalse);
    childRelease.complete();
    expect((await child).status, RunStatus.completed);
    expect((await parent.done).status, RunStatus.completed);
  });
}
