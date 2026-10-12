import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;
import 'live_tree_cancel_validate.dart' show readCancellationTree;
import 'live_uncooperative_cancel_validate.dart'
    show uncooperativeOldMarker, uncooperativeNewMarker;
import 'remote_resource_test_processes.dart';

/// Cancels a model-created tree around resource save and service failure.
Future<Map<String, Object?>> validateAdmittedWriteCancellation(
  ModelAdapter model, {
  required int oldWriterDepth,
  bool wrongNewGoal = false,
  bool crashServiceBeforeSave = false,
  bool crashServiceAfterSave = false,
  bool cancelAfterServiceCrash = false,
}) async {
  final crashService = crashServiceBeforeSave || crashServiceAfterSave;
  if (crashServiceBeforeSave && crashServiceAfterSave ||
      crashServiceAfterSave && !cancelAfterServiceCrash) {
    throw ArgumentError('Post-save crash mode cancels after the service crash');
  }
  if (cancelAfterServiceCrash && !crashService) {
    throw ArgumentError('Cancel-after-crash requires service crash mode');
  }
  final directory = await Directory.systemTemp.createTemp('cutdex-admitted-');
  final resourceDirectory = Directory.fromUri(
    directory.uri.resolve('resources/'),
  );
  final sessions = FileSessionStore(
    Directory.fromUri(directory.uri.resolve('sessions/')),
  );
  final key = base64Url.encode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  RemoteTestService? service;
  RemoteTestSubmitter? worker;
  RemoteTestSubmitter? retry;
  RemoteTestSubmitter? preNewRetry;
  OnlineResourceAuthorization? online;
  AgentRun? old;
  AgentRun? fresh;
  Timer? deadline;
  final ready = Completer<void>();
  final rootHeld = Completer<void>();
  final trace = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  final modelGenerations = <Map<String, Object?>>[];
  RemoteWritePermit? oldPermit;
  String? operationId;
  String? oldWriterId;
  Map<String, Object?>? retryResult;
  Map<String, Object?>? preNewRetryResult;
  Map<String, Object?>? journalAfterCrash;
  Map<String, Object?>? journalAfterRestart;
  Map<String, Object?>? restartedState;
  Map<String, Object?>? unknownRecovery;
  Map<String, Object?>? receiptBeforeCrash;
  Map<String, Object?>? receiptAfterCrash;
  Map<String, Object?>? receiptAfterRestart;
  Map<String, Object?>? recoveryDuringNewTask;
  var originalResponsePendingAtCrash = false;
  final servicePids = <int>[];
  int? crashExitCode;
  var cancellationPendingWhileOffline = false;
  var phase = 'old';
  var prematureModelCalls = 0;
  void record(String kind, [Map<String, Object?> details = const {}]) {
    actions.add({
      'sequence': actions.length + 1,
      'kind': kind,
      'phase': phase,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    stdout.writeln('ADMITTED_WRITE $kind');
  }

  AgentTool tool(
    String name,
    Future<ToolResult> Function(ToolCall, ToolContext) execute, {
    bool value = false,
  }) => AgentTool(
    name: name,
    alwaysAvailable: true,
    description: switch (name) {
      'hold_old_root' =>
        'Old root must hold until host cancellation, not wait_agent.',
      'uncooperative_old_tool' =>
        'Assigned old writer launches one real independent resource write and waits for cancellation.',
      'write_new_value' =>
        'New writer saves the requested value after host cancellation completes.',
      _ =>
        'Root verifies actual resource and tests an old worker retry; report actual a and polluted without repairing.',
    },
    parameters: {
      'type': 'object',
      'properties': value
          ? {
              'value': {'type': 'integer'},
            }
          : <String, Object?>{},
      if (value) 'required': ['value'],
      'additionalProperties': false,
    },
    validate: (args) => value
        ? args.length == 1 && args['value'] is int
              ? null
              : 'Supply integer value'
        : args.isEmpty
        ? null
        : 'No arguments',
    execute: execute,
  );
  Future<Map<String, Object?>> durableView() async {
    // Independent process reads the flushed journal, not the service's cache.
    final snapshot = (await FileSessionStore(
      resourceDirectory,
    ).read('shared'))!;
    return {
      for (final k in ['data', 'generation', 'resourceRevision'])
        k: snapshot.agentState[k],
    };
  }

  Future<Map<String, Object?>?> receiptView() async {
    final snapshot = (await FileSessionStore(
      resourceDirectory,
    ).read('shared'))!;
    final raw = (snapshot.agentState['receipts'] as Map)[operationId] as Map?;
    return (raw?['result'] as Map?)?.cast<String, Object?>();
  }

  try {
    service = await RemoteTestService.start(
      resourceDirectory,
      key,
      leaseDuration: const Duration(seconds: 2),
      requireOnlineAuthorization: true,
      holdAdmittedSave: !crashServiceAfterSave,
      holdCommittedResponse: crashServiceAfterSave,
    );
    servicePids.add(service.process.pid);
    final endpoint = service.url;
    final client = FencedResourceClient(
      baseUrl: service.url,
      resourceId: 'shared',
      controlKey: key,
      requestTimeout: const Duration(seconds: 10),
    );
    online = await OnlineResourceAuthorization.start();
    final authority = RemoteResourceTaskAuthority(
      client,
      onlineAuthorization: online,
    );
    final auditedModel = _GenerationModel(
      model,
      client,
      modelGenerations,
      () => prematureModelCalls++,
    );
    final manager = SessionManager(
      model: LiveTraceModel(auditedModel, trace),
      store: sessions,
      contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
      resourceTaskAuthority: authority,
      multiAgent: MultiAgentConfig(
        maxConcurrent: 2,
        maxDepth: 2,
        maxChildren: 3,
        childMaxTurns: 10,
        maxDelegatedTurns: 60,
      ),
      tools: [
        tool('hold_old_root', (_, ctx) async {
          if ((await sessions.read(ctx.sessionId))!.depth != 0) {
            return ToolResult('Root only', isError: true);
          }
          if (!rootHeld.isCompleted) rootHeld.complete();
          await ctx.cancellation.whenCancelled;
          return ToolResult('Root cancelled', isError: true);
        }),
        tool('uncooperative_old_tool', (_, ctx) async {
          if ((await sessions.read(ctx.sessionId))!.depth != oldWriterDepth) {
            return ToolResult('Assigned old writer only', isError: true);
          }
          if (worker != null) {
            return ToolResult('Already launched', isError: true);
          }
          final workerService = service;
          if (workerService == null) throw StateError('Service not started');
          oldPermit = authority.permitFor(ctx);
          operationId = ctx.operationId;
          oldWriterId = ctx.sessionId;
          worker = await RemoteTestSubmitter.start(
            workerService.url,
            oldPermit!,
            operationId!,
            waitForGo: false,
          );
          while ((await workerService.control('state'))['held'] != 1) {
            if (ctx.cancellation.isCancelled) {
              return ToolResult('Setup stopped', isError: true);
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          ready.complete();
          await ctx.cancellation.whenCancelled;
          // The external worker ignores this token and keeps its original POST.
          return ToolResult('Old local tool cancelled', isError: true);
        }),
        tool('write_new_value', (call, ctx) async {
          if ((await sessions.read(ctx.sessionId))!.depth != 1) {
            return ToolResult('New child only', isError: true);
          }
          final result = await client.commit(
            authority.permitFor(ctx),
            operationId: ctx.operationId,
            patch: {'a': wrongNewGoal ? 12 : call.arguments['value']},
          );
          record('new_write', {'result': result.toJson()});
          return result;
        }, value: true),
        tool('inspect_current_value', (_, ctx) async {
          if ((await sessions.read(ctx.sessionId))!.depth != 0) {
            return ToolResult('Root only', isError: true);
          }
          if (retry == null) {
            final retryService = service;
            if (retryService == null) throw StateError('Service not started');
            retry = await RemoteTestSubmitter.start(
              retryService.url,
              oldPermit!,
              operationId!,
              waitForGo: true,
            );
            await retry!.go(retryService.url);
            retryResult = await retry!.result.timeout(
              const Duration(seconds: 30),
            );
            record('old_worker_retried_during_new_task', retryResult!);
          }
          final state = (await client.inspect()).data;
          if (crashServiceAfterSave) {
            final recovery = await client.recover(oldPermit!, operationId!);
            recoveryDuringNewTask = {
              'status': recovery.status.name,
              'result': recovery.result?.toJson(),
            };
            record(
              'old_receipt_recovered_during_new_task',
              recoveryDuringNewTask!,
            );
          }
          return ToolResult(
            'Actual resource',
            data: {
              'a': (state['data'] as Map)['a'],
              'polluted': (state['data'] as Map)['a'] != 15,
              'resourceRevision': state['resourceRevision'],
            },
          );
        }),
      ],
    );
    final session = await manager.create(
      system:
          'Use the real tools to carry out assigned tasks. Delegate writes, verify resources and report honestly. Do not repair old worker writes.',
    );
    old = await manager.prompt(
      session.id,
      oldWriterDepth == 1
          ? '$uncooperativeOldMarker：创建writer子代理，让它调用uncooperative_old_tool一次。主代理随后必须hold_old_root，不要wait_agent。spawn_agent使用fork_turns=none。'
          : '$uncooperativeOldMarker：创建leader子代理，指示leader创建writer孙代理，writer调用uncooperative_old_tool一次，leader再wait_agent。主代理必须hold_old_root，不要wait_agent。所有spawn_agent使用fork_turns=none。',
      maxTurns: 20,
    );
    var oldDoneSettled = false;
    final oldDone = _outcome(old.done);
    unawaited(oldDone.then((_) => oldDoneSettled = true));
    await Future.wait([
      ready.future,
      rootHeld.future,
    ]).timeout(const Duration(minutes: 2));
    final activeTree = await readCancellationTree(sessions, old.snapshot);
    await service.control('release');
    Map<String, Object?> state;
    final boundary = crashServiceAfterSave ? 'pendingResponse' : 'pendingSave';
    final waitForSave = Stopwatch()..start();
    do {
      state = await service.control('state');
      if (waitForSave.elapsed > const Duration(seconds: 30)) {
        throw StateError('Old write never reached $boundary boundary');
      }
      if (state[boundary] == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } while (state[boundary] == null);
    final beforeCancel = await durableView();
    if (crashServiceAfterSave) receiptBeforeCrash = await receiptView();
    final approved = (state['onlineChecks'] as List)
        .cast<Map>()
        .where((c) => c['runId'] == oldPermit!.runId && c['allowed'] == true)
        .toList();
    record(
      crashServiceAfterSave
          ? 'write_and_receipt_saved_response_withheld'
          : 'online_admitted_but_not_saved',
      {'serviceState': state, 'journal': beforeCancel},
    );
    final observedSubmission = _submissionOutcome(worker!);
    var responseSettled = false;
    unawaited(observedSubmission.then((_) => responseSettled = true));
    Future<void> crash() async {
      final crashedService = service;
      if (crashedService == null) throw StateError('Service not started');
      originalResponsePendingAtCrash = !responseSettled;
      crashExitCode = await crashedService.crash();
      journalAfterCrash = await durableView();
      if (crashServiceAfterSave) receiptAfterCrash = await receiptView();
      record(
        crashServiceAfterSave
            ? 'resource_service_killed_before_success_response'
            : 'resource_service_killed_without_save',
        {
          'pid': crashedService.process.pid,
          'exitCode': crashExitCode,
          'journal': journalAfterCrash,
        },
      );
    }

    if (cancelAfterServiceCrash) await crash();
    phase = 'cancelling';
    record('root_cancel_requested');
    var cancellationSettled = false;
    final cancellation = _outcome(old.cancel());
    unawaited(cancellation.then((_) => cancellationSettled = true));
    Future<String?> probe() async {
      try {
        final unexpected = await manager.prompt(
          session.id,
          'EARLY_ADMITTED_WRITE_PROBE',
          maxTurns: 1,
        );
        await _outcome(unexpected.cancel());
        return null;
      } catch (error) {
        return error.toString();
      }
    }

    final immediateStartError = await probe();
    final held = Stopwatch()..start();
    // Longer than both the two-second lease and control RPC timeout. Time is
    // only a test stressor; runtime stop proof still requires the resource lock.
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final pendingState = cancelAfterServiceCrash
        ? state
        : await service.control('state');
    final journalWhileWaiting = await durableView();
    final cancelPendingBeyondLease = !cancellationSettled && !oldDoneSettled;
    final afterExpiryStartError = await probe();
    final heldMs = held.elapsedMilliseconds;
    record(
      crashServiceAfterSave
          ? 'cancel_waits_beyond_lease_after_response_loss'
          : 'cancel_waits_beyond_lease_for_admitted_save',
      {
        'cancelPending': !cancellationSettled,
        'donePending': !oldDoneSettled,
        'heldMs': heldMs,
        'serviceState': pendingState,
        'journal': journalWhileWaiting,
        'newStartError': afterExpiryStartError,
      },
    );
    if (crashService) {
      if (!cancelAfterServiceCrash) await crash();
      // A dead service is not a stop acknowledgement. Allow control timeouts
      // and lease expiry while the endpoint remains offline before restarting.
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      cancellationPendingWhileOffline = !cancellationSettled && !oldDoneSettled;
      final offlineStartError = await probe();
      record('cancel_still_waits_for_resource_stop_while_offline', {
        'cancelPending': !cancellationSettled,
        'donePending': !oldDoneSettled,
        'newStartError': offlineStartError,
        'journal': await durableView(),
      });
      if (offlineStartError?.contains('writer') != true) {
        throw StateError(
          'Replacement escaped writer lease while service offline',
        );
      }
      service = await RemoteTestService.start(
        resourceDirectory,
        key,
        port: endpoint.port,
        leaseDuration: const Duration(seconds: 2),
        requireOnlineAuthorization: true,
      );
      servicePids.add(service.process.pid);
      journalAfterRestart = await durableView();
      if (crashServiceAfterSave) receiptAfterRestart = await receiptView();
      restartedState = await service.control('state');
      record('resource_service_restarted_same_directory', {
        'pids': servicePids,
        'journal': journalAfterRestart,
      });
    } else {
      await service.control('release_save');
    }
    final oldSubmission = await observedSubmission.timeout(
      const Duration(seconds: 30),
    );
    final cancelResult = await cancellation.timeout(
      const Duration(seconds: 30),
    );
    final oldDoneResult = await oldDone.timeout(const Duration(seconds: 30));
    final afterCancel = (await client.inspect()).data;
    final saveAfterCancel = await service.control('state');
    final stopProofs = authority.stopProofs;
    record(
      crashService
          ? 'service_restarted_then_cancel_confirmed'
          : 'admitted_write_saved_then_cancel_confirmed',
      {
        'oldSubmission': oldSubmission,
        'cancellation': cancelResult,
        'resource': afterCancel,
        'stopProofs': stopProofs,
      },
    );
    if (crashService) {
      final recovery = await client.recover(oldPermit!, operationId!);
      unknownRecovery = {
        'status': recovery.status.name,
        'result': recovery.result?.toJson(),
      };
      preNewRetry = await RemoteTestSubmitter.start(
        service.url,
        oldPermit!,
        operationId!,
        waitForGo: true,
      );
      await preNewRetry.go(service.url);
      preNewRetryResult = await preNewRetry.result.timeout(
        const Duration(seconds: 30),
      );
      record('old_retry_before_new_generation_rejected', preNewRetryResult);
    }
    final oldTree = [for (final s in activeTree) (await sessions.read(s.id))!];
    final baseline = oldTree
        .skip(1)
        .map((s) => jsonEncode(s.toJson()))
        .toList();
    phase = 'new';
    fresh = await manager.prompt(
      session.id,
      '$uncooperativeNewMarker：新任务，创建新的writer子代理，fork_turns=none，message包含$uncooperativeNewMarker，让它write_new_value(value:15)一次。主代理wait_agent后必须inspect_current_value核验实际资源并测试旧进程重试。不修复，仅回复JSON {"a":实际整数,"polluted":实际布尔值}。',
      maxTurns: 20,
    );
    deadline = Timer(
      const Duration(minutes: 2),
      () => unawaited(fresh!.cancel()),
    );
    final finished = await fresh.done;
    deadline.cancel();
    final finalResource = (await client.inspect()).data;
    final journalFinal = await durableView();
    final newTree = await readCancellationTree(sessions, finished);
    final audit = (finalResource['audit'] as List).cast<Map>();
    final oldWrites = audit
        .where((a) => a['kind'] == 'committed' && a['generation'] == 1)
        .toList();
    final newWrites = audit
        .where((a) => a['kind'] == 'committed' && a['generation'] == 2)
        .toList();
    final newActivation = audit.firstWhere(
      (a) => a['kind'] == 'activated' && a['generation'] == 2,
    );
    final retryData = (retryResult?['result'] as Map?)?['data'] as Map?;
    Map? summary;
    try {
      final text = finished.history.last.text;
      summary =
          jsonDecode(
                text.substring(text.indexOf('{'), text.lastIndexOf('}') + 1),
              )
              as Map;
    } catch (_) {}
    final checks = <String, bool>{
      'modelCreatedExpectedActiveTree':
          activeTree.length == oldWriterDepth + 1 &&
          activeTree.every((s) => s.status == RunStatus.running),
      'oldWriterAtAssignedDepth': activeTree.any(
        (s) => s.id == oldWriterId && s.depth == oldWriterDepth,
      ),
      'workerAndServiceAreIndependentProcesses':
          worker!.process.pid != pid &&
          service.process.pid != pid &&
          worker!.process.pid != service.process.pid,
      'oldTransactionPassedRealOnlineCheck': approved.length == 1,
      crashServiceAfterSave
          ? 'pauseIsAfterCommitBeforeSuccessResponse'
          : 'pauseIsAtActualStorageSave': crashServiceAfterSave
          ? (state['pendingResponse'] as Map)['operationId'] == operationId &&
                (state['pendingResponse'] as Map)['responseSent'] == false
          : (state['pendingSave'] as Map)['operationId'] == operationId &&
                state['saveCompleted'] == false,
      crashServiceAfterSave
              ? 'oldValueAlreadyDurableBeforeCancellation'
              : 'diskUnchangedBeforeCancellation':
          beforeCancel['resourceRevision'] == (crashServiceAfterSave ? 2 : 1) &&
          (beforeCancel['data'] as Map)['a'] ==
              (crashServiceAfterSave ? 10 : 99),
      'cancelAndDoneStillPendingBeyondLease': cancelPendingBeyondLease,
      if (!cancelAfterServiceCrash)
        'actualSaveStillHeldBeyondLease':
            pendingState['saveCompleted'] == false &&
            pendingState['pendingSave'] != null,
      'diskUnchangedThroughoutCancellationWait':
          jsonEncode(beforeCancel) == jsonEncode(journalWhileWaiting),
      'noNewGenerationDuringWait': journalWhileWaiting['generation'] == 1,
      'immediateReplacementBlocked':
          immediateStartError?.contains('writer') == true,
      'replacementStillBlockedBeyondLease':
          afterExpiryStartError?.contains('writer') == true,
      'noModelWorkFromReplacementProbes': prematureModelCalls == 0,
      crashService
          ? 'oldOriginalRequestHasUnknownTransportOutcome'
          : 'oldOriginalRequestEventuallyCommitted': crashService
          ? oldSubmission['transportOutcome'] == 'unknown'
          : oldSubmission['status'] == 200 &&
                (oldSubmission['result'] as Map)['isError'] != true &&
                oldSubmission['operationId'] == operationId,
      crashService
              ? 'cancelCompletedAfterRestartStopConfirmation'
              : 'cancelCompletedAfterActualSave':
          (crashService
              ? saveAfterCancel['saveCompleted'] == false
              : saveAfterCancel['saveCompleted'] == true) &&
          cancelResult['status'] == 'cancelled' &&
          oldDoneResult['status'] == 'cancelled',
      'entireTreeHasStopProofBeforeNewTask':
          stopProofs.length == activeTree.length &&
          stopProofs.every((p) => p['stopped'] == true),
      crashServiceBeforeSave
              ? 'crashedOldWriteNeverBecameDurable'
              : 'oldValueDurableBeforeNewTask':
          afterCancel['generation'] == 1 &&
          afterCancel['resourceRevision'] == (crashServiceBeforeSave ? 1 : 2) &&
          (afterCancel['data'] as Map)['a'] ==
              (crashServiceBeforeSave ? 99 : 10),
      crashServiceBeforeSave
          ? 'noOldTransactionInDurableAudit'
          : 'onlyOneOldTransaction': crashServiceBeforeSave
          ? oldWrites.isEmpty
          : oldWrites.length == 1 &&
                (oldWrites.single['patch'] as Map)['a'] == 10,
      if (!crashServiceBeforeSave)
        'oldCommitPrecedesNewActivation':
            oldWrites.length == 1 &&
            (oldWrites.single['sequence'] as int) <
                (newActivation['sequence'] as int),
      'newTaskCompletedWithFreshRunId':
          finished.status == RunStatus.completed &&
          finished.runId != old.snapshot.runId,
      'newModelRequestsOnlyAfterGenerationTwo':
          modelGenerations.isNotEmpty &&
          modelGenerations.every((g) => g['generation'] == 2),
      'newChildActuallyWrote15':
          newWrites.length == 1 &&
          (newWrites.single['patch'] as Map)['a'] == 15 &&
          newTree.skip(1).any((s) => s.runId == newWrites.single['runId']),
      'oldRetryDuringNewTaskRejected':
          retryResult?['status'] == 409 &&
          retryData?['code'] == 'stale_task_generation' &&
          retryData?['executed'] == false,
      'oldRetryDidNotAddBusinessRevision':
          finalResource['resourceRevision'] == (crashServiceBeforeSave ? 2 : 3),
      'actualResourceNotPolluted':
          (finalResource['data'] as Map)['a'] == 15 &&
          (journalFinal['data'] as Map)['a'] == 15,
      'mainAgentSummarizedActualState':
          summary?['a'] == 15 && summary?['polluted'] == false,
      'oldDescendantSnapshotsUnchangedDuringNewTask':
          (await Future.wait(
            oldTree.skip(1).map((s) => sessions.read(s.id)),
          )).indexed.every(
            (entry) => jsonEncode(entry.$2!.toJson()) == baseline[entry.$1],
          ),
    };
    if (crashService) {
      final preNewData = (preNewRetryResult!['result'] as Map)['data'] as Map;
      checks.addAll({
        'serviceActuallyKilledAndReplaced':
            crashExitCode != null &&
            crashExitCode != 0 &&
            servicePids.length == 2 &&
            servicePids.first != servicePids.last,
        'cancellationHeldWriterLeaseWhileServiceOffline':
            cancellationPendingWhileOffline,
        'journalUnchangedAcrossCrashAndRestart':
            jsonEncode(beforeCancel) == jsonEncode(journalAfterCrash) &&
            jsonEncode(beforeCancel) == jsonEncode(journalAfterRestart),
        'restartHasNoInMemoryApprovalOrPendingSave':
            restartedState!['pendingSave'] == null &&
            restartedState['pendingResponse'] == null &&
            (restartedState['onlineChecks'] as List).isEmpty,
        crashServiceAfterSave
                ? 'lostSuccessResponseRecoveredWithoutReplay'
                : 'missingReceiptClassifiedUnknownWithoutReplay':
            unknownRecovery!['status'] ==
            (crashServiceAfterSave ? 'completed' : 'unknown'),
        'oldRetryBeforeNewGenerationDeniedByStop':
            preNewRetryResult['status'] == 409 &&
            [
              'task_write_lease_expired',
              'task_write_revoked',
            ].contains(preNewData['code']) &&
            preNewData['executed'] == false &&
            preNewData['currentGeneration'] == 1,
      });
    }
    if (crashServiceAfterSave) {
      final saved = (state['pendingResponse'] as Map)['result'];
      checks.addAll({
        'originalClientHadNoResponseAtCrash': originalResponsePendingAtCrash,
        'receiptFlushedBeforeCrashAndPreserved':
            receiptBeforeCrash != null &&
            jsonEncode(receiptBeforeCrash) == jsonEncode(saved) &&
            jsonEncode(receiptBeforeCrash) == jsonEncode(receiptAfterCrash) &&
            jsonEncode(receiptBeforeCrash) == jsonEncode(receiptAfterRestart),
        'recoveryReturnsExactOriginalReceiptAfterStop':
            jsonEncode(unknownRecovery!['result']) ==
            jsonEncode(receiptBeforeCrash),
        'historicalReceiptStillRecoverableDuringNewTask':
            recoveryDuringNewTask!['status'] == 'completed' &&
            jsonEncode(recoveryDuringNewTask!['result']) ==
                jsonEncode(receiptBeforeCrash),
        'onlyOriginalAndNewWriteInBusinessAudit':
            audit.where((a) => a['kind'] == 'committed').length == 2,
      });
    }
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'oldWriterDepth': oldWriterDepth,
      'crashServiceBeforeSave': crashServiceBeforeSave,
      'crashServiceAfterSave': crashServiceAfterSave,
      'receiptBeforeCrash': receiptBeforeCrash,
      'receiptAfterCrash': receiptAfterCrash,
      'receiptAfterRestart': receiptAfterRestart,
      'recoveryDuringNewTask': recoveryDuringNewTask,
      'cancelAfterServiceCrash': cancelAfterServiceCrash,
      'crashExitCode': crashExitCode,
      'servicePids': servicePids,
      'journalAfterCrash': journalAfterCrash,
      'journalAfterRestart': journalAfterRestart,
      'restartedState': restartedState,
      'unknownRecovery': unknownRecovery,
      'oldRetryBeforeNewGeneration': preNewRetryResult,
      'hostPid': pid,
      'servicePid': service.process.pid,
      'workerPid': worker!.process.pid,
      'heldMs': heldMs,
      'preSaveState': state,
      'commitBoundaryState': state,
      'pendingCancellationState': pendingState,
      'journalBeforeCancel': beforeCancel,
      'journalWhileWaiting': journalWhileWaiting,
      'resourceAfterCancellation': afterCancel,
      'finalResource': finalResource,
      'immediateStartError': immediateStartError,
      'afterExpiryStartError': afterExpiryStartError,
      'oldSubmission': oldSubmission,
      'oldRetry': retryResult,
      'cancellationOutcome': cancelResult,
      'oldDoneOutcome': oldDoneResult,
      'oldStopProofs': stopProofs,
      'newModelGenerations': modelGenerations,
      'finalAnswer': finished.history.last.text,
      'hostActions': actions,
      'modelTrace': trace,
      'newTaskPolluted': (finalResource['data'] as Map)['a'] != 15,
    };
  } finally {
    deadline?.cancel();
    if (service != null) {
      try {
        await service.control('release');
        await service.control('release_save');
        await service.control('release_response');
      } catch (_) {}
    }
    if (fresh != null && !fresh.isSettled) await _outcome(fresh.cancel());
    if (old != null && !old.isSettled) {
      await _outcome(old.cancel());
      await _outcome(old.done);
    }
    await retry?.close();
    await preNewRetry?.close();
    await worker?.close();
    await online?.close();
    await service?.close();
    await directory.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _submissionOutcome(
  RemoteTestSubmitter worker,
) async {
  try {
    return await worker.result;
  } catch (error) {
    // Connection loss is unknown, never an assertion that no write occurred.
    return {
      'transportOutcome': 'unknown',
      'errorType': error.runtimeType.toString(),
      'pid': worker.process.pid,
      'exitCode': await worker.process.exitCode,
    };
  }
}

Future<Map<String, Object?>> _outcome(Future<SessionSnapshot> future) async {
  try {
    return {'status': (await future).status.name};
  } catch (error) {
    return {
      'error': error.toString(),
      'errorType': error.runtimeType.toString(),
    };
  }
}

class _GenerationModel implements ModelAdapter {
  _GenerationModel(
    this.model,
    this.client,
    this.observations,
    this.onPremature,
  );
  final ModelAdapter model;
  final FencedResourceClient client;
  final List<Map<String, Object?>> observations;
  final void Function() onPremature;
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    final user = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    if (user.contains('EARLY_ADMITTED_WRITE_PROBE')) onPremature();
    if (user.contains(uncooperativeNewMarker)) {
      final state = (await client.inspect()).data;
      observations.add({
        'generation': state['generation'],
        'at': DateTime.now().toUtc().toIso8601String(),
      });
    }
    yield* model.stream(request, cancellation);
  }
}

Future<Map<String, Object?>> validateAdmittedWriteModes(
  ModelAdapter model,
) async {
  final cases = <Map<String, Object?>>[];
  for (final depth in [1, 2]) {
    cases.add(
      await validateAdmittedWriteCancellation(model, oldWriterDepth: depth),
    );
  }
  return {
    'passed': cases.every((c) => c['passed'] == true),
    'checks': {
      for (final c in cases)
        'admitted_write_depth_${c['oldWriterDepth']}': c['passed'] == true,
    },
    'cases': cases,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateAdmittedWriteModes,
  label: 'REMOTE_ADMITTED_WRITE',
);
