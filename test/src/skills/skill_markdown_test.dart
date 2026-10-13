import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

void main() {
  const parser = SkillMarkdownParser();

  test('catalog metadata can be parsed without a body or tool dependencies', () {
    const header =
        '---\nname: edit\ndescription: editing\nrequired-tools: invalid\n---\n';
    expect(parser.parseDescriptor(header).id, 'edit');
    expect(() => parser.parse(header), throwsFormatException);
  });

  test('parses standard front matter and preserves the Markdown body', () {
    const body = '\n# 剪辑\n\nRead [guide](references/guide.md).\n\n---\n';
    final skill = parser.parse(
      '---\nname: video-editing\ndescription: 帮助剪辑视频\n---\n$body',
    );
    expect(skill.descriptor.id, 'video-editing');
    expect(skill.descriptor.description, '帮助剪辑视频');
    expect(skill.descriptor.version, '1');
    expect(skill.requiredTools, isEmpty);
    expect(skill.instructions, body);
  });

  test('supports YAML blocks, metadata version and tool dependencies', () {
    final skill = parser.parse('''---
name: editing
description: >-
  Edit clips:
  preserve original audio.
metadata:
  version: "2.0"
  author: host
required-tools:
  - read_clip
  - edit_clip
  - read_clip
allowed-tools: shell
---
Keep cuts intentional.
''');
    expect(
      skill.descriptor.description,
      'Edit clips: preserve original audio.',
    );
    expect(skill.descriptor.version, '2.0');
    expect(skill.requiredTools, ['read_clip', 'edit_clip']);
  });

  test('top-level version overrides metadata version', () {
    final skill = parser.parse('''---
name: edit
description: editing
version: 3
metadata:
  version: "2"
---
Instructions.
''');
    expect(skill.descriptor.version, '3');
  });

  test('accepts a BOM and CRLF without changing body line endings', () {
    final skill = parser.parse(
      '\uFEFF---\r\nname: edit\r\ndescription: editing\r\n---\r\n'
      '\r\n# Edit\r\nInstructions.\r\n',
    );
    expect(skill.instructions, '\r\n# Edit\r\nInstructions.\r\n');
  });

  final invalidDocuments = <String, String>{
    'missing opening delimiter': '# Instructions',
    'missing closing delimiter': '---\nname: edit\nInstructions',
    'empty header': '---\n---\nInstructions',
    'non-map header': '---\n- edit\n---\nInstructions',
    'malformed YAML': '---\nname: [\n---\nInstructions',
    'duplicate keys': '---\nname: edit\nname: other\n---\nInstructions',
    'missing name': '---\ndescription: editing\n---\nInstructions',
    'numeric name': '---\nname: 42\ndescription: editing\n---\nInstructions',
    'empty description': '---\nname: edit\ndescription: " "\n---\nInstructions',
    'missing description': '---\nname: edit\n---\nInstructions',
    'empty instructions': '---\nname: edit\ndescription: editing\n---\n \n',
    'boolean version':
        '---\nname: edit\ndescription: editing\nversion: true\n---\nInstructions',
    'null version':
        '---\nname: edit\ndescription: editing\nversion: null\n---\nInstructions',
    'list version':
        '---\nname: edit\ndescription: editing\nversion: []\n---\nInstructions',
    'nonfinite version':
        '---\nname: edit\ndescription: editing\nversion: .inf\n---\nInstructions',
    'string tool list':
        '---\nname: edit\ndescription: editing\nrequired-tools: shell\n---\nInstructions',
    'empty tool name':
        '---\nname: edit\ndescription: editing\nrequired-tools: [" "]\n---\nInstructions',
    'numeric tool name':
        '---\nname: edit\ndescription: editing\nrequired-tools: [1]\n---\nInstructions',
  };
  for (final entry in invalidDocuments.entries) {
    test('rejects ${entry.key} with the source path', () {
      expect(
        () => parser.parse(entry.value, source: '/skills/edit/SKILL.md'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('/skills/edit/SKILL.md'),
          ),
        ),
      );
    });
  }
}
