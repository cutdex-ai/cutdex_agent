import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel;
import 'multi_agent_test.dart' show call, spawn, childRequest;

ModelResponse question({bool withWrite = false, String id = 'question'}) =>
    ModelResponse(
      calls: [
        ToolCall(
          id: id,
          name: 'request_user_input',
          arguments: {
            'question': '最终时长选择10秒还是20秒？',
            'reason': '同一字段无法同时等于两个值。',
            'options': [
              {'id': 'ten', 'label': '严格10秒'},
              {'id': 'twenty', 'label': '严格20秒'},
            ],
          },
        ),
        if (withWrite) ToolCall(id: 'stale-write', name: 'edit'),
      ],
    );

SessionManager configured(
  ModelAdapter model,
  SessionStore store, {
  Iterable<AgentTool> tools = const [],
}) => SessionManager(
  model: model,
  store: store,
  tools: tools,
  contextBuilder: ContextBuilder(),
  multiAgent: MultiAgentConfig(),
);

Future<SessionSnapshot> ask(SessionManager manager) async {
  final session = await manager.create();
  return (await manager.prompt(session.id, '两个互斥目标')).done;
}

void main() {
  test(
    'durable question blocks model and batch writes; selected answer resumes same run',
    () async {
      final directory = await Directory.systemTemp.createTemp('cutdex-input-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileSessionStore(directory);
      var writes = 0;
      final model = ScriptedModel((request, _) async* {
        if (request.messages.length == 1) {
          yield question(withWrite: true);
        } else {
          expect(request.messages.last.text, contains('twenty: 严格20秒'));
          final results = request.messages.where(
            (m) => m.role == MessageRole.tool,
          );
          expect(results, hasLength(2));
          expect(results.last.isError, isTrue);
          expect(results.last.text, contains('superseded_by_user_input'));
          yield ModelResponse(text: '按用户选择，执行20秒目标。');
        }
      });
      final edit = AgentTool(
        name: 'edit',
        description: 'write',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async {
          writes++;
          return ToolResult('written');
        },
      );
      final manager = configured(model, store, tools: [edit]);
      final session = await manager.create();
      final run = await manager.prompt(session.id, '两个互斥目标');
      final events = <AgentEvent>[];
      final subscription = run.events.listen(events.add);
      final waiting = await run.done;
      await subscription.cancel();
      expect(waiting.status, RunStatus.waitingUser);
      expect(waiting.pendingUserInput!.options.map((o) => o.id), [
        'ten',
        'twenty',
      ]);
      expect(waiting.pending.map((c) => c.status), [
        CallStatus.started,
        CallStatus.planned,
      ]);
      expect(
        events.any((e) => e.kind == AgentEventKind.userInputRequested),
        isTrue,
      );
      expect(writes, 0);
      expect(model.requests, hasLength(1));
      final reopened = configured(
        model,
        FileSessionStore(directory),
        tools: [edit],
      );
      final stillWaiting = await (await reopened.resume(session.id)).done;
      expect(stillWaiting.status, RunStatus.waitingUser);
      expect(model.requests, hasLength(1));
      expect(writes, 0);
      final result = await (await reopened.answerUserInput(
        session.id,
        requestId: waiting.pendingUserInput!.id,
        optionId: 'twenty',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(result.runId, waiting.runId);
      expect(result.runStart, waiting.runStart);
      expect(result.pendingUserInput, isNull);
      expect(result.pending, isEmpty);
      expect(writes, 0);
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'stale, invalid and duplicate answers cannot mutate checkpoint',
    () async {
      final model = ScriptedModel((request, _) async* {
        yield request.messages.length == 1
            ? question()
            : ModelResponse(text: 'done');
      });
      final store = InMemorySessionStore();
      final manager = configured(model, store);
      final waiting = await ask(manager);
      final id = waiting.pendingUserInput!.id;
      for (final args in [
        {'requestId': 'stale', 'optionId': 'ten'},
        {'requestId': id, 'optionId': 'absent'},
        {'requestId': id, 'text': ' '},
        {'requestId': id},
        {'requestId': id, 'text': 'twenty', 'optionId': 'ten'},
      ]) {
        await expectLater(
          manager.answerUserInput(
            waiting.id,
            requestId: args['requestId']!,
            optionId: args['optionId'],
            text: args['text'],
          ),
          throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
        );
        expect(
          jsonEncode((await store.read(waiting.id))!.toJson()),
          jsonEncode(waiting.toJson()),
        );
      }
      await expectLater(manager.prompt(waiting.id, '跳过问题'), throwsStateError);
      final result = await (await manager.answerUserInput(
        waiting.id,
        requestId: id,
        optionId: 'ten',
      )).done;
      await expectLater(
        manager.answerUserInput(waiting.id, requestId: id, optionId: 'twenty'),
        throwsStateError,
      );
      expect((await store.read(waiting.id))!.revision, result.revision);
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'free text is actual user input and may produce another durable question',
    () async {
      final model = ScriptedModel((request, _) async* {
        if (request.messages.length == 1) {
          yield question();
        } else if (request.messages.last.text.contains('取消两个旧目标，使用15秒')) {
          yield question(id: 'second-question');
        } else {
          yield ModelResponse(text: 'done');
        }
      });
      final manager = configured(model, InMemorySessionStore());
      final first = await ask(manager);
      final second = await (await manager.answerUserInput(
        first.id,
        requestId: first.pendingUserInput!.id,
        text: '取消两个旧目标，使用15秒',
      )).done;
      expect(second.status, RunStatus.waitingUser);
      expect(second.runId, first.runId);
      expect(second.pendingUserInput!.id, isNot(first.pendingUserInput!.id));
    },
  );

  test(
    'question stops active child and is not available to child models',
    () async {
      final entered = Completer<void>();
      var writes = 0;
      final model = ScriptedModel((request, token) async* {
        if (childRequest(request)) {
          expect(
            request.tools.map((t) => t.name),
            isNot(contains('request_user_input')),
          );
          if (!entered.isCompleted) entered.complete();
          await token.whenCancelled;
          token.throwIfCancelled();
          writes++;
          yield ModelResponse(text: 'unsafe');
        } else if (request.messages.length == 1) {
          yield spawn('worker');
        } else {
          await entered.future;
          yield question();
        }
      });
      final store = InMemorySessionStore();
      final result = await ask(configured(model, store));
      expect(result.status, RunStatus.waitingUser);
      expect(
        (await store.read(result.childSessionIds.single))!.status,
        RunStatus.cancelled,
      );
      expect(writes, 0);
    },
  );

  test(
    'crash checkpoint with unanswered question does not replay model or planned calls',
    () async {
      final model = ScriptedModel((request, _) async* {
        yield question(withWrite: true);
      });
      final store = InMemorySessionStore();
      final manager = configured(model, store);
      final waiting = await ask(manager);
      await store.save(
        waiting.update({
          'revision': waiting.revision + 1,
          'status': RunStatus.running.name,
        }),
        expectedRevision: waiting.revision,
      );
      final recovered = await (await configured(
        model,
        store,
      ).resume(waiting.id)).done;
      expect(recovered.status, RunStatus.waitingUser);
      expect(recovered.pendingUserInput!.id, waiting.pendingUserInput!.id);
      expect(model.requests, hasLength(1));
      expect(recovered.pending.last.status, CallStatus.planned);
    },
  );

  test('old snapshot without input fields remains readable', () {
    final json = SessionSnapshot(id: 'old').toJson()
      ..remove('pendingUserInput');
    expect(SessionSnapshot.fromJson(json).pendingUserInput, isNull);
  });

  test('selected goal can be reassigned to the same stopped child', () async {
    var stage = 0;
    var applied = 0;
    final entered = Completer<void>();
    final model = ScriptedModel((request, token) async* {
      if (childRequest(request)) {
        if (!request.messages.last.text.contains('chosen twenty')) {
          if (!entered.isCompleted) entered.complete();
          await token.whenCancelled;
          token.throwIfCancelled();
        } else {
          applied = 20;
          yield ModelResponse(text: 'chosen twenty applied');
        }
      } else {
        switch (stage++) {
          case 0:
            yield spawn('worker');
          case 1:
            await entered.future;
            yield question();
          case 2:
            yield call('reassign', 'followup_task', {
              'target': 'worker',
              'message': 'chosen twenty; abandon ten',
            });
          case 3:
            yield call('wait-selected', 'wait_agent');
          default:
            yield ModelResponse(text: '20 verified');
        }
      }
    });
    final store = InMemorySessionStore();
    final manager = configured(model, store);
    final waiting = await ask(manager);
    final childId = waiting.childSessionIds.single;
    final stopped = (await store.read(childId))!;
    expect(stopped.status, RunStatus.cancelled);
    final done = await (await manager.answerUserInput(
      waiting.id,
      requestId: waiting.pendingUserInput!.id,
      optionId: 'twenty',
    )).done;
    final child = (await store.read(childId))!;
    expect(done.status, RunStatus.completed);
    expect(done.childSessionIds, [childId]);
    expect(child.status, RunStatus.completed);
    expect(child.parentRunId, waiting.runId);
    expect(child.runId, isNot(stopped.runId));
    expect(applied, 20);
  });

  test(
    'unanswered recovery cancels persisted child calls instead of replaying old mutations',
    () async {
      final model = ScriptedModel((_, _) async* {
        yield question();
      });
      final store = InMemorySessionStore();
      final manager = configured(model, store);
      final waiting = await ask(manager);
      final child = SessionSnapshot(
        id: 'interrupted-child',
        runId: 'child-run',
        parentSessionId: waiting.id,
        parentRunId: waiting.runId,
        depth: 1,
        status: RunStatus.paused,
        agentState: {'name': '/root/worker'},
        history: [
          AgentMessage(
            role: MessageRole.assistant,
            calls: [ToolCall(id: 'obsolete', name: 'edit')],
          ),
        ],
        pending: [
          CallRecord(
            call: ToolCall(id: 'obsolete', name: 'edit'),
            operationId: 'old-write',
          ),
        ],
      );
      await store.save(child, expectedRevision: null);
      await store.save(
        waiting.update({
          'revision': waiting.revision + 1,
          'childSessionIds': [child.id],
        }),
        expectedRevision: waiting.revision,
      );
      var writes = 0;
      final edit = AgentTool(
        name: 'edit',
        description: 'write',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async {
          writes++;
          return ToolResult('written');
        },
      );
      final result = await (await configured(
        model,
        store,
        tools: [edit],
      ).resume(waiting.id)).done;
      expect(result.status, RunStatus.waitingUser);
      final stopped = (await store.read(child.id))!;
      expect(stopped.status, RunStatus.cancelled);
      expect(stopped.pending, isEmpty);
      expect(stopped.history.last.text, contains('executed":false'));
      expect(writes, 0);
      expect(model.requests, hasLength(1));
    },
  );

  test(
    'completed calls before a question remain paired; later batch calls are discarded',
    () async {
      var writes = 0;
      final model = ScriptedModel((request, _) async* {
        if (request.messages.length == 1) {
          yield ModelResponse(
            calls: [
              ToolCall(id: 'prior-write', name: 'edit'),
              ...question(withWrite: true).calls,
            ],
          );
        } else {
          final tools = request.messages
              .where((m) => m.role == MessageRole.tool)
              .toList();
          expect(tools.map((m) => m.callId), [
            'prior-write',
            'question',
            'stale-write',
          ]);
          expect(tools.first.isError, isFalse);
          expect(tools.last.isError, isTrue);
          yield ModelResponse(text: 'done');
        }
      });
      final edit = AgentTool(
        name: 'edit',
        description: 'write',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async {
          writes++;
          return ToolResult('written');
        },
      );
      final manager = configured(model, InMemorySessionStore(), tools: [edit]);
      final waiting = await ask(manager);
      expect(writes, 1);
      final result = await (await manager.answerUserInput(
        waiting.id,
        requestId: waiting.pendingUserInput!.id,
        optionId: 'ten',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(writes, 1);
    },
  );

  test(
    'invalid question produces a tool error rather than suspending',
    () async {
      final model = ScriptedModel((request, _) async* {
        if (request.messages.length == 1) {
          yield call('invalid', 'request_user_input', {
            'question': 'choose',
            'options': [
              {'id': 'same', 'label': 'one'},
              {'id': 'same', 'label': 'two'},
            ],
          });
        } else {
          expect(request.messages.last.isError, isTrue);
          yield ModelResponse(text: 'done');
        }
      });
      final result = await ask(configured(model, InMemorySessionStore()));
      expect(result.pendingUserInput, isNull);
      expect(result.status, RunStatus.completed);
    },
  );
}
