import 'dart:async';
import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

class ScriptedModel implements ModelAdapter {
  ScriptedModel(this.respond);
  final Stream<ModelEvent> Function(ModelRequest, CancellationToken) respond;
  final List<ModelRequest> requests = [];
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) {
    requests.add(request);
    return respond(request, cancellation);
  }
}

AgentTool tool({
  Future<ToolResult> Function(ToolCall, ToolContext)? execute,
  Future<ToolRecovery> Function(ToolCall, ToolContext)? recover,
  String? Function(Map<String, Object?>)? validate,
}) => AgentTool(
  name: 'edit',
  description: 'Fake edit',
  parameters: {'type': 'object'},
  validate: validate ?? (_) => null,
  execute: execute ?? (_, _) async => ToolResult('ok'),
  recover: recover,
);
ScriptedModel callThenAnswer() => ScriptedModel((request, _) async* {
  if (request.messages.last.role == MessageRole.tool) {
    yield ModelResponse(text: 'done');
  } else {
    yield const TextDelta('editing');
    yield ModelResponse(
      calls: [ToolCall(id: 'call-1', name: 'edit')],
    );
  }
});
Future<AgentRun> start(SessionManager manager, {int maxTurns = 20}) async {
  final session = await manager.create();
  return manager.prompt(session.id, 'edit please', maxTurns: maxTurns);
}

