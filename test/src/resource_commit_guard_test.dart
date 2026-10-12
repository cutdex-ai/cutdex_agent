import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel;

ToolContext context(String id, String run, CancellationToken token) =>
    ToolContext(
      sessionId: id,
      runId: run,
      operationId: '$id:$run:write',
      cancellation: token,
      onProgress: (_) {},
    );

void main() {
  for (final ending in ['completed', 'paused', 'failed']) {
    test(
      'manager revokes resource authority after $ending settlement',
      () async {
        final guard = ResourceCommitGuard();
        ResourceWritePermit? captured;
        CancellationToken? capturedToken;
        var responses = 0;
        final model = ScriptedModel((_, _) async* {
          if (responses++ == 0) {
            yield ModelResponse(
              calls: [ToolCall(id: 'capture', name: 'capture', arguments: {})],
            );
          } else if (ending == 'failed') {
            throw StateError('Injected model failure');
          } else {
            yield ModelResponse(text: 'done');
          }
        });
        final manager = SessionManager(
          model: model,
          store: InMemorySessionStore(),
          contextBuilder: ContextBuilder(),
          resourceCommitGuard: guard,
          tools: [
            AgentTool(
              name: 'capture',
              description: 'Capture resource authority',
              parameters: {'type': 'object', 'properties': <String, Object?>{}},
              validate: (_) => null,
              execute: (_, ctx) async {
                captured = guard.issue(ctx);
                capturedToken = ctx.cancellation;
                return guard.commit(
                  captured!,
                  () => ToolResult('active commit'),
                );
              },
            ),
          ],
        );
        final session = await manager.create();
        final run = await manager.prompt(
          session.id,
          'capture then finish',
          maxTurns: ending == 'paused' ? 1 : 3,
        );
        final result = await run.done;
        expect(result.status.name, ending);
        expect(captured, isNotNull);
        var wrote = false;
        expect(
          guard.commit(captured!, () {
            wrote = true;
            return ToolResult('obsolete background write');
          }).isError,
          isTrue,
        );
        expect(wrote, isFalse);
        if (ending != 'failed') expect(capturedToken!.isCancelled, isFalse);
      },
    );
  }
  late ResourceCommitGuard guard;
  late CancellationToken rootToken;
  late CancellationToken childToken;
  late CancellationToken grandchildToken;
  late void Function() revokeRoot;
  late void Function() revokeChild;
  late void Function() revokeGrandchild;
  late List<ResourceWritePermit> permits;
  var writes = 0;
  ToolResult write() {
    writes++;
    return ToolResult('committed');
  }

  setUp(() {
    guard = ResourceCommitGuard();
    rootToken = CancellationToken();
    childToken = CancellationToken();
    grandchildToken = CancellationToken();
    writes = 0;
    revokeRoot = guard.registerRun(
      SessionSnapshot(id: 'root', runId: 'old'),
      rootToken,
    );
    revokeChild = guard.registerRun(
      SessionSnapshot(
        id: 'child',
        runId: 'child-run',
        parentSessionId: 'root',
        parentRunId: 'old',
      ),
      childToken,
    );
    revokeGrandchild = guard.registerRun(
      SessionSnapshot(
        id: 'grandchild',
        runId: 'leaf-run',
        parentSessionId: 'child',
        parentRunId: 'child-run',
      ),
      grandchildToken,
    );
    permits = [
      guard.issue(context('root', 'old', rootToken)),
      guard.issue(context('child', 'child-run', childToken)),
      guard.issue(context('grandchild', 'leaf-run', grandchildToken)),
    ];
  });
  test('root child and grandchild inherit one task generation', () {
    expect(permits.map((p) => p.rootRunId), everyElement('old'));
    expect(permits.map((p) => p.generation).toSet(), hasLength(1));
    for (final p in permits) {
      expect(guard.commit(p, write).isError, isFalse);
    }
    expect(writes, 3);
  });
  test(
    'new root generation rejects old descendants even without cancelled tokens',
    () {
      guard.registerRun(
        SessionSnapshot(id: 'root', runId: 'new'),
        CancellationToken(),
      );
      for (final p in permits) {
        final r = guard.commit(p, write);
        expect(r.data['code'], 'stale_task_generation');
        expect(r.data['executed'], isFalse);
      }
      expect(writes, 0);
      expect(grandchildToken.isCancelled, isFalse);
    },
  );
  test('root revocation synchronously blocks entire ancestry', () {
    revokeRoot();
    for (final p in permits) {
      expect(guard.commit(p, write).isError, isTrue);
    }
    expect(writes, 0);
    expect(rootToken.isCancelled, isFalse);
  });
  test('child revocation blocks grandchild but preserves parent', () {
    revokeChild();
    expect(guard.commit(permits[1], write).isError, isTrue);
    expect(guard.commit(permits[2], write).isError, isTrue);
    expect(guard.commit(permits[0], write).isError, isFalse);
    expect(writes, 1);
  });
  test('settled grandchild cannot keep using its credential', () {
    revokeGrandchild();
    expect(guard.commit(permits[2], write).isError, isTrue);
    expect(guard.commit(permits[1], write).isError, isFalse);
  });
  test(
    'same logical run resume issues a new activation without resurrecting old permits',
    () {
      revokeRoot();
      final token = CancellationToken();
      guard.registerRun(SessionSnapshot(id: 'root', runId: 'old'), token);
      expect(guard.commit(permits[0], write).isError, isTrue);
      final renewed = guard.issue(context('root', 'old', token));
      expect(renewed.generation, greaterThan(permits[0].generation));
      expect(guard.commit(renewed, write).isError, isFalse);
    },
  );
  test('old cancellation hook cannot revoke a newer root activation', () {
    final token = CancellationToken();
    guard.registerRun(SessionSnapshot(id: 'root', runId: 'new'), token);
    revokeRoot();
    expect(
      guard.commit(guard.issue(context('root', 'new', token)), write).isError,
      isFalse,
    );
  });
  test('cancelled tokens cannot mint or use write permits', () {
    grandchildToken.cancel();
    expect(
      () => guard.issue(context('grandchild', 'leaf-run', grandchildToken)),
      throwsStateError,
    );
    expect(guard.commit(permits[2], write).data['executed'], isFalse);
    expect(writes, 0);
  });
  test('orphan ancestry and stale run identities fail closed', () {
    final token = CancellationToken();
    guard.registerRun(
      SessionSnapshot(
        id: 'orphan',
        runId: 'o',
        parentSessionId: 'root',
        parentRunId: 'wrong',
      ),
      token,
    );
    expect(() => guard.issue(context('orphan', 'o', token)), throwsStateError);
    expect(
      () => guard.issue(context('child', 'wrong', childToken)),
      throwsStateError,
    );
    expect(
      () => guard.issue(context('child', 'child-run', CancellationToken())),
      throwsStateError,
    );
  });
  test('foreign guards cannot accept or revive credentials', () {
    final other = ResourceCommitGuard();
    expect(
      other.commit(permits[0], write).data['code'],
      'foreign_write_permit',
    );
    expect(writes, 0);
  });
}
