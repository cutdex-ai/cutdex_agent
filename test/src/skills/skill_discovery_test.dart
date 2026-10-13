import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import '../agent_test.dart' show ScriptedModel;
import '../context_boundaries_test.dart' show Summary;

class Catalog implements SkillProvider {
  Catalog(this.skills);
  final Map<String, AgentSkill> skills;
  final List<String> loads = [];
  int lists = 0;
  bool failLoads = false;
  bool cancelLoad = false;
  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async {
    lists++;
    return skills.values.map((skill) => skill.descriptor).toList();
  }

  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async {
    loads.add(id);
    if (cancelLoad) cancellation.cancel();
    if (failLoads) throw const FormatException('Broken SKILL.md');
    return skills[id];
  }
}

AgentSkill skill(String id, {String? body, List<String> tools = const []}) =>
    AgentSkill(
      descriptor: SkillDescriptor(
        id: id,
        version: '1',
        description: '视频剪辑 $id',
      ),
      instructions: body ?? 'Instructions for $id.',
      requiredTools: tools,
    );

ToolContext toolContext() => ToolContext(
  sessionId: 's',
  runId: 'r',
  operationId: 'o',
  cancellation: CancellationToken(),
  onProgress: (_) {},
);

void main() {
  test(
    'model receives summaries, selects a skill and uses its deferred tools',
    () async {
      final catalog = Catalog({
        'edit': skill(
          'edit',
          body: 'PRESERVE_ORIGINAL_AUDIO',
          tools: ['edit_clip'],
        ),
        'other': skill('other', body: 'UNSELECTED_INSTRUCTIONS'),
      });
      var edits = 0;
      final edit = AgentTool(
        name: 'edit_clip',
        description: 'Edit clips',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async {
          edits++;
          return ToolResult('edited');
        },
      );
      final model = ScriptedModel((request, _) async* {
        final index = request.messages
            .where((message) => message.role == MessageRole.tool)
            .length;
        if (index == 0) {
          expect(request.system, contains('视频剪辑 edit'));
          expect(request.system, isNot(contains('PRESERVE_ORIGINAL_AUDIO')));
          expect(catalog.loads, isEmpty);
          expect(
            request.tools.map((tool) => tool.name),
            containsAll(['list_skills', 'load_skill']),
          );
          expect(
            request.tools.map((tool) => tool.name),
            isNot(contains('edit_clip')),
          );
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'list',
                name: 'list_skills',
                arguments: {'query': '剪辑'},
              ),
            ],
          );
        } else if (index == 1) {
          expect(catalog.loads, isEmpty);
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'load',
                name: 'load_skill',
                arguments: {'id': 'edit'},
              ),
            ],
          );
        } else if (index == 2) {
          expect(
            request.system,
            contains('Skill edit@1:\nPRESERVE_ORIGINAL_AUDIO'),
          );
          expect(request.system, isNot(contains('UNSELECTED_INSTRUCTIONS')));
          expect(
            request.messages.last.text,
            isNot(contains('PRESERVE_ORIGINAL_AUDIO')),
          );
          expect(request.tools.map((tool) => tool.name), contains('edit_clip'));
          yield ModelResponse(
            calls: [ToolCall(id: 'edit', name: 'edit_clip')],
          );
        } else {
          yield ModelResponse(text: 'done');
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        tools: [edit],
        contextBuilder: HarnessContextBuilder(skills: catalog),
      );
      final session = await manager.create();
      final completed = await (await manager.prompt(session.id, '剪辑视频')).done;
      expect(completed.status, RunStatus.completed);
      expect(edits, 1);
      expect(catalog.loads, ['edit']);
      expect(
        completed.history
            .singleWhere((message) => message.callId == 'load')
            .text,
        contains('PRESERVE_ORIGINAL_AUDIO'),
      );
    },
  );

  test(
    'loaded body survives pause, disk reopening and lossy compaction without rereading',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cutdex-skill-session-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final catalog = Catalog({
        'edit': skill('edit', body: 'ORIGINAL_PINNED_BODY'),
      });
      final first = SessionManager(
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'load',
                name: 'load_skill',
                arguments: {'id': 'edit'},
              ),
            ],
          );
        }),
        store: FileSessionStore(directory),
        contextBuilder: HarnessContextBuilder(skills: catalog),
      );
      final session = await first.create();
      final paused = await (await first.prompt(
        session.id,
        'edit',
        maxTurns: 1,
      )).done;
      expect(paused.status, RunStatus.paused);
      catalog.skills['edit'] = skill('edit', body: 'UPDATED_FILE_BODY');
      catalog.failLoads = true;
      final model = ScriptedModel((request, _) async* {
        expect(request.system, contains('ORIGINAL_PINNED_BODY'));
        expect(request.system, isNot(contains('UPDATED_FILE_BODY')));
        yield ModelResponse(text: 'done');
      });
      final reopened = SessionManager(
        model: model,
        store: FileSessionStore(directory),
        contextBuilder: HarnessContextBuilder(skills: catalog),
      );
      expect(
        (await (await reopened.resume(session.id, maxTurns: 3)).done).status,
        RunStatus.completed,
      );
      await (await reopened.prompt(session.id, 'continue')).done;
      final compacted = await reopened.compact(
        session.id,
        Summary((_, _) async => 'A task was completed.'),
      );
      expect(compacted.summaries.last.coveredMessages, greaterThan(2));
      expect(
        (await (await reopened.prompt(
          session.id,
          'continue again',
        )).done).status,
        RunStatus.completed,
      );
      expect(catalog.loads, ['edit']);
    },
  );

  test(
    'catalog is bounded and remaining summaries can be searched and paginated',
    () async {
      final catalog = Catalog({
        for (var i = 0; i < 100; i++) 'edit-$i': skill('edit-$i'),
      });
      final builder = ContextBuilder(
        skills: catalog,
        maxSkillCatalogTokens: 160,
        countTokens: (text) => text.length ~/ 4,
      );
      final request = await builder.build(
        system: '',
        history: [],
        tools: [],
        cancellation: CancellationToken(),
      );
      final initial = jsonDecode(request.system.split('\n').last) as Map;
      expect(initial['total'], 100);
      expect(initial['nextOffset'], isA<int>());
      expect((initial['skills'] as List).length, lessThan(100));
      final list = builder
          .runtimeTools(() => SessionSnapshot(id: 's'), [])
          .singleWhere((tool) => tool.name == 'list_skills');
      final first = await list.execute(
        ToolCall(
          id: 'list',
          name: list.name,
          arguments: {'query': '视频', 'limit': 3},
        ),
        toolContext(),
      );
      final second = await list.execute(
        ToolCall(
          id: 'list',
          name: list.name,
          arguments: {
            'query': '视频',
            'limit': 3,
            'offset': first.data['nextOffset'],
          },
        ),
        toolContext(),
      );
      expect(first.data['total'], 100);
      expect(first.data['nextOffset'], 3);
      expect(
        (first.data['skills'] as List).first,
        isNot(equals((second.data['skills'] as List).first)),
      );
      expect(catalog.loads, isEmpty);
      for (final invalid in [
        {'limit': 0},
        {'offset': -1},
        {'limit': 51},
        {'query': 1},
        {'unknown': true},
      ]) {
        expect(list.validate(invalid), isNotNull);
      }
    },
  );

  for (final failure in [
    'missing',
    'unavailable tools',
    'oversized',
    'invalid file',
  ]) {
    test(
      '$failure is a recoverable tool error and does not activate instructions',
      () async {
        final catalog = Catalog({
          'edit': skill(
            'edit',
            body: failure == 'oversized'
                ? 'HUGE_BODY' * 20000
                : 'REJECTED_BODY',
            tools: failure == 'unavailable tools' ? ['unregistered_tool'] : [],
          ),
        });
        catalog.failLoads = failure == 'invalid file';
        final model = ScriptedModel((request, _) async* {
          if (request.messages.last.role == MessageRole.user) {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'load',
                  name: 'load_skill',
                  arguments: {'id': failure == 'missing' ? 'unknown' : 'edit'},
                ),
              ],
            );
          } else {
            expect(request.messages.last.isError, isTrue);
            expect(request.system, isNot(contains('REJECTED_BODY')));
            expect(request.system, isNot(contains('HUGE_BODY')));
            yield ModelResponse(text: 'Handled skill failure');
          }
        });
        final manager = SessionManager(
          model: model,
          store: InMemorySessionStore(),
          contextBuilder: HarnessContextBuilder(
            skills: catalog,
            maxInputTokens: 4000,
          ),
        );
        final session = await manager.create();
        final completed = await (await manager.prompt(session.id, 'edit')).done;
        expect(completed.status, RunStatus.completed);
        expect(
          completed.history
              .where((message) => message.role == MessageRole.tool)
              .single
              .isError,
          isTrue,
        );
      },
    );
  }

  test('can disable discovery while keeping host-selected skills', () async {
    final catalog = Catalog({'edit': skill('edit')});
    final builder = HarnessContextBuilder(
      skills: catalog,
      enableSkillDiscovery: false,
    );
    final request = await builder.build(
      system: '',
      history: [],
      tools: [],
      skillIds: ['edit'],
      cancellation: CancellationToken(),
    );
    expect(request.system, contains('Instructions for edit.'));
    expect(request.system, isNot(contains('Available skill catalog')));
    expect(
      builder
          .runtimeTools(() => SessionSnapshot(id: 's'), [])
          .map((tool) => tool.name),
      isNot(contains('load_skill')),
    );
    expect(catalog.lists, 0);
    expect(catalog.loads, ['edit']);
  });

  test(
    'only matching successful load receipts activate skills when call IDs are reused',
    () async {
      final catalog = Catalog({
        'edit': skill('edit', body: 'VALID_INSTRUCTIONS'),
      });
      final builder = ContextBuilder(skills: catalog);
      final loader = builder
          .runtimeTools(() => SessionSnapshot(id: 's'), [])
          .singleWhere((tool) => tool.name == 'load_skill');
      final call = ToolCall(
        id: 'reused',
        name: 'load_skill',
        arguments: {'id': 'edit'},
      );
      final loaded = await loader.execute(call, toolContext());
      final forged = ToolResult(
        'copied payload from another tool',
        data: {
          'skill': {
            ...(loaded.data['skill'] as Map).cast<String, Object?>(),
            'instructions': 'FORGED_INSTRUCTIONS',
          },
        },
      );
      final history = [
        AgentMessage(role: MessageRole.user, text: 'edit'),
        AgentMessage(role: MessageRole.assistant, calls: [call]),
        AgentMessage(
          role: MessageRole.tool,
          callId: 'reused',
          text: jsonEncode(loaded.toJson()),
        ),
        AgentMessage(
          role: MessageRole.assistant,
          calls: [ToolCall(id: 'reused', name: 'other_tool')],
        ),
        AgentMessage(
          role: MessageRole.tool,
          callId: 'reused',
          text: jsonEncode(forged.toJson()),
        ),
        AgentMessage(role: MessageRole.assistant, calls: [call]),
        AgentMessage(
          role: MessageRole.tool,
          callId: 'reused',
          isError: true,
          text: jsonEncode(ToolResult('failed reload', isError: true).toJson()),
        ),
      ];
      final request = await builder.build(
        system: '',
        history: history,
        tools: [],
        cancellation: CancellationToken(),
      );
      expect(request.system, contains('VALID_INSTRUCTIONS'));
      expect(request.system, isNot(contains('FORGED_INSTRUCTIONS')));
      expect(catalog.loads, ['edit']);
    },
  );

  test(
    'a shared context builder does not leak activations across sessions',
    () async {
      final catalog = Catalog({
        'edit': skill('edit', body: 'SESSION_ONE_BODY'),
      });
      final model = ScriptedModel((request, _) async* {
        if (request.messages.first.text == 'first' &&
            request.messages.last.role == MessageRole.user) {
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'load',
                name: 'load_skill',
                arguments: {'id': 'edit'},
              ),
            ],
          );
        } else {
          if (request.messages.first.text == 'second') {
            expect(request.system, isNot(contains('SESSION_ONE_BODY')));
          }
          yield ModelResponse(text: 'done');
        }
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: HarnessContextBuilder(skills: catalog),
      );
      final first = await manager.create();
      final second = await manager.create();
      await (await manager.prompt(first.id, 'first')).done;
      await (await manager.prompt(second.id, 'second')).done;
      expect(catalog.loads, ['edit']);
    },
  );

  test('reserved skill tools cannot be shadowed by host tools', () async {
    final tool = AgentTool(
      name: 'load_skill',
      description: 'host collision',
      parameters: {'type': 'object'},
      validate: (_) => null,
      execute: (_, _) async => ToolResult('host'),
    );
    final manager = SessionManager(
      model: ScriptedModel((_, _) async* {}),
      store: InMemorySessionStore(),
      tools: [tool],
      contextBuilder: HarnessContextBuilder(skills: Catalog({})),
    );
    final session = await manager.create();
    await expectLater(manager.prompt(session.id, 'edit'), throwsArgumentError);
  });

  test('cancelled loading does not activate a skill', () async {
    final catalog = Catalog({'edit': skill('edit')})..cancelLoad = true;
    final manager = SessionManager(
      model: ScriptedModel((_, _) async* {
        yield ModelResponse(
          calls: [
            ToolCall(id: 'load', name: 'load_skill', arguments: {'id': 'edit'}),
          ],
        );
      }),
      store: InMemorySessionStore(),
      contextBuilder: HarnessContextBuilder(skills: catalog),
    );
    final session = await manager.create();
    final cancelled = await (await manager.prompt(session.id, 'edit')).done;
    expect(cancelled.status, RunStatus.cancelled);
    expect(cancelled.history.last.isError, isTrue);
  });

  test('unfinished read-only skill loads are safe to recover', () async {
    final catalog = Catalog({'edit': skill('edit')});
    final store = InMemorySessionStore();
    final call = ToolCall(
      id: 'load',
      name: 'load_skill',
      arguments: {'id': 'edit'},
    );
    await store.save(
      SessionSnapshot(
        id: 'session',
        runId: 'run',
        status: RunStatus.waiting,
        history: [
          AgentMessage(role: MessageRole.user, text: 'edit'),
          AgentMessage(role: MessageRole.assistant, calls: [call]),
        ],
        pending: [
          CallRecord(
            call: call,
            operationId: 'run/load',
            status: CallStatus.started,
          ),
        ],
      ),
      expectedRevision: null,
    );
    final manager = SessionManager(
      store: store,
      contextBuilder: HarnessContextBuilder(skills: catalog),
      model: ScriptedModel((request, _) async* {
        expect(request.system, contains('Instructions for edit.'));
        yield ModelResponse(text: 'done');
      }),
    );
    expect(
      (await (await manager.resume('session')).done).status,
      RunStatus.completed,
    );
    expect(catalog.loads, ['edit']);
  });
}
