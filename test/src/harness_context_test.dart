import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel;
import 'context_boundaries_test.dart' show Summary;

AgentTool fixture(String name) => AgentTool(
  name: name,
  description: '$name batch resources',
  parameters: {
    'type': 'object',
    'properties': {
      for (var i = 0; i < 40; i++) 'field$i': {'type': 'string'},
    },
  },
  validate: (_) => null,
  execute: (_, _) async => ToolResult('ok'),
);
ToolContext context() => ToolContext(
  sessionId: 's',
  runId: 'r',
  operationId: 'o',
  cancellation: CancellationToken(),
  onProgress: (_) {},
);
List<AgentMessage> pair(
  String id,
  String name,
  Map<String, Object?> args,
  ToolResult result,
) => [
  AgentMessage(
    role: MessageRole.assistant,
    calls: [ToolCall(id: id, name: name, arguments: args)],
  ),
  AgentMessage(
    role: MessageRole.tool,
    callId: id,
    text: jsonEncode(result.toJson()),
    isError: result.isError,
  ),
];
Map<String, Object?> plan(String status) => {
  'steps': [
    {'step': 'process and verify all resources', 'status': status},
  ],
  'checkpoint': 'source=A target=B nextOffset=80 version=v4',
};

void main() {
  test(
    'compaction keeps original instructions as user messages, not system policy',
    () async {
      final history = [
        AgentMessage(role: MessageRole.user, text: 'unrelated previous task'),
        AgentMessage(
          role: MessageRole.assistant,
          text: 'finished previous task',
        ),
        AgentMessage(
          role: MessageRole.user,
          text: 'Keep all source media and original audio.',
        ),
        AgentMessage(role: MessageRole.assistant, text: 'working'),
        AgentMessage(role: MessageRole.user, text: 'Also preserve timing.'),
        AgentMessage(role: MessageRole.assistant, text: 'continuing'),
      ];
      final request = await HarnessContextBuilder().build(
        system: 'host policy',
        history: history,
        tools: [],
        taskStart: 2,
        requiredHistoryStart: 2,
        summary: ContextSummary(
          text: 'Lossy summary without the constraints.',
          coveredMessages: 6,
          source: 'test',
        ),
        cancellation: CancellationToken(),
      );
      expect(request.system, isNot(contains('Keep all source media')));
      expect(
        request.messages
            .where((m) => m.role == MessageRole.user)
            .map((m) => m.text),
        containsAll([
          'Keep all source media and original audio.',
          'Also preserve timing.',
        ]),
      );
      expect(
        request.messages.map((m) => m.text),
        isNot(contains('unrelated previous task')),
      );
    },
  );

  test('active skills load their required deferred tools', () async {
    final host = [fixture('required_tool'), fixture('irrelevant_tool')];
    final builder = HarnessContextBuilder(skills: _RequiredSkill());
    final request = await builder.build(
      system: '',
      history: [AgentMessage(role: MessageRole.user, text: 'use skill')],
      tools: host,
      skillIds: ['edit'],
      cancellation: CancellationToken(),
    );
    expect(request.tools.map((t) => t.name), ['required_tool']);
    expect(request.system, contains('Skill edit@1'));
  });

  test('durable result identity separates reused provider call IDs', () async {
    final history = <AgentMessage>[];
    for (var i = 0; i < 2; i++) {
      history.add(
        AgentMessage(
          role: MessageRole.assistant,
          calls: [ToolCall(id: 'same', name: 'tool$i')],
        ),
      );
      history.add(
        AgentMessage(
          role: MessageRole.tool,
          callId: 'same',
          resultId: 'run$i/same',
          text: jsonEncode(ToolResult('result', data: {'value': i}).toJson()),
        ),
      );
    }
    final reader = HarnessContextBuilder()
        .runtimeTools(() => SessionSnapshot(id: 's', history: history), [])
        .singleWhere((t) => t.name == 'read_tool_result');
    final first = await reader.execute(
      ToolCall(
        id: 'read',
        name: reader.name,
        arguments: {'resultId': 'run0/same', 'path': '/data/value'},
      ),
      context(),
    );
    expect(first.data['value'], 0);
    final index = await reader.execute(
      ToolCall(id: 'index', name: reader.name),
      context(),
    );
    expect((index.data['results'] as List).map((r) => (r as Map)['tool']), [
      'tool0',
      'tool1',
    ]);
  });

  test(
    'large catalog is deferred; search activates only requested schemas',
    () async {
      final builder = HarnessContextBuilder(maxActiveTools: 3);
      final host = [for (var i = 0; i < 200; i++) fixture('resource_$i')];
      final history = [
        AgentMessage(role: MessageRole.user, text: 'edit resources'),
      ];
      final all = [
        ...host,
        ...builder.runtimeTools(
          () => SessionSnapshot(id: 's', history: history),
          host,
        ),
      ];
      final first = await builder.build(
        system: '',
        history: history,
        tools: all,
        cancellation: CancellationToken(),
      );
      expect(
        first.tools.map((t) => t.name),
        unorderedEquals(['tool_search', 'read_tool_result', 'update_plan']),
      );
      final search = all.singleWhere((t) => t.name == 'tool_search');
      final args = <String, Object?>{'query': 'resource_137', 'limit': 1};
      final result = await search.execute(
        ToolCall(id: 'search', name: search.name, arguments: args),
        context(),
      );
      history.addAll(pair('search', search.name, args, result));
      final loaded = builder.selectTools(history, all);
      expect(loaded.map((t) => t.name), contains('resource_137'));
      expect(loaded, hasLength(4));
      expect(search.validate({'query': '', 'limit': 1}), isNotNull);
      expect(search.validate({'query': 'resource', 'offset': -1}), isNotNull);
      expect(search.validate({'query': 'resource', 'limit': 100}), isNotNull);
    },
  );

  test(
    'bounded results remain recoverable by JSON pointer, Unicode and pages',
    () async {
      final builder = HarnessContextBuilder(maxResultBytes: 1024);
      final entries = [
        for (var i = 0; i < 138; i++) {'id': '$i', 'text': '字幕🎬$i'},
      ];
      final history = pair(
        'large',
        'resources',
        {},
        ToolResult(
          'complete',
          data: {'items': entries, 'a/b~c': '中🎬文', 'huge': 'x' * 2000},
        ),
      );
      final snapshot = SessionSnapshot(id: 's', history: history);
      final projected = builder.projectHistory(history);
      expect(utf8.encode(projected.last.text).length, lessThan(1024));
      expect(jsonDecode(projected.last.text)['resultId'], 'large');
      expect(history.last.text, contains('字幕🎬137'));
      final reader = builder
          .runtimeTools(() => snapshot, [])
          .singleWhere((t) => t.name == 'read_tool_result');
      Future<ToolResult> read(String path, [int offset = 0]) => reader.execute(
        ToolCall(
          id: 'r',
          name: reader.name,
          arguments: {
            'resultId': 'large',
            'path': path,
            'offset': offset,
            'limit': 100,
          },
        ),
        context(),
      );
      final collected = <Object?>[];
      var offset = 0;
      while (true) {
        final result = await read('/data/items', offset);
        expect(result.isError, isFalse);
        expect(utf8.encode(jsonEncode(result.toJson())).length, lessThan(1024));
        collected.addAll(result.data['items'] as List);
        final next = result.data['nextOffset'] as int?;
        if (next == null) break;
        expect(next, greaterThan(offset));
        offset = next;
      }
      expect(collected, entries);
      expect((await read('/data/a~1b~0c', 1)).data['text'], '🎬文');
      expect((await read('/data/items/0/id')).data['text'], '0');
      expect((await read('/data/missing')).isError, isTrue);
      expect((await read('/data/items/-1')).isError, isTrue);
      expect(
        (await reader.execute(
          ToolCall(
            id: 'bad',
            name: reader.name,
            arguments: {'resultId': 'other-session'},
          ),
          context(),
        )).isError,
        isTrue,
      );
    },
  );

  test(
    'plan survives compaction projection and prevents premature completion',
    () async {
      var request = 0;
      final model = ScriptedModel((input, _) async* {
        request++;
        if (request == 1) {
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'plan',
                name: 'update_plan',
                arguments: plan('in_progress'),
              ),
            ],
          );
        } else if (request == 2) {
          yield ModelResponse(text: 'done too early');
        } else if (request == 3) {
          expect(
            input.messages.last.text,
            contains('Runtime continuation notice'),
          );
          expect(input.system, contains('nextOffset=80'));
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'finished',
                name: 'update_plan',
                arguments: plan('completed'),
              ),
            ],
          );
        } else {
          yield ModelResponse(text: 'verified');
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: HarnessContextBuilder(),
      );
      final session = await manager.create();
      final result = await (await manager.prompt(
        session.id,
        'do the entire task',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(result.history.last.text, 'verified');
      expect(request, 4);
    },
  );

  test(
    'unfinished plan exhausts budget as paused, blocked plan may report blocker',
    () async {
      for (final status in ['in_progress', 'blocked']) {
        var request = 0;
        final manager = SessionManager(
          model: ScriptedModel((_, _) async* {
            if (++request == 1) {
              yield ModelResponse(
                calls: [
                  ToolCall(
                    id: 'p',
                    name: 'update_plan',
                    arguments: plan(status),
                  ),
                ],
              );
            } else {
              yield ModelResponse(text: 'stop');
            }
          }),
          store: InMemorySessionStore(),
          contextBuilder: HarnessContextBuilder(),
        );
        final session = await manager.create();
        final result = await (await manager.prompt(
          session.id,
          'task',
          maxTurns: 2,
        )).done;
        expect(
          result.status,
          status == 'blocked' ? RunStatus.completed : RunStatus.paused,
        );
      }
    },
  );

  test(
    'reopened file store retrieves results and resumes durable plan without replay',
    () async {
      final dir = await Directory.systemTemp.createTemp('agent-harness-');
      addTearDown(() => dir.delete(recursive: true));
      var executions = 0;
      final host = AgentTool(
        name: 'resources',
        description: 'resources',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async {
          executions++;
          return ToolResult(
            'saved',
            data: {
              'items': List.generate(200, (i) => {'id': i, 'text': 'value$i'}),
            },
          );
        },
      );
      final first = SessionManager(
        store: FileSessionStore(dir),
        contextBuilder: HarnessContextBuilder(maxResultBytes: 1024),
        tools: [host],
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'p',
                name: 'update_plan',
                arguments: plan('in_progress'),
              ),
              ToolCall(id: 'large', name: 'resources'),
            ],
          );
        }),
      );
      final session = await first.create();
      final stopped = await (await first.prompt(
        session.id,
        'process',
        maxTurns: 1,
      )).done;
      expect(stopped.status, RunStatus.paused);
      var turn = 0;
      final second = SessionManager(
        store: FileSessionStore(dir),
        contextBuilder: HarnessContextBuilder(maxResultBytes: 1024),
        tools: [host],
        model: ScriptedModel((input, _) async* {
          expect(input.system, contains('nextOffset=80'));
          if (++turn == 1) {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'read',
                  name: 'read_tool_result',
                  arguments: {
                    'resultId': stopped.history.last.resultId,
                    'path': '/data/items/199/id',
                  },
                ),
              ],
            );
          } else if (turn == 2) {
            expect(jsonDecode(input.messages.last.text)['data']['value'], 199);
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'done',
                  name: 'update_plan',
                  arguments: plan('completed'),
                ),
              ],
            );
          } else {
            yield ModelResponse(text: 'verified');
          }
        }),
      );
      final done = await (await second.resume(session.id, maxTurns: 5)).done;
      expect(done.status, RunStatus.completed);
      expect(executions, 1);
    },
  );

  test(
    'compaction with a large deferred catalog preserves plan and tool access',
    () async {
      var summaries = 0;
      var turns = 0;
      final builder = HarnessContextBuilder(
        maxInputTokens: 6500,
        maxResultBytes: 1024,
        summarizer: Summary((_, _) async {
          summaries++;
          return 'Continue resource processing; original result large is readable with read_tool_result.';
        }),
      );
      final manager = SessionManager(
        store: InMemorySessionStore(),
        contextBuilder: builder,
        tools: [for (var i = 0; i < 100; i++) fixture('resource_$i')],
        model: ScriptedModel((input, _) async* {
          expect(input.tools.length, lessThan(10));
          if (++turns == 1) {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'p',
                  name: 'update_plan',
                  arguments: plan('in_progress'),
                ),
              ],
            );
          } else if (turns < 9) {
            yield ModelResponse(
              text: 'Analysis of resources. ' * 200,
              calls: [
                ToolCall(
                  id: 's$turns',
                  name: 'tool_search',
                  arguments: {'query': 'resource_99', 'limit': 1},
                ),
              ],
            );
          } else if (turns == 9) {
            expect(input.system, contains('nextOffset=80'));
            expect(input.tools.map((t) => t.name), contains('resource_99'));
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'done',
                  name: 'update_plan',
                  arguments: plan('completed'),
                ),
              ],
            );
          } else {
            yield ModelResponse(text: 'verified');
          }
        }),
      );
      final session = await manager.create();
      final result = await (await manager.prompt(
        session.id,
        'process all resources',
      )).done;
      expect(result.status, RunStatus.completed, reason: result.error);
      expect(summaries, greaterThan(0));
      expect(result.summaries, isNotEmpty);
    },
  );
}

class _RequiredSkill implements SkillProvider {
  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async =>
      [];
  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async =>
      AgentSkill(
        descriptor: SkillDescriptor(id: id, version: '1', description: 'edit'),
        instructions: 'Use required_tool.',
        requiredTools: ['required_tool'],
      );
}
