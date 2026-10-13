import '../run/cancellation.dart';

class SkillDescriptor {
  const SkillDescriptor({
    required this.id,
    required this.version,
    required this.description,
  });
  final String id;
  final String version;
  final String description;
}

class AgentSkill {
  AgentSkill({
    required this.descriptor,
    required this.instructions,
    Iterable<String> requiredTools = const [],
  }) : requiredTools = List.unmodifiable(requiredTools);
  final SkillDescriptor descriptor;
  final String instructions;
  final List<String> requiredTools;
}

/// Supplies lightweight catalog metadata and separately loaded skill bodies.
abstract interface class SkillProvider {
  /// Lists descriptors without loading instruction bodies into model context.
  ///
  /// Discovery requires unique IDs and non-empty IDs, versions and descriptions.
  Future<List<SkillDescriptor>> list(CancellationToken cancellation);

  /// Loads the full instructions for [id], or returns `null` when absent.
  Future<AgentSkill?> load(String id, CancellationToken cancellation);
}
