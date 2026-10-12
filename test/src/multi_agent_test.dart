import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel;

const collaborationNames = {
  'spawn_agent',
  'send_message',
  'followup_task',
  'wait_agent',
  'list_agents',
  'interrupt_agent',
  'request_user_input',
};

ModelResponse call(
  String id,
  String name, [
  Map<String, Object?> args = const {},
]) => ModelResponse(
  calls: [ToolCall(id: id, name: name, arguments: args)],
);
ModelResponse spawn(String name, {String fork = 'none', int? turns}) =>
    call('spawn-$name', 'spawn_agent', {
      'task_name': name,
      'message': 'task $name',
      'fork_turns': fork,
      'max_turns': ?turns,
    });
String? lastTool(ModelRequest request) =>
    request.messages.expand((m) => m.calls).lastOrNull?.name;
Map<String, Object?> data(ModelRequest request) =>
    (jsonDecode(request.messages.last.text) as Map)['data']
        as Map<String, Object?>;
bool childRequest(ModelRequest request) =>
    !request.system.contains('You are /root.');
Future<AgentRun> start(
  SessionManager manager, [
  String prompt = 'parent task',
]) async {
  final session = await manager.create();
  return manager.prompt(session.id, prompt);
}

SessionManager managerFor(
  ModelAdapter model, {
  SessionStore? store,
  MultiAgentConfig? config,
  ContextBuilder? context,
}) => SessionManager(
  model: model,
  store: store ?? InMemorySessionStore(),
  multiAgent: config ?? MultiAgentConfig(),
  contextBuilder: context ?? ContextBuilder(),
);

class FailingStore implements SessionStore {
  FailingStore(this.inner, this.fail);
  final SessionStore inner;
  final bool Function(SessionSnapshot) fail;
  bool failed = false;
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    if (!failed && fail(snapshot)) {
      failed = true;
      throw StateError('simulated crash boundary');
    }
    await inner.save(snapshot, expectedRevision: expectedRevision);
  }

  @override
  Future<SessionSnapshot?> read(String id) => inner.read(id);
  @override
  Future<Object> acquire(String id) => inner.acquire(id);
  @override
  Future<void> release(String id, Object lease) => inner.release(id, lease);
}

