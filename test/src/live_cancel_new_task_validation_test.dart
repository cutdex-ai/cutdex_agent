import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_cancel_new_task_validate.dart';
import 'agent_test.dart' show ScriptedModel;

ScriptedModel taskSwitchModel({bool wrongGoal = false}) {
  var id = 0;
  final stages = <String, int>{};
  ModelResponse call(String name, [Map<String, Object?> args = const {}]) =>
      ModelResponse(
        calls: [ToolCall(id: 'call-${++id}', name: name, arguments: args)],
      );
  return ScriptedModel((request, _) async* {
    final name = RegExp(
      r'Multi-agent collaboration: You are ([^\s]+)\. ',
    ).firstMatch(request.system)!.group(1)!;
    final user = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    final fresh = user.contains(newTaskMarker);
    final stage = stages.update(
      '${fresh ? 'new' : 'old'}:$name',
      (v) => v + 1,
      ifAbsent: () => 0,
    );
    if (!fresh) {
      if (name == '/root' && stage == 0) {
        yield call('spawn_agent', {
          'task_name': 'leader',
          'message': '$oldTaskMarker create writers',
        });
      } else if (name == '/root' && stage == 1) {
        yield call('hold_root_until_cancel');
      } else if (name == '/root/leader' && stage == 0) {
        yield ModelResponse(
          calls: [
            for (final key in ['a', 'b'])
              ...call('spawn_agent', {
                'task_name': 'writer_$key',
                'message': '$oldTaskMarker write $key',
              }).calls,
            ...call('send_message', {
              'target': 'parent',
              'message': '$oldNoticeMarker old goals 10 and 20',
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
      } else {
        yield call('wait_agent', {'timeout_ms': 60000});
      }
    } else if (name == '/root') {
      switch (stage) {
        case 0:
          yield call('list_agents');
        case 1:
          yield call('send_message', {
            'target': RegExp(
              r'send_message\(target:([^,]+),',
            ).firstMatch(user)!.group(1),
            'message': 'OLD_CONTROL_PROBE',
          });
        case 2:
          yield call('spawn_agent', {
            'task_name': 'leader',
            'message': '$newTaskMarker write a=15 only',
          });
        case 3:
          yield call('wait_agent', {'timeout_ms': 60000});
        case 4:
          yield call('inspect_shared_resource');
        default:
          yield ModelResponse(text: '{"a":15}');
      }
    } else if (stage == 0) {
      yield call('write_new_goal', {'key': 'a', 'value': wrongGoal ? 10 : 15});
    } else {
      yield ModelResponse(text: 'new goal 15 saved');
    }
  });
}

void main() {
  test(
    'new root task archives unread old messages before its task boundary',
    () async {
      final store = InMemorySessionStore();
      final previous = SessionSnapshot(
        id: 'root',
        runId: 'cancelled-run',
        status: RunStatus.cancelled,
        stopRequested: true,
        history: [AgentMessage(role: MessageRole.user, text: 'previous task')],
        agentState: {
          'inbox': ['$oldNoticeMarker retained late report'],
          'inputs': {'old-input': true},
        },
      );
      await store.save(previous, expectedRevision: null);
      final model = ScriptedModel((request, _) async* {
        final start = request.messages.indexWhere((m) => m.text == 'new goal');
        expect(start, greaterThan(0));
        expect(
          request.messages
              .take(start)
              .any((m) => m.runtimeNotice && m.text.contains(oldNoticeMarker)),
          isTrue,
        );
        expect(
          request.messages
              .skip(start)
              .any((m) => m.text.contains(oldNoticeMarker)),
          isFalse,
        );
        yield ModelResponse(text: 'new task complete');
      });
      final manager = SessionManager(
        model: model,
        store: store,
        contextBuilder: ContextBuilder(),
        multiAgent: MultiAgentConfig(),
      );
      final result = await (await manager.prompt(previous.id, 'new goal')).done;
      expect(result.status, RunStatus.completed);
      expect(result.runStart, 2);
      expect(result.history[1].text, '$oldNoticeMarker retained late report');
      expect(result.history[1].runtimeNotice, isTrue);
      expect(result.history[result.runStart].text, 'new goal');
      expect(result.agentState['inbox'], isEmpty);
      expect((result.agentState['inputs'] as Map)['old-input'], isTrue);
    },
  );

  for (final reopen in [false, true]) {
    test(
      'cancel then new task isolates runs, names, targets and mailboxes (reopen=$reopen)',
      () async {
        final report = await validateCancelThenNewTask(
          taskSwitchModel(),
          reopenManager: reopen,
          observation: const Duration(milliseconds: 100),
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
        expect(report['oldPendingInbox'], isNotEmpty);
        expect(report['newRunId'], isNot(report['oldRunId']));
        expect((report['checks'] as Map)['prematureStartRejected'], isTrue);
        expect(
          (report['checks']
              as Map)['oldMailboxNotDeliveredAsCurrentTaskNotice'],
          isTrue,
        );
      },
    );
  }
  test(
    'new task harness rejects writing obsolete goal even when summary claims 15',
    () async {
      final report = await validateCancelThenNewTask(
        taskSwitchModel(wrongGoal: true),
        observation: const Duration(milliseconds: 100),
      );
      expect(report['passed'], isFalse);
      expect(
        (report['checks'] as Map)['onlyNewChildCommittedNewGoal'],
        isFalse,
      );
      expect((report['checks'] as Map)['newSummaryCorrect'], isTrue);
    },
  );
}
