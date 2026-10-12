import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_tree_cancel_validate.dart'
    show validateTreeCancellation;
import 'agent_test.dart' show ScriptedModel;

ScriptedModel cancellationTreeModel() {
  var id = 0;
  final stages = <String, int>{};
  ModelResponse call(String tool, [Map<String, Object?> args = const {}]) =>
      ModelResponse(
        calls: [ToolCall(id: 'call-${++id}', name: tool, arguments: args)],
      );
  return ScriptedModel((request, _) async* {
    final name = RegExp(
      r'Multi-agent collaboration: You are ([^\s]+)\. ',
    ).firstMatch(request.system)!.group(1)!;
    final stage = stages.update(name, (v) => v + 1, ifAbsent: () => 0);
    if (name == '/root' && stage == 0) {
      yield call('spawn_agent', {
        'task_name': 'leader',
        'message': 'Spawn two writers',
      });
    } else if (name == '/root/leader' && stage == 0) {
      yield ModelResponse(
        calls: [
          for (final key in ['a', 'b'])
            ...call('spawn_agent', {
              'task_name': 'writer_$key',
              'message': 'Write $key',
            }).calls,
        ],
      );
    } else if (name.contains('/writer_') && stage == 0) {
      final key = name.endsWith('_a') ? 'a' : 'b';
      final args = {'key': key, 'value': key == 'a' ? 10 : 20};
      yield ModelResponse(
        calls: [
          ...call('gated_write', args).calls,
          ...call('append_extra', args).calls,
        ],
      );
    } else if (stage < 5) {
      yield call('wait_agent', {'timeout_ms': 60000});
    } else {
      yield ModelResponse(text: 'finished');
    }
  });
}

void main() {
  test(
    'root cancel settles full tree, drops queued writes and remains stopped after restart',
    () async {
      final report = await validateTreeCancellation(
        cancellationTreeModel(),
        observation: const Duration(milliseconds: 200),
      );
      expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
      expect(report['sessionsAfterCancel'] as List, hasLength(4));
      expect(report['initialResource'], report['finalResource']);
      expect(report['modelCallsAtCancel'], report['modelCallsAfterCancel']);
      final cancelledCalls = (report['sessionsAfterCancel'] as List)
          .where((s) => (s as Map)['depth'] == 2)
          .expand((s) => (s as Map)['messages'] as List)
          .where(
            (m) =>
                (m as Map)['role'] == 'tool' &&
                (m['text'] as String).contains('Cancelled before execution'),
          );
      expect(cancelledCalls, hasLength(2));
    },
  );

  test(
    'an uncooperative write is detected even if every session ends cancelled',
    () async {
      final report = await validateTreeCancellation(
        cancellationTreeModel(),
        honorsCancellation: false,
        observation: const Duration(milliseconds: 100),
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['entireTreeCancelled'], isTrue);
      expect(
        (report['checks'] as Map)['noCommitsAfterCancelRequested'],
        isFalse,
      );
      expect(
        (report['checks'] as Map)['resourceUnchangedAfterCancellation'],
        isFalse,
      );
    },
  );

  test(
    'cancel and precommit release in the same turn cannot bypass descendant tokens',
    () async {
      final report = await validateTreeCancellation(
        cancellationTreeModel(),
        releaseWithCancel: true,
        observation: const Duration(milliseconds: 100),
      );
      expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
      expect(report['initialResource'], report['finalResource']);
      expect(
        (report['resourceActions'] as List).where(
          (a) => (a as Map)['kind'] == 'commit',
        ),
        isEmpty,
      );
    },
  );
}