void main() {
  test(
    'new turn updates target instructions without replacing history',
    () async {
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
      );
      final session = await manager.create(system: 'timeline A');
      await (await manager.prompt(session.id, 'first')).done;
      final switched = await (await manager.prompt(
        session.id,
        'second',
        system: 'timeline B',
      )).done;
      expect(model.requests.last.system, startsWith('timeline B\n'));
      expect(switched.system, 'timeline B');
      expect(
        switched.history
            .where((m) => m.role == MessageRole.user)
            .map((m) => m.text),
        ['first', 'second'],
      );
      await (await manager.prompt(session.id, 'third')).done;
      expect(model.requests.last.system, startsWith('timeline B\n'));
    },
  );

  test('an empty final model response is a protocol failure', () async {
    final model = ScriptedModel((_, _) async* {
      yield ModelResponse();
    });
    final manager = SessionManager(model: model, store: InMemorySessionStore());
    final result = await (await start(manager)).done;
    expect(result.status, RunStatus.failed);
    expect(result.failure, RunFailure.protocol);
    expect(
      result.history.where((m) => m.role == MessageRole.assistant),
      isEmpty,
    );
  });

  test(
    'token estimation handles multilingual input and explicit counters',
    () async {
      final builder = ContextBuilder();
      for (final text in ['hello world ' * 100, '请剪辑这段视频' * 100, '🎬' * 100]) {
        final history = [AgentMessage(role: MessageRole.user, text: text)];
        final estimate = builder.measureInput(system: '', history: history);
        expect(estimate, greaterThan(0));
        await expectLater(
          ContextBuilder(maxInputTokens: estimate - 1).build(
            system: '',
            history: history,
            tools: [],
            cancellation: CancellationToken(),
          ),
          throwsA(isA<ContextOverflow>()),
        );
        final request = await ContextBuilder(maxInputTokens: estimate).build(
          system: '',
          history: history,
          tools: [],
          cancellation: CancellationToken(),
        );
        expect(request.messages.single.text, text);
      }
      final exact = ContextBuilder(maxInputTokens: 10, countTokens: (_) => 11);
      expect(exact.measureInput(system: 'hi'), 11);
      await expectLater(
        exact.build(
          system: 'hi',
          history: [],
          tools: [],
          cancellation: CancellationToken(),
        ),
        throwsA(isA<ContextOverflow>()),
      );
    },
  );

  for (final entry in <Object, RunFailure>{
    const ContextOverflow('too small'): RunFailure.contextBudget,
    const ModelHttpException(401): RunFailure.authentication,
    const ModelHttpException(403): RunFailure.authentication,
    const ModelHttpException(503): RunFailure.connection,
    const ModelConnectionException(): RunFailure.connection,
    TimeoutException('timed out'): RunFailure.connection,
    const ModelProtocolException('incomplete stream'): RunFailure.protocol,
    const FormatException('bad JSON'): RunFailure.protocol,
    StateError('internal'): RunFailure.request,
  }.entries) {
    test(
      'persists typed failure for ${entry.key.runtimeType} ${entry.value}',
      () async {
        final store = InMemorySessionStore();
        final manager = SessionManager(
          model: ScriptedModel((_, _) => Stream<ModelEvent>.error(entry.key)),
          store: store,
        );
        final result = await (await start(manager)).done;
        expect(result.status, RunStatus.failed);
        expect(result.failure, entry.value);
        expect(SessionSnapshot.fromJson(result.toJson()).failure, entry.value);
        final legacy = result.toJson()..remove('failure');
        expect(SessionSnapshot.fromJson(legacy).failure, isNull);
      },
    );
  }
  test('budget failure stops before calling the model', () async {
    final model = callThenAnswer();
    final manager = SessionManager(
      model: model,
      store: InMemorySessionStore(),
      contextBuilder: ContextBuilder(maxInputTokens: 1),
    );
    final result = await (await start(manager)).done;
    expect(result.failure, RunFailure.contextBudget);
    expect(model.requests, isEmpty);
  });

  test(
    'executes tools, persists real results, and streams ordered events',
    () async {
      final model = callThenAnswer();
      final store = InMemorySessionStore();
      final manager = SessionManager(
        model: model,
        store: store,
        tools: [tool()],
      );
      final run = await start(manager);
      final events = <AgentEvent>[];
      final subscription = run.events.listen(events.add);
      final result = await run.done;
      await subscription.cancel();
      expect(result.status, RunStatus.completed);
      expect(result.history.map((m) => m.role), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
        MessageRole.assistant,
      ]);
      expect(jsonDecode(result.history[2].text)['text'], 'ok');
      expect(events.any((e) => e.kind == AgentEventKind.textDelta), isTrue);
      expect(events.map((e) => e.sequence).toSet().length, events.length);
      expect(model.requests.length, 2);
      expect((await store.read(result.id))!.toJson(), result.toJson());
    },
  );

  test('validation errors are returned without executing', () async {
    var executions = 0;
    final run = await start(
      SessionManager(
        model: callThenAnswer(),
        store: InMemorySessionStore(),
        tools: [
          tool(
            validate: (_) => 'bad arguments',
            execute: (_, _) async {
              executions++;
              return ToolResult('bad');
            },
          ),
        ],
      ),
    );
    final result = await run.done;
    expect(executions, 0);
    expect(result.history[2].isError, isTrue);
    expect(result.status, RunStatus.completed);
  });

  test('unknown tools yield explicit errors', () async {
    final result = await (await start(
      SessionManager(model: callThenAnswer(), store: InMemorySessionStore()),
    )).done;
    expect(result.history[2].isError, isTrue);
  });

  test('partial model stream never executes a tool', () async {
    var executions = 0;
    final model = ScriptedModel((_, _) async* {
      yield const TextDelta('{incomplete');
    });
    final result = await (await start(
      SessionManager(
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
      ),
    )).done;
    expect(result.status, RunStatus.failed);
    expect(executions, 0);
    expect(result.history.length, 1);
  });

  test('ambiguous execution reconciles without repeating the edit', () async {
    var executions = 0;
    String? operationId;
    final store = InMemorySessionStore();
    final manager = SessionManager(
      model: callThenAnswer(),
      store: store,
      tools: [
        tool(
          execute: (_, context) async {
            executions++;
            operationId = context.operationId;
            throw StateError('connection lost after commit');
          },
          recover: (_, context) async {
            expect(context.operationId, operationId);
            return ToolRecovery.completed(ToolResult('committed'));
          },
        ),
      ],
    );
    final first = await (await start(manager)).done;
    expect(first.status, RunStatus.waiting);
    expect(first.pending.single.status, CallStatus.started);
    // A new manager simulates rebuilding the execution layer from stored data.
    final restored = SessionManager(
      model: callThenAnswer(),
      store: store,
      tools: manager.tools,
    );
    final result = await (await restored.resume(first.id)).done;
    expect(result.status, RunStatus.completed);
    expect(executions, 1);
    expect(result.runId, first.runId);
  });

  test('unknown recovery outcome remains waiting', () async {
    var executions = 0;
    final manager = SessionManager(
      model: callThenAnswer(),
      store: InMemorySessionStore(),
      tools: [
        tool(
          execute: (_, _) async {
            executions++;
            throw StateError('unknown');
          },
          recover: (_, _) async => const ToolRecovery.unknown(),
        ),
      ],
    );
    final first = await (await start(manager)).done;
    final second = await (await manager.resume(first.id)).done;
    expect(second.status, RunStatus.waiting);
    expect(executions, 1);
  });

  test(
    'confirmed not-started operation can be retried with same identity',
    () async {
      final ids = <String>[];
      final manager = SessionManager(
        model: callThenAnswer(),
        store: InMemorySessionStore(),
        tools: [
          tool(
            execute: (_, context) async {
              ids.add(context.operationId);
              if (ids.length == 1) throw StateError('not submitted');
              return ToolResult('ok');
            },
            recover: (_, _) async => const ToolRecovery.notStarted(),
          ),
        ],
      );
      final first = await (await start(manager)).done;
      expect(
        (await (await manager.resume(first.id)).done).status,
        RunStatus.completed,
      );
      expect(ids.length, 2);
      expect(ids.toSet().length, 1);
    },
  );

  test(
    'pause settles at tool boundary, then resumes without duplicate edit',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var executions = 0;
      final manager = SessionManager(
        model: callThenAnswer(),
        store: InMemorySessionStore(),
        tools: [
          tool(
            execute: (_, _) async {
              executions++;
              entered.complete();
              await release.future;
              return ToolResult('ok');
            },
          ),
        ],
      );
      final run = await start(manager);
      await entered.future;
      final paused = run.pause();
      release.complete();
      expect((await paused).status, RunStatus.paused);
      expect(
        (await (await manager.resume(run.snapshot.id)).done).status,
        RunStatus.completed,
      );
      expect(executions, 1);
    },
  );

  test('model cancellation propagates and settles', () async {
    final entered = Completer<void>();
    final model = ScriptedModel((_, cancellation) async* {
      entered.complete();
      await cancellation.whenCancelled;
      cancellation.throwIfCancelled();
    });
    final run = await start(
      SessionManager(model: model, store: InMemorySessionStore()),
    );
    await entered.future;
    expect((await run.cancel()).status, RunStatus.cancelled);
  });

  test('cancellation preserves successful tool side effect', () async {
    final entered = Completer<void>();
    final manager = SessionManager(
      model: callThenAnswer(),
      store: InMemorySessionStore(),
      tools: [
        tool(
          execute: (_, context) async {
            entered.complete();
            await context.cancellation.whenCancelled;
            return ToolResult('already committed');
          },
        ),
      ],
    );
    final run = await start(manager);
    await entered.future;
    final result = await run.cancel();
    expect(result.status, RunStatus.cancelled);
    expect(result.history.last.role, MessageRole.tool);
    expect(result.history.last.text, contains('already committed'));
  });

  test('steering is persisted and included in next model request', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final model = ScriptedModel((request, _) async* {
      if (request.messages.length == 1) {
        entered.complete();
        await release.future;
      }
      yield ModelResponse(text: 'answer');
    });
    final run = await start(
      SessionManager(model: model, store: InMemorySessionStore()),
    );
    await entered.future;
    await run.steer('use a shorter version');
    release.complete();
    expect((await run.done).status, RunStatus.completed);
    expect(model.requests.length, 2);
    expect(model.requests.last.messages.last.text, 'use a shorter version');
  });

  test('turn budget pauses and explicit extension continues', () async {
    final manager = SessionManager(
      model: callThenAnswer(),
      store: InMemorySessionStore(),
      tools: [tool()],
    );
    final result = await (await start(manager, maxTurns: 1)).done;
    expect(result.status, RunStatus.paused);
    expect(
      (await (await manager.resume(result.id, maxTurns: 2)).done).status,
      RunStatus.completed,
    );
  });

  test('same-session writer lease excludes another manager', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final model = ScriptedModel((_, _) async* {
      entered.complete();
      await release.future;
      yield ModelResponse(text: 'ok');
    });
    final store = InMemorySessionStore();
    final manager = SessionManager(model: model, store: store);
    final run = await start(manager);
    await entered.future;
    await expectLater(
      SessionManager(model: model, store: store).resume(run.snapshot.id),
      throwsStateError,
    );
    release.complete();
    await run.done;
  });

  test('snapshot JSON roundtrip retains pending recovery identity', () async {
    final manager = SessionManager(
      model: callThenAnswer(),
      store: InMemorySessionStore(),
      tools: [tool(execute: (_, _) async => throw StateError('unknown'))],
    );
    final result = await (await start(manager)).done;
    final decoded = SessionSnapshot.fromJson(
      (jsonDecode(jsonEncode(result.toJson())) as Map).cast<String, Object?>(),
    );
    expect(decoded.toJson(), result.toJson());
    expect(decoded.history.clear, throwsUnsupportedError);
  });

  test('tool arguments are deeply immutable', () {
    final nested = <String, Object?>{
      'items': [1],
    };
    final call = ToolCall(id: 'a', name: 'edit', arguments: nested);
    (nested['items']! as List).add(2);
    expect(call.arguments['items'], [1]);
    expect(
      () => (call.arguments['items']! as List).add(3),
      throwsUnsupportedError,
    );
  });

  test(
    'context pruning preserves complete tool pairs and full source history',
    () async {
      final history = [
        AgentMessage(role: MessageRole.user, text: 'old' * 1000),
        AgentMessage(role: MessageRole.assistant, text: 'old answer'),
        AgentMessage(role: MessageRole.user, text: 'new'),
        AgentMessage(
          role: MessageRole.assistant,
          calls: [ToolCall(id: 'a', name: 'edit')],
        ),
        AgentMessage(role: MessageRole.tool, callId: 'a', text: 'result'),
      ];
      final request = await ContextBuilder(maxInputTokens: 1000).build(
        system: '',
        history: history,
        tools: [],
        cancellation: CancellationToken(),
      );
      expect(request.messages.length, 3);
      expect(history.length, 5);
      expect(request.messages[1].calls.single.id, request.messages[2].callId);
    },
  );

  test('oversized current turn fails explicitly', () async {
    await expectLater(
      ContextBuilder(maxInputTokens: 10).build(
        system: 'required' * 10,
        history: [],
        tools: [],
        cancellation: CancellationToken(),
      ),
      throwsA(isA<ContextOverflow>()),
    );
  });

  test('memory scope is isolated and deletion affects next context', () async {
    final memory = InMemoryMemoryProvider();
    for (final scope in ['a', 'b']) {
      await memory.put(
        AgentMemory(
          id: 'preference',
          scope: scope,
          text: 'short videos $scope',
          source: 'user',
          updatedAt: DateTime.utc(2026),
        ),
      );
    }
    final builder = ContextBuilder(memory: memory);
    Future<ModelRequest> build() => builder.build(
      system: '',
      history: [AgentMessage(role: MessageRole.user, text: 'short')],
      tools: [],
      cancellation: CancellationToken(),
      memoryScope: 'a',
    );
    expect((await build()).system, contains('short videos a'));
    expect((await build()).system, isNot(contains('short videos b')));
    await memory.delete(scope: 'a', id: 'preference');
    expect((await build()).system, isNot(contains('short videos a')));
  });

  test('storage failure before tool start prevents execution', () async {
    var executions = 0;
    final store = FailingStore();
    final manager = SessionManager(
      model: callThenAnswer(),
      store: store,
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
    await expectLater(run.done, throwsStateError);
    expect(executions, 0);
    expect(
      (await store.read(run.snapshot.id))!.pending.single.status,
      CallStatus.planned,
    );
  });
}

class FailingStore extends InMemorySessionStore {
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    if (snapshot.pending.any((c) => c.status == CallStatus.started)) {
      throw StateError('disk failed');
    }
    await super.save(snapshot, expectedRevision: expectedRevision);
  }
}
