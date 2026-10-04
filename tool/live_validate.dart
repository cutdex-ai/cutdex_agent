import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

void check(bool value, String description) {
  if (!value) throw StateError(description);
}

class LiveSummary implements ContextSummarizer {
  LiveSummary(this.model);
  final OpenAiChatAdapter model;
  @override
  String get source => '${model.model}/live-summary';
  @override
  Future<String> summarize(
    List<AgentMessage> messages,
    CancellationToken cancellation,
  ) async {
    final request = ModelRequest(
      system:
          'Summarize the supplied conversation. Preserve exact identifiers, numerical constraints and user preferences. Do not call tools. Return a concise factual summary.',
      messages: [
        AgentMessage(
          role: MessageRole.user,
          text: jsonEncode(messages.map((m) => m.toJson()).toList()),
        ),
      ],
      tools: [],
      maxOutputTokens: 2048,
    );
    final events = await model.stream(request, cancellation).toList();
    return events.whereType<ModelResponse>().single.text;
  }
}

Future<void> main(List<String> args) async {
  final baseUrl = Platform.environment['CUTDEX_LIVE_BASE_URL']?.trim();
  if (baseUrl == null || baseUrl.isEmpty) {
    throw ArgumentError('CUTDEX_LIVE_BASE_URL is required');
  }
  final modelId = Platform.environment['CUTDEX_LIVE_MODEL']?.trim();
  if (modelId == null || modelId.isEmpty) {
    throw ArgumentError('CUTDEX_LIVE_MODEL is required');
  }
  // CLI boundary only: the library receives apiKey as a constructor argument.
  // Avoid echoing the key in interactive terminals; never persist it.
  final previousEcho = stdin.hasTerminal ? stdin.echoMode : null;
  String? inputKey;
  try {
    if (previousEcho != null) stdin.echoMode = false;
    inputKey = stdin.readLineSync()?.trim();
  } finally {
    if (previousEcho != null) stdin.echoMode = previousEcho;
  }
  final key = inputKey;
  if (key == null || key.isEmpty) {
    throw ArgumentError('API key required on stdin');
  }
  final model = OpenAiChatAdapter(
    baseUrl: Uri.parse(baseUrl),
    model: modelId,
    apiKey: key,
  );
  final report = <String, Object?>{'model': model.model, 'checks': <Object?>[]};
  final checks = report['checks']! as List<Object?>;
  Future<void> test(
    String name,
    Future<Map<String, Object?>> Function() body,
  ) async {
    stdout.writeln('START $name');
    final watch = Stopwatch()..start();
    try {
      final result = await body();
      checks.add({
        'name': name,
        'passed': true,
        'elapsedMs': watch.elapsedMilliseconds,
        ...result,
      });
      stdout.writeln('PASS $name ${jsonEncode(result)}');
    } catch (error) {
      final detail = error
          .toString()
          .replaceAll(baseUrl, '[REDACTED_ENDPOINT]')
          .replaceAll(key, '[REDACTED]');
      checks.add({
        'name': name,
        'passed': false,
        'elapsedMs': watch.elapsedMilliseconds,
        'error': detail,
      });
      stdout.writeln('FAIL $name $detail');
      exitCode = 1;
    }
  }

  await test('streaming_chat', () async {
    final manager = SessionManager(
      model: model,
      store: InMemorySessionStore(),
      contextBuilder: ContextBuilder(maxOutputTokens: 2048),
    );
    final session = await manager.create(
      system: 'Follow the user instruction exactly.',
    );
    final run = await manager.prompt(
      session.id,
      'Reply with exactly CUTDEX_READY',
    );
    var deltas = 0;
    final sub = run.events.listen((e) {
      if (e.kind == AgentEventKind.textDelta) deltas++;
    });
    final result = await run.done;
    await sub.cancel();
    check(result.status == RunStatus.completed, 'Run failed: ${result.error}');
    check(
      result.history.last.text.trim() == 'CUTDEX_READY',
      'Unexpected reply',
    );
    check(deltas > 0, 'No text deltas');
    return {
      'reply': result.history.last.text,
      'textDeltas': deltas,
      'turns': result.turns,
    };
  });
  await test('tool_edit_verify', () async {
    var duration = 12;
    var edits = 0;
    var reads = 0;
    final store = InMemorySessionStore();
    final manager = SessionManager(
      model: model,
      store: store,
      contextBuilder: ContextBuilder(maxOutputTokens: 2048),
      tools: [
        AgentTool(
          name: 'read_clip',
          description:
              'Read the current duration in seconds of the single test clip.',
          parameters: {
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          validate: (a) => a.isEmpty ? null : 'No arguments',
          execute: (_, _) async {
            reads++;
            return ToolResult(
              'Current clip duration',
              data: {'durationSeconds': duration},
            );
          },
        ),
        AgentTool(
          name: 'trim_clip',
          description: 'Set the single test clip duration in seconds.',
          parameters: {
            'type': 'object',
            'properties': {
              'durationSeconds': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 12,
              },
            },
            'required': ['durationSeconds'],
            'additionalProperties': false,
          },
          validate: (a) =>
              a.length == 1 &&
                  a['durationSeconds'] is int &&
                  (a['durationSeconds']! as int) >= 1 &&
                  (a['durationSeconds']! as int) <= 12
              ? null
              : 'Invalid duration',
          execute: (call, _) async {
            duration = call.arguments['durationSeconds']! as int;
            edits++;
            return ToolResult('Updated', data: {'durationSeconds': duration});
          },
        ),
      ],
    );
    final session = await manager.create(
      system:
          'You are a video editing agent. Use tools to inspect and edit; never claim success without checking the result. After a write, call read_clip again.',
    );
    final result = await (await manager.prompt(
      session.id,
      'First read the clip duration, then trim it to 5 seconds exactly once, then read again to verify. Report the verified duration.',
      maxTurns: 6,
    )).done;
    check(result.status == RunStatus.completed, 'Run failed: ${result.error}');
    check(
      duration == 5 && edits == 1 && reads >= 2,
      'Wrong edit counts: duration=$duration edits=$edits reads=$reads',
    );
    return {
      'durationSeconds': duration,
      'edits': edits,
      'reads': reads,
      'turns': result.turns,
      'reply': result.history.last.text,
    };
  });
  await test('cancel_and_resume', () async {
    final directory = await Directory.systemTemp.createTemp('cutdex-live-');
    try {
      final store = FileSessionStore(directory);
      final manager = SessionManager(
        model: model,
        store: store,
        contextBuilder: ContextBuilder(maxOutputTokens: 4096),
      );
      final session = await manager.create(
        system: 'Follow the latest instruction.',
      );
      final run = await manager.prompt(
        session.id,
        'Write integers 1 through 2000, one per line, no explanation.',
      );
      var observed = false;
      final sub = run.events.listen((e) {
        if (!observed && e.kind == AgentEventKind.textDelta) {
          observed = true;
          unawaited(run.cancel());
        }
      });
      final cancelled = await run.done;
      await sub.cancel();
      check(
        observed && cancelled.status == RunStatus.cancelled,
        'Cancellation failed: ${cancelled.status} ${cancelled.error}',
      );
      final restored = SessionManager(
        model: model,
        store: FileSessionStore(directory),
        contextBuilder: ContextBuilder(maxOutputTokens: 2048),
      );
      final resume = await restored.resume(session.id);
      await resume.steer(
        'Replace the previous request. Reply with exactly CUTDEX_RECOVERED',
      );
      final result = await resume.done;
      check(
        result.status == RunStatus.completed &&
            result.history.last.text.trim() == 'CUTDEX_RECOVERED',
        'Resume failed: ${result.status} ${result.error}',
      );
      check(result.runId == cancelled.runId, 'Logical run changed');
      return {
        'cancelledAfterText': observed,
        'restoredSameRun': true,
        'reply': result.history.last.text,
      };
    } finally {
      await directory.delete(recursive: true);
    }
  });
  await test('real_context_summary', () async {
    final manager = SessionManager(
      model: model,
      store: InMemorySessionStore(),
      contextBuilder: ContextBuilder(maxOutputTokens: 2048),
    );
    final session = await manager.create(
      system: 'Remember the user constraints and answer concisely.',
    );
    final first = await (await manager.prompt(
      session.id,
      'For this edit, target duration is 17 seconds, preserve original audio, project code is AZURE-731. Acknowledge briefly.',
    )).done;
    check(first.status == RunStatus.completed, 'Setup failed: ${first.error}');
    final second = await (await manager.prompt(
      session.id,
      'We will continue later. Reply OK.',
    )).done;
    check(
      second.status == RunStatus.completed,
      'Follow-up failed: ${second.error}',
    );
    final compacted = await manager.compact(session.id, LiveSummary(model));
    check(compacted.history.length == second.history.length, 'History changed');
    check(compacted.summaries.isNotEmpty, 'No summary');
    final summary = compacted.summaries.last;
    check(
      summary.text.contains('17') &&
          summary.text.contains('AZURE-731') &&
          summary.text.toLowerCase().contains('audio'),
      'Summary lost constraints',
    );
    final finalRun = await (await manager.prompt(
      session.id,
      'State the exact project code, target duration, and audio constraint.',
    )).done;
    check(
      finalRun.status == RunStatus.completed &&
          finalRun.history.last.text.contains('AZURE-731') &&
          finalRun.history.last.text.contains('17') &&
          finalRun.history.last.text.toLowerCase().contains('audio'),
      'Recall failed: ${finalRun.error}',
    );
    return {
      'coveredMessages': summary.coveredMessages,
      'historyPreserved': true,
      'summary': summary.text,
      'reply': finalRun.history.last.text,
    };
  });
  final output = args.isEmpty ? null : File(args.first);
  if (output != null) {
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }
  stdout.writeln('LIVE_VALIDATION_COMPLETE');
}
