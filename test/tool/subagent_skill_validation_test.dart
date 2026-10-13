import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../tool/subagent_skill_validation.dart';
import '../src/agent_test.dart' show ScriptedModel;

ModelAdapter scenario({
  bool loadUnrelated = false,
  bool claimedOnly = false,
  bool multiLevel = false,
  bool wrongCoordinatorSummary = false,
  bool coordinatorLoadsSkill = false,
}) => ScriptedModel((request, _) async* {
  final actor = RegExp(
    r'Multi-agent collaboration: You are ([^\s]+)\. ',
  ).firstMatch(request.system)!.group(1)!;
  final previous = request.messages
      .expand((message) => message.calls)
      .lastOrNull;
  ModelResponse call(
    String name,
    Map<String, Object?> args, {
    String suffix = '',
  }) => ModelResponse(
    calls: [ToolCall(id: '$actor-$name-$suffix', name: name, arguments: args)],
  );
  if (claimedOnly) {
    yield ModelResponse(text: '两个子代理都完成了，视频已导出。');
    return;
  }
  if (actor == '/root' || actor == '/root/coordinator') {
    final coordinating = actor == '/root/coordinator';
    if (multiLevel && !coordinating && previous == null) {
      yield call('spawn_agent', {
        'task_name': 'coordinator',
        'message': '自己创建剪辑和调色孙代理，等两位报告后回读项目，汇总JSON。',
        'fork_turns': 'none',
      });
    } else if (coordinating && coordinatorLoadsSkill && previous == null) {
      yield call('load_skill', {'id': 'video-editing'});
    } else if (previous == null ||
        (coordinating && previous.name == 'load_skill')) {
      yield ModelResponse(
        calls: [
          ToolCall(
            id: '$actor-spawn-edit',
            name: 'spawn_agent',
            arguments: {
              'task_name': 'edit',
              'message': '将视频计划时长调整为10秒并保留音频，独立选择技能，读取、修改后回读。',
              'fork_turns': coordinatorLoadsSkill ? 'all' : 'none',
            },
          ),
          ToolCall(
            id: '$actor-spawn-grade',
            name: 'spawn_agent',
            arguments: {
              'task_name': 'grade',
              'message': '将曝光设为0.5 EV、白平衡5600 K，只改调色字段，独立选择技能，读取、修改后回读。',
              'fork_turns': coordinatorLoadsSkill ? 'all' : 'none',
            },
          ),
        ],
      );
    } else if (coordinating && previous.name == 'read_media_project') {
      final data =
          (jsonDecode(request.messages.last.text) as Map)['data'] as Map;
      yield ModelResponse(
        text: jsonEncode({
          'durationSeconds': wrongCoordinatorSummary
              ? 12
              : data['durationSeconds'],
          'preserveAudio': data['preserveAudio'],
          'exposureEv': data['exposureEv'],
          'whiteBalanceKelvin': data['whiteBalanceKelvin'],
        }),
      );
    } else if (previous.name == 'render_media_project') {
      final result = ToolResult.fromJson(
        (jsonDecode(request.messages.last.text) as Map).cast<String, Object?>(),
      );
      yield ModelResponse(
        text: jsonEncode({
          for (final key in [
            'outputVideo',
            'durationSeconds',
            'exposureEv',
            'whiteBalanceKelvin',
            'originalAudioPreserved',
          ])
            key: result.data[key],
        }),
      );
    } else if (previous.name == 'wait_agent') {
      final data =
          (jsonDecode(request.messages.last.text) as Map)['data'] as Map;
      final agents = data['agents'] as List;
      if (agents.length == (multiLevel && !coordinating ? 1 : 2) &&
          agents.every((agent) => (agent as Map)['status'] == 'completed')) {
        // The render tool reads the latest project and verifies its real output.
        // A separate read is optional; this models the valid direct-export path.
        yield call(
          coordinating ? 'read_media_project' : 'render_media_project',
          {},
        );
      } else {
        yield call('wait_agent', {
          'timeout_ms': 1000,
        }, suffix: '${request.messages.length}');
      }
    } else {
      yield call('wait_agent', {'timeout_ms': 1000});
    }
    return;
  }
  final editing = actor.endsWith('/edit');
  final skillId = editing ? 'video-editing' : 'color-grading';
  final write = editing ? 'set_cut_duration' : 'set_color_grade';
  if (previous == null) {
    yield ModelResponse(
      calls: [
        ToolCall(
          id: '$actor-load',
          name: 'load_skill',
          arguments: {'id': skillId},
        ),
        if (loadUnrelated)
          ToolCall(
            id: '$actor-unrelated',
            name: 'load_skill',
            arguments: {'id': editing ? 'color-grading' : 'video-editing'},
          ),
      ],
    );
  } else if (previous.name == 'load_skill' || previous.name == write) {
    yield call('read_media_project', {}, suffix: '${request.messages.length}');
  } else if (request.messages
      .expand((message) => message.calls)
      .any((entry) => entry.name == write)) {
    yield ModelResponse(text: '自己的字段已完成并通过回读验证。');
  } else {
    yield call(
      write,
      editing
          ? {'durationSeconds': 10, 'preserveAudio': true}
          : {'exposureEv': 0.5, 'whiteBalanceKelvin': 5600},
    );
  }
});

