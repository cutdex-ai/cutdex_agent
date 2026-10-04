import 'dart:convert';
import 'summary.dart';
import '../session/snapshot.dart';
import '../memory/memory.dart';
import '../model/adapter.dart';
import '../model/messages.dart';
import '../run/cancellation.dart';
import '../skills/skills.dart';
import '../tools/tool.dart';

class ContextOverflow implements Exception {
  const ContextOverflow(this.message);
  final String message;
  @override
  String toString() => 'ContextOverflow: $message';
}

class ContextBuilder {
  ContextBuilder({
    this.maxInputTokens = 32000,
    this.maxOutputTokens = 4096,
    this.skills,
    this.memory,
    this.summarizer,
    int Function(String)? countTokens,
  }) : countTokens = countTokens ?? _estimateTokens {
    if (maxInputTokens <= 0 || maxOutputTokens <= 0) {
      throw ArgumentError('Budgets must be positive');
    }
  }

  /// Input budget is separate from reserved output; the host must fit both in
  /// the provider context window. The default is a model-independent estimate;
  /// inject a model tokenizer when an exact token count is available.
  final int maxInputTokens;
  final int maxOutputTokens;
  final int Function(String) countTokens;
  final SkillProvider? skills;
  final MemoryProvider? memory;

  /// Enables durable automatic compaction at model-request boundaries.
  final ContextSummarizer? summarizer;
  static int _estimateTokens(String text) {
    // Structured ASCII (including tool JSON) commonly shares tokens across
    // characters. Counting every UTF-8 byte as a token makes usable windows
    // appear full. Allow one token per three ASCII characters, two per BMP
    // non-ASCII character, and three per supplementary character, then reserve
    // 25% for tokenizer variation and protocol framing. This is an estimate,
    // not a replacement for a provider's tokenizer or context-limit response.
    var thirds = 0;
    for (final rune in text.runes) {
      thirds += rune <= 0x7f ? 1 : (rune <= 0xffff ? 6 : 9);
    }
    return (thirds * 5 + 11) ~/ 12;
  }

  /// Uses the same token counter as request construction.
  int measureInput({
    required String system,
    List<AgentMessage> history = const [],
    List<AgentTool> tools = const [],
  }) => countTokens(
    jsonEncode({
      'system': system,
      'messages': history.map((m) => m.toJson()..remove('usage')).toList(),
      'tools': tools.map((t) => t.declaration).toList(),
    }),
  );

  /// Runtime capabilities are registered alongside host tools under the same
  /// execution, journaling and recovery contract.
  List<AgentTool> runtimeTools(
    SessionSnapshot Function() snapshot,
    List<AgentTool> tools,
  ) => const [];

  List<AgentTool> selectTools(
    List<AgentMessage> history,
    List<AgentTool> tools,
  ) => tools;

  String prepareSystem(
    String system,
    List<AgentMessage> history, {
    int? taskStart,
  }) => system;

  List<AgentMessage> pinnedInstructions(
    List<AgentMessage> history, {
    required int covered,
    required int taskStart,
  }) => const [];

  String? completionReminder(List<AgentMessage> history) => null;

  /// Request-only projection. Preserve message count/order and tool pairing;
  /// references must resolve in the slice or through a durable runtime reader.
  List<AgentMessage> projectHistory(List<AgentMessage> history) => history;

