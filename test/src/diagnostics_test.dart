import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

class _Model implements ModelAdapter {
  _Model({this.toolOnly = false, this.fail = false});
  final bool toolOnly;
  final bool fail;
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    token.throwIfCancelled();
    if (fail) throw StateError('SECRET_ERROR');
    if (!toolOnly) yield TextDelta('SECRET_REPLY');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    yield ModelResponse(text: toolOnly ? '' : 'SECRET_REPLY');
  }
}

void main() {
  final request = ModelRequest(
    system: 'SECRET_PROMPT',
    messages: [],
    tools: [],
    maxOutputTokens: 20,
  );
  test(
    'counts summary separately and measures first text without content',
    () async {
      final trace = RunDiagnostics();
      await trace
          .modelEvents(_Model(), request, CancellationToken(), summary: false)
          .drain<void>();
      await trace
          .modelEvents(
            _Model(toolOnly: true),
            request,
            CancellationToken(),
            summary: true,
          )
          .drain<void>();
      final spans = trace.toJson()['spans'] as List;
      expect(spans.map((s) => s['stage']), ['model', 'summaryModel']);
      expect(spans[0]['firstTextUs'], greaterThan(0));
      expect(spans[0]['durationUs'], greaterThan(spans[0]['firstTextUs']));
      expect(spans[1]['firstTextUs'], isNull);
      expect(spans[1]['firstEventUs'], greaterThan(0));
      expect(jsonEncode(trace.toJson()), isNot(contains('SECRET')));
    },
  );
  test(
    'failed and cancelled requests retain timings and propagate errors',
    () async {
      final trace = RunDiagnostics();
      await expectLater(
        trace
            .modelEvents(
              _Model(fail: true),
              request,
              CancellationToken(),
              summary: false,
            )
            .drain<void>(),
        throwsStateError,
      );
      final token = CancellationToken()..cancel();
      await expectLater(
        trace
            .modelEvents(_Model(), request, token, summary: true)
            .drain<void>(),
        throwsA(isA<AgentCancelled>()),
      );
      final spans = trace.toJson()['spans'] as List;
      expect(spans.map((s) => s['outcome']), ['error', 'cancelled']);
      expect(jsonEncode(trace.toJson()), isNot(contains('SECRET')));
    },
  );
  test('scope is isolated and bounded', () async {
    final trace = RunDiagnostics();
    expect(RunDiagnostics.current, isNull);
    await trace.scope(() async {
      expect(RunDiagnostics.current, same(trace));
      for (var i = 0; i < 2050; i++) {
        await trace.measure('prepare', () async {});
      }
    });
    expect(RunDiagnostics.current, isNull);
    expect((trace.toJson()['spans'] as List).length, 2048);
    expect(trace.toJson()['dropped'], 2);
  });
}
