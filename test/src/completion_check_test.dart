import 'dart:async';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show ScriptedModel;

void main() {
  test(
    'failed artifact check continues same task and persists final evidence',
    () async {
      var requests = 0, checks = 0;
      final manager = SessionManager(
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(),
        model: ScriptedModel((request, _) async* {
          if (requests++ > 0) {
            expect(request.messages.last.runtimeNotice, isTrue);
            expect(request.messages.last.text, contains('gainDb'));
          }
          yield ModelResponse(text: 'done');
        }),
        completionCheck: (snapshot, token) async => ++checks == 1
            ? ToolResult(
                'Mismatch',
                isError: true,
                data: {'field': 'gainDb', 'expected': -12, 'actual': -6},
              )
            : ToolResult('Checked', data: {'version': 'v2'}),
      );
      final s = await manager.create();
      final end = await (await manager.prompt(s.id, 'edit')).done;
      expect(end.status, RunStatus.completed);
      expect(checks, 2);
      expect(
        end.history
            .where((m) => m.role == MessageRole.user && !m.runtimeNotice)
            .length,
        1,
      );
      expect((end.completionEvidence!['result'] as Map)['isError'], false);
      expect(
        SessionSnapshot.fromJson(end.toJson()).completionEvidence,
        end.completionEvidence,
      );
    },
  );
  test(
    'unresolved check pauses at turn budget and does not falsely complete',
    () async {
      final manager = SessionManager(
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(),
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(text: 'done');
        }),
        completionCheck: (_, _) async =>
            ToolResult('Missing clip', isError: true),
      );
      final s = await manager.create();
      final end = await (await manager.prompt(s.id, 'edit', maxTurns: 1)).done;
      expect(end.status, RunStatus.paused);
      expect((end.completionEvidence!['result'] as Map)['isError'], true);
    },
  );
  test(
    'new user task clears previous acceptance and checks current state',
    () async {
      var valid = true;
      final store = InMemorySessionStore();
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      SessionManager manager() => SessionManager(
        store: store,
        model: model,
        contextBuilder: ContextBuilder(),
        completionCheck: (s, _) async {
          expect(s.completionEvidence, isNull);
          return ToolResult('current', isError: !valid);
        },
      );
      final m = manager();
      final s = await m.create();
      expect(
        (await (await m.prompt(s.id, 'first')).done).status,
        RunStatus.completed,
      );
      valid = false;
      final end = await (await manager().prompt(
        s.id,
        'second',
        maxTurns: 1,
      )).done;
      expect(end.status, RunStatus.paused);
    },
  );
  test('cancel during verification cannot publish accepted evidence', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final manager = SessionManager(
      store: InMemorySessionStore(),
      model: ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      }),
      completionCheck: (_, _) async {
        entered.complete();
        await release.future;
        return ToolResult('ok');
      },
    );
    final s = await manager.create();
    final run = await manager.prompt(s.id, 'work');
    await entered.future;
    final stopping = run.cancel();
    release.complete();
    await stopping;
    final end = await run.done;
    expect(end.status, RunStatus.cancelled);
    expect(end.completionEvidence, isNull);
  });
  test('unavailable checker is a failure, never completed', () async {
    final manager = SessionManager(
      store: InMemorySessionStore(),
      model: ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      }),
      completionCheck: (_, _) async => throw StateError('read unavailable'),
    );
    final s = await manager.create();
    expect(
      (await (await manager.prompt(s.id, 'work')).done).status,
      RunStatus.failed,
    );
  });
}
