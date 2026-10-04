import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

const usage = TokenUsage(
  inputTokens: 100,
  outputTokens: 20,
  totalTokens: 120,
  cachedInputTokens: 60,
  reasoningOutputTokens: 12,
);

class UsageModel implements ModelAdapter {
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    yield ModelResponse(text: 'done', usage: usage);
  }
}

void main() {
  final adapter = OpenAiResponsesAdapter(
    baseUrl: Uri.parse('https://invalid.example/v1'),
    model: 'test',
    apiKey: '',
  );
  ModelResponse decode(Object? raw) {
    final decoder = adapter.createDecoder();
    decoder.add(
      jsonEncode({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'usage': raw,
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'ok'},
              ],
            },
          ],
        },
      }),
    );
    return decoder.finish();
  }

  test('Responses counts preserve subsets without adding them to total', () {
    final result = decode({
      'input_tokens': 100,
      'output_tokens': 20,
      'total_tokens': 120,
      'input_tokens_details': {'cached_tokens': 60},
      'output_tokens_details': {'reasoning_tokens': 12},
    });
    expect(result.usage!.toJson(), usage.toJson());
  });
  test('missing and invalid telemetry do not fail a valid response', () {
    for (final raw in [
      null,
      {},
      {'input_tokens': -1, 'output_tokens': 20, 'total_tokens': 19},
    ]) {
      final result = decode(raw);
      expect(result.text, 'ok');
      expect(result.usage, isNull);
    }
    final result = decode({
      'input_tokens': 100,
      'output_tokens': 20,
      'total_tokens': 120,
      'input_tokens_details': {'cached_tokens': 101},
      'output_tokens_details': {'reasoning_tokens': '12'},
    });
    expect(result.usage!.cachedInputTokens, isNull);
    expect(result.usage!.reasoningOutputTokens, isNull);
  });
  test('usage survives run persistence and store reopening', () async {
    final dir = await Directory.systemTemp.createTemp('cutdex-usage-');
    addTearDown(() => dir.delete(recursive: true));
    final manager = SessionManager(
      model: UsageModel(),
      store: FileSessionStore(dir),
    );
    final session = await manager.create();
    await (await manager.prompt(session.id, 'hello')).done;
    final restored = (await FileSessionStore(dir).read(session.id))!;
    expect(restored.history.last.usage!.toJson(), usage.toJson());
  });
  test('usage is excluded from wire input and context estimates', () {
    final plain = AgentMessage(role: MessageRole.assistant, text: 'ok');
    final counted = AgentMessage(
      role: MessageRole.assistant,
      text: 'ok',
      usage: usage,
    );
    final context = ContextBuilder();
    expect(
      context.measureInput(system: '', history: [counted]),
      context.measureInput(system: '', history: [plain]),
    );
    expect(counted.estimatedTokens, plain.estimatedTokens);
    Map<String, Object?> body(AgentMessage message) => adapter.body(
      ModelRequest(
        system: '',
        messages: [message],
        tools: [],
        maxOutputTokens: 20,
      ),
    );
    expect(body(counted), body(plain));
    expect(AgentMessage.fromJson(plain.toJson()).usage, isNull);
  });
  test('ordinary and summary diagnostics both retain usage', () async {
    final diagnostics = RunDiagnostics();
    for (final summary in [false, true]) {
      await diagnostics
          .modelEvents(
            UsageModel(),
            ModelRequest(
              system: '',
              messages: [],
              tools: [],
              maxOutputTokens: 20,
            ),
            CancellationToken(),
            summary: summary,
          )
          .drain<void>();
    }
    final spans = diagnostics.toJson()['spans'] as List;
    expect(spans.map((s) => s['usage']), [usage.toJson(), usage.toJson()]);
  });
}
