import 'dart:async';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_validate.dart' show validateCancelAndResume;
import '../../tool/live_multi_agent_validate.dart' show validateMultiAgent;
import 'agent_test.dart' show ScriptedModel;

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
    'multi-agent validation rejects claimed work without child runs',
    () async {
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(
          text:
              '{"sales":{"total":600,"mean":120},"latency":{"p50":110,"p95":1900}}',
        );
      });
      final report = await validateMultiAgent(model);
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['modelSpawnedTwoChildren'], isFalse);
      expect((report['checks'] as Map)['childrenReadAndSavedResults'], isFalse);
    },
  );

  test(
    'multi-agent validation checks actual child reads and saved analyses',
    () async {
      final model = ScriptedModel((request, _) async* {
        final isRoot = request.system.contains('You are /root.');
        final lastCall = request.messages
            .expand((m) => m.calls)
            .lastOrNull
            ?.name;
        if (isRoot) {
          if (request.messages.length == 1) {
            yield ModelResponse(
              calls: [
                for (final name in ['sales', 'latency'])
                  ToolCall(
                    id: name,
                    name: 'spawn_agent',
                    arguments: {'task_name': name, 'message': name},
                  ),
              ],
            );
          } else if (lastCall == 'spawn_agent') {
            yield ModelResponse(
              calls: [ToolCall(id: 'wait', name: 'wait_agent')],
            );
          } else {
            yield ModelResponse(
              text:
                  '{"sales":{"total":600,"mean":120},"latency":{"p50":110,"p95":1900}}',
            );
          }
        } else {
          final dataset = request.system.contains('You are /root/sales.')
              ? 'sales'
              : 'latency';
          if (lastCall == null) {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'discover',
                  name: 'tool_search',
                  arguments: {'query': 'dataset analysis'},
                ),
              ],
            );
          } else if (lastCall == 'tool_search') {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'read',
                  name: 'read_dataset',
                  arguments: {'dataset': dataset},
                ),
              ],
            );
          } else if (lastCall == 'read_dataset') {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'save',
                  name: 'save_analysis',
                  arguments: {
                    'dataset': dataset,
                    'analysis': dataset == 'sales'
                        ? {'total': 600, 'mean': 120}
                        : {'p50': 110, 'p95': 1900},
                  },
                ),
              ],
            );
          } else {
            yield ModelResponse(text: 'analysis saved');
          }
        }
      });
      final report = await validateMultiAgent(model);
      expect(report['passed'], isTrue);
      expect(report['children'], hasLength(2));
      expect(
        (report['businessActions'] as List).where(
          (a) => a['tool'] == 'save_analysis',
        ),
        hasLength(2),
      );
    },
  );

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
