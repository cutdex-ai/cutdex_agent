import 'dart:async';
import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show ScriptedModel;

class FixedSkill implements SkillProvider {
  FixedSkill(this.instructions);
  final String instructions;
  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async =>
      [];
  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async =>
      AgentSkill(
        descriptor: SkillDescriptor(id: id, version: '1', description: 'fixed'),
        instructions: instructions,
      );
}

class Summary implements ContextSummarizer {
  Summary(this.build);
  final Future<String> Function(List<AgentMessage>, CancellationToken) build;
  @override
  String get source => 'offline-test';
  @override
  Future<String> summarize(
    List<AgentMessage> messages,
    CancellationToken cancellation,
  ) => build(messages, cancellation);
}

void main() {
  test('steering cannot evict the active run goal and constraints', () async {
    final history = [
      AgentMessage(role: MessageRole.user, text: 'old session' * 1000),
      AgentMessage(role: MessageRole.assistant, text: 'old response'),
      AgentMessage(
        role: MessageRole.user,
        text: 'Keep original audio; do not delete source media.',
      ),
      AgentMessage(role: MessageRole.assistant, text: 'plan'),
      AgentMessage(
        role: MessageRole.user,
        text: 'Also shorten the introduction',
      ),
    ];
    final request = await ContextBuilder(maxInputTokens: 1000).build(
      system: '',
      history: history,
      tools: [],
      cancellation: CancellationToken(),
      requiredHistoryStart: 2,
    );
    expect(request.messages.length, 3);
    expect(request.messages.first.text, contains('do not delete source media'));
    expect(request.messages.last.text, 'Also shorten the introduction');
    await expectLater(
      ContextBuilder(
        maxInputTokens:
            ContextBuilder().measureInput(
              system: '',
              history: history.sublist(2),
            ) -
            1,
      ).build(
        system: '',
        history: history,
        tools: [],
        cancellation: CancellationToken(),
        requiredHistoryStart: 2,
      ),
      throwsA(isA<ContextOverflow>()),
    );
  });

  test('injected byte counter includes Unicode and JSON escapes', () async {
    final history = [
      AgentMessage(role: MessageRole.user, text: 'old' * 500),
      AgentMessage(role: MessageRole.assistant, text: 'old result'),
      AgentMessage(role: MessageRole.user, text: '剪辑🎬\n"' * 20),
    ];
    final request =
        await ContextBuilder(
          maxInputTokens: 1000,
          countTokens: (text) => utf8.encode(text).length,
        ).build(
          system: 'keep constraints',
          history: history,
          tools: [],
          cancellation: CancellationToken(),
        );
    final bytes = utf8
        .encode(
          jsonEncode({
            'system': request.system,
            'messages': request.messages.map((m) => m.toJson()).toList(),
            'tools': [],
          }),
        )
        .length;
    expect(bytes, lessThanOrEqualTo(1000));
    expect(request.messages.last.text, history.last.text);
  });

  test('selected skill is never silently dropped for budget', () async {
    await expectLater(
      ContextBuilder(
        maxInputTokens: 500,
        skills: FixedSkill('instruction' * 1000),
      ).build(
        system: '',
        history: [],
        tools: [],
        skillIds: ['selected'],
        cancellation: CancellationToken(),
      ),
      throwsA(isA<ContextOverflow>()),
    );
  });

  test('selected skills require a provider', () async {
    await expectLater(
      ContextBuilder().build(
        system: '',
        history: [],
        tools: [],
        skillIds: ['selected'],
        cancellation: CancellationToken(),
      ),
      throwsStateError,
    );
  });

  test('summary boundary cannot split a tool call/result group', () async {
    final history = [
      AgentMessage(role: MessageRole.user, text: 'edit'),
      AgentMessage(
        role: MessageRole.assistant,
        calls: [ToolCall(id: 'call', name: 'edit')],
      ),
      AgentMessage(role: MessageRole.tool, callId: 'call', text: 'done'),
    ];
    await expectLater(
      ContextBuilder().build(
        system: '',
        history: history,
        tools: [],
        cancellation: CancellationToken(),
        summary: const ContextSummary(
          text: 'summary',
          coveredMessages: 2,
          source: 'test',
        ),
      ),
      throwsStateError,
    );
  });

  test('multi-call group stays whole under history pruning', () async {
    final history = [
      AgentMessage(role: MessageRole.user, text: 'old' * 10000),
      AgentMessage(role: MessageRole.assistant, text: 'old result'),
      AgentMessage(
        role: MessageRole.user,
        text: 'current task and constraints',
      ),
      AgentMessage(
        role: MessageRole.assistant,
        calls: [
          ToolCall(id: 'a', name: 'read'),
          ToolCall(id: 'b', name: 'read'),
        ],
      ),
      AgentMessage(role: MessageRole.tool, callId: 'a', text: 'a result'),
      AgentMessage(role: MessageRole.tool, callId: 'b', text: 'b result'),
    ];
    final request = await ContextBuilder(maxInputTokens: 1500).build(
      system: '',
      history: history,
      tools: [],
      cancellation: CancellationToken(),
    );
    expect(request.messages.length, 4);
    expect(request.messages.first.text, 'current task and constraints');
    expect(
      request.messages
          .where((m) => m.role == MessageRole.tool)
          .map((m) => m.callId),
      ['a', 'b'],
    );
    expect(history.length, 6);
  });

  test(
    'failed or cancelled summary leaves history and revision untouched',
    () async {
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'answer');
      });
      final store = InMemorySessionStore();
      final manager = SessionManager(model: model, store: store);
      final session = await manager.create();
      await (await manager.prompt(session.id, 'one')).done;
      final before = await (await manager.prompt(session.id, 'two')).done;
      await expectLater(
        manager.compact(
          session.id,
          Summary((_, _) async => throw StateError('summary failed')),
        ),
        throwsStateError,
      );
      expect((await store.read(session.id))!.toJson(), before.toJson());
      final token = CancellationToken();
      await expectLater(
        manager.compact(
          session.id,
          Summary((_, _) async {
            token.cancel();
            return 'summary';
          }),
          cancellation: token,
        ),
        throwsA(isA<AgentCancelled>()),
      );
      expect((await store.read(session.id))!.toJson(), before.toJson());
      await expectLater(
        manager.compact(session.id, Summary((_, _) async => ' ')),
        throwsStateError,
      );
      expect((await store.read(session.id))!.toJson(), before.toJson());
    },
  );

  test('compaction cannot race an active session writer', () async {
    final entered = Completer<void>();
    final released = Completer<void>();
    final model = ScriptedModel((_, _) async* {
      entered.complete();
      await released.future;
      yield ModelResponse(text: 'answer');
    });
    final manager = SessionManager(model: model, store: InMemorySessionStore());
    final session = await manager.create();
    final run = await manager.prompt(session.id, 'task');
    await entered.future;
    await expectLater(
      manager.compact(session.id, Summary((_, _) async => 'summary')),
      throwsStateError,
    );
    released.complete();
    await run.done;
  });
}
