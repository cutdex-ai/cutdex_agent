import 'dart:async';

import '../model/adapter.dart';
import 'cancellation.dart';

/// Bounded, content-free monotonic timings. Parent spans include child spans;
/// their durations must not be added together to estimate elapsed time.
class RunDiagnostics {
  static final Object _key = Object();
  static RunDiagnostics? get current => Zone.current[_key] as RunDiagnostics?;
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _spans = [];
  int _dropped = 0;

  T scope<T>(T Function() action) => runZoned(action, zoneValues: {_key: this});

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final start = _clock.elapsedMicroseconds;
    var outcome = 'error';
    try {
      final value = await action();
      outcome = 'completed';
      return value;
    } on AgentCancelled {
      outcome = 'cancelled';
      rethrow;
    } finally {
      _record(stage, start, outcome);
    }
  }

  void _record(
    String stage,
    int start,
    String outcome, [
    Map<String, Object?> details = const {},
  ]) {
    if (_spans.length >= 2048) {
      _dropped++;
      return;
    }
    _spans.add({
      'stage': stage,
      'startUs': start,
      'durationUs': _clock.elapsedMicroseconds - start,
      'outcome': outcome,
      ...details,
    });
  }

  /// This measures adapter events, not network bytes. Tool-only responses may
  /// have no text at all; firstTextUs then remains null.
  Stream<ModelEvent> modelEvents(
    ModelAdapter model,
    ModelRequest request,
    CancellationToken cancellation, {
    required bool summary,
  }) async* {
    final start = _clock.elapsedMicroseconds;
    int? firstEvent;
    int? firstText;
    var outcome = 'incomplete';
    Map<String, Object?>? usage;
    Map<String, Object?> failureDetails = const {};
    try {
      await for (final event in model.stream(request, cancellation)) {
        final elapsed = _clock.elapsedMicroseconds - start;
        firstEvent ??= elapsed;
        if (event is TextDelta && event.text.isNotEmpty ||
            event is ModelResponse && event.text.isNotEmpty) {
          firstText ??= elapsed;
        }
        if (event is ModelResponse) {
          outcome = 'completed';
          usage = event.usage?.toJson();
        }
        yield event;
      }
    } catch (error) {
      failureDetails = switch (error) {
        ModelConnectionException() => {
          'connectionKind': error.kind.name,
          'connectionStage': error.stage.name,
          'osErrorCode': error.osErrorCode,
        },
        ModelHttpException() => {'httpStatus': error.statusCode},
        _ => const {},
      };
      outcome = cancellation.isCancelled ? 'cancelled' : 'error';
      rethrow;
    } finally {
      _record(
        summary ? 'summaryModel' : 'model',
        start,
        cancellation.isCancelled ? 'cancelled' : outcome,
        {
          'usage': ?usage,
          'firstEventUs': firstEvent,
          'firstTextUs': firstText,
          ...failureDetails,
        },
      );
    }
  }

  Map<String, Object?> toJson() => {
    'elapsedUs': _clock.elapsedMicroseconds,
    'dropped': _dropped,
    'spans': [for (final span in _spans) Map<String, Object?>.of(span)],
  };
}
