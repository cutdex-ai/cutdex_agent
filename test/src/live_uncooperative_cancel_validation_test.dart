import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_uncooperative_cancel_validate.dart';
import 'agent_test.dart' show ScriptedModel;

ScriptedModel uncooperativeModel({
  bool wrongNewGoal = false,
  bool oldDirectChild = false,
}) {
  var id = 0;
  final stages = <String, int>{};
  ModelResponse call(String name, [Map<String, Object?> args = const {}]) =>
      ModelResponse(
        calls: [ToolCall(id: 'late-${++id}', name: name, arguments: args)],
      );
  return ScriptedModel((request, _) async* {
    final name = RegExp(
      r'Multi-agent collaboration: You are ([^\s]+)\. ',
    ).firstMatch(request.system)!.group(1)!;
    final user = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    final fresh = user.contains(uncooperativeNewMarker);
    final stage = stages.update(
      '${fresh ? 'new' : 'old'}:$name',
      (v) => v + 1,
      ifAbsent: () => 0,
    );
    if (!fresh) {
      if (name == '/root') {
        yield stage == 0
            ? call('spawn_agent', {
                'task_name': oldDirectChild ? 'writer' : 'leader',
                'message': '$uncooperativeOldMarker spawn writer',
              })
            : call('hold_old_root');
      } else if (name == '/root/leader' && stage == 0) {
        yield call('spawn_agent', {
          'task_name': 'writer',
          'message': '$uncooperativeOldMarker old tool',
        });
      } else if (name == '/root/leader') {
        yield call('wait_agent', {'timeout_ms': 60000});
      } else {
        yield call('uncooperative_old_tool');
      }
    } else if (name != '/root') {
      yield stage == 0
          ? call('write_new_value', {'value': wrongNewGoal ? 12 : 15})
          : ModelResponse(text: 'New write done');
    } else {
      switch (stage) {
        case 0:
          yield call('spawn_agent', {
            'task_name': 'writer',
            'message': '$uncooperativeNewMarker write 15',
          });
        case 1:
          yield call('wait_agent', {'timeout_ms': 60000});
        case 2:
          yield call('inspect_current_value');
        default:
          final result =
              (jsonDecode(
                        request.messages
                            .lastWhere((m) => m.role == MessageRole.tool)
                            .text,
                      )
                      as Map)['data']
                  as Map;
          yield ModelResponse(
            text: jsonEncode({
              'a': result['a'],
              'polluted': result['polluted'],
            }),
          );
      }
    }
  });
}

void main() {
  for (final depth in [1, 2]) {
    test(
      'generation fence rejects detached old writer at depth $depth',
      () async {
        final report = await validateUncooperativeCancellation(
          uncooperativeModel(oldDirectChild: depth == 1),
          mode: UncooperativeMode.detachedWrite,
          guarded: true,
          oldWriterDepth: depth,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
        expect(report['newTaskPolluted'], isFalse);
        expect(report['oldSubmissionsRejected'], 1);
        expect((report['finalResource'] as Map)['a'], 15);
      },
    );
  }
  test('generation fence rejects ignored-token pending submission', () async {
    final report = await validateUncooperativeCancellation(
      uncooperativeModel(),
      mode: UncooperativeMode.pendingWrite,
      guarded: true,
    );
    expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
    expect(report['oldWritesAfterCancelRequest'], 0);
    expect(report['oldSubmissionsRejected'], 1);
  });
  for (final mode in UncooperativeMode.values) {
    test(
      'uncooperative ${mode.name} reports actual cancellation and resource boundary',
      () async {
        final report = await validateUncooperativeCancellation(
          uncooperativeModel(),
          mode: mode,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
        expect(
          report['newTaskPolluted'],
          mode == UncooperativeMode.detachedWrite,
        );
        expect(
          report['oldWritesDuringNewTask'],
          mode == UncooperativeMode.detachedWrite ? 1 : 0,
        );
        expect(
          (report['finalResource'] as Map)['a'],
          mode == UncooperativeMode.detachedWrite ? 10 : 15,
        );
      },
    );
  }
  test(
    'harness rejects wrong new goal even if detached old write masks it',
    () async {
      final report = await validateUncooperativeCancellation(
        uncooperativeModel(wrongNewGoal: true),
        mode: UncooperativeMode.detachedWrite,
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['newChildActuallyWrote15'], isFalse);
      expect(report['newTaskPolluted'], isTrue);
    },
  );
}