  Future<ModelRequest> build({
    required String system,
    required List<AgentMessage> history,
    required List<AgentTool> tools,
    required CancellationToken cancellation,
    List<String> skillIds = const [],
    String? memoryScope,
    ContextSummary? summary,
    int? requiredHistoryStart,
    int? taskStart,
  }) async {
    cancellation.throwIfCancelled();
    system = prepareSystem(
      system,
      history,
      taskStart: taskStart ?? requiredHistoryStart,
    );
    final registeredTools = tools;
    final loadedSkills = <AgentSkill>[];
    final skillProvider = skills;
    if (skillProvider == null && skillIds.isNotEmpty) {
      throw StateError('Selected skills require a provider');
    }
    if (skillProvider != null) {
      for (final id in skillIds.toSet()) {
        cancellation.throwIfCancelled();
        final skill = await skillProvider.load(id, cancellation);
        if (skill == null) throw StateError('Skill not found: $id');
        if (skill.descriptor.id != id) {
          throw StateError('Skill provider returned the wrong identity: $id');
        }
        if (skill.requiredTools.any(
          (name) => !registeredTools.any((t) => t.name == name),
        )) {
          throw StateError('Skill requires unavailable tools: $id');
        }
        loadedSkills.add(skill);
      }
    }
    final requiredTools = loadedSkills.expand((s) => s.requiredTools).toSet();
    final discovered = selectTools(history, tools).map((t) => t.name).toSet();
    tools = [
      for (final tool in registeredTools)
        if (requiredTools.contains(tool.name) || discovered.contains(tool.name))
          tool,
    ];

    if (summary != null &&
        (summary.coveredMessages < 0 ||
            summary.coveredMessages > history.length ||
            !isSafeSummaryBoundary(history, summary.coveredMessages))) {
      throw StateError('Invalid summary boundary');
    }
    final effectiveSystem = summary == null
        ? system
        : '$system\n\nConversation summary (${summary.source}): ${summary.text}';
    final parts = <String>[effectiveSystem];
    final covered = summary?.coveredMessages ?? 0;
    history = [
      ...history.take(covered),
      ...projectHistory(history.sublist(covered)),
    ];
    final requestedStart =
        requiredHistoryStart ??
        history.lastIndexWhere((m) => m.role == MessageRole.user);
    if (requiredHistoryStart != null &&
        (requiredHistoryStart < 0 || requiredHistoryStart > history.length)) {
      throw ArgumentError('Invalid required history boundary');
    }
    final start = requestedStart < covered ? covered : requestedStart;
    final requiredStart = start < 0 ? 0 : start;
    if (requiredStart < history.length &&
        history[requiredStart].role != MessageRole.user &&
        !(summary != null && requiredStart == covered)) {
      throw StateError('Required history must start at a user turn');
    }
    final turns = <List<AgentMessage>>[];
    for (final message in history.sublist(covered, requiredStart)) {
      if (message.role == MessageRole.user || turns.isEmpty) turns.add([]);
      turns.last.add(message);
    }
    // Keep all active-run instructions, including the original goal and later
    // steering. Only history outside that boundary may be pruned.
    final selected = <AgentMessage>[
      ...pinnedInstructions(
        history,
        covered: covered,
        taskStart: taskStart ?? (requestedStart < 0 ? 0 : requestedStart),
      ),
      if (summary != null && covered == history.length)
        AgentMessage(
          role: MessageRole.user,
          text:
              'Continue the pending task from the summary. Completed actions '
              'are already recorded; do not execute them again.',
        ),
      ...history.skip(requiredStart),
    ];
    int inputSize(List<String> sections, List<AgentMessage> messages) {
      final count = measureInput(
        system: sections.join('\n\n'),
        history: messages,
        tools: tools,
      );
      if (count < 0) {
        throw StateError('Token counter returned a negative count');
      }
      return count;
    }

    if (inputSize(parts, selected) > maxInputTokens) {
      throw const ContextOverflow(
        'Required instructions, summary, tools and current turn exceed input budget',
      );
    }
    void addSection(String text, {bool required = false}) {
      final proposed = [...parts, text];
      if (inputSize(proposed, selected) <= maxInputTokens) {
        parts.add(text);
      } else if (required) {
        throw const ContextOverflow('Selected skill exceeds input budget');
      }
    }

    for (final skill in loadedSkills) {
      addSection(
        'Skill ${skill.descriptor.id}@${skill.descriptor.version}:\n${skill.instructions}',
        required: true,
      );
    }
    final memoryProvider = memory;
    if (memoryProvider != null && memoryScope != null) {
      final query =
          history.where((m) => m.role == MessageRole.user).lastOrNull?.text ??
          '';
      final memories = await memoryProvider.search(
        scope: memoryScope,
        query: query,
        limit: 8,
        cancellation: cancellation,
      );
      for (final item in memories) {
        if (item.scope != memoryScope) {
          throw StateError('Memory provider returned an unauthorized scope');
        }
        addSection('Memory (${item.id}, source: ${item.source}): ${item.text}');
      }
    }
    for (final turn in turns.reversed) {
      final proposed = [...turn, ...selected];
      if (inputSize(parts, proposed) > maxInputTokens) break;
      selected.insertAll(0, turn);
    }
    cancellation.throwIfCancelled();
    return ModelRequest(
      system: parts.join('\n\n'),
      messages: selected,
      tools: tools,
      maxOutputTokens: maxOutputTokens,
    );
  }
}
