import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel;

class TestLease implements ResourceTaskLease {
  TestLease(this.close);
  final Future<void> Function() close;
  @override
  Future<void> revoke() => close();
}

class TestAuthority implements ResourceTaskAuthority {
  TestAuthority(this.open);
  final Future<ResourceTaskLease> Function(SessionSnapshot) open;
  @override
  Future<ResourceTaskLease> activate(SessionSnapshot snapshot) =>
      open(snapshot);
}

class AdmissionTestLease extends TestLease
    implements ResourceTaskAdmissionLease {
  AdmissionTestLease(super.close);
  bool open = true;
  @override
  void stopAdmission() => open = false;
}

void main() {
  test(
    'cancel closes commit admission before its first asynchronous wait',
    () async {
      final ack = Completer<void>();
      final holding = Completer<void>();
      final lease = AdmissionTestLease(() => ack.future);
      final manager = SessionManager(
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [ToolCall(id: 'hold', name: 'hold')],
          );
        }),
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(),
        resourceTaskAuthority: TestAuthority((_) async => lease),
        tools: [
          AgentTool(
            name: 'hold',
            description: 'hold',
            parameters: {'type': 'object'},
            validate: (_) => null,
            execute: (_, context) async {
              holding.complete();
              await context.cancellation.whenCancelled;
              return ToolResult('cancelled');
            },
          ),
        ],
      );
      final session = await manager.create();
      final run = await manager.prompt(session.id, 'hold');
      await holding.future;
      final cancelled = run.cancel();
      expect(lease.open, isFalse);
      ack.complete();
      expect((await cancelled).status, RunStatus.cancelled);
    },
  );
  test(
    'no model work starts before external activation acknowledgement',
    () async {
      final started = Completer<void>();
      final ack = Completer<void>();
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(),
        resourceTaskAuthority: TestAuthority((_) async {
          started.complete();
          await ack.future;
          return TestLease(() async {});
        }),
      );
      final session = await manager.create();
      final opening = manager.prompt(session.id, 'task');
      await started.future;
      expect(model.requests, isEmpty);
      ack.complete();
      expect((await (await opening).done).status, RunStatus.completed);
      expect(model.requests, hasLength(1));
    },
  );
  test(
    'cancel and writer release wait for resource-side revocation acknowledgement',
    () async {
      final toolStarted = Completer<void>();
      final revokeStarted = Completer<void>();
      final ack = Completer<void>();
      var revokeCalls = 0;
      final store = InMemorySessionStore();
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(
          calls: [ToolCall(id: 'hold', name: 'hold')],
        );
      });
      final manager = SessionManager(
        model: model,
        store: store,
        contextBuilder: ContextBuilder(),
        resourceTaskAuthority: TestAuthority(
          (_) async => TestLease(() async {
            revokeCalls++;
            if (!revokeStarted.isCompleted) revokeStarted.complete();
            await ack.future;
          }),
        ),
        tools: [
          AgentTool(
            name: 'hold',
            description: 'hold',
            parameters: {'type': 'object'},
            validate: (_) => null,
            execute: (_, ctx) async {
              toolStarted.complete();
              await ctx.cancellation.whenCancelled;
              return ToolResult('cancelled');
            },
          ),
        ],
      );
      final session = await manager.create();
      final run = await manager.prompt(session.id, 'hold');
      await toolStarted.future;
      final cancellation = run.cancel();
      await revokeStarted.future;
      expect(run.isSettled, isFalse);
      await expectLater(
        manager.prompt(session.id, 'too early'),
        throwsStateError,
      );
      ack.complete();
      expect((await cancellation).status, RunStatus.cancelled);
      expect(revokeCalls, 1);
      final lease = await store.acquire(session.id);
      await store.release(session.id, lease);
    },
  );
  test(
    'revocation failure is surfaced and still releases the session lease',
    () async {
      final store = InMemorySessionStore();
      final manager = SessionManager(
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(text: 'done');
        }),
        store: store,
        contextBuilder: ContextBuilder(),
        resourceTaskAuthority: TestAuthority(
          (_) async => TestLease(() async {
            throw StateError('Remote revoke unavailable');
          }),
        ),
      );
      final session = await manager.create();
      final run = await manager.prompt(session.id, 'finish');
      await expectLater(run.done, throwsStateError);
      final lease = await store.acquire(session.id);
      await store.release(session.id, lease);
    },
  );
}
