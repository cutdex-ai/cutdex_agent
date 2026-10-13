import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:path/path.dart' as p;

import 'media_project_fixture.dart';

Map? _summary(String answer) {
  final start = answer.indexOf('{'), end = answer.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final value = jsonDecode(answer.substring(start, end + 1));
    return value is Map ? value : null;
  } on FormatException {
    return null;
  }
}

List<Map<String, Object?>> _deliveredOutputs(List<AgentMessage> messages) {
  final outputs = <Map<String, Object?>>[];
  for (final message in messages) {
    if (message.role == MessageRole.tool) {
      final value = jsonDecode(message.text);
      if (value is Map && value['data'] is Map) {
        for (final item in value['data']['agents'] as List? ?? []) {
          if (item is Map) outputs.add(item.cast<String, Object?>());
        }
      }
    } else if (message.runtimeNotice &&
        message.text.startsWith('[Runtime child results;')) {
      final values = jsonDecode(message.text.split('\n')[1]) as List;
      for (final item in values) {
        outputs.add((item as Map).cast<String, Object?>());
      }
    }
  }
  return outputs
      .where((item) => item['status'] == 'completed' && item['output'] != null)
      .toList();
}

bool _received(List requests, List<SessionSnapshot> children) =>
    children.isNotEmpty &&
    children.every(
      (child) => requests.any((raw) {
        final entry = raw as Map;
        return (entry['deliveredOutputs'] as List).any(
          (item) =>
              (item as Map)['agent_id'] == child.id &&
              item['output'] == child.history.last.text,
        );
      }),
    );

class _Skills implements SkillProvider {
  _Skills(this.directory);
  final DirectorySkillProvider directory;
  final Map<String, AgentSkill> bodies = {};
  @override
  Future<List<SkillDescriptor>> list(CancellationToken token) =>
      directory.list(token);
  @override
  Future<AgentSkill?> load(String id, CancellationToken token) async {
    final skill = await directory.load(id, token);
    if (skill != null) bodies[id] = skill;
    return skill;
  }
}

class _Trace implements ModelAdapter {
  _Trace(this.model, this.skills, this.log);
  final ModelAdapter model;
  final _Skills skills;
  final void Function(String) log;
  final List<Map<String, Object?>> requests = [];
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final actor =
        RegExp(
          r'Multi-agent collaboration: You are ([^\s]+)\. ',
        ).firstMatch(request.system)?.group(1) ??
        'unknown';
    final catalogs = request.system
        .split('\n')
        .where((line) => line.startsWith('{"skills":'));
    final entry = <String, Object?>{
      'actor': actor,
      'request': requests.length + 1,
      'catalog': catalogs.isEmpty ? null : jsonDecode(catalogs.last),
      'activeSkills': [
        for (final skill in skills.bodies.values)
          if (request.system.contains(skill.instructions)) skill.descriptor.id,
      ],
      'containsSkillBody': request.system.contains('Skill source:'),
      'tools': request.tools.map((tool) => tool.name).toList(),
      'deliveredOutputs': _deliveredOutputs(request.messages),
      'calls': <Map<String, Object?>>[],
    };
    requests.add(entry);
    log(
      'MODEL $actor #${entry['request']} activeSkills=${entry['activeSkills']}',
    );
    await for (final event in model.stream(request, token)) {
      if (event is ModelResponse) {
        entry['calls'] = event.calls.map((call) => call.toJson()).toList();
        for (final call in event.calls) {
          log('CALL $actor ${call.name}');
        }
      }
      yield event;
    }
  }
}

List<Map<String, Object?>> _results(SessionSnapshot snapshot) {
  final calls = <String, ToolCall>{};
  final results = <Map<String, Object?>>[];
  for (var index = 0; index < snapshot.history.length; index++) {
    final message = snapshot.history[index];
    for (final call in message.calls) {
      calls[call.id] = call;
    }
    if (message.role != MessageRole.tool) continue;
    final call = calls.remove(message.callId);
    if (call == null || message.isError) continue;
    final result = ToolResult.fromJson(
      (jsonDecode(message.text) as Map).cast<String, Object?>(),
    );
    if (result.isError) continue;
    final data = call.name == 'load_skill'
        ? {'id': (result.data['skill'] as Map)['id']}
        : result.data;
    results.add({
      'tool': call.name,
      'arguments': call.arguments,
      'data': data,
      'historyIndex': index,
    });
  }
  return results;
}

bool _gradeMatches(Map state) =>
    state['exposureEv'] == 0.5 && state['whiteBalanceKelvin'] == 5600;

