import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel, tool;
import 'context_boundaries_test.dart' show Summary;

class ProjectedBuilder extends ContextBuilder {
  ProjectedBuilder(ContextSummarizer summarizer)
    : super(maxInputTokens: 1400, summarizer: summarizer);
  @override
  List<AgentMessage> projectHistory(List<AgentMessage> history) => [
    for (final message in history)
      if (message.role == MessageRole.tool)
        AgentMessage(
          role: MessageRole.tool,
          callId: message.callId,
          text: 'Saved state; unchanged duplicate fields omitted.',
        )
      else
        message,
  ];
}

void main() {
  test(
    'large fixed instructions do not repeatedly consume compaction headroom',
    () async {
      var summaries = 0;
      final builder = ContextBuilder(
        maxInputTokens: 2400,
        countTokens: (text) => text.length,
        summarizer: Summary((_, _) async {
          summaries++;
          return 'summary';
        }),
      );
      final system = 'policy ' * 140;
      final prompt = 'task ' * 180;
      final size = builder.measureInput(
        system: system,
        history: [AgentMessage(role: MessageRole.user, text: prompt)],
      );
      expect(size, greaterThan(2400 * .8));
      final manager = SessionManager(
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(text: 'done');
        }),
        store: InMemorySessionStore(),
        contextBuilder: builder,
      );
      final session = await manager.create(system: system);
      final result = await (await manager.prompt(session.id, prompt)).done;
      expect(result.status, RunStatus.completed);
      expect(summaries, 0);
    },
  );

  test(
    'compaction uses the projected request, not raw tool output size',
    () async {
      var summaries = 0;
      final model = ScriptedModel((request, _) async* {
        if (request.messages.last.role == MessageRole.tool) {
          expect(request.messages.last.text, contains('Saved state'));
          yield ModelResponse(text: 'done');
        } else {
          yield ModelResponse(
            calls: [ToolCall(id: 'once', name: 'edit')],
          );
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: ProjectedBuilder(
          Summary((_, _) async {
            summaries++;
            return 'summary';
          }),
        ),
        tools: [tool(execute: (_, _) async => ToolResult('duplicate ' * 3000))],
      );
      final session = await manager.create();
      final result = await (await manager.prompt(session.id, 'edit')).done;
      expect(result.status, RunStatus.completed);
      expect(summaries, 0);
      expect(
        result.history
            .where((m) => m.role == MessageRole.tool)
            .single
            .text
            .length,
        greaterThan(20000),
      );
    },
  );

  test(
    'long active run compacts twice without replaying edits; reload keeps history',
    () async {
      var edits = 0;
      var summaries = 0;
      final store = InMemorySessionStore();
      final summarizer = Summary((messages, _) async {
        summaries++;
        expect(messages.where((m) => m.role == MessageRole.tool), isNotEmpty);
        if (summaries > 1) expect(messages.first.text, contains('Completed'));
        return 'Goal: edit then report. Constraints: preserve audio. '
            'Completed: $edits edits saved. Pending: continue verification.';
      });
      final model = ScriptedModel((request, _) async* {
        if (edits < 2) {
          yield ModelResponse(
            calls: [ToolCall(id: 'edit-$edits', name: 'edit')],
          );
        } else {
          expect(request.system, contains('Completed: 2 edits saved'));
          yield ModelResponse(text: 'verified');
        }
      });
      final manager = SessionManager(
        model: model,
        store: store,
        contextBuilder: ContextBuilder(
          maxInputTokens: 1400,
          summarizer: summarizer,
        ),
        tools: [
          tool(
            execute: (_, _) async {
              edits++;
              return ToolResult('Saved. ${'state ' * 1000}');
            },
          ),
        ],
      );
      final session = await manager.create();
      final result = await (await manager.prompt(
        session.id,
        'Edit twice; preserve audio.',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(edits, 2);
      expect(summaries, 2);
      expect(result.summaries, hasLength(2));
      expect(
        result.history.where((m) => m.role == MessageRole.tool),
        hasLength(2),
      );
      expect(result.history.last.text, 'verified');
      final loaded = SessionSnapshot.fromJson(
        (await store.read(session.id))!.toJson(),
      );
      expect(loaded.summaries.last.text, contains('2 edits'));
      expect(loaded.history.length, result.history.length);
    },
  );

  for (final mode in ['throw', 'empty', 'cancel', 'larger']) {
    test(
      '$mode summary keeps original history and does not repeat tools',
      () async {
        var edits = 0;
        final model = ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [ToolCall(id: 'once', name: 'edit')],
          );
        });
        final manager = SessionManager(
          model: model,
          store: InMemorySessionStore(),
          contextBuilder: ContextBuilder(
            maxInputTokens: 1200,
            summarizer: Summary((_, token) async {
              if (mode == 'throw') throw StateError('offline');
              if (mode == 'cancel') token.cancel();
              return mode == 'larger' ? 'summary ' * 5000 : '';
            }),
          ),
          tools: [
            tool(
              execute: (_, _) async {
                edits++;
                return ToolResult('saved ' * 1000);
              },
            ),
          ],
        );
        final session = await manager.create();
        final result = await (await manager.prompt(session.id, 'edit')).done;
        expect(edits, 1);
        expect(result.summaries, isEmpty);
        expect(result.history.last.role, MessageRole.tool);
        expect(
          result.status,
          mode == 'cancel' ? RunStatus.cancelled : RunStatus.failed,
        );
        expect(model.requests, hasLength(1));
      },
    );
  }

  test(
    'steering received during compaction is preserved before next request',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var edits = 0;
      final model = ScriptedModel((request, _) async* {
        if (edits == 0) {
          yield ModelResponse(
            calls: [ToolCall(id: 'once', name: 'edit')],
          );
        } else {
          expect(request.messages.last.text, 'Keep the mask unchanged.');
          yield ModelResponse(text: 'done');
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(
          maxInputTokens: 1400,
          summarizer: Summary((_, _) async {
            entered.complete();
            await release.future;
            return 'Completed: edit saved. Pending: report.';
          }),
        ),
        tools: [
          tool(
            execute: (_, _) async {
              edits++;
              return ToolResult('state ' * 1000);
            },
          ),
        ],
      );
      final session = await manager.create();
      final run = await manager.prompt(session.id, 'edit');
      await entered.future;
      await run.steer('Keep the mask unchanged.');
      release.complete();
      final result = await run.done;
      expect(result.status, RunStatus.completed);
      expect(edits, 1);
      expect(
        result.history.where((m) => m.text == 'Keep the mask unchanged.'),
        hasLength(1),
      );
    },
  );

  test(
    'new prompt compacts older history before it would be silently pruned',
    () async {
      var calls = 0;
      final model = ScriptedModel((request, _) async* {
        if (calls++ == 0) {
          yield ModelResponse(text: 'old response ' * 500);
        } else {
          expect(request.system, contains('preserve audio'));
          expect(request.messages.last.text, 'next task');
          yield ModelResponse(text: 'done');
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(
          maxInputTokens: 1400,
          summarizer: Summary(
            (_, _) async =>
                'Constraint: preserve audio. Completed: first task.',
          ),
        ),
      );
      final session = await manager.create();
      await (await manager.prompt(session.id, 'preserve audio')).done;
      final result = await (await manager.prompt(session.id, 'next task')).done;
      expect(result.status, RunStatus.completed);
      expect(result.summaries, hasLength(1));
      expect(result.history.first.text, 'preserve audio');
    },
  );

  test('only complete multi-call batches can be summarized', () {
    final history = [
      AgentMessage(role: MessageRole.user, text: 'edit'),
      AgentMessage(
        role: MessageRole.assistant,
        calls: [
          ToolCall(id: 'a', name: 'edit'),
          ToolCall(id: 'b', name: 'edit'),
        ],
      ),
      AgentMessage(role: MessageRole.tool, callId: 'a', text: 'saved'),
      AgentMessage(role: MessageRole.tool, callId: 'b', text: 'saved'),
      AgentMessage(role: MessageRole.assistant, text: 'verified'),
    ];
    expect(isSafeSummaryBoundary(history, 2), isFalse);
    expect(isSafeSummaryBoundary(history, 3), isFalse);
    expect(isSafeSummaryBoundary(history, 4), isTrue);
  });

  test(
    'model summarizer rejects incomplete and empty-section checkpoints',
    () async {
      for (final text in [
        'Done; keep editing.',
        '## Goal\nedit\n## Constraints\n## Completed\nsaved\n## Pending\nNone\n## References\nNone',
        '```\n## Goal\nedit\n## Constraints\nNone\n## Completed\nsaved\n## Pending\nNone\n## References\nNone\n```',
      ]) {
        final summarizer = ModelContextSummarizer(
          model: ScriptedModel((_, _) async* {
            yield ModelResponse(text: text);
          }),
          budget: ContextBuilder(),
        );
        await expectLater(
          summarizer.summarize([
            AgentMessage(role: MessageRole.user, text: 'edit'),
          ], CancellationToken()),
          throwsA(isA<ModelProtocolException>()),
        );
      }
    },
  );

  test(
    'model summarizer bounds chunks, carries prior summary and strips opaque state',
    () async {
      final budget = ContextBuilder(maxInputTokens: 1600, maxOutputTokens: 200);
      var calls = 0;
      final model = ScriptedModel((request, _) async* {
        expect(request.tools, isEmpty);
        expect(
          budget.measureInput(
            system: request.system,
            history: request.messages,
          ),
          lessThanOrEqualTo(1600),
        );
        expect(request.messages.single.text, isNot(contains('opaque-secret')));
        if (calls++ > 0) {
          expect(request.messages.single.text, contains('preserve audio'));
        }
        yield ModelResponse(
          text:
              '## Goal\npreserve audio\n## Constraints\nNone\n'
              '## Completed\nsaved edits\n## Pending\nNone\n## References\nNone',
        );
      });
      final summarizer = ModelContextSummarizer(model: model, budget: budget);
      final diagnostics = RunDiagnostics();
      final result = await diagnostics.scope(
        () => summarizer.summarize([
          AgentMessage(
            role: MessageRole.user,
            text: 'preserve audio ${'data ' * 2000}',
            providerData: {'blob': 'opaque-secret'},
          ),
        ], CancellationToken()),
      );
      expect(
        (diagnostics.toJson()['spans'] as List)
            .where((s) => s['stage'] == 'summaryModel')
            .length,
        calls,
      );
      expect(calls, greaterThan(1));
      expect(result, contains('preserve audio'));
    },
  );
}