Future<void> main() async {
  var available = true;
  try {
    for (final executable in ['ffmpeg', 'ffprobe']) {
      if ((await Process.run(executable, ['-version'])).exitCode != 0) {
        available = false;
      }
    }
  } on ProcessException {
    available = false;
  }
  final skip = available
      ? false
      : 'FFmpeg and ffprobe are required for the actual media fixture';
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cutdex-subagent-media-');
  });
  tearDown(() => root.delete(recursive: true));
  Future<Map<String, Object?>> validate(
    ModelAdapter model, {
    bool multiLevel = false,
  }) => validateSubagentSkills(
    model,
    skillDirectory: Directory('example/media_skills').absolute.path,
    outputRoot: root.path,
    multiLevel: multiLevel,
  );

  test(
    'two children load isolated skills and produce verified real media',
    () async {
      final report = await validate(scenario());
      expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
      expect(
        (report['checks'] as Map)['childrenCompletedBeforeRender'],
        isTrue,
      );
      final children = report['children'] as List;
      expect(children.length, 2);
      expect(
        children.every((child) => (child as Map)['passed'] == true),
        isTrue,
      );
      final render = (report['project'] as Map)['render'] as Map;
      expect(render['originalAudioPreserved'], isTrue);
      expect((render['durationSeconds'] as num) - 10, closeTo(0, 0.1));
      expect(await File(report['outputVideo'] as String).exists(), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'grandchildren isolate skills and deliver summaries through both layers',
    () async {
      final report = await validate(
        scenario(multiLevel: true),
        multiLevel: true,
      );
      expect(report['passed'], isTrue, reason: jsonEncode(report));
      expect((report['sessionTree'] as List).length, 4);
      expect(
        (report['children'] as List).every((raw) => (raw as Map)['depth'] == 2),
        isTrue,
      );
      final coordinator = (report['coordinators'] as List).single as Map;
      expect(coordinator['passed'], isTrue);
      expect(
        (report['checks'] as Map)['rootReceivedCoordinatorReportBeforeRender'],
        isTrue,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'correct media does not hide an incorrect coordinator summary',
    () async {
      final report = await validate(
        scenario(multiLevel: true, wrongCoordinatorSummary: true),
        multiLevel: true,
      );
      expect((report['checks'] as Map)['actualVideoDuration'], isTrue);
      expect((report['checks'] as Map)['parentSummaryMatchesArtifact'], isTrue);
      final coordinator = (report['coordinators'] as List).single as Map;
      expect(
        (coordinator['checks'] as Map)['summaryMatchesMergedProject'],
        isFalse,
      );
      expect(report['passed'], isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'coordinator loading and forked worker skill leakage are rejected',
    () async {
      final report = await validate(
        scenario(multiLevel: true, coordinatorLoadsSkill: true),
        multiLevel: true,
      );
      expect((report['checks'] as Map)['actualVideoDuration'], isTrue);
      final coordinator = (report['coordinators'] as List).single as Map;
      expect((coordinator['checks'] as Map)['noExecutionSkills'], isFalse);
      expect(
        (report['children'] as List).any(
          (raw) =>
              ((raw as Map)['checks'] as Map)['initialCatalogOnly'] == false,
        ),
        isTrue,
      );
      expect(report['passed'], isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'flat delegation cannot pass the multilevel hierarchy validation',
    () async {
      final report = await validate(scenario(), multiLevel: true);
      expect((report['checks'] as Map)['actualVideoDuration'], isTrue);
      expect(
        (report['checks'] as Map)['modelCreatedExpectedHierarchy'],
        isFalse,
      );
      expect(report['passed'], isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real output cannot hide unrelated skill loading in children',
    () async {
      final report = await validate(scenario(loadUnrelated: true));
      expect((report['checks'] as Map)['actualVideoDuration'], isTrue);
      expect((report['checks'] as Map)['decodedAudioPreserved'], isTrue);
      expect(
        (report['checks']
            as Map)['childrenIndependentlySelectedDifferentSkills'],
        isFalse,
      );
      expect(report['passed'], isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a claimed delegation and export without real work is rejected',
    () async {
      final report = await validate(scenario(claimedOnly: true));
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['modelSpawnedTwoChildren'], isFalse);
      expect((report['checks'] as Map)['actualVideoDuration'], isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
