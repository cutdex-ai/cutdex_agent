import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

/// The business goal supplied to the model without naming a skill.
enum SkillDiscoveryTask { editing, colorGrading }

class _ObservedSkills implements SkillProvider {
  _ObservedSkills(this.directory, this.log);
  final DirectorySkillProvider directory;
  final void Function(String) log;
  final List<String> loadedIds = [];
  final Map<String, AgentSkill> bodies = {};
  final Map<String, SkillDescriptor> descriptors = {};
  @override
  Future<List<SkillDescriptor>> list(CancellationToken cancellation) async {
    final catalog = await directory.list(cancellation);
    descriptors
      ..clear()
      ..addEntries(catalog.map((entry) => MapEntry(entry.id, entry)));
    return catalog;
  }

  @override
  Future<AgentSkill?> load(String id, CancellationToken cancellation) async {
    loadedIds.add(id);
    log('   [宿主读取 SKILL.md 正文] $id');
    final skill = await directory.load(id, cancellation);
    if (skill != null) bodies[id] = skill;
    return skill;
  }
}

class _TraceModel implements ModelAdapter {
  _TraceModel(this.model, this.skills, this.log);
  final ModelAdapter model;
  final _ObservedSkills skills;
  final void Function(String) log;
  final List<Map<String, Object?>> trace = [];
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    final catalogLines = request.system
        .split('\n')
        .where((line) => line.startsWith('{"skills":'));
    final catalog = catalogLines.isEmpty
        ? null
        : jsonDecode(catalogLines.last) as Map;
    final entry = <String, Object?>{
      'request': trace.length + 1,
      'catalog': catalog,
      'bodiesReadBeforeRequest': skills.loadedIds.toList(),
      'activeSkillIds': [
        for (final skill in skills.bodies.values)
          if (request.system.contains(skill.instructions)) skill.descriptor.id,
      ],
      'containsSkillSource': request.system.contains('Skill source:'),
      'tools': request.tools.map((tool) => tool.name).toList(),
      'calls': <Map<String, Object?>>[],
    };
    trace.add(entry);
    log(
      '   [模型请求 ${trace.length}] 正文 ${entry['activeSkillIds'] as List}；可用工具 ${entry['tools']}',
    );
    await for (final event in model.stream(request, cancellation)) {
      if (event is ModelResponse) {
        entry['calls'] = event.calls.map((call) => call.toJson()).toList();
      }
      yield event;
    }
  }
}

