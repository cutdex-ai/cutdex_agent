import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel, start;

class Skills implements SkillProvider {
  final List<String> loaded = [];
  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async => [
    const SkillDescriptor(id: 'edit', version: '1', description: 'editing'),
  ];
  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async {
    loaded.add(id);
    return AgentSkill(
      descriptor: const SkillDescriptor(
        id: 'edit',
        version: '1',
        description: 'editing',
      ),
      instructions: 'Keep cuts intentional',
      requiredTools: id == 'restricted' ? ['shell'] : [],
    );
  }
}

class Summarizer implements ContextSummarizer {
  @override
  String get source => 'test-summarizer-v1';
  @override
  Future<String> summarize(
    List<AgentMessage> messages,
    CancellationToken cancellation,
  ) async => 'User prefers concise edits';
}

void main() {
  test(
    'skills load only selected IDs and cannot add tool permissions',
    () async {
      final skills = Skills();
      final builder = ContextBuilder(skills: skills);
      final request = await builder.build(
        system: '',
        history: [],
        tools: [],
        skillIds: ['edit'],
        cancellation: CancellationToken(),
      );
      expect(skills.loaded, ['edit']);
      expect(request.system, contains('edit@1'));
      expect(request.tools, isEmpty);
      await expectLater(
        builder.build(
          system: '',
          history: [],
          tools: [],
          skillIds: ['restricted'],
          cancellation: CancellationToken(),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'compaction appends source-bounded summaries without rewriting history',
    () async {
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'answer');
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
      );
      final first = await (await start(manager)).done;
      final second = await (await manager.prompt(
        first.id,
        'another question',
      )).done;
      final compacted = await manager.compact(first.id, Summarizer());
      expect(
        compacted.history.map((m) => m.toJson()),
        second.history.map((m) => m.toJson()),
      );
      expect(compacted.summaries.single.coveredMessages, 2);
      expect(compacted.summaries.single.source, 'test-summarizer-v1');
      await (await manager.prompt(first.id, 'continue')).done;
      expect(
        model.requests.last.system,
        contains('User prefers concise edits'),
      );
      expect(model.requests.last.messages.first.text, 'another question');
    },
  );

  test('event sequence remains increasing after a resumed run', () async {
    final model = ScriptedModel((_, _) async* {
      yield ModelResponse(text: 'answer');
    });
    final manager = SessionManager(model: model, store: InMemorySessionStore());
    final run = await start(manager);
    final events = <AgentEvent>[];
    final a = run.events.listen(events.add);
    final first = await run.done;
    final next = await manager.prompt(first.id, 'next');
    final b = next.events.listen(events.add);
    await next.done;
    await a.cancel();
    await b.cancel();
    final sequences = events.map((e) => e.sequence).toList();
    expect(sequences.toSet().length, sequences.length);
    expect(sequences, [...sequences]..sort());
  });

  test(
    'child delegation preserves isolated history and durable linkage',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final parentModel = ScriptedModel((_, _) async* {
        entered.complete();
        await release.future;
        yield ModelResponse(text: 'parent answer');
      });
      final store = InMemorySessionStore();
      final parentManager = SessionManager(model: parentModel, store: store);
      final parent = await start(parentManager);
      await entered.future;
      final childModel = ScriptedModel((request, _) async* {
        yield ModelResponse(text: 'child answer');
      });
      final coordinator = AgentCoordinator(
        manager: SessionManager(model: childModel, store: store),
      );
      final child = await coordinator.delegate(
        parent: parent,
        prompt: 'analyze a scene',
      );
      expect(child.parentSessionId, parent.snapshot.id);
      expect(child.depth, 1);
      expect(child.history.first.text, 'analyze a scene');
      expect(parent.snapshot.childSessionIds, [child.id]);
      expect(parent.snapshot.history.length, 1);
      expect(parent.snapshot.delegatedTurns, 10);
      release.complete();
      await parent.done;
    },
  );

  test('parent cancellation propagates to active child', () async {
    final parentEntered = Completer<void>();
    final childEntered = Completer<void>();
    final store = InMemorySessionStore();
    final parentModel = ScriptedModel((_, token) async* {
      parentEntered.complete();
      await token.whenCancelled;
      token.throwIfCancelled();
    });
    final parent = await start(
      SessionManager(model: parentModel, store: store),
    );
    await parentEntered.future;
    final childModel = ScriptedModel((_, token) async* {
      childEntered.complete();
      await token.whenCancelled;
      token.throwIfCancelled();
    });
    final coordinator = AgentCoordinator(
      manager: SessionManager(model: childModel, store: store),
    );
    final child = coordinator.delegate(parent: parent, prompt: 'analyze');
    await childEntered.future;
    await parent.cancel();
    expect((await child).status, RunStatus.cancelled);
  });

  test('delegation budget is enforced without failing the parent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final model = ScriptedModel((_, _) async* {
      entered.complete();
      await release.future;
      yield ModelResponse(text: 'done');
    });
    final store = InMemorySessionStore();
    final parent = await start(SessionManager(model: model, store: store));
    await entered.future;
    final coordinator = AgentCoordinator(
      manager: SessionManager(model: model, store: store),
      maxDelegatedTurns: 2,
    );
    await expectLater(
      coordinator.delegate(parent: parent, prompt: 'too much', maxTurns: 3),
      throwsA(isA<DelegationLimit>()),
    );
    release.complete();
    expect((await parent.done).status, RunStatus.completed);
  });
}
