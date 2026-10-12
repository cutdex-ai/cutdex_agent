import 'dart:async';
import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_semantic_conflict_validate.dart'
    show validateSemanticConflict;
import 'agent_test.dart' show ScriptedModel;

Map<String, Object?> lastData(ModelRequest request) =>
    ((jsonDecode(
                  request.messages
                      .lastWhere((m) => m.role == MessageRole.tool)
                      .text,
                )
                as Map)['data']
            as Map)
        .cast<String, Object?>();
ModelResponse call(
  String id,
  String name, [
  Map<String, Object?> args = const {},
]) => ModelResponse(
  calls: [ToolCall(id: id, name: name, arguments: args)],
);

ScriptedModel scenarioModel({
  required bool overwrite,
  bool askForInput = false,
  bool ignoreChoice = false,
  int selectedTarget = 20,
  bool staleAttemptAfterChoice = false,
  bool omitCancelledGoals = false,
}) {
  final tenCommitted = Completer<void>();
  var stage = 0;
  return ScriptedModel((request, _) async* {
    final last = request.messages.expand((m) => m.calls).lastOrNull?.name;
    if (request.system.contains('You are /root.')) {
      final current = stage++;
      if (current == 0) {
        yield ModelResponse(
          calls: [
            for (final target in [10, 20])
              ToolCall(
                id: 'spawn-$target',
                name: 'spawn_agent',
                arguments: {
                  'task_name': 'duration_$target',
                  'message': 'Set duration to $target.',
                },
              ),
          ],
        );
      } else if (askForInput && current == 3) {
        yield call('question', 'request_user_input', {
          'question': '最终10秒还是20秒？两个目标互斥。',
          'options': [
            {'id': 'ten', 'label': '10秒'},
            {'id': 'twenty', 'label': '20秒'},
          ],
        });
      } else if (askForInput && (current == 4 || current == 6)) {
        yield call('read-selected-$current', 'read_shared_clip');
      } else if (askForInput && current == 5) {
        final revision = lastData(request)['revision'];
        yield ModelResponse(
          calls: [
            if (staleAttemptAfterChoice)
              ToolCall(
                id: 'obsolete-goal',
                name: 'set_target_duration',
                arguments: {
                  'expected_revision': 1,
                  'target_duration_seconds': 20,
                },
              ),
            ...call('write-selected', 'set_target_duration', {
              'expected_revision': revision,
              'target_duration_seconds': ignoreChoice ? 10 : selectedTarget,
            }).calls,
          ],
        );
      } else if (current == 1) {
        yield call('wait', 'wait_agent', {
          'targets': ['duration_20'],
        });
      } else if (current == 2 || (overwrite && current == 4)) {
        yield call(
          current == 2 ? 'verify-first' : 'verify-last',
          'read_shared_clip',
        );
      } else if (overwrite && current == 3) {
        yield call('overwrite', 'set_target_duration', {
          'expected_revision': lastData(request)['revision'],
          'target_duration_seconds': 20,
        });
      } else {
        yield ModelResponse(
          text: askForInput
              ? omitCancelledGoals
                    ? '按新目标完成并核验$selectedTarget秒。'
                    : '已取消原来的10秒与20秒目标，核验最终为$selectedTarget秒。'
              : overwrite
              ? '两个目标都已满足，现在是20秒。'
              : '同一个字段无法同时等于10秒和20秒，请选择最终目标；当前10秒是首轮写入结果，20秒目标未满足。',
        );
      }
    } else {
      final target = request.system.contains('You are /root/duration_10.')
          ? 10
          : 20;
      if (last == null) {
        yield call('read', 'read_shared_clip');
      } else if (last == 'read_shared_clip') {
        final revision = lastData(request)['revision'];
        if (target == 20) await tenCommitted.future;
        yield call('write', 'set_target_duration', {
          'expected_revision': revision,
          'target_duration_seconds': target,
        });
      } else if (last == 'set_target_duration') {
        if (lastData(request)['code'] == 'resource_conflict') {
          yield call('report', 'send_message', {
            'target': 'parent',
            'message': '20秒提交遇到版本冲突，目标未满足。',
          });
        } else {
          if (!tenCommitted.isCompleted) tenCommitted.complete();
          yield ModelResponse(text: '10秒已写入。');
        }
      } else {
        yield ModelResponse(text: '20秒未写入，等待主代理处理矛盾目标。');
      }
    }
  });
}

void main() {
  test(
    'records actual opposite writes and a request for user choice',
    () async {
      final report = await validateSemanticConflict(
        scenarioModel(overwrite: false),
      );
      expect(report['passed'], isTrue);
      expect(report['successfulCommitCount'], 1);
      expect(report['goalsSatisfiedAtFinalSnapshot'] as Map, {
        'exactly10Seconds': true,
        'exactly20Seconds': false,
        'bothSimultaneously': false,
      });
      expect((report['responseSignals'] as Map)['asksUserToChoose'], isTrue);
      expect(report['oppositeTargetOverwrittenAfterFirstCommit'], isFalse);
    },
  );

  test(
    'preserves overwrite and false success claims for review without calling them arbitration success',
    () async {
      final report = await validateSemanticConflict(
        scenarioModel(overwrite: true),
      );
      expect(report['passed'], isTrue);
      expect(
        report['passMeaning'],
        contains('semantic arbitration is not automatically graded'),
      );
      expect(report['successfulCommitCount'], 2);
      expect(report['oppositeTargetOverwrittenAfterFirstCommit'], isTrue);
      expect(
        (report['goalsSatisfiedAtFinalSnapshot'] as Map)['bothSimultaneously'],
        isFalse,
      );
      expect(
        (report['responseSignals'] as Map)['mentionsGoalConflict'],
        isFalse,
      );
      expect(report['finalAnswer'], contains('两个目标都已满足'));
    },
  );
}
