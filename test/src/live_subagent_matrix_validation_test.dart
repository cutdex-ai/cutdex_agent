import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/live_subagent_matrix_validate.dart';
import 'agent_test.dart' show ScriptedModel;

ScriptedModel scenarioModel(
  SubagentScenario scenario, {
  bool obsoleteWrite = false,
  bool wrongRelayTool = false,
  bool wrongSummary = false,
}) {
  var id = 0;
  ModelResponse call(String name, [Map<String, Object?> args = const {}]) =>
      ModelResponse(
        calls: [ToolCall(id: 'call-${++id}', name: name, arguments: args)],
      );
  ModelResponse spawn(String name) =>
      call('spawn_agent', {'task_name': name, 'message': 'Do $name'});
  ModelResponse wait([String? target]) => call('wait_agent', {
    if (target != null) 'targets': [target],
  });
  ModelResponse save(String key, int value) =>
      call('save_result', {'key': key, 'value': value});
  ModelResponse read([String source = 'numbers']) =>
      call('read_numbers', {'dataset': source});
  ModelResponse hold() => call('hold_for_parent', {'proposed_value': 10});
  ModelResponse follow([String target = 'worker']) => call('followup_task', {
    'target': target,
    'message':
        'Cancel old goal and apply chosen=15, or recover using numbers as assigned.',
  });
  final finished = ModelResponse(
    text: 'Child finished and reported actual results.',
  );
  final summary = switch (scenario) {
    SubagentScenario.handoff => {'producer': 21, 'consumer': 42},
    SubagentScenario.activeFollowup ||
    SubagentScenario.interrupt => {'chosen': 15},
    _ => {'total': 21},
  };
  final sequences = <String, List<ModelResponse>>{};
  final inspect = call('inspect_tasks');
  final checkpoint = call('wait_for_checkpoint');
  switch (scenario) {
    case SubagentScenario.nested:
      sequences['/root'] = [spawn('leader'), wait('leader'), inspect];
      sequences['/root/leader'] = [
        ModelResponse(calls: [...spawn('left').calls, ...spawn('right').calls]),
        wait(),
        save('total', 21),
        finished,
      ];
      sequences['/root/leader/left'] = [
        read('left'),
        save('left', 10),
        finished,
      ];
      sequences['/root/leader/right'] = [
        read('right'),
        save('right', 11),
        finished,
      ];
    case SubagentScenario.handoff:
      sequences['/root'] = [
        ModelResponse(
          calls: [...spawn('producer').calls, ...spawn('consumer').calls],
        ),
        wait('producer'),
        checkpoint,
        wrongRelayTool
            ? follow('consumer')
            : call('send_message', {
                'target': 'consumer',
                'message': 'Producer sum is 21; save consumer=42',
              }),
        wait('consumer'),
        inspect,
      ];
      sequences['/root/producer'] = [
        read(),
        save('producer', 21),
        call('send_message', {'target': 'parent', 'message': 'producer=21'}),
        finished,
      ];
      sequences['/root/consumer'] = [hold(), save('consumer', 42), finished];
    case SubagentScenario.activeFollowup:
      sequences['/root'] = [
        spawn('worker'),
        checkpoint,
        follow(),
        wait(),
        inspect,
      ];
      sequences['/root/worker'] = [
        hold(),
        save('chosen', obsoleteWrite ? 10 : 15),
        finished,
      ];
    case SubagentScenario.interrupt:
      sequences['/root'] = [
        spawn('worker'),
        checkpoint,
        call('interrupt_agent', {'target': 'worker'}),
        follow(),
        wait(),
        inspect,
      ];
      sequences['/root/worker'] = [hold(), save('chosen', 15), finished];
    case SubagentScenario.recovery:
      sequences['/root'] = [spawn('worker'), wait(), follow(), wait(), inspect];
      sequences['/root/worker'] = [
        read('missing'),
        call('send_message', {
          'target': 'parent',
          'message': 'dataset_unavailable',
        }),
        finished,
        read(),
        save('total', 21),
        finished,
      ];
    case SubagentScenario.limits:
      sequences['/root'] = [
        spawn('blocked'),
        checkpoint,
        spawn('worker'),
        call('send_message', {
          'target': 'unrelated_agent',
          'message': 'test boundary',
        }),
        call('interrupt_agent', {'target': 'blocked'}),
        spawn('worker'),
        wait(),
        inspect,
      ];
      sequences['/root/blocked'] = [hold()];
      sequences['/root/worker'] = [read(), save('total', 21), finished];
    case SubagentScenario.transportFault:
      sequences['/root'] = [spawn('worker'), wait(), follow(), wait(), inspect];
      sequences['/root/worker'] = [read(), read(), save('total', 21), finished];
  }
  final stages = <String, int>{};
  return ScriptedModel((request, _) async* {
    final name = RegExp(
      r'Multi-agent collaboration: You are ([^\s]+)\. ',
    ).firstMatch(request.system)!.group(1)!;
    final stage = stages.update(name, (value) => value + 1, ifAbsent: () => 0);
    final responses = sequences[name] ?? [];
    if (stage < responses.length) {
      yield responses[stage];
    } else {
      yield name == '/root'
          ? ModelResponse(
              text: jsonEncode(
                wrongSummary
                    ? {
                        'total': 999,
                        'chosen': 999,
                        'producer': 999,
                        'consumer': 999,
                      }
                    : summary,
              ),
            )
          : finished;
    }
  });
}

void main() {
  for (final scenario in SubagentScenario.values) {
    test(
      'matrix validates ${scenario.name} using actual coordination receipts',
      () async {
        final report = await validateSubagentScenario(
          scenarioModel(scenario),
          scenario,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
        expect(report['coordination'], isNotEmpty);
        expect(report['sessions'], isNotEmpty);
      },
    );
  }
  test('matrix rejects obsolete writes after active steering', () async {
    final report = await validateSubagentScenario(
      scenarioModel(SubagentScenario.activeFollowup, obsoleteWrite: true),
      SubagentScenario.activeFollowup,
    );
    expect(report['passed'], isFalse);
    expect((report['checks'] as Map)['oldGoalNeverAttempted'], isFalse);
  });
  test(
    'correct handoff artifacts alone do not prove requested parent relay',
    () async {
      final report = await validateSubagentScenario(
        scenarioModel(SubagentScenario.handoff, wrongRelayTool: true),
        SubagentScenario.handoff,
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['childArtifactsCorrectOnDisk'], isTrue);
      expect(
        (report['checks'] as Map)['actualParentRelayToWaitingConsumer'],
        isFalse,
      );
    },
  );
  test(
    'matrix rejects summary contradicting committed child artifacts',
    () async {
      final report = await validateSubagentScenario(
        scenarioModel(SubagentScenario.nested, wrongSummary: true),
        SubagentScenario.nested,
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['childArtifactsCorrectOnDisk'], isTrue);
      expect((report['checks'] as Map)['summaryMatchesActualResults'], isFalse);
    },
  );
}
