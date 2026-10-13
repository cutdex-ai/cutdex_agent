import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../run/cancellation.dart';
import 'skill_markdown.dart';
import 'skills.dart';

/// Discovers skills in a directory containing `SKILL.md` files.
///
/// Each [list] or [load] rescans the front matter, so file changes are visible on
/// the next call. Scans include the root and, by default, all subdirectories;
/// symbolic links are skipped. Results are sorted by skill ID. Invalid headers
/// throw [FormatException], duplicate IDs throw [StateError], and filesystem
/// errors propagate. This provider never executes scripts or registers tools.
class DirectorySkillProvider implements SkillProvider {
  /// Creates a provider rooted at [directoryPath].
  ///
  /// Resolves relative paths at construction time. Set [recursive] to `false`
  /// to inspect only files immediately inside the directory.
  DirectorySkillProvider(String directoryPath, {this.recursive = true})
    : directoryPath = p.normalize(p.absolute(directoryPath)) {
    if (directoryPath.trim().isEmpty) {
      throw ArgumentError.value(
        directoryPath,
        'directoryPath',
        'Must not be empty',
      );
    }
  }

  /// The absolute directory path used for discovery.
  final String directoryPath;

  /// Whether scans include subdirectories.
  final bool recursive;

  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async {
    final skills = await _scan(cancellation);
    return List.unmodifiable(skills.values.map((entry) => entry.descriptor));
  }

  /// Loads a discovered skill with its absolute source and directory paths.
  ///
  /// Reads and validates only the selected body, throwing [FormatException]
  /// for invalid UTF-8, empty instructions or invalid tool dependencies.
  /// Returns `null` if [id] is absent. Relative references in the instructions
  /// resolve from the skill directory; reading them still requires host tools.
  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async {
    final skills = await _scan(cancellation);
    final entry = skills[id];
    if (entry == null) return null;
    final bytes = await File(entry.path).readAsBytes();
    cancellation.throwIfCancelled();
    final skill = const SkillMarkdownParser().parse(
      _decode(bytes, entry.path),
      source: entry.path,
    );
    if (skill.descriptor.id != id) {
      throw FormatException(
        '${entry.path}: Skill identity changed during loading',
      );
    }
    return AgentSkill(
      descriptor: skill.descriptor,
      instructions:
          'Skill source: ${entry.path}\n'
          'Resolve relative references from: ${p.dirname(entry.path)}\n\n'
          '${skill.instructions}',
      requiredTools: skill.requiredTools,
    );
  }

  Future<Map<String, ({SkillDescriptor descriptor, String path})>> _scan(
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final files = <File>[];
    await for (final entity in Directory(
      directoryPath,
    ).list(recursive: recursive, followLinks: false)) {
      cancellation.throwIfCancelled();
      if (entity is File && p.basename(entity.path) == 'SKILL.md') {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final skills = <String, ({SkillDescriptor descriptor, String path})>{};
    for (final file in files) {
      cancellation.throwIfCancelled();
      final descriptor = const SkillMarkdownParser().parseDescriptor(
        await _readHeader(file, cancellation),
        source: file.path,
      );
      final id = descriptor.id;
      if (skills.containsKey(id)) {
        throw StateError(
          'Duplicate skill ID "$id": ${skills[id]!.path} and ${file.path}',
        );
      }
      skills[id] = (descriptor: descriptor, path: file.path);
    }
    cancellation.throwIfCancelled();
    final ids = skills.keys.toList()..sort();
    return {for (final id in ids) id: skills[id]!};
  }

  String _decode(List<int> bytes, String path) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FormatException('$path: SKILL.md must contain valid UTF-8');
    }
  }

  Future<String> _readHeader(File file, CancellationToken cancellation) async {
    final header = BytesBuilder();
    var line = <int>[];
    var first = true;
    await for (final chunk in file.openRead()) {
      cancellation.throwIfCancelled();
      for (final byte in chunk) {
        line.add(byte);
        if (byte != 10) continue;
        header.add(line);
        var text = _decode(line, file.path).trimRight();
        if (first && text.startsWith('\uFEFF')) text = text.substring(1);
        if (!first && text == '---' || first && text != '---') {
          return _decode(header.takeBytes(), file.path);
        }
        first = false;
        line = <int>[];
      }
    }
    cancellation.throwIfCancelled();
    header.add(line);
    return _decode(header.takeBytes(), file.path);
  }
}
