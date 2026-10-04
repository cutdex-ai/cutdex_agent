import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_validate.dart' show validateCancelAndResume;

class CancellationModel implements ModelAdapter {
  int requests = 0;

  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    requests++;
    if (requests == 1) {
      yield const TextDelta('1\n');
      while (!cancellation.isCancelled) {
        await Future<void>.delayed(Duration.zero);
      }
      cancellation.throwIfCancelled();
    }
    yield ModelResponse(text: 'CUTDEX_RECOVERED');
  }
}

void main() {
  test(
    'live validation reconciles cancellation before starting a new run',
    () async {
      final model = CancellationModel();
      final result = await validateCancelAndResume(model);
      expect(result, {
        'cancelledAfterText': true,
        'reconciledSameRun': true,
        'followUpNewRun': true,
        'reply': 'CUTDEX_RECOVERED',
      });
      // Reconciliation of the cancelled run must not dispatch a model request.
      expect(model.requests, 2);
    },
  );
}
