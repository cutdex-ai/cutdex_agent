import 'package:yaml/yaml.dart';

import 'skills.dart';

/// Parses YAML front matter and Markdown instructions from a `SKILL.md` file.
///
/// Requires non-empty `name` and `description` strings. The name becomes the
/// skill ID. An optional `version` string or number defaults to `1`; it may also
/// be supplied in `metadata.version`. Optional `required-tools` is a list of
/// non-empty tool names. Other metadata is ignored.
class SkillMarkdownParser {
  const SkillMarkdownParser();

  /// Parses [markdown], using [source] to identify errors.
  ///
  /// Preserves the Markdown body, including whitespace and line endings.
  /// Throws [FormatException] for invalid front matter or an empty body.
  AgentSkill parse(String markdown, {String? source}) {
    final parsed = _frontMatter(markdown, source);
    if (parsed.body.trim().isEmpty) {
      throw FormatException(
        '${source ?? 'SKILL.md'}: Markdown instructions are empty',
      );
    }
    return AgentSkill(
      descriptor: _descriptor(parsed.header, source),
      instructions: parsed.body,
      requiredTools: _requiredTools(parsed.header, source),
    );
  }

  /// Parses only the catalog metadata, without requiring a Markdown body.
  ///
  /// Accepts a complete file or just its delimited YAML front matter.
  SkillDescriptor parseDescriptor(String markdown, {String? source}) {
    return _descriptor(_frontMatter(markdown, source).header, source);
  }

  ({YamlMap header, String body}) _frontMatter(
    String markdown,
    String? source,
  ) {
    Never invalid(String message) =>
        throw FormatException('${source ?? 'SKILL.md'}: $message');

    final text = markdown.startsWith('\uFEFF')
        ? markdown.substring(1)
        : markdown;
    final opening = RegExp(r'^---[ \t]*\r?\n').firstMatch(text);
    if (opening == null) {
      invalid('Expected YAML front matter starting with ---');
    }
    final closing = RegExp(
      r'^---[ \t]*\r?$',
      multiLine: true,
    ).firstMatch(text.substring(opening.end));
    if (closing == null) invalid('Missing closing --- for YAML front matter');
    final headerEnd = opening.end + closing.start;
    var bodyStart = opening.end + closing.end;
    if (bodyStart < text.length && text[bodyStart] == '\n') bodyStart++;

    Object? header;
    try {
      header = loadYaml(text.substring(opening.end, headerEnd));
    } on YamlException catch (error) {
      invalid('Invalid YAML: $error');
    }
    if (header is! YamlMap) invalid('Front matter must be a YAML mapping');
    return (header: header, body: text.substring(bodyStart));
  }

  SkillDescriptor _descriptor(YamlMap header, String? source) {
    Never invalid(String message) =>
        throw FormatException('${source ?? 'SKILL.md'}: $message');

    String requiredString(String key) {
      final value = header[key];
      if (value is! String || value.trim().isEmpty) {
        invalid('$key must be a non-empty string');
      }
      return value.trim();
    }

    final id = requiredString('name');
    final description = requiredString('description');
    final metadata = header['metadata'];
    final Object? version = header.containsKey('version')
        ? header['version']
        : (metadata is Map && metadata.containsKey('version')
              ? metadata['version']
              : '1');
    if ((version is! String && version is! num) ||
        version.toString().trim().isEmpty ||
        (version is num && !version.isFinite)) {
      invalid('version must be a non-empty string or finite number');
    }

    return SkillDescriptor(
      id: id,
      version: version.toString().trim(),
      description: description,
    );
  }

  List<String> _requiredTools(YamlMap header, String? source) {
    Never invalid(String message) =>
        throw FormatException('${source ?? 'SKILL.md'}: $message');
    final tools = <String>[];
    if (header.containsKey('required-tools')) {
      final requiredTools = header['required-tools'];
      if (requiredTools is! List) invalid('required-tools must be a list');
      for (final name in requiredTools) {
        if (name is! String || name.trim().isEmpty) {
          invalid('required-tools entries must be non-empty strings');
        }
        if (!tools.contains(name.trim())) tools.add(name.trim());
      }
    }
    return tools;
  }
}
