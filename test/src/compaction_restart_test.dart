import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import 'agent_test.dart' show ScriptedModel, tool;
import 'context_boundaries_test.dart' show Summary;

void main() {
  test(
    'disk restart after compaction preserves constraints and completed edits',
    () async {
      final root = await Directory.systemTemp.createTemp('compaction-restart-');
      addTearDown(() => root.delete(recursive: true));
      var edits = 0;
      final summarizer = Summary((messages, _) async {
        expect(messages.map((m) => m.text).join('\n'), contains('180 seconds'));
        return 'Goal: finish 180 seconds. Constraints: source -24 dB; voice 0 dB. '
            'Completed: $edits edits saved on sequence:fixture. '
            'Pending: verify without repeating edits. References: stress-shot-01.';
      });
      ContextBuilder budget() =>
          ContextBuilder(maxInputTokens: 1400, summarizer: summarizer);
      final tools = [
        tool(
          execute: (_, _) async {
            edits++;
            return ToolResult('Saved 180 seconds. ${'state ' * 1000}');
          },
        ),
      ];
      final first = SessionManager(
        model: ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [ToolCall(id: 'edit-$edits', name: 'edit')],
          );
        }),
        store: FileSessionStore(root),
        contextBuilder: budget(),
        tools: tools,
      );
      final session = await first.create(system: 'Only edit sequence:fixture.');
      final paused = await (await first.prompt(
        session.id,
        'Make two edits; preserve 180 seconds and source -24 dB; voice 0 dB.',
        maxTurns: 2,
      )).done;
      expect(paused.status, RunStatus.paused);
      expect(paused.summaries, isNotEmpty);
      expect(edits, 2);

      // A new store and manager recreate the process boundary, with no run cache.
      final restoredStore = FileSessionStore(root);
      final loaded = (await restoredStore.read(session.id))!;
      expect(
        loaded.history.map((m) => m.toJson()).toList(),
        paused.history.map((m) => m.toJson()).toList(),
      );
      final restored = SessionManager(
        model: ScriptedModel((request, _) async* {
          expect(request.system, contains('Only edit sequence:fixture'));
          expect(request.system, contains('180 seconds'));
          expect(request.system, contains('source -24 dB; voice 0 dB'));
          expect(request.system, contains('2 edits saved'));
          yield ModelResponse(text: 'verified');
        }),
        store: restoredStore,
        contextBuilder: budget(),
        tools: tools,
      );
      final result = await (await restored.resume(
        session.id,
        maxTurns: 8,
      )).done;
      expect(result.status, RunStatus.completed);
      expect(edits, 2);
      expect(
        result.history.where((m) => m.role == MessageRole.tool),
        hasLength(2),
      );
      expect(result.summaries.length, greaterThan(paused.summaries.length));
      expect(
        (await FileSessionStore(root).read(session.id))!.history.last.text,
        'verified',
      );
    },
  );
}