/// Validates real delegation and per-child skill selection on actual media files.
///
/// Generates a twelve-second test video with audio, persists a shared edit
/// project and sessions, and lets the model create its own children. The parent
/// renders the final MP4 with FFmpeg. No skill IDs or child names are supplied
/// in the user instruction. Model requests, journaled results, file mutations,
/// decoded audio hashes and measured pixel changes determine success.
/// With [multiLevel], a coordinating child must create the two workers itself
/// and return their merged results to the root before export.
Future<Map<String, Object?>> validateSubagentSkills(
  ModelAdapter model, {
  required String skillDirectory,
  required String outputRoot,
  MediaCommands? commands,
  bool multiLevel = false,
  void Function(String)? onLog,
  Duration timeout = const Duration(minutes: 6),
}) async {
  final log = onLog ?? (_) {};
  final base = await Directory(p.absolute(outputRoot)).create(recursive: true);
  final directory = await base.createTemp('run-');
  final guard = ResourceCommitGuard();
  final media = MediaProjectFixture(
    directory,
    commands ?? MediaCommands(),
    guard,
  );
  log('生成真实测试视频：${media.sourcePath}');
  await media.prepare();
  final store = FileSessionStore(Directory(p.join(directory.path, 'sessions')));
  media.childrenCompleteAtRender = (id) async {
    final parent = await store.read(id);
    if (parent == null ||
        parent.parentSessionId != null ||
        parent.childSessionIds.length != (multiLevel ? 1 : 2)) {
      return false;
    }
    for (final childId in parent.childSessionIds) {
      final child = await store.read(childId);
      if (child?.status != RunStatus.completed) {
        return false;
      }
      if (multiLevel) {
        if (child!.childSessionIds.length != 2) return false;
        for (final id in child.childSessionIds) {
          if ((await store.read(id))?.status != RunStatus.completed) {
            return false;
          }
        }
      }
    }
    return true;
  };
  final skills = _Skills(DirectorySkillProvider(skillDirectory));
  final traced = _Trace(model, skills, log);
  final manager = SessionManager(
    model: traced,
    store: store,
    tools: media.tools,
    resourceCommitGuard: guard,
    contextBuilder: HarnessContextBuilder(
      skills: skills,
      maxOutputTokens: 2048,
    ),
    multiAgent: MultiAgentConfig(
      maxConcurrent: multiLevel ? 3 : 2,
      maxDepth: multiLevel ? 2 : 1,
      maxChildren: 2,
      maxDelegatedTurns: multiLevel ? 64 : 48,
      childMaxTurns: multiLevel ? 24 : 16,
    ),
  );
  final session = await manager.create(
    system:
        '使用实际工具完成媒体制作并核对证据。执行剪辑或调色的末端代理根据分配目标从技能目录自主选择并加载相关技能，然后读取、修改并回读自己的字段。'
        '主代理和协调代理负责委派、等待和汇总，不代替执行代理修改字段，也无需加载他们的技能正文。只有主代理导出视频。'
        '共享项目按字段合并更新；时长与调色互不覆盖。对子代理提供独立业务目标，不指定技能ID。',
  );
  const singleLevelPrompt =
      '请启动两个子代理，分别处理同一个真实媒体项目：一位将视频计划时长缩短为10秒并保留音频，'
      '另一位将曝光补偿设为+0.5 EV、白平衡设为5600 K，只修改调色字段，时长由另一位负责。'
      '让他们各自自主发现并按需加载适用技能、读取当前项目、完成修改后回读验证。'
      '主代理等待两个子任务完成，读取合并项目，调用渲染工具导出实际视频。'
      '最终只返回JSON，包含 outputVideo、durationSeconds（以实际回读为准）、exposureEv、whiteBalanceKelvin、originalAudioPreserved。';
  const multiLevelPrompt =
      '请只创建一位协调子代理，让这位子代理自己继续创建两位孙代理处理同一个真实媒体项目。'
      '一位孙代理将计划时长缩短为10秒并保留音频；另一位将曝光补偿设为+0.5 EV、白平衡设为5600 K，只改调色字段。'
      '两位孙代理各自自主发现并按需加载适用技能，读取项目、修改自己的字段并回读验证，再向协调子代理报告结果。'
      '协调子代理必须等待两位孙代理完成，审阅他们的报告，再回读合并项目，只返回JSON，包含 durationSeconds、preserveAudio、exposureEv、whiteBalanceKelvin。'
      '主代理等待并审阅协调子代理的汇总报告，然后调用渲染工具导出实际视频。主代理与协调子代理只负责各自的协调工作，不加载执行技能或代写业务字段。'
      '最终只返回JSON，包含 outputVideo、durationSeconds（实际导出值）、exposureEv、whiteBalanceKelvin、originalAudioPreserved。';
  final prompt = multiLevel ? multiLevelPrompt : singleLevelPrompt;
  final run = await manager.prompt(session.id, prompt, maxTurns: 24);
  var timedOut = false;
  final result = await run.done.timeout(
    timeout,
    onTimeout: () async {
      timedOut = true;
      await run.cancel();
      return run.done;
    },
  );
  final directChildren = <SessionSnapshot>[
    for (final id in result.childSessionIds) ?await store.read(id),
  ];
  final grandchildren = <SessionSnapshot>[
    for (final child in directChildren)
      for (final id in child.childSessionIds) ?await store.read(id),
  ];
  final children = multiLevel ? grandchildren : directChildren;
  final current = await media.state();
  final render = current['render'] as Map?;
  final rootResults = _results(result);
  final rootRequests = traced.requests
      .where((entry) => entry['actor'] == '/root')
      .toList();
  final childReports = <Map<String, Object?>>[];
  for (final child in children) {
    final name = child.agentState['name'] as String;
    final requests = traced.requests
        .where((entry) => entry['actor'] == name)
        .toList();
    final results = _results(child);
    final loaded = results
        .where((entry) => entry['tool'] == 'load_skill')
        .map((entry) => (entry['data'] as Map)['id'])
        .toSet();
    final skillId = loaded.length == 1 ? loaded.single : null;
    final editing = skillId == 'video-editing';
    final validSkill = {'video-editing', 'color-grading'}.contains(skillId);
    final writeTool = editing ? 'set_cut_duration' : 'set_color_grade';
    final peerWrite = editing ? 'set_color_grade' : 'set_cut_duration';
    final writes = results
        .where((entry) => entry['tool'] == writeTool)
        .toList();
    final reads = results
        .where((entry) => entry['tool'] == 'read_media_project')
        .toList();
    final ownRequests = requests
        .where(
          (entry) => (entry['calls'] as List).any(
            (raw) => {
              'read_media_project',
              'set_cut_duration',
              'set_color_grade',
            }.contains((raw as Map)['name']),
          ),
        )
        .toList();
    final firstCatalog = requests.isEmpty
        ? null
        : requests.first['catalog'] as Map?;
    final firstIds = (firstCatalog?['skills'] as List? ?? [])
        .map((raw) => (raw as Map)['id'])
        .toSet();
    final checks = <String, bool>{
      'completed': child.status == RunStatus.completed,
      'initialCatalogOnly':
          requests.isNotEmpty &&
          requests.first['containsSkillBody'] == false &&
          firstIds.containsAll({'video-editing', 'color-grading'}),
      'oneRelevantSkill': validSkill && loaded.length == 1,
      'noUnrelatedSkillAttempts':
          validSkill &&
          requests.every(
            (entry) => (entry['calls'] as List).every(
              (raw) =>
                  (raw as Map)['name'] != 'load_skill' ||
                  (raw['arguments'] as Map)['id'] == skillId,
            ),
          ),
      'bodyBeforeBusinessCalls':
          ownRequests.isNotEmpty &&
          ownRequests.every(
            (entry) =>
                (entry['activeSkills'] as List).length == 1 &&
                (entry['activeSkills'] as List).contains(skillId) &&
                (entry['tools'] as List).contains(writeTool),
          ),
      'readBeforeWrite':
          reads.isNotEmpty &&
          writes.isNotEmpty &&
          (reads.first['historyIndex'] as int) <
              (writes.first['historyIndex'] as int),
      'ownFieldWrite':
          writes.isNotEmpty &&
          media.actions.any(
            (action) =>
                action['sessionId'] == child.id && action['tool'] == writeTool,
          ),
      'noPeerFieldWrite': requests.every(
        (entry) => (entry['calls'] as List).every(
          (raw) =>
              (raw as Map)['name'] != peerWrite &&
              raw['name'] != 'render_media_project',
        ),
      ),
      'readbackVerified':
          writes.isNotEmpty &&
          reads.any(
            (entry) =>
                (entry['historyIndex'] as int) >
                    (writes.last['historyIndex'] as int) &&
                (editing
                    ? (entry['data'] as Map)['durationSeconds'] == 10 &&
                          (entry['data'] as Map)['preserveAudio'] == true
                    : _gradeMatches(entry['data'] as Map)),
          ),
    };
    childReports.add({
      'assignedTask': child.history
          .skip(child.runStart)
          .firstWhere(
            (message) =>
                message.role == MessageRole.user && !message.runtimeNotice,
          )
          .text,
      'id': child.id,
      'name': name,
      'parentSessionId': child.parentSessionId,
      'depth': child.depth,
      'status': child.status.name,
      'loadedSkillIds': loaded.toList(),
      'checks': checks,
      'passed': checks.values.every((value) => value),
      'toolResults': results,
      if (child.error != null) 'error': child.error,
    });
  }
  final editingOwner = media.actions
      .where((action) => action['tool'] == 'set_cut_duration')
      .map((action) => action['sessionId'])
      .toSet();
  final gradingOwner = media.actions
      .where((action) => action['tool'] == 'set_color_grade')
      .map((action) => action['sessionId'])
      .toSet();
  final childIds = children.map((child) => child.id).toSet();
  final answer = result.history.last.text;
  final summary = _summary(answer);
  final coordinatorReports = <Map<String, Object?>>[];
  if (multiLevel) {
    for (final child in directChildren) {
      final name = child.agentState['name'];
      final requests = traced.requests
          .where((entry) => entry['actor'] == name)
          .toList();
      final results = _results(child);
      final ownChildren = grandchildren
          .where((entry) => entry.parentSessionId == child.id)
          .toList();
      final combined = _summary(child.history.last.text);
      final verifiedReads = requests
          .where(
            (entry) => (entry['calls'] as List).any(
              (raw) => (raw as Map)['name'] == 'read_media_project',
            ),
          )
          .toList();
      final coordinatorChecks = <String, bool>{
        'completed': child.status == RunStatus.completed,
        'initialCatalogOnly':
            requests.isNotEmpty && requests.first['containsSkillBody'] == false,
        'noExecutionSkills':
            requests.isNotEmpty &&
            requests.every(
              (entry) =>
                  (entry['activeSkills'] as List).isEmpty &&
                  (entry['calls'] as List).every(
                    (raw) => (raw as Map)['name'] != 'load_skill',
                  ),
            ),
        'modelSpawnedTwoGrandchildren':
            ownChildren.length == 2 &&
            results.where((entry) => entry['tool'] == 'spawn_agent').length ==
                2,
        'receivedBothGrandchildReportsBeforeReadback': verifiedReads.any(
          (request) => _received([request], ownChildren),
        ),
        'mergedProjectReadback': results.any(
          (entry) =>
              entry['tool'] == 'read_media_project' &&
              (entry['data'] as Map)['durationSeconds'] == 10 &&
              (entry['data'] as Map)['preserveAudio'] == true &&
              _gradeMatches(entry['data'] as Map),
        ),
        'summaryMatchesMergedProject':
            combined != null &&
            combined['durationSeconds'] == current['durationSeconds'] &&
            combined['preserveAudio'] == current['preserveAudio'] &&
            _gradeMatches(combined),
        'noWorkerWritesOrRender': requests.every(
          (entry) => (entry['calls'] as List).every(
            (raw) => !{
              'set_cut_duration',
              'set_color_grade',
              'render_media_project',
            }.contains((raw as Map)['name']),
          ),
        ),
      };
      coordinatorReports.add({
        'id': child.id,
        'name': name,
        'parentSessionId': child.parentSessionId,
        'depth': child.depth,
        'childSessionIds': child.childSessionIds,
        'status': child.status.name,
        'checks': coordinatorChecks,
        'passed': coordinatorChecks.values.every((value) => value),
        'toolResults': results,
        'finalAnswer': child.history.last.text,
        'error': child.error,
      });
    }
  }
  final checks = <String, bool>{
    'parentCompleted': result.status == RunStatus.completed && !timedOut,
    'singleUserTask':
        result.history
            .where(
              (message) =>
                  message.role == MessageRole.user && !message.runtimeNotice,
            )
            .length ==
        1,
    if (!multiLevel)
      'modelSpawnedTwoChildren':
          children.length == 2 &&
          rootResults.where((entry) => entry['tool'] == 'spawn_agent').length ==
              2,
    'childrenIndependentlySelectedDifferentSkills':
        childReports.length == 2 &&
        childReports.every((child) => child['passed'] == true) &&
        childReports
            .map((child) => (child['loadedSkillIds'] as List).single)
            .toSet()
            .containsAll({'video-editing', 'color-grading'}),
    'distinctChildFieldOwners':
        editingOwner.length == 1 &&
        gradingOwner.length == 1 &&
        editingOwner.single != gradingOwner.single &&
        childIds.contains(editingOwner.single) &&
        childIds.contains(gradingOwner.single),
    'parentDoesNotLoadChildSkills': rootRequests.every(
      (entry) =>
          (entry['activeSkills'] as List).isEmpty &&
          (entry['calls'] as List).every(
            (raw) => (raw as Map)['name'] != 'load_skill',
          ),
    ),
    if (multiLevel) ...{
      'modelCreatedExpectedHierarchy':
          directChildren.length == 1 &&
          grandchildren.length == 2 &&
          rootResults.where((entry) => entry['tool'] == 'spawn_agent').length ==
              1 &&
          directChildren.every(
            (child) => child.parentSessionId == session.id && child.depth == 1,
          ) &&
          grandchildren.every(
            (child) =>
                child.parentSessionId == directChildren.single.id &&
                child.depth == 2 &&
                child.childSessionIds.isEmpty,
          ),
      'coordinatorVerifiedAndAggregatedGrandchildren':
          coordinatorReports.length == 1 &&
          coordinatorReports.every((entry) => entry['passed'] == true),
      'rootReceivedCoordinatorReportBeforeRender': rootRequests.any(
        (entry) =>
            (entry['calls'] as List).any(
              (raw) => (raw as Map)['name'] == 'render_media_project',
            ) &&
            _received([entry], directChildren),
      ),
    },
    'parentReadbackAndRender':
        rootResults.any(
          (entry) =>
              {
                'read_media_project',
                'render_media_project',
              }.contains(entry['tool']) &&
              (entry['data'] as Map)['durationSeconds'] is num &&
              (((entry['data'] as Map)['durationSeconds'] as num) - 10).abs() <
                  0.1 &&
              _gradeMatches(entry['data'] as Map),
        ) &&
        media.actions.any(
          (action) =>
              action['tool'] == 'render_media_project' &&
              action['sessionId'] == session.id,
        ),
    'sharedProjectPreservesBothChanges':
        current['durationSeconds'] == 10 &&
        current['preserveAudio'] == true &&
        _gradeMatches(current),
    'renderUsesLatestProjectVersion':
        render != null && render['projectVersion'] == current['version'],
    'childrenCompletedBeforeRender':
        render?['childrenCompleteAtRenderStart'] == true,
    'actualVideoDuration':
        render != null &&
        render['hasVideo'] == true &&
        ((render['durationSeconds'] as num) - 10).abs() < 0.1 &&
        await File(media.outputPath).exists(),
    'decodedAudioPreserved':
        render != null &&
        render['hasAudio'] == true &&
        render['originalAudioPreserved'] == true &&
        render['sourceAudioHash'] == render['outputAudioHash'],
    'measuredExposureAndWhiteBalanceChange':
        render != null &&
        (render['outputFrame'] as Map)['meanLuma'] >
            (render['sourceFrame'] as Map)['meanLuma'] + 1 &&
        (render['outputFrame'] as Map)['redToBlueRatio'] >
            (render['sourceFrame'] as Map)['redToBlueRatio'] * 1.01,
    'parentSummaryMatchesArtifact':
        render != null &&
        summary != null &&
        summary['outputVideo'] == media.outputPath &&
        summary['durationSeconds'] is num &&
        ((summary['durationSeconds'] as num) -
                    (render['durationSeconds'] as num))
                .abs() <
            0.1 &&
        _gradeMatches(summary) &&
        summary['originalAudioPreserved'] == true,
  };
  return {
    'passed': checks.values.every((value) => value),
    'checks': checks,
    'runDirectory': directory.path,
    'sourceVideo': media.sourcePath,
    'outputVideo': media.outputPath,
    'projectFile': media.projectPath,
    'parentSessionId': session.id,
    'parentStatus': result.status.name,
    'parentError': result.error,
    'timedOut': timedOut,
    'multiLevel': multiLevel,
    'prompt': prompt,
    'children': childReports,
    'coordinators': coordinatorReports,
    'sessionTree': [
      for (final snapshot in [result, ...directChildren, ...grandchildren])
        {
          'id': snapshot.id,
          'name': snapshot.agentState['name'],
          'parentSessionId': snapshot.parentSessionId,
          'depth': snapshot.depth,
          'status': snapshot.status.name,
          'childSessionIds': snapshot.childSessionIds,
        },
    ],
    'requests': traced.requests,
    'businessActions': media.actions,
    'project': {...current}..remove('receipts'),
    'finalAnswer': answer,
  };
}
