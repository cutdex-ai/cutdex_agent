import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../agent_test.dart' show ScriptedModel;

void main() {
  late Directory root;
  late DirectorySkillProvider provider;
  late CancellationToken cancellation;

  Future<File> writeSkill(
    List<String> directories,
    String id, {
    String body = 'Keep cuts intentional.',
    String header = '',
  }) async {
    final file = File(p.joinAll([root.path, ...directories, 'SKILL.md']));
    await file.parent.create(recursive: true);
    return file.writeAsString(
      '---\nname: $id\ndescription: Editing $id\n$header---\n$body',
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cutdex-skills-');
    provider = DirectorySkillProvider(root.path);
    cancellation = CancellationToken();
  });
  tearDown(() => root.delete(recursive: true));

  test('discovers root and nested files sorted by metadata ID', () async {
    await writeSkill([], 'zebra');
    await writeSkill(['folder-with-other-name'], 'alpha');
    await writeSkill(['group', '.system', 'edit'], 'middle');
    await File(p.join(root.path, 'README.md')).writeAsString('ignored');
    await Directory(
      p.join(root.path, 'ignored', 'SKILL.md'),
    ).create(recursive: true);
    final descriptors = await provider.list(cancellation);
    expect(descriptors.map((skill) => skill.id), ['alpha', 'middle', 'zebra']);
    expect(descriptors.first.description, 'Editing alpha');
    final skill = await provider.load('middle', cancellation);
    expect(skill!.instructions, contains('Keep cuts intentional.'));
    expect(
      skill.instructions,
      contains(p.join(root.path, 'group', '.system', 'edit', 'SKILL.md')),
    );
    expect(
      skill.instructions,
      contains(
        'Resolve relative references from: ${p.join(root.path, 'group', '.system', 'edit')}',
      ),
    );
  });

  test('loads without an initial list and reflects file changes', () async {
    final file = await writeSkill(['edit'], 'edit');
    expect((await provider.load('edit', cancellation))!.descriptor.id, 'edit');
    await writeSkill(['edit'], 'edit', body: 'Updated instructions.');
    expect(
      (await provider.load('edit', cancellation))!.instructions,
      contains('Updated instructions.'),
    );
    await writeSkill(['new'], 'new');
    expect((await provider.list(cancellation)).map((skill) => skill.id), [
      'edit',
      'new',
    ]);
    await file.delete();
    expect(await provider.load('edit', cancellation), isNull);
    expect(await provider.load('../new', cancellation), isNull);
    expect(await provider.load('unknown', cancellation), isNull);
  });

  test('can disable recursive discovery', () async {
    await writeSkill([], 'root');
    await writeSkill(['child'], 'child');
    final shallow = DirectorySkillProvider(root.path, recursive: false);
    expect((await shallow.list(cancellation)).map((skill) => skill.id), [
      'root',
    ]);
  });

  test('empty directories produce an empty catalog', () async {
    expect(await provider.list(cancellation), isEmpty);
    expect(await provider.load('missing', cancellation), isNull);
  });

  test(
    'listing reads only front matter; loading validates only the selected body',
    () async {
      final file = await writeSkill(['bad-body'], 'bad-body');
      await file.writeAsBytes([
        ...'---\nname: bad-body\ndescription: listed without reading body\n---\n'
            .codeUnits,
        0xff,
      ]);
      await writeSkill(['good'], 'good');
      expect((await provider.list(cancellation)).map((skill) => skill.id), [
        'bad-body',
        'good',
      ]);
      expect(
        (await provider.load('good', cancellation))!.instructions,
        contains('Keep cuts intentional.'),
      );
      await expectLater(
        provider.load('bad-body', cancellation),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('missing roots propagate filesystem errors', () async {
    final missing = DirectorySkillProvider(p.join(root.path, 'missing'));
    await expectLater(
      missing.list(cancellation),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rejects empty paths and resolves relative paths', () {
    expect(() => DirectorySkillProvider(' '), throwsArgumentError);
    final relative = p.relative(root.path);
    expect(
      DirectorySkillProvider(relative).directoryPath,
      p.normalize(root.path),
    );
  });

  test('duplicate IDs report both conflicting files', () async {
    final first = await writeSkill(['a'], 'same');
    final second = await writeSkill(['b'], 'same');
    await expectLater(
      provider.list(cancellation),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains(first.path), contains(second.path)),
        ),
      ),
    );
  });

  test('invalid files fail discovery with their source path', () async {
    final file = File(p.join(root.path, 'SKILL.md'));
    await file.writeAsString('Not a skill');
    await expectLater(
      provider.list(cancellation),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains(file.path),
        ),
      ),
    );
    await file.writeAsBytes([0xff]);
    await expectLater(
      provider.load('edit', cancellation),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains(file.path),
        ),
      ),
    );
  });

  test(
    'cancelled discovery and loading stop before filesystem access',
    () async {
      final missing = DirectorySkillProvider(p.join(root.path, 'missing'));
      cancellation.cancel();
      await expectLater(
        missing.list(cancellation),
        throwsA(isA<AgentCancelled>()),
      );
      await expectLater(
        missing.load('edit', cancellation),
        throwsA(isA<AgentCancelled>()),
      );
    },
  );

  test(
    'skips file and directory symlinks including cycles',
    () async {
      final file = await writeSkill(['real'], 'edit');
      await Directory(p.join(root.path, 'alias-file')).create();
      await Link(p.join(root.path, 'alias-file', 'SKILL.md')).create(file.path);
      await Link(p.join(root.path, 'alias-directory')).create(file.parent.path);
      await Link(p.join(file.parent.path, 'cycle')).create(root.path);
      expect((await provider.list(cancellation)).map((skill) => skill.id), [
        'edit',
      ]);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows privileges'
        : false,
  );

  test(
    'host session loads selected skills and their required deferred tools',
    () async {
      await writeSkill(
        ['edit'],
        'edit',
        header: 'required-tools: [edit_clip]\n',
      );
      await writeSkill(
        ['other'],
        'other',
        body: 'Unselected skill instructions.',
      );
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      final edit = AgentTool(
        name: 'edit_clip',
        description: 'Edit a clip',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, _) async => ToolResult('edited'),
      );
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        tools: [edit],
        contextBuilder: HarnessContextBuilder(skills: provider),
      );
      final session = await manager.create(skillIds: ['edit']);
      final result = await (await manager.prompt(
        session.id,
        'Edit a clip',
      )).done;
      expect(result.status, RunStatus.completed);
      final request = model.requests.single;
      expect(request.system, contains('Skill edit@1'));
      expect(request.system, contains('Keep cuts intentional.'));
      expect(request.system, isNot(contains('Unselected skill instructions.')));
      expect(request.tools.map((tool) => tool.name), contains('edit_clip'));

      await expectLater(
        ContextBuilder(skills: provider).build(
          system: '',
          history: [],
          tools: [],
          skillIds: ['edit'],
          cancellation: cancellation,
        ),
        throwsStateError,
      );
    },
  );
}