class _ExampleClip {
  double durationSeconds = 12;
  bool originalAudioPreserved = true;
  double exposureEv = 0;
  int whiteBalanceKelvin = 6500;
  Map<String, Object?> get state => {
    'durationSeconds': durationSeconds,
    'originalAudioPreserved': originalAudioPreserved,
    'exposureEv': exposureEv,
    'whiteBalanceKelvin': whiteBalanceKelvin,
  };
  List<AgentTool> get tools => [
    AgentTool(
      name: 'read_example_clip',
      description: '读取内存中示例素材的实际时长和音频状态',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': <String, Object?>{},
      },
      validate: (args) => args.isEmpty ? null : '不接受参数',
      execute: (_, context) async {
        context.cancellation.throwIfCancelled();
        return ToolResult(
          '素材当前状态',
          data: {
            'durationSeconds': durationSeconds,
            'originalAudioPreserved': originalAudioPreserved,
          },
        );
      },
    ),
    AgentTool(
      name: 'read_example_color',
      description: '读取内存中示例素材的曝光补偿、白平衡、时长和音频状态',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': <String, Object?>{},
      },
      validate: (args) => args.isEmpty ? null : '不接受参数',
      execute: (_, context) async {
        context.cancellation.throwIfCancelled();
        return ToolResult('素材当前调色状态', data: state);
      },
    ),
    AgentTool(
      name: 'grade_example_clip',
      description: '修改内存中示例素材的曝光补偿和白平衡，保持时长与音频不变',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'exposureEv': {'type': 'number', 'minimum': -2, 'maximum': 2},
          'whiteBalanceKelvin': {
            'type': 'integer',
            'minimum': 2000,
            'maximum': 10000,
          },
        },
        'required': ['exposureEv', 'whiteBalanceKelvin'],
      },
      validate: (args) {
        final exposure = args['exposureEv'];
        final balance = args['whiteBalanceKelvin'];
        if (args.keys.any(
              (key) => !{'exposureEv', 'whiteBalanceKelvin'}.contains(key),
            ) ||
            exposure is! num ||
            !exposure.isFinite ||
            exposure < -2 ||
            exposure > 2 ||
            balance is! int ||
            balance < 2000 ||
            balance > 10000) {
          return '曝光补偿须在 -2 到 2 EV，白平衡须为 2000 到 10000 K 的整数';
        }
        return null;
      },
      execute: (call, context) async {
        context.cancellation.throwIfCancelled();
        exposureEv = (call.arguments['exposureEv'] as num).toDouble();
        whiteBalanceKelvin = call.arguments['whiteBalanceKelvin'] as int;
        return ToolResult('调色已完成');
      },
    ),
    AgentTool(
      name: 'trim_example_clip',
      description: '缩短内存中的示例素材并保留原始音频',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0},
          'preserveAudio': {'type': 'boolean'},
        },
        'required': ['durationSeconds', 'preserveAudio'],
      },
      validate: (args) {
        final seconds = args['durationSeconds'];
        if (args.keys.any(
              (key) => !{'durationSeconds', 'preserveAudio'}.contains(key),
            ) ||
            seconds is! num ||
            !seconds.isFinite ||
            seconds <= 0 ||
            seconds > durationSeconds ||
            args['preserveAudio'] != true) {
          return '时长须大于 0 且不超过素材长度，并设置 preserveAudio: true';
        }
        return null;
      },
      execute: (call, context) async {
        context.cancellation.throwIfCancelled();
        durationSeconds = (call.arguments['durationSeconds'] as num).toDouble();
        originalAudioPreserved = call.arguments['preserveAudio'] as bool;
        return ToolResult('剪辑已完成');
      },
    ),
  ];
}

List<Map<String, Object?>> _successfulCalls(SessionSnapshot snapshot) {
  final calls = <String, ToolCall>{};
  final results = <Map<String, Object?>>[];
  for (var i = 0; i < snapshot.history.length; i++) {
    final message = snapshot.history[i];
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
        ? {
            'id': (result.data['skill'] as Map)['id'],
            'version': (result.data['skill'] as Map)['version'],
          }
        : result.data;
    results.add({
      'name': call.name,
      'arguments': call.arguments,
      'data': data,
      'historyIndex': i,
    });
  }
  return results;
}

