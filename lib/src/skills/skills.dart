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

abstract interface class SkillProvider {
  Future<List<SkillDescriptor>> list(CancellationToken cancellation);
  Future<AgentSkill?> load(String id, CancellationToken cancellation);
}
