import 'dart:async';
import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_conflict_validate.dart' show validateConflict;
import 'agent_test.dart' show ScriptedModel;

ToolCall toolCall(
  String id,
  String name, [
  Map<String, Object?> arguments = const {},
]) => ToolCall(id: id, name: name, arguments: arguments);
Map<String, Object?> lastData(ModelRequest request) =>
    ((jsonDecode(
                  request.messages
                      .lastWhere((m) => m.role == MessageRole.tool)
                      .text,
                )
                as Map)['data']
            as Map)
        .cast<String, Object?>();

ScriptedModel conflictModel({required bool coordinate}) {
  final colorCommitted = Completer<void>();
  var parentStage = 0;
  var reported = false;
  return ScriptedModel((request, _) async* {
    final root = request.system.contains('You are /root.');
    final lastCall = request.messages.expand((m) => m.calls).lastOrNull;
    if (root) {
      final stage = parentStage++;
      if (stage == 0) {
        yield ModelResponse(
          calls: [
            for (final marker in ['color', 'audio'])
              toolCall('spawn-$marker', 'spawn_agent', {
                'task_name': marker,
                'message': marker,
              }),
          ],
        );
      } else if (stage == 1) {
        yield ModelResponse(
          calls: [
            toolCall('wait-initial', 'wait_agent', {
              'targets': ['audio'],
            }),
          ],
        );
      } else if (coordinate && stage == 2) {
        yield ModelResponse(
          calls: [
            toolCall('retry', 'followup_task', {
              'target': 'audio',
              'message':
                  'Read current resource and retry audio, preserving color.',
            }),
          ],
        );
      } else if (coordinate && stage == 3) {
        yield ModelResponse(
          calls: [
            toolCall('wait-retry', 'wait_agent', {
              'targets': ['audio'],
            }),
          ],
        );
      } else if (lastCall?.name != 'read_shared_resource') {
        yield ModelResponse(
          calls: [toolCall('verify', 'read_shared_resource')],
        );
      } else {
        yield ModelResponse(text: jsonEncode(lastData(request)));
      }
    } else {
      final marker = request.system.contains('You are /root/color.')
          ? 'color'
          : 'audio';
      final followup = request.messages.any(
        (m) => m.text.contains('retry audio'),
      );
      if (lastCall == null ||
          (coordinate &&
              reported &&
              followup &&
              lastCall.name == 'send_message')) {
        yield ModelResponse(
          calls: [
            toolCall(followup ? 'reread' : 'read', 'read_shared_resource'),
          ],
        );
      } else if (lastCall.name == 'read_shared_resource') {
        final data = lastData(request);
        if (marker == 'audio' && data['revision'] == 1) {
          await colorCommitted.future;
        }
        yield ModelResponse(
          calls: [
            toolCall(
              followup || data['revision'] == 2 ? 'retry-write' : 'write',
              'write_shared_resource',
              {
                'expected_revision': data['revision'],
                'entries': [...data['entries'] as List, marker],
              },
            ),
          ],
        );
      } else if (lastCall.name == 'write_shared_resource') {
        final data = lastData(request);
        if (data['code'] == 'resource_conflict') {
          if (coordinate) {
            reported = true;
            yield ModelResponse(
              calls: [
                toolCall('report', 'send_message', {
                  'target': 'parent',
                  'message':
                      'audio resource_conflict: revision 1 is stale; please arrange retry.',
                }),
              ],
            );
          } else {
            yield ModelResponse(
              calls: [toolCall('reread', 'read_shared_resource')],
            );
          }
        } else {
          if (marker == 'color' && !colorCommitted.isCompleted) {
            colorCommitted.complete();
          }
          yield ModelResponse(text: '$marker committed');
        }
      } else {
        yield ModelResponse(
          text: 'Conflict reported to parent; awaiting followup task.',
        );
      }
    }
  });
}

void main() {
  test('forces stale writes and verifies parent-coordinated retry', () async {
    final result = await validateConflict(conflictModel(coordinate: true));
    expect(result['passed'], isTrue);
    expect(result['conflictCount'], 1);
    expect((result['finalResource'] as Map)['revision'], 3);
    final retry = (result['coordinatedRetries'] as List).single as Map;
    expect(
      retry['conflictSequence'],
      lessThan(retry['coordinationSequence'] as int),
    );
    expect(
      retry['coordinationSequence'],
      lessThan(retry['rereadSequence'] as int),
    );
    expect(retry['rereadSequence'], lessThan(retry['commitSequence'] as int));
  });

  test(
    'correct final content from autonomous child retry is not parent coordination',
    () async {
      final result = await validateConflict(conflictModel(coordinate: false));
      expect(
        (result['checks'] as Map)['finalResourcePreservesBothChanges'],
        isTrue,
      );
      expect(
        (result['checks'] as Map)['parentCoordinatedRereadAndRetry'],
        isFalse,
      );
      expect(result['passed'], isFalse);
    },
  );
}
