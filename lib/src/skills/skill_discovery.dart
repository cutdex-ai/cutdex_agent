import 'dart:convert';

import '../model/messages.dart';
import '../run/cancellation.dart';
import '../tools/tool.dart';
import 'skills.dart';

// Internal protocol for skill discovery and immutable activation receipts.
class SkillDiscovery {
  SkillDiscovery(this.provider);
  final SkillProvider provider;

  Future<List<SkillDescriptor>> catalog(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final descriptors = await provider.list(cancellation);
    cancellation.throwIfCancelled();
    final ids = <String>{};
    for (final descriptor in descriptors) {
      if (descriptor.id.trim().isEmpty ||
          descriptor.version.trim().isEmpty ||
          descriptor.description.trim().isEmpty ||
          !ids.add(descriptor.id)) {
        throw StateError(
          'Invalid or duplicate skill descriptor: ${descriptor.id}',
        );
      }
    }
    return descriptors.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  static Map<String, Object?> describe(SkillDescriptor descriptor) => {
    'id': descriptor.id,
    'version': descriptor.version,
    'description': String.fromCharCodes(descriptor.description.runes.take(512)),
  };

  List<AgentTool> tools() => [
    AgentTool(
      name: 'list_skills',
      description:
          'List available skill summaries without loading instructions. '
          'Use query to filter IDs and descriptions; use offset to read more.',
      alwaysAvailable: true,
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'query': {'type': 'string'},
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
        },
      },
      validate: (args) {
        if (args.keys.any(
              (key) => !{'query', 'offset', 'limit'}.contains(key),
            ) ||
            args['query'] != null && args['query'] is! String ||
            args['offset'] != null &&
                (args['offset'] is! int || (args['offset'] as int) < 0) ||
            args['limit'] != null &&
                (args['limit'] is! int ||
                    (args['limit'] as int) < 1 ||
                    (args['limit'] as int) > 50)) {
          return 'Supply optional string query, nonnegative offset and limit 1..50';
        }
        return null;
      },
      execute: (call, context) async {
        try {
          final all = await catalog(context.cancellation);
          final query = (call.arguments['query'] as String? ?? '')
              .toLowerCase()
              .trim();
          final matches = all
              .where(
                (skill) => '${skill.id} ${skill.description}'
                    .toLowerCase()
                    .contains(query),
              )
              .toList();
          final offset = call.arguments['offset'] as int? ?? 0;
          final page = matches
              .skip(offset)
              .take(call.arguments['limit'] as int? ?? 20)
              .toList();
          final end = offset + page.length;
          return ToolResult(
            'Available skill summaries',
            data: {
              'skills': page.map(describe).toList(),
              'total': matches.length,
              'nextOffset': end < matches.length ? end : null,
            },
          );
        } catch (error) {
          return ToolResult('Cannot list skills: $error', isError: true);
        }
      },
      recover: (_, _) async => const ToolRecovery.notStarted(),
    ),
    AgentTool(
      name: 'load_skill',
      description:
          'Load and activate one skill by its exact catalog ID when '
          'relevant to the task. Full instructions and required tool schemas '
          'become available on the next model request and persist in this session. '
          'Loading a skill does not execute its scripts or grant tool permissions.',
      alwaysAvailable: true,
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      validate: (args) =>
          args.keys.any((key) => key != 'id') ||
              args['id'] is! String ||
              (args['id'] as String).trim().isEmpty
          ? 'Supply a non-empty skill id'
          : null,
      execute: (call, context) async {
        try {
          final id = call.arguments['id'] as String;
          final descriptors = await catalog(context.cancellation);
          if (!descriptors.any((skill) => skill.id == id)) {
            return ToolResult('Skill not found in catalog: $id', isError: true);
          }
          final skill = await provider.load(id, context.cancellation);
          context.cancellation.throwIfCancelled();
          if (skill == null || skill.descriptor.id != id) {
            return ToolResult(
              'Skill missing or identity changed: $id',
              isError: true,
            );
          }
          if (skill.instructions.trim().isEmpty) {
            return ToolResult(
              'Skill instructions are empty: $id',
              isError: true,
            );
          }
          return ToolResult(
            'Skill loaded: $id',
            data: {
              'skill': {
                'id': skill.descriptor.id,
                'version': skill.descriptor.version,
                'description': skill.descriptor.description,
                'instructions': skill.instructions,
                'requiredTools': skill.requiredTools,
              },
            },
          );
        } catch (error) {
          return ToolResult('Cannot load skill: $error', isError: true);
        }
      },
      recover: (_, _) async => const ToolRecovery.notStarted(),
    ),
  ];

  static AgentSkill? resultSkill(ToolResult result) {
    if (result.isError || result.data['skill'] is! Map) return null;
    final data = result.data['skill'] as Map;
    if (data['id'] is! String ||
        data['version'] is! String ||
        data['description'] is! String ||
        data['instructions'] is! String ||
        data['requiredTools'] is! List ||
        (data['requiredTools'] as List).any((name) => name is! String)) {
      return null;
    }
    return AgentSkill(
      descriptor: SkillDescriptor(
        id: data['id'] as String,
        version: data['version'] as String,
        description: data['description'] as String,
      ),
      instructions: data['instructions'] as String,
      requiredTools: (data['requiredTools'] as List).cast<String>(),
    );
  }

  static Map<AgentMessage, AgentSkill> receipts(List<AgentMessage> history) {
    final calls = <String, ToolCall>{};
    final results = <AgentMessage, AgentSkill>{};
    for (final message in history) {
      if (message.role == MessageRole.assistant) {
        for (final call in message.calls) {
          calls[call.id] = call;
        }
      }
      if (message.role != MessageRole.tool) continue;
      final call = calls.remove(message.callId);
      if (call?.name != 'load_skill' || message.isError) continue;
      try {
        final result = ToolResult.fromJson(
          (jsonDecode(message.text) as Map).cast<String, Object?>(),
        );
        final skill = resultSkill(result);
        if (skill != null && skill.descriptor.id == call!.arguments['id']) {
          results[message] = skill;
        }
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return results;
  }

  static Map<String, AgentSkill> active(List<AgentMessage> history) => {
    for (final skill in receipts(history).values) skill.descriptor.id: skill,
  };

  static List<AgentMessage> project(List<AgentMessage> history) {
    final loaded = receipts(history);
    return [
      for (final message in history)
        if (loaded[message] case final AgentSkill skill)
          AgentMessage(
            role: message.role,
            callId: message.callId,
            resultId: message.resultId,
            runtimeNotice: message.runtimeNotice,
            isError: message.isError,
            providerData: message.providerData,
            text: jsonEncode(
              ToolResult(
                'Skill instructions are active in system context',
                data: {
                  ...describe(skill.descriptor),
                  'requiredTools': skill.requiredTools,
                },
              ).toJson(),
            ),
          )
        else
          message,
    ];
  }
}