/// Runs one task and checks actual discovery, loading and business operations.
///
/// The same verifier accepts an offline adapter or a live HTTP adapter. The
/// host specifies only [skillDirectory], never skill IDs or forced tool choices.
/// Evidence includes model requests, successful journaled calls and final state.
/// A claimed completion without this evidence fails the report.
Future<Map<String, Object?>> validateSkillDiscovery(
  ModelAdapter model, {
  required String skillDirectory,
  SkillDiscoveryTask task = SkillDiscoveryTask.editing,
  void Function(String)? onLog,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final log = onLog ?? (_) {};
  final editing = task == SkillDiscoveryTask.editing;
  final keyword = editing ? '剪辑' : '调色';
  final prompt = editing
      ? '请把示例视频剪辑为 10 秒，保留原始音频并验证结果。'
      : '请给示例视频调色：将曝光补偿设为 +0.5 EV、白平衡设为 5600 K，保持原始时长和音频不变，并验证结果。';
  final readTool = editing ? 'read_example_clip' : 'read_example_color';
  final writeTool = editing ? 'trim_example_clip' : 'grade_example_clip';
  const allBusinessTools = {
    'read_example_clip',
    'trim_example_clip',
    'read_example_color',
    'grade_example_clip',
  };
  final provider = _ObservedSkills(DirectorySkillProvider(skillDirectory), log);
  final clip = _ExampleClip();
  final traced = _TraceModel(model, provider, log);
  final manager = SessionManager(
    model: traced,
    store: InMemorySessionStore(),
    tools: clip.tools,
    contextBuilder: HarnessContextBuilder(
      skills: provider,
      maxOutputTokens: 2048,
    ),
  );
  final session = await manager.create(
    system: '根据用户目标自主选择相关技能。执行业务操作前，按需加载适合任务的技能并遵循正文流程。只根据工具实际结果回答。',
  );
  final run = await manager.prompt(session.id, prompt, maxTurns: 16);
  final subscription = run.events.listen((event) {
    if (event.kind == AgentEventKind.toolStarted) {
      log('   [模型调用] ${event.text}');
    }
  });
  var timedOut = false;
  late final SessionSnapshot result;
  try {
    result = await run.done.timeout(
      timeout,
      onTimeout: () async {
        timedOut = true;
        await run.cancel();
        return run.done;
      },
    );
  } finally {
    await subscription.cancel();
  }
  final successful = _successfulCalls(result);
  final loads = successful
      .where((call) => call['name'] == 'load_skill')
      .toList();
  final reads = successful.where((call) => call['name'] == readTool).toList();
  final writes = successful.where((call) => call['name'] == writeTool).toList();
  final selectedIds = loads
      .map((call) => (call['data'] as Map)['id'] as String)
      .toSet();
  final first = traced.trace.firstOrNull;
  final firstCatalog = first?['catalog'] as Map?;
  final initialDescriptors = (firstCatalog?['skills'] as List? ?? [])
      .cast<Map>();
  final discoveredIds = {
    ...initialDescriptors.map((entry) => entry['id']),
    for (final call in successful.where(
      (call) => call['name'] == 'list_skills',
    ))
      for (final entry in (call['data'] as Map)['skills'] as List)
        (entry as Map)['id'],
  };
  final relevant = provider.descriptors.values
      .where((entry) => entry.description.contains(keyword))
      .map((entry) => entry.id)
      .toSet();
  final businessBeforeLoad = successful.any(
    (call) =>
        allBusinessTools.contains(call['name']) &&
        (loads.isEmpty ||
            (call['historyIndex'] as int) <
                (loads.first['historyIndex'] as int)),
  );
  final businessRequests = traced.trace
      .where(
        (entry) => (entry['calls'] as List).any(
          (call) => allBusinessTools.contains((call as Map)['name']),
        ),
      )
      .toList();
  final checks = <String, bool>{
    'completed': result.status == RunStatus.completed && !timedOut,
    'noHostPreselection': session.skillIds.isEmpty,
    'initialCatalogOnly':
        firstCatalog != null &&
        first?['containsSkillSource'] == false &&
        (first?['bodiesReadBeforeRequest'] as List).isEmpty &&
        !(first?['tools'] as List).any(allBusinessTools.contains),
    'modelSelectedRelevantSkill':
        selectedIds.length == 1 &&
        relevant.contains(selectedIds.single) &&
        discoveredIds.contains(selectedIds.single),
    'onlySelectedBodiesRead':
        selectedIds.isNotEmpty &&
        provider.loadedIds.every(selectedIds.contains),
    'noUnrelatedSkillLoads':
        provider.loadedIds.every(relevant.contains) &&
        traced.trace.every(
          (entry) => (entry['calls'] as List).every((raw) {
            final call = raw as Map;
            return call['name'] != 'load_skill' ||
                relevant.contains((call['arguments'] as Map)['id']);
          }),
        ),
    'noUnrelatedBusinessCalls': traced.trace.every(
      (entry) => (entry['calls'] as List).every(
        (raw) =>
            !allBusinessTools.contains((raw as Map)['name']) ||
            {readTool, writeTool}.contains(raw['name']),
      ),
    ),
    'bodyDeliveredBeforeBusinessCalls':
        selectedIds.isNotEmpty &&
        !businessBeforeLoad &&
        businessRequests.isNotEmpty &&
        businessRequests.every(
          (entry) =>
              (entry['activeSkillIds'] as List).any(selectedIds.contains) &&
              (entry['tools'] as List).contains(readTool) &&
              (entry['tools'] as List).contains(writeTool),
        ),
    editing ? 'readBeforeTrim' : 'readBeforeGrade':
        reads.isNotEmpty &&
        writes.isNotEmpty &&
        (reads.first['historyIndex'] as int) <
            (writes.first['historyIndex'] as int),
    editing ? 'trimExecuted' : 'gradeExecuted': writes.isNotEmpty,
    editing ? 'verifiedAfterTrim' : 'verifiedAfterGrade':
        writes.isNotEmpty &&
        reads.any(
          (call) =>
              (call['historyIndex'] as int) >
                  (writes.last['historyIndex'] as int) &&
              (editing
                  ? (call['data'] as Map)['durationSeconds'] == 10
                  : (call['data'] as Map)['exposureEv'] == 0.5 &&
                        (call['data'] as Map)['whiteBalanceKelvin'] == 5600 &&
                        (call['data'] as Map)['durationSeconds'] == 12) &&
              (call['data'] as Map)['originalAudioPreserved'] == true,
        ),
    'finalStateCorrect':
        (editing
            ? clip.durationSeconds == 10
            : clip.exposureEv == 0.5 && clip.whiteBalanceKelvin == 5600) &&
        clip.originalAudioPreserved,
    'unrelatedStateUnchanged': editing
        ? clip.exposureEv == 0 && clip.whiteBalanceKelvin == 6500
        : clip.durationSeconds == 12 && clip.originalAudioPreserved,
  };
  return {
    'passed': checks.values.every((value) => value),
    'task': task.name,
    'prompt': prompt,
    'sessionId': session.id,
    'checks': checks,
    'status': result.status.name,
    'failure': result.failure?.name,
    'error': result.error,
    'timedOut': timedOut,
    'modelRequests': traced.trace,
    'successfulToolCalls': successful,
    'loadedSkillIds': provider.loadedIds,
    'finalState': clip.state,
    'answer': result.history
        .lastWhere(
          (message) => message.role == MessageRole.assistant,
          orElse: () => AgentMessage(role: MessageRole.assistant, text: ''),
        )
        .text,
  };
}

/// Checks task-specific skill selection using two isolated sessions.
///
/// Both tasks receive the same catalog and all business tools. Expected IDs
/// are checked only after execution and are never supplied to the model.
Future<Map<String, Object?>> validateSkillTaskSelection(
  ModelAdapter model, {
  required String skillDirectory,
  void Function(String)? onLog,
}) async {
  final cases = <String, Map<String, Object?>>{};
  for (final task in SkillDiscoveryTask.values) {
    onLog?.call('\n任务：${task.name}');
    cases[task.name] = await validateSkillDiscovery(
      model,
      skillDirectory: skillDirectory,
      task: task,
      onLog: onLog == null
          ? null
          : (message) => onLog('[${task.name}] $message'),
    );
  }
  final editing = cases['editing']!;
  final grading = cases['colorGrading']!;
  bool onlyLoaded(Map<String, Object?> report, String id) {
    final ids = (report['loadedSkillIds'] as List).toSet();
    return ids.length == 1 && ids.contains(id);
  }

  bool bothInCatalog(Map<String, Object?> report) {
    final requests = report['modelRequests'] as List;
    if (requests.isEmpty) return false;
    final catalog = (requests.first as Map)['catalog'] as Map?;
    final ids = (catalog?['skills'] as List? ?? [])
        .map((entry) => (entry as Map)['id'])
        .toSet();
    return ids.containsAll({'video-editing', 'color-grading'});
  }

  final checks = {
    'editingPassed': editing['passed'] == true,
    'colorGradingPassed': grading['passed'] == true,
    'editingOnlyLoadsVideoEditing': onlyLoaded(editing, 'video-editing'),
    'colorGradingOnlyLoadsColorGrading': onlyLoaded(grading, 'color-grading'),
    'bothTasksSeeBothSkills': bothInCatalog(editing) && bothInCatalog(grading),
    'distinctSessions': editing['sessionId'] != grading['sessionId'],
  };
  return {
    'passed': checks.values.every((value) => value),
    'checks': checks,
    'cases': cases,
  };
}