void main() {
  group('model-directed collaboration', () {
    test(
      'disabled by default and visible immediately with the default harness',
      () async {
        final model = ScriptedModel((_, _) async* {
          yield ModelResponse(text: 'done');
        });
        await (await start(
          SessionManager(model: model, store: InMemorySessionStore()),
        )).done;
        expect(
          model.requests.single.tools
              .map((t) => t.name)
              .toSet()
              .intersection(collaborationNames),
          isEmpty,
        );
        await (await start(
          SessionManager(
            model: model,
            store: InMemorySessionStore(),
            multiAgent: MultiAgentConfig(),
          ),
        )).done;
        expect(
          model.requests.last.tools.map((t) => t.name),
          containsAll(collaborationNames),
        );
        expect(
          model.requests.last.system,
          contains('Multi-agent collaboration'),
        );
      },
    );

    test(
      'spawns two children concurrently and returns their outputs to the model',
      () async {
        final entered = <String, Completer<void>>{
          'a': Completer<void>(),
          'b': Completer<void>(),
        };
        final release = Completer<void>();
        final waiting = Completer<void>();
        final store = InMemorySessionStore();
        final model = ScriptedModel((request, token) async* {
          if (childRequest(request)) {
            final name = request.messages.last.text.split(' ').last;
            entered[name]!.complete();
            await Future.any([release.future, token.whenCancelled]);
            token.throwIfCancelled();
            yield ModelResponse(text: '$name result');
          } else if (request.messages.length == 1) {
            yield ModelResponse(
              calls: [...spawn('a').calls, ...spawn('b').calls],
            );
          } else if (lastTool(request) == 'spawn_agent') {
            waiting.complete();
            yield call('wait', 'wait_agent', {'timeout_ms': 60000});
          } else {
            yield ModelResponse(text: 'combined results');
          }
        });
        final run = await start(managerFor(model, store: store));
        await waiting.future;
        await Future.wait(entered.values.map((v) => v.future));
        expect(run.snapshot.childSessionIds, hasLength(2));
        release.complete();
        final result = await run.done;
        expect(result.status, RunStatus.completed);
        final rootRequests = model.requests.where((r) => !childRequest(r));
        expect(
          rootRequests.any(
            (r) => r.messages.any((m) => m.text.contains('a result')),
          ),
          isTrue,
        );
        expect(
          rootRequests.any(
            (r) => r.messages.any((m) => m.text.contains('b result')),
          ),
          isTrue,
        );
        for (final id in result.childSessionIds) {
          final child = (await store.read(id))!;
          expect(child.parentSessionId, result.id);
          expect(child.parentRunId, result.runId);
          expect(child.history.first.text, startsWith('task '));
          expect(child.depth, 1);
        }
      },
    );

    test(
      'a premature final answer triggers result collection and synthesis',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            yield ModelResponse(text: 'child evidence');
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else if (request.messages.last.runtimeNotice) {
            expect(request.messages.last.text, contains('child evidence'));
            yield ModelResponse(text: 'reviewed child evidence');
          } else {
            yield ModelResponse(text: 'premature answer');
          }
        });
        final result = await (await start(managerFor(model))).done;
        expect(result.history.last.text, 'reviewed child evidence');
        expect(result.status, RunStatus.completed);
      },
    );

    test(
      'fork copies complete history and excludes the pending tool batch',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            expect(
              request.messages.map((m) => m.text),
              contains('prior user context'),
            );
            expect(request.messages.expand((m) => m.calls), isEmpty);
            yield ModelResponse(text: 'child done');
          } else if (request.messages.last.text == 'prior user context') {
            yield ModelResponse(text: 'prior answer');
          } else if (request.messages.last.text == 'parent task') {
            yield spawn('forked', fork: 'all');
          } else {
            yield ModelResponse(text: 'done');
          }
        });
        final manager = managerFor(model);
        final session = await manager.create();
        await (await manager.prompt(session.id, 'prior user context')).done;
        expect(
          (await (await manager.prompt(session.id, 'parent task')).done).status,
          RunStatus.completed,
        );
        // A new parent turn must not restore reservations from the previous run.
        expect(
          (await (await manager.prompt(
            session.id,
            'another task',
          )).done).status,
          RunStatus.completed,
        );
      },
    );

    test(
      'children at the depth limit cannot discover or execute inherited spawn calls',
      () async {
        final store = InMemorySessionStore();
        var childRequests = 0;
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            expect(
              request.tools.map((t) => t.name),
              isNot(contains('spawn_agent')),
            );
            if (childRequests++ == 0) {
              yield spawn('grandchild');
            } else {
              expect(request.messages.last.isError, isTrue);
              yield ModelResponse(text: 'assigned child task done');
            }
          } else if (request.messages.length == 1) {
            expect(request.tools.map((t) => t.name), contains('spawn_agent'));
            yield spawn('worker', fork: 'all');
          } else {
            yield ModelResponse(text: 'done');
          }
        });
        final result = await (await start(
          managerFor(
            model,
            store: store,
            config: MultiAgentConfig(maxDepth: 1),
          ),
        )).done;
        expect(result.status, RunStatus.completed);
        final child = (await store.read(result.childSessionIds.single))!;
        expect(child.childSessionIds, isEmpty);
        expect(child.status, RunStatus.completed);
      },
    );

    test(
      'concurrency is shared with descendants, and errors remain model-visible',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            if (request.messages.length == 1) {
              yield spawn('grandchild');
            } else {
              expect(request.messages.last.isError, isTrue);
              expect(request.messages.last.text, contains('concurrency'));
              yield ModelResponse(text: 'handled limit');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else {
            yield ModelResponse(text: 'done');
          }
        });
        final result = await (await start(
          managerFor(model, config: MultiAgentConfig(maxConcurrent: 1)),
        )).done;
        expect(result.status, RunStatus.completed);
        expect(result.childSessionIds, hasLength(1));
      },
    );

    test(
      'depth, count, turn limits and invalid arguments do not create children',
      () async {
        for (final config in [
          MultiAgentConfig(maxDepth: 0),
          MultiAgentConfig(maxDelegatedTurns: 2, childMaxTurns: 2),
        ]) {
          final model = ScriptedModel((request, _) async* {
            if (request.messages.length == 1) {
              yield spawn('worker', turns: 3);
            } else {
              expect(request.messages.last.isError, isTrue);
              yield ModelResponse(text: 'handled');
            }
          });
          final result = await (await start(
            managerFor(model, config: config),
          )).done;
          expect(result.childSessionIds, isEmpty);
          expect(result.delegatedTurns, 0);
        }
        final model = ScriptedModel((request, _) async* {
          if (request.messages.length == 1) {
            yield call('bad', 'spawn_agent', {
              'task_name': '../other',
              'message': 'task',
            });
          } else {
            expect(request.messages.last.isError, isTrue);
            yield ModelResponse(text: 'handled');
          }
        });
        expect(
          (await (await start(managerFor(model))).done).childSessionIds,
          isEmpty,
        );
      },
    );

    test('rejects unrelated agent targets and tool name collisions', () async {
      final store = InMemorySessionStore();
      final model = ScriptedModel((request, _) async* {
        if (request.messages.length == 1) {
          yield call('foreign', 'interrupt_agent', {'target': 'unrelated'});
        } else {
          expect(request.messages.last.isError, isTrue);
          expect(request.messages.last.text, contains('unauthorized'));
          yield ModelResponse(text: 'handled');
        }
      });
      final manager = managerFor(model, store: store);
      final foreign = await manager.create(id: 'unrelated');
      await (await start(manager)).done;
      expect((await store.read(foreign.id))!.revision, foreign.revision);
      expect(
        () => SessionManager(
          model: model,
          store: store,
          multiAgent: MultiAgentConfig(),
          tools: [
            AgentTool(
              name: 'spawn_agent',
              description: 'collision',
              parameters: {},
              validate: (_) => null,
              execute: (_, _) async => ToolResult('x'),
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test(
      'idle messages do not start turns and followup preserves history and budget',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            yield ModelResponse(
              text:
                  request.messages.any((m) => m.text.contains('remember this'))
                  ? 'followup result'
                  : 'initial result',
            );
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else if (request.messages.last.runtimeNotice) {
            yield ModelResponse(text: 'combined');
          } else {
            switch (lastTool(request)) {
              case 'spawn_agent':
                yield call('wait-first', 'wait_agent', {'timeout_ms': 60000});
              case 'wait_agent':
                if (request.messages
                    .expand((m) => m.calls)
                    .any((c) => c.id == 'follow')) {
                  yield ModelResponse(text: 'done');
                } else {
                  yield call('send', 'send_message', {
                    'target': 'worker',
                    'message': 'remember this',
                  });
                }
              case 'send_message':
                yield call('follow', 'followup_task', {
                  'target': 'worker',
                  'message': 'additional task',
                  'max_turns': 3,
                });
              case 'followup_task':
                yield call('wait-second', 'wait_agent', {'timeout_ms': 60000});
            }
          }
        });
        final store = InMemorySessionStore();
        final result = await (await start(
          managerFor(model, store: store),
        )).done;
        expect(result.status, RunStatus.completed);
        expect(result.childSessionIds, hasLength(1));
        expect(result.delegatedTurns, 13);
        final child = (await store.read(result.childSessionIds.single))!;
        expect(
          child.history
              .where((m) => m.role == MessageRole.assistant)
              .map((m) => m.text),
          ['initial result', 'followup result'],
        );
        expect(
          child.history.where((m) => m.text.contains('remember this')),
          hasLength(1),
        );
        expect(model.requests.where(childRequest), hasLength(2));
      },
    );

    test(
      'interrupt cancels a turn and the same child accepts followup work',
      () async {
        final entered = Completer<void>();
        final model = ScriptedModel((request, token) async* {
          if (childRequest(request)) {
            if (request.messages.last.text == 'task worker') {
              entered.complete();
              await token.whenCancelled;
              token.throwIfCancelled();
            } else {
              yield ModelResponse(text: 'new child result');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else if (request.messages.last.runtimeNotice) {
            yield ModelResponse(text: 'done');
          } else {
            switch (lastTool(request)) {
              case 'spawn_agent':
                await entered.future;
                yield call('interrupt', 'interrupt_agent', {
                  'target': 'worker',
                });
              case 'interrupt_agent':
                expect(data(request)['status'], 'cancelled');
                yield call('follow', 'followup_task', {
                  'target': 'worker',
                  'message': 'new work',
                });
              case 'followup_task':
                yield call('wait', 'wait_agent');
              case 'wait_agent':
                yield ModelResponse(text: 'done');
            }
          }
        });
        final result = await (await start(managerFor(model))).done;
        expect(result.status, RunStatus.completed);
        expect(result.childSessionIds, hasLength(1));
        expect(result.delegatedTurns, 20);
      },
    );

    test(
      'wait timeout is bounded and parent cancellation settles its child',
      () async {
        final waiting = Completer<void>();
        final model = ScriptedModel((request, token) async* {
          if (childRequest(request)) {
            await token.whenCancelled;
            token.throwIfCancelled();
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else if (lastTool(request) == 'spawn_agent') {
            yield call('wait', 'wait_agent', {'timeout_ms': 5});
          } else {
            expect(data(request)['timed_out'], isTrue);
            waiting.complete();
            await token.whenCancelled;
            token.throwIfCancelled();
          }
        });
        final store = InMemorySessionStore();
        final run = await start(managerFor(model, store: store));
        await waiting.future;
        final result = await run.cancel();
        expect(result.status, RunStatus.cancelled);
        expect(
          (await store.read(result.childSessionIds.single))!.status,
          RunStatus.cancelled,
        );
      },
    );
  });

  group('continuation boundaries', () {
    test(
      'child messages reach the parent without starting a new parent run',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            if (request.messages.length == 1) {
              yield call('report', 'send_message', {
                'target': 'parent',
                'message': 'finding from child',
              });
            } else {
              yield ModelResponse(text: 'child finished');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else {
            yield ModelResponse(text: 'parent finished');
          }
        });
        final result = await (await start(managerFor(model))).done;
        expect(result.status, RunStatus.completed);
        expect(
          result.history.where(
            (m) => m.runtimeNotice && m.text.contains('finding from child'),
          ),
          hasLength(1),
        );
        expect(
          result.history.where(
            (m) => m.role == MessageRole.user && !m.runtimeNotice,
          ),
          hasLength(1),
        );
      },
    );

    test(
      'active followup is delivered before the next child request',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final queued = Completer<void>();
        var childCalls = 0;
        final model = ScriptedModel((request, token) async* {
          if (childRequest(request)) {
            childCalls++;
            if (childCalls == 1) {
              entered.complete();
              await Future.any([release.future, token.whenCancelled]);
              token.throwIfCancelled();
              yield ModelResponse(text: 'initial answer');
            } else {
              expect(request.messages.last.runtimeNotice, isTrue);
              expect(
                request.messages.last.text,
                contains('additional requirement'),
              );
              yield ModelResponse(text: 'revised answer');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else if (lastTool(request) == 'spawn_agent') {
            await entered.future;
            yield call('follow', 'followup_task', {
              'target': 'worker',
              'message': 'additional requirement',
            });
          } else {
            if (!queued.isCompleted) queued.complete();
            yield ModelResponse(text: 'parent done');
          }
        });
        final store = InMemorySessionStore();
        final run = await start(managerFor(model, store: store));
        await queued.future;
        release.complete();
        final result = await run.done;
        final child = (await store.read(result.childSessionIds.single))!;
        expect(child.history.last.text, 'revised answer');
        expect(result.delegatedTurns, 10);
        expect(childCalls, 2);
      },
    );

    test(
      'paused child followup reuses its run and collects its updated result',
      () async {
        var childCalls = 0;
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            childCalls++;
            if (childCalls == 1) {
              yield call('list', 'list_agents');
            } else {
              expect(
                request.messages.last.text,
                contains('continue with more budget'),
              );
              yield ModelResponse(text: 'completed after pause');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker', turns: 1);
          } else if (request.messages.last.runtimeNotice) {
            expect(
              request.messages.last.text,
              contains('completed after pause'),
            );
            yield ModelResponse(text: 'reviewed new result');
          } else {
            switch (lastTool(request)) {
              case 'spawn_agent':
                yield call('wait', 'wait_agent');
              case 'wait_agent':
                expect(
                  (data(request)['agents'] as List).single['status'],
                  'paused',
                );
                yield call('follow', 'followup_task', {
                  'target': 'worker',
                  'message': 'continue with more budget',
                  'max_turns': 2,
                });
              case 'followup_task':
                yield ModelResponse(text: 'early answer');
            }
          }
        });
        final store = InMemorySessionStore();
        final result = await (await start(
          managerFor(model, store: store),
        )).done;
        expect(result.status, RunStatus.completed);
        expect(result.history.last.text, 'reviewed new result');
        expect(result.delegatedTurns, 3);
        final child = (await store.read(result.childSessionIds.single))!;
        expect(child.turns, 2);
        expect(child.maxTurns, 3);
      },
    );

    test(
      'parent cannot complete while a child has exhausted its turn budget',
      () async {
        var childCalls = 0;
        var continued = false;
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            if (childCalls++ == 0) {
              yield call('child-list', 'list_agents');
            } else {
              yield ModelResponse(text: 'child final report');
            }
          } else if (request.messages.length == 1) {
            yield spawn('worker', turns: 1);
          } else if (request.messages.last.runtimeNotice &&
              request.messages.last.text.contains(
                'Runtime unfinished child turns',
              )) {
            continued = true;
            yield call('finish-child', 'followup_task', {
              'target': 'worker',
              'message':
                  'Verify and return your final report without repeating writes.',
              'max_turns': 2,
            });
          } else if (lastTool(request) == 'spawn_agent' ||
              lastTool(request) == 'followup_task') {
            yield call(
              lastTool(request) == 'spawn_agent'
                  ? 'wait-initial'
                  : 'wait-final',
              'wait_agent',
            );
          } else {
            yield ModelResponse(text: 'parent tries to finish');
          }
        });
        final store = InMemorySessionStore();
        final result = await (await start(
          managerFor(model, store: store),
        )).done;
        expect(continued, isTrue);
        expect(result.status, RunStatus.completed);
        expect(
          (await store.read(result.childSessionIds.single))!.status,
          RunStatus.completed,
        );
        expect(childCalls, 2);
      },
    );

    test(
      'ignored child budget exhaustion pauses the parent instead of completing',
      () async {
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            yield call('child-list', 'list_agents');
          } else if (request.messages.length == 1) {
            yield spawn('worker', turns: 1);
          } else {
            yield ModelResponse(
              text: 'claims completion without continuing the child',
            );
          }
        });
        final manager = managerFor(model);
        final session = await manager.create();
        final result = await (await manager.prompt(
          session.id,
          'parent task',
          maxTurns: 3,
        )).done;
        expect(result.status, RunStatus.paused);
        expect(result.error, contains('turn budget'));
        expect(
          result.history.any(
            (m) =>
                m.runtimeNotice &&
                m.text.contains('Runtime unfinished child turns'),
          ),
          isTrue,
        );
      },
    );

    test(
      'count limits and duplicate task names preserve the first child',
      () async {
        for (final duplicate in [true, false]) {
          final model = ScriptedModel((request, _) async* {
            if (childRequest(request)) {
              yield ModelResponse(text: 'child done');
            } else if (request.messages.length == 1) {
              yield spawn('worker');
            } else if (request.messages.last.runtimeNotice) {
              yield ModelResponse(text: 'done');
            } else if (request.messages.expand((m) => m.calls).length == 1) {
              yield call('second', 'spawn_agent', {
                'task_name': duplicate ? 'worker' : 'second',
                'message': 'another task',
              });
            } else {
              expect(request.messages.last.isError, isTrue);
              yield ModelResponse(text: 'handled');
            }
          });
          final result = await (await start(
            managerFor(model, config: MultiAgentConfig(maxChildren: 1)),
          )).done;
          expect(result.childSessionIds, hasLength(1));
          expect(result.delegatedTurns, 10);
        }
      },
    );
  });

  group('collaboration recovery', () {
    for (final boundary in ['create', 'spawn-result']) {
      test(
        'resumes after $boundary failure without duplicating child or budget',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'multi-agent-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final disk = FileSessionStore(directory);
          final store = FailingStore(
            disk,
            (s) => boundary == 'create'
                ? s.parentSessionId != null && s.runId == null
                : s.parentSessionId == null &&
                      s.pending.any(
                        (c) =>
                            c.call.name == 'spawn_agent' &&
                            c.status == CallStatus.finished,
                      ),
          );
          var childCalls = 0;
          final model = ScriptedModel((request, _) async* {
            if (childRequest(request)) {
              childCalls++;
              yield ModelResponse(text: 'child result');
            } else if (request.messages.length == 1) {
              yield spawn('worker');
            } else {
              yield ModelResponse(text: 'parent done');
            }
          });
          final first = managerFor(model, store: store);
          final run = await start(first);
          if (boundary == 'create') {
            expect((await run.done).status, RunStatus.waiting);
          } else {
            await expectLater(run.done, throwsStateError);
          }
          expect(store.failed, isTrue);
          final restored = managerFor(
            model,
            store: FileSessionStore(directory),
          );
          final result = await (await restored.resume(run.snapshot.id)).done;
          expect(result.status, RunStatus.completed);
          expect(result.childSessionIds, hasLength(1));
          expect(result.delegatedTurns, 10);
          expect(
            childCalls,
            boundary == 'create' ? equals(1) : lessThanOrEqualTo(1),
          );
        },
      );
    }

    test(
      'resumes a persisted running child before the parent model request',
      () async {
        final store = InMemorySessionStore();
        await store.save(
          SessionSnapshot(
            id: 'parent',
            runId: 'parent-run',
            status: RunStatus.running,
            childSessionIds: ['child'],
            delegatedTurns: 10,
            history: [
              AgentMessage(role: MessageRole.user, text: 'parent task'),
            ],
          ),
          expectedRevision: null,
        );
        await store.save(
          SessionSnapshot(
            id: 'child',
            runId: 'child-run',
            status: RunStatus.running,
            parentSessionId: 'parent',
            parentRunId: 'parent-run',
            depth: 1,
            agentState: {'name': '/root/worker'},
            history: [
              AgentMessage(role: MessageRole.user, text: 'task worker'),
            ],
          ),
          expectedRevision: null,
        );
        final model = ScriptedModel((request, _) async* {
          if (childRequest(request)) {
            yield ModelResponse(text: 'restored child result');
          } else if (request.messages.last.runtimeNotice) {
            expect(
              request.messages.last.text,
              contains('restored child result'),
            );
            yield ModelResponse(text: 'restored parent result');
          } else {
            yield ModelResponse(text: 'early parent result');
          }
        });
        final result = await (await managerFor(
          model,
          store: store,
        ).resume('parent')).done;
        expect(result.status, RunStatus.completed);
        expect(result.history.last.text, 'restored parent result');
        expect((await store.read('child'))!.runId, 'child-run');
      },
    );

    test(
      'stopped parent restores and cancels unfinished descendants without model calls',
      () async {
        final store = InMemorySessionStore();
        await store.save(
          SessionSnapshot(
            id: 'parent',
            runId: 'parent-run',
            status: RunStatus.running,
            stopRequested: true,
            childSessionIds: ['child'],
            delegatedTurns: 10,
            history: [
              AgentMessage(role: MessageRole.user, text: 'parent task'),
            ],
          ),
          expectedRevision: null,
        );
        await store.save(
          SessionSnapshot(
            id: 'child',
            runId: 'child-run',
            status: RunStatus.running,
            parentSessionId: 'parent',
            parentRunId: 'parent-run',
            depth: 1,
            agentState: {'name': '/root/worker'},
            history: [
              AgentMessage(role: MessageRole.user, text: 'task worker'),
            ],
          ),
          expectedRevision: null,
        );
        final model = ScriptedModel((_, _) async* {
          fail('Cancelled recovery must not call the model');
        });
        final result = await (await managerFor(
          model,
          store: store,
        ).resume('parent')).done;
        expect(result.status, RunStatus.cancelled);
        expect((await store.read('child'))!.status, RunStatus.cancelled);
      },
    );

    test(
      'cancelled spawn recovery does not create a merely reserved child',
      () async {
        final store = InMemorySessionStore();
        final toolCall = ToolCall(
          id: 'spawn',
          name: 'spawn_agent',
          arguments: {'task_name': 'worker', 'message': 'task worker'},
        );
        final operation = jsonEncode(['parent', 'parent-run', 'spawn']);
        await store.save(
          SessionSnapshot(
            id: 'parent',
            runId: 'parent-run',
            status: RunStatus.running,
            stopRequested: true,
            childSessionIds: ['reserved-child'],
            delegatedTurns: 10,
            agentState: {
              'reservations': {
                operation: {
                  'id': 'reserved-child',
                  'name': '/root/worker',
                  'message': 'task worker',
                  'maxTurns': 10,
                  'fork': 'none',
                },
              },
            },
            history: [
              AgentMessage(role: MessageRole.user, text: 'parent task'),
              AgentMessage(role: MessageRole.assistant, calls: [toolCall]),
            ],
            pending: [
              CallRecord(
                call: toolCall,
                operationId: operation,
                status: CallStatus.started,
              ),
            ],
          ),
          expectedRevision: null,
        );
        final model = ScriptedModel((_, _) async* {
          fail('Cancelled spawn must not call the model');
        });
        final result = await (await managerFor(
          model,
          store: store,
        ).resume('parent')).done;
        expect(result.status, RunStatus.cancelled);
        expect(await store.read('reserved-child'), isNull);
        expect(result.pending, isEmpty);
        expect(result.history.last.text, contains('not replayed'));
      },
    );

    test(
      'host-started child turns share the manager concurrency limit',
      () async {
        final entered = Completer<void>();
        final model = ScriptedModel((request, token) async* {
          if (childRequest(request)) {
            entered.complete();
            await token.whenCancelled;
            token.throwIfCancelled();
          } else if (request.messages.length == 1) {
            yield spawn('worker');
          } else {
            expect(request.messages.last.isError, isTrue);
            expect(request.messages.last.text, contains('concurrency'));
            yield ModelResponse(text: 'handled capacity');
          }
        });
        final manager = managerFor(
          model,
          config: MultiAgentConfig(maxConcurrent: 1),
        );
        final child = await manager.create(
          parentSessionId: 'some-parent',
          agentState: {'name': '/root/external'},
          depth: 1,
        );
        final active = await manager.prompt(child.id, 'external task');
        await entered.future;
        final result = await (await start(manager)).done;
        expect(result.status, RunStatus.completed);
        expect(result.childSessionIds, isEmpty);
        await active.cancel();
      },
    );

    test('old snapshots deserialize with empty collaboration state', () {
      final json = SessionSnapshot(id: 'old').toJson()..remove('agentState');
      expect(SessionSnapshot.fromJson(json).agentState, isEmpty);
    });
  });
}
