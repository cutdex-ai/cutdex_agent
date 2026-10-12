import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;
import 'live_semantic_conflict_validate.dart' show DurationResource;

const userChoiceConflictPrompt =
    '这是受控冲突测试，分两阶段执行。第一阶段用于复现冲突：同时启动两个子代理'
    '修改 shared-clip 的同一个 target_duration_seconds 字段，一个严格10秒，另一个'
    '严格20秒；两者都先读取再按版本提交，必须各完成首轮读写尝试，版本冲突时报告'
    '给你并结束本轮。首轮写入仅用于实验，不代表最终目标优先级。第二阶段由你读取'
    '核对状态，明确说明最终10秒和最终20秒互斥，用 request_user_input 询问我选择'
    '哪个最终目标，然后等待我的真实输入；收到输入后只执行所选目标，重新读取版本、'
    '核验最终字段，并汇总。';

/// Verifies durable suspension and model continuation with a host-supplied choice.
///
/// The default chooser simulates selecting the opposite of the initial winning
/// write, exercising an actual change after the run stops to ask the user.
/// Supply [freeText] and [expectedDuration] to test a replacement goal without
/// choosing an option. The expected value is used only to check tool outcomes.
Future<Map<String, Object?>> validateUserChoiceConflict(
  ModelAdapter model, {
  Future<String> Function(UserInputRequest)? choose,
  String? freeText,
  int? expectedDuration,
}) async {
  if (freeText != null &&
      (freeText.trim().isEmpty ||
          choose != null ||
          expectedDuration == null ||
          expectedDuration < 1 ||
          expectedDuration > 120)) {
    throw ArgumentError(
      'Free text requires an expected duration 1..120 and no option chooser',
    );
  }
  if (freeText == null && expectedDuration != null) {
    throw ArgumentError('expectedDuration is only used with free text');
  }
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-choice-live-',
  );
  final sessions = Directory('${directory.path}/sessions');
  final store = FileSessionStore(sessions);
  final actions = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  final file = File('${directory.path}/shared-clip.json');
  final resource = DurationResource(file, store, actions);
  final traced = LiveTraceModel(model, trace);
  SessionManager managerFor(SessionStore storage) => SessionManager(
    model: traced,
    store: storage,
    tools: resource.tools,
    contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
    multiAgent: MultiAgentConfig(
      maxDepth: 1,
      maxChildren: 2,
      childMaxTurns: 10,
      maxDelegatedTurns: 60,
    ),
  );
  AgentRun? active;
  Timer? deadline;
  var timedOut = false;
  void arm(AgentRun run) {
    active = run;
    deadline?.cancel();
    deadline = Timer(const Duration(minutes: 5), () {
      timedOut = true;
      unawaited(run.cancel());
    });
  }

  try {
    await file.writeAsString(jsonEncode(resource.state), flush: true);
    final manager = managerFor(store);
    final session = await manager.create(
      system:
          'Use actual tools and report verified state in concise Chinese. '
          'During the controlled experiment complete the two initial attempts first. '
          'A child receiving resource_conflict reports to parent and finishes. '
          'The primary coordinator asks the user about conflicting final goals.',
    );
    final run = await manager.prompt(
      session.id,
      userChoiceConflictPrompt,
      maxTurns: 30,
    );
    arm(run);
    final waiting = await run.done;
    deadline?.cancel();
    final question = waiting.pendingUserInput;
    final atWait = jsonDecode(await file.readAsString());
    final actionsAtWait = actions.length;
    final callsAtWait = trace.length;
    final commitsAtWait = actions.where((a) => a['kind'] == 'commit').length;
    final checks = <String, bool>{
      'modelAskedAndSuspended':
          waiting.status == RunStatus.waitingUser && question != null,
      'bothInitialChildWritesAttempted':
          resource.initialReads.length == 2 &&
          resource.initialReads.values.every((v) => v == 1) &&
          resource.initialWriteTargets.values.toSet().containsAll({10, 20}),
      'oneInitialCommitAndStaleRejection':
          commitsAtWait == 1 &&
          actions.any(
            (a) =>
                a['kind'] == 'version_conflict' &&
                jsonEncode(a['state_before']) == jsonEncode(a['state_after']),
          ),
      'questionExplainsOppositeTargets':
          question != null &&
          '${question.question} ${question.reason} ${question.options.map((o) => o.label).join(' ')}'
              .contains('10') &&
          '${question.question} ${question.reason} ${question.options.map((o) => o.label).join(' ')}'
              .contains('20'),
    };
    if (question == null) {
      return {
        'passed': false,
        'checks': checks,
        'parentStatus': waiting.status.name,
        'parentError': waiting.error,
        'finalAnswer': waiting.history.last.text,
        'resourceActions': actions,
        'modelTrace': trace,
        'finalResource': atWait,
      };
    }
    stdout.writeln('USER_INPUT_REQUEST ${jsonEncode(question.toJson())}');
    // Reopen disk storage and verify resume cannot choose or dispatch a model.
    final reopened = managerFor(FileSessionStore(sessions));
    final blocked = await reopened.resume(session.id);
    arm(blocked);
    final restored = await blocked.done;
    deadline?.cancel();
    final callsAfterUnansweredResume = trace.length;
    checks['restartPreservesQuestionAndRun'] =
        restored.status == RunStatus.waitingUser &&
        restored.pendingUserInput?.id == question.id &&
        restored.runId == waiting.runId &&
        jsonEncode(restored.childSessionIds) ==
            jsonEncode(waiting.childSessionIds);
    checks['resumeWithoutAnswerDoesNoWork'] =
        trace.length == callsAtWait &&
        actions.length == actionsAtWait &&
        jsonEncode(jsonDecode(await file.readAsString())) == jsonEncode(atWait);
    final simulatedTarget = (atWait as Map)['target_duration_seconds'] == 10
        ? 20
        : 10;
    final optionId = freeText != null
        ? null
        : choose == null
        ? question.options
              .singleWhere(
                (o) =>
                    o.label.contains('$simulatedTarget') &&
                    !o.label.contains('${simulatedTarget == 20 ? 10 : 20}'),
              )
              .id
        : await choose(question);
    final selected = optionId == null
        ? null
        : question.options.singleWhere((o) => o.id == optionId);
    final selectedDuration = freeText != null
        ? expectedDuration!
        : RegExp(r'20').hasMatch(selected!.label)
        ? 20
        : 10;
    final answerSource = freeText != null
        ? 'simulated_user_free_text_by_test_host'
        : choose == null
        ? 'simulated_user_choice_by_test_host'
        : 'test_chooser';
    checks['noWorkUntilAnswerSubmitted'] =
        trace.length == callsAtWait &&
        actions.length == actionsAtWait &&
        jsonEncode(jsonDecode(await file.readAsString())) == jsonEncode(atWait);
    resource.record('host_user_answer', {
      'request_id': question.id,
      'option_id': ?optionId,
      if (selected != null) 'label': selected.label,
      'text': ?freeText,
      'source': answerSource,
    });
    final continued = await reopened.answerUserInput(
      session.id,
      requestId: question.id,
      optionId: optionId,
      text: freeText,
      maxTurns: 40,
    );
    arm(continued);
    final result = await continued.done;
    deadline?.cancel();
    final disk = (jsonDecode(await file.readAsString()) as Map)
        .cast<String, Object?>();
    final children = [
      for (final id in result.childSessionIds) (await store.read(id))!,
    ];
    final afterAnswer = actions.skip(actionsAtWait).toList();
    final finalAnswer = result.history.last.text;
    checks.addAll({
      'sameRunResumedAndQuestionCleared':
          result.runId == waiting.runId && result.pendingUserInput == null,
      'onlyChosenTargetWrittenAfterAnswer': afterAnswer
          .where((a) => a['kind'] == 'commit')
          .every((a) => a['target_duration_seconds'] == selectedDuration),
      'onlyChosenTargetAttemptedAfterAnswer': afterAnswer
          .where((a) => a['kind'] == 'write_attempt')
          .every((a) => a['target_duration_seconds'] == selectedDuration),
      'chosenTargetVerifiedByParent':
          disk['target_duration_seconds'] == selectedDuration &&
          afterAnswer.any(
            (a) =>
                a['kind'] == 'read' &&
                a['agent_id'] == result.id &&
                a['revision'] == disk['revision'] &&
                a['target_duration_seconds'] == selectedDuration,
          ),
      'childrenSettled':
          children.length == 2 &&
          children.every(
            (c) =>
                {RunStatus.completed, RunStatus.cancelled}.contains(c.status),
          ),
      'parentCompleted': result.status == RunStatus.completed && !timedOut,
    });
    if (freeText != null) {
      final userResult = result.history
          .where((m) => m.role == MessageRole.tool && m.resultId == question.id)
          .single;
      final answerData = (jsonDecode(userResult.text) as Map)['data'] as Map;
      checks.addAll({
        'freeTextDeliveredWithoutOption':
            answerData['text'] == freeText &&
            !answerData.containsKey('option_id'),
        'newTargetActuallyCommitted': afterAnswer.any(
          (a) =>
              a['kind'] == 'commit' &&
              a['target_duration_seconds'] == selectedDuration,
        ),
        'summaryMentionsNewTarget': RegExp(
          '$selectedDuration\\s*秒',
        ).hasMatch(finalAnswer),
        'summaryExplainsOriginalGoalsCancelled':
            RegExp(r'取消|不再|放弃|作废|替代|撤销|废弃').hasMatch(finalAnswer) &&
            RegExp(r'原|10|20|互斥').hasMatch(finalAnswer),
      });
    }
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'prompt': userChoiceConflictPrompt,
      'question': question.toJson(),
      'answerSource': answerSource,
      'answerText': ?freeText,
      'selectedOption': selected?.toJson(),
      'selectedDuration': selectedDuration,
      'statusAtQuestion': waiting.status.name,
      'resourceAtQuestion': atWait,
      'modelCallsAtQuestion': callsAtWait,
      'modelCallsAfterUnansweredResume': callsAfterUnansweredResume,
      'parentRunId': result.runId,
      'parentStatus': result.status.name,
      'parentTurns': result.turns,
      'parentError': result.error,
      'finalResource': disk,
      'finalAnswer': finalAnswer,
      'resourceActions': actions,
      'modelTrace': trace,
      'parentMessages': result.history.map((m) => m.toJson()).toList(),
      'children': [
        for (final child in children)
          {
            'name': child.agentState['name'],
            'status': child.status.name,
            'turns': child.turns,
            'messages': child.history.map((m) => m.toJson()).toList(),
          },
      ],
    };
  } finally {
    deadline?.cancel();
    if (active != null && !active!.isSettled) await active!.cancel();
    await directory.delete(recursive: true);
  }
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateUserChoiceConflict,
  label: 'LIVE_USER_CHOICE',
);
