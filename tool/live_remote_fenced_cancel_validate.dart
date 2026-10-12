import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

import 'live_multi_agent_validate.dart' show LiveTraceModel, runLiveValidation;
import 'live_tree_cancel_validate.dart' show readCancellationTree;
import 'live_uncooperative_cancel_validate.dart'
    show uncooperativeOldMarker, uncooperativeNewMarker, delayedResultMarker;
import 'remote_resource_test_processes.dart';

/// Tests server-side fencing of delayed submissions from an independent worker.
///
/// The model creates the agent tree; the old tool launches an actual Dart
/// process that ignores cancellation and retains its original portable permit.
/// No local ResourceCommitGuard or client-side cancellation check gates its POST.
Future<Map<String, Object?>> validateRemoteFencedCancellation(
  ModelAdapter model, {
  required int oldWriterDepth,
  bool restartService = false,
  RemoteRevokeFault revocationFault = RemoteRevokeFault.none,
  bool protectUnconfirmedWindow = false,
  bool protectCancellationWaiting = false,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'cutdex-remote-fence-',
  );
  final sessions = FileSessionStore(
    Directory.fromUri(directory.uri.resolve('sessions/')),
  );
  final resourceDirectory = Directory.fromUri(
    directory.uri.resolve('resources/'),
  );
  final controlKey = base64Url.encode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  RemoteTestService? service;
  RemoteTestSubmitter? worker;
  OnlineResourceAuthorization? onlineAuthorization;
  RemoteWritePermit? capturedOldPermit;
  Map<String, Object?>? pendingCancellationResource;
  Map<String, Object?>? pendingCancellationLease;
  var cancellationStillPendingAtSubmission = false;
  AgentRun? old;
  AgentRun? fresh;
  Timer? deadline;
  var timedOut = false;
  var phase = 'old';
  var sequence = 0;
  final actions = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  final ready = Completer<void>();
  final heldRoot = Completer<void>();
  final cancellationObservationReady = Completer<void>();
  Map<String, Object?>? oldActor;
  Map<String, Object?>? beforeLate;
  Map<String, Object?>? workerResult;
  final servicePids = <int>[];
  final savedWorkerInputs = <String>[];
  final activationObservations = <Map<String, Object?>>[];
  Map<String, Object?>? cancellationOutcome;
  Map<String, Object?>? oldDoneOutcome;
  Map<String, Object?>? faultStateBeforeNew;
  Map<String, Object?>? faultStateAfterLateRevokes;
  String? prematureStartError;
  String? startAfterCancelError;
  var prematureModelCalls = 0;
  Map<String, Object?>? unconfirmedWindowResource;
  List<Map<String, Object?>>? oldStopProofs;
  Future<AgentRun>? replacementOpening;
  void record(String kind, [Map<String, Object?> details = const {}]) {
    actions.add({
      'sequence': ++sequence,
      'phase': phase,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    stdout.writeln('REMOTE_FENCE $kind');
  }

  Future<Map<String, Object?>> actor(ToolContext context) async {
    final s = (await sessions.read(context.sessionId))!;
    return {
      'agentId': s.id,
      'runId': s.runId,
      'depth': s.depth,
      'name': s.agentState['name'] ?? '/root',
    };
  }

  AgentTool tool(
    String name,
    Future<ToolResult> Function(ToolCall, ToolContext) execute, {
    bool takesValue = false,
  }) => AgentTool(
    name: name,
    alwaysAvailable: true,
    description: switch (name) {
      'hold_old_root' =>
        'Old root waits for host cancellation. Do not wait_agent instead.',
      'uncooperative_old_tool' =>
        'Assigned old writer starts a real external delayed operation; only this writer may call it.',
      'write_new_value' =>
        'New direct child writes the new goal through the remote resource service.',
      _ =>
        'Root reads actual remote resource after host releases the old delayed operation; do not repair.',
    },
    parameters: {
      'type': 'object',
      'properties': takesValue
          ? {
              'value': {'type': 'integer'},
            }
          : <String, Object?>{},
      if (takesValue) 'required': ['value'],
      'additionalProperties': false,
    },
    validate: (a) => takesValue
        ? (a.length == 1 && a['value'] is int ? null : 'Supply integer value')
        : (a.isEmpty ? null : 'No arguments'),
    execute: execute,
  );
  try {
    service = await RemoteTestService.start(
      resourceDirectory,
      controlKey,
      revocationFault: revocationFault,
      leaseDuration: protectCancellationWaiting
          ? const Duration(seconds: 10)
          : protectUnconfirmedWindow
          ? const Duration(seconds: 2)
          : revocationFault == RemoteRevokeFault.none
          ? const Duration(seconds: 10)
          : null,
      holdReplacementActivation: protectUnconfirmedWindow,
      requireOnlineAuthorization: protectCancellationWaiting,
    );
    servicePids.add(service.process.pid);
    final endpoint = service.url;
    final client = FencedResourceClient(
      baseUrl: endpoint,
      resourceId: 'shared',
      controlKey: controlKey,
      requestTimeout: protectUnconfirmedWindow
          ? const Duration(seconds: 10)
          : revocationFault == RemoteRevokeFault.none
          ? const Duration(minutes: 2)
          : const Duration(seconds: 1),
    );
    if (protectCancellationWaiting) {
      onlineAuthorization = await OnlineResourceAuthorization.start();
    }
    final authority = RemoteResourceTaskAuthority(
      client,
      onlineAuthorization: onlineAuthorization,
    );
    final initial = (await client.inspect()).data;
    final manager = SessionManager(
      model: LiveTraceModel(
        revocationFault == RemoteRevokeFault.none
            ? model
            : _ActivationAuditModel(
                model,
                client,
                activationObservations,
                onPremature: () => prematureModelCalls++,
              ),
        trace,
      ),
      store: sessions,
      resourceTaskAuthority: authority,
      contextBuilder: HarnessContextBuilder(maxOutputTokens: 2048),
      multiAgent: MultiAgentConfig(
        maxConcurrent: 2,
        maxDepth: 2,
        maxChildren: 3,
        childMaxTurns: 10,
        maxDelegatedTurns: 60,
      ),
      tools: [
        tool('hold_old_root', (_, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != 0) return ToolResult('Root only', isError: true);
          record('root_held', who);
          if (!heldRoot.isCompleted) heldRoot.complete();
          await ctx.cancellation.whenCancelled;
          if (revocationFault != RemoteRevokeFault.none) {
            // Hold local cleanup briefly so the first immediate-start probe
            // deterministically occurs before the root writer lease is released.
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          return ToolResult('Old hold cancelled', isError: true);
        }),
        tool('uncooperative_old_tool', (_, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != oldWriterDepth) {
            return ToolResult('Assigned old writer only', isError: true);
          }
          if (worker != null) {
            return ToolResult('Already started old operation', isError: true);
          }
          final permit = authority.permitFor(ctx);
          capturedOldPermit = permit;
          savedWorkerInputs.add(ctx.operationId);
          oldActor = who;
          worker = await RemoteTestSubmitter.start(
            endpoint,
            permit,
            ctx.operationId,
            waitForGo: restartService,
          );
          record('external_worker_started', {
            ...who,
            'pid': worker!.process.pid,
            'generation': permit.generation,
            'rootRunId': permit.rootRunId,
          });
          if (!restartService) {
            while ((await service!.control('state'))['held'] != 1) {
              if (ctx.cancellation.isCancelled) {
                return ToolResult('Setup interrupted', isError: true);
              }
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            record('old_http_request_received_and_held');
          }
          if (!ready.isCompleted) ready.complete();
          await ctx.cancellation.whenCancelled;
          // The external worker and the server's pending request remain alive.
          return ToolResult(
            delayedResultMarker,
            data: {'backgroundStillPending': true},
          );
        }),
        tool('write_new_value', (call, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != 1) {
            return ToolResult('New child only', isError: true);
          }
          if (revocationFault != RemoteRevokeFault.none) {
            // The new run may open immediately while the host finishes reading
            // fault evidence. Hold only its business write until those reads
            // finish; old writes are still fenced exclusively by the server.
            await Future.any<void>([
              cancellationObservationReady.future,
              ctx.cancellation.whenCancelled,
            ]);
            if (ctx.cancellation.isCancelled) {
              return ToolResult(
                'Observation interrupted',
                isError: true,
                data: {'executed': false},
              );
            }
          }
          final result = await client.commit(
            authority.permitFor(ctx),
            operationId: ctx.operationId,
            patch: {'a': call.arguments['value']},
          );
          record('new_remote_submission', {...who, 'result': result.toJson()});
          return result;
        }, takesValue: true),
        tool('inspect_current_value', (_, ctx) async {
          final who = await actor(ctx);
          if (who['depth'] != 0) return ToolResult('Root only', isError: true);
          beforeLate ??= (await client.inspect()).data;
          record('new_value_before_old_submit', {'resource': beforeLate});
          if (revocationFault == RemoteRevokeFault.timeoutBeforeCommit) {
            final revokeService = service;
            if (revokeService == null) throw StateError('Service not started');
            await revokeService.control('release_revokes');
            while (true) {
              final state = await revokeService.control('state');
              final faults = (state['revokeFaults'] as List).cast<Map>();
              if (faults.length == oldWriterDepth + 1 &&
                  faults.every(
                    (f) =>
                        f['applied'] == true &&
                        f['currentGenerationAtApply'] == 2,
                  )) {
                faultStateAfterLateRevokes = state;
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            record('timed_out_revokes_applied_during_new_task', {
              'state': faultStateAfterLateRevokes,
              'newTaskRunning': fresh != null && !fresh.isSettled,
            });
          }
          if (restartService) {
            await worker!.go(service!.url);
          } else {
            await service!.control('release');
          }
          workerResult ??= await worker!.result.timeout(
            const Duration(seconds: 30),
          );
          record('old_external_result', workerResult!);
          final actual = (await client.inspect()).data;
          record('authoritative_resource_after_old_submit', actual);
          return ToolResult(
            'Actual remote resource',
            data: {
              'a': (actual['data'] as Map)['a'],
              'polluted': (actual['data'] as Map)['a'] != 15,
              'resourceRevision': actual['resourceRevision'],
            },
          );
        }),
      ],
    );
    final session = await manager.create(
      system:
          'Follow current assigned tasks with actual tools. Delegate writes, inspect actual state, and report honestly. '
          'Do not repair external writes in this controlled experiment.',
    );
    old = await manager.prompt(
      session.id,
      oldWriterDepth == 1
          ? '$uncooperativeOldMarker：当前初始化任务尚未取消。创建writer子代理，让它调用uncooperative_old_tool一次；'
                '主代理随后必须hold_old_root，不要wait_agent。spawn_agent使用fork_turns=none。'
          : '$uncooperativeOldMarker：当前初始化任务尚未取消。主代理创建leader，然后必须hold_old_root，不要wait_agent。'
                '给leader完整指令：创建writer孙代理，writer调用uncooperative_old_tool一次；leader再wait_agent。'
                '所有spawn_agent使用fork_turns=none。主代理和leader不能调用旧工具。',
      maxTurns: 20,
    );
    // A failed remote acknowledgement can make done complete with an error
    // before the host finishes its cancellation probe. Observe it immediately.
    final observedOldDone = _observeOutcome(old.done);
    final timeout = Completer<void>();
    deadline = Timer(const Duration(minutes: 2), () {
      timedOut = true;
      timeout.complete();
    });
    await Future.any<void>([
      Future.wait([ready.future, heldRoot.future]),
      observedOldDone.then<void>((_) {}),
      timeout.future,
    ]);
    deadline.cancel();
    final beforeTree = await readCancellationTree(sessions, old.snapshot);
    final checks = <String, bool>{
      'modelCreatedActiveOldTaskTree':
          !timedOut &&
          beforeTree.length == oldWriterDepth + 1 &&
          beforeTree.every((s) => s.status == RunStatus.running) &&
          ready.isCompleted &&
          heldRoot.isCompleted,
      'oldSubmitterIsIndependentProcess':
          worker != null &&
          worker!.process.pid != pid &&
          !servicePids.contains(worker!.process.pid),
      'resourceServiceIsIndependentProcess': servicePids.single != pid,
    };
    if (!checks.values.every((v) => v)) {
      return {
        'passed': false,
        'checks': checks,
        'modelTrace': trace,
        'hostActions': actions,
        'oldWriterDepth': oldWriterDepth,
        'restartService': restartService,
      };
    }
    phase = 'cancelling';
    record('root_cancel_requested');
    final cancellation = _observeOutcome(old.cancel());
    var cancellationSettled = false;
    unawaited(cancellation.then((_) => cancellationSettled = true));
    if (revocationFault != RemoteRevokeFault.none) {
      AgentRun? premature;
      try {
        premature = await manager.prompt(
          session.id,
          'EARLY_REVOCATION_FAULT_PROBE',
          maxTurns: 1,
        );
      } catch (error) {
        prematureStartError = error.toString();
      }
      if (premature != null) {
        await _observeOutcome(premature.cancel());
      }
      record('immediate_new_task_probe', {'error': prematureStartError});
    }
    if (protectCancellationWaiting) {
      pendingCancellationLease = (await client.leaseStatus(
        capturedOldPermit!,
      )).data;
      cancellationStillPendingAtSubmission = !cancellationSettled;
      await service.control('release');
      workerResult = await worker!.result.timeout(const Duration(seconds: 30));
      pendingCancellationResource = (await client.inspect()).data;
      record('old_submit_during_cancel_wait', {
        'cancellationPending': cancellationStillPendingAtSubmission,
        'leaseStatus': pendingCancellationLease,
        'submission': workerResult,
        'resource': pendingCancellationResource,
      });
    }
    cancellationOutcome = await cancellation.timeout(
      const Duration(seconds: 30),
    );
    record('root_cancel_outcome', cancellationOutcome);
    if (revocationFault == RemoteRevokeFault.none &&
        cancellationOutcome['error'] != null) {
      throw StateError(
        'Normal remote cancellation failed: ${cancellationOutcome['error']}',
      );
    }
    final newPrompt =
        '$uncooperativeNewMarker：新任务。创建新writer子代理，fork_turns=none，message包含$uncooperativeNewMarker，'
        '让它write_new_value(value:15)一次。主代理wait_agent后必须inspect_current_value核验远端实际资源。'
        '读取会放行旧进程提交；不要修复，按实际结果仅回复JSON {"a":实际整数,"polluted":实际布尔值}。';
    if (revocationFault != RemoteRevokeFault.none &&
        !protectUnconfirmedWindow) {
      // Try again immediately on cancellation error, without assuming it means
      // the old local run has already released its writer lease.
      phase = 'new';
      try {
        fresh = await manager.prompt(session.id, newPrompt, maxTurns: 20);
      } catch (error) {
        startAfterCancelError = error.toString();
      }
      record('new_task_attempt_after_cancel_error', {
        'error': startAfterCancelError,
      });
    }
    oldDoneOutcome = await observedOldDone.timeout(const Duration(seconds: 30));
    final cancelled = old.snapshot;
    record('old_local_tree_settled', oldDoneOutcome);
    final oldTree = [
      cancelled,
      for (final s in beforeTree.skip(1)) (await sessions.read(s.id))!,
    ];
    final oldBaseline = oldTree
        .skip(1)
        .map((s) => jsonEncode(s.toJson()))
        .toList();
    final afterCancel = (await client.inspect()).data;
    if (revocationFault != RemoteRevokeFault.none) {
      faultStateBeforeNew = await service.control('state');
      // If the second probe succeeded, activation has already changed only the
      // generation; the fault state still proves old authority/revocation truth.
    }
    if (restartService) {
      await service.close();
      service = await RemoteTestService.start(
        resourceDirectory,
        controlKey,
        port: endpoint.port,
      );
      servicePids.add(service.process.pid);
      record('resource_service_restarted', {'pids': servicePids});
    }
    final afterRestart = (await client.inspect()).data;
    cancellationObservationReady.complete();
    phase = 'new';
    if (protectUnconfirmedWindow) {
      oldStopProofs = authority.stopProofs;
      replacementOpening = manager.prompt(session.id, newPrompt, maxTurns: 20);
      unawaited(
        replacementOpening.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      while ((await service.control('state'))['replacementActivationsHeld'] !=
          1) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      unconfirmedWindowResource = (await client.inspect()).data;
      record(
        'replacement_activation_pending_old_generation_still_current',
        unconfirmedWindowResource,
      );
      // Attempt the original write before the replacement generation exists.
      // Its rejection must be due to revoked/expired authority, not generation 2.
      await service.control('release');
      workerResult = await worker!.result.timeout(const Duration(seconds: 30));
      record(
        'old_submit_rejected_in_unconfirmed_generation_window',
        workerResult!,
      );
      await service.control('release_activation');
      fresh = await replacementOpening;
    }
    fresh ??= await manager.prompt(session.id, newPrompt, maxTurns: 20);
    record('new_task_started', {'runId': fresh.snapshot.runId});
    final current = fresh;
    deadline = Timer(const Duration(minutes: 2), () {
      timedOut = true;
      unawaited(current.cancel());
    });
    final result = await fresh.done;
    deadline.cancel();
    final finalResource = (await client.inspect()).data;
    final resultBody = workerResult?['result'] as Map?;
    final resultData = resultBody?['data'] as Map?;
    final audit = (finalResource['audit'] as List).cast<Map>();
    final oldIds = oldTree.map((s) => s.runId).toSet();
    final oldWrites = audit
        .where((a) => a['kind'] == 'committed' && oldIds.contains(a['runId']))
        .toList();
    final newWrites = audit
        .where((a) => a['kind'] == 'committed' && a['generation'] == 2)
        .toList();
    final revokedOld = audit
        .where((a) => a['kind'] == 'revoked' && a['generation'] == 1)
        .toList();
    final deniedOld = audit
        .where(
          (a) => a['kind'] == 'rejected' && a['runId'] == oldActor!['runId'],
        )
        .toList();
    final oldAfter = [
      for (final s in beforeTree.skip(1)) (await sessions.read(s.id))!,
    ];
    final newTree = await readCancellationTree(sessions, result);
    Map? summary;
    try {
      final answer = result.history.last.text;
      summary =
          jsonDecode(
                answer.substring(
                  answer.indexOf('{'),
                  answer.lastIndexOf('}') + 1,
                ),
              )
              as Map;
    } catch (_) {}
    checks.addAll({
      if (revocationFault == RemoteRevokeFault.none)
        'cancelJoinedOldTreeAndAcknowledgedRevocation':
            oldTree.every((s) => s.status == RunStatus.cancelled) &&
            revokedOld.length == oldTree.length,
      'noOldWriteInPreSubmitObservation':
          afterCancel['resourceRevision'] == 1 &&
          (afterCancel['data'] as Map)['a'] == 99,
      'resourceAuthorityPersistedAcrossRestart':
          jsonEncode(afterCancel) == jsonEncode(afterRestart),
      'serviceRestartIsAnActualNewProcess':
          !restartService ||
          servicePids.length == 2 && servicePids.first != servicePids.last,
      'newTaskCompletedWithNewRunId':
          !timedOut &&
          result.status == RunStatus.completed &&
          result.runId != cancelled.runId,
      'newChildReallyCommitted15':
          newWrites.length == 1 &&
          (newWrites.single['patch'] as Map)['a'] == 15 &&
          newTree.skip(1).any((s) => s.runId == newWrites.single['runId']),
      protectUnconfirmedWindow
              ? 'newTaskValueVerifiedAfterWindowWriteRefused'
              : 'newValueWas15BeforeOldSubmitReleased':
          beforeLate != null && (beforeLate!['data'] as Map)['a'] == 15,
      'oldProcessActuallySentOriginalOperation':
          workerResult != null &&
          workerResult!['pid'] == worker!.process.pid &&
          workerResult!['operationId'] == savedWorkerInputs.single,
      'serverRejectedOldGeneration':
          workerResult?['status'] == 409 &&
          resultBody?['isError'] == true &&
          (protectCancellationWaiting
              ? (resultData?['code'] == 'task_commit_admission_closed')
              : protectUnconfirmedWindow
              ? [
                  'task_write_lease_expired',
                  'task_write_revoked',
                ].contains(resultData?['code'])
              : resultData?['code'] == 'stale_task_generation') &&
          resultData?['executed'] == false,
      'serverAuditProvesRejectedOldSubmission':
          deniedOld.length == 1 &&
          deniedOld.single['generation'] == 1 &&
          deniedOld.single['currentGeneration'] ==
              (protectUnconfirmedWindow || protectCancellationWaiting ? 1 : 2),
      'noOldCommitAtResourceEnd': oldWrites.isEmpty,
      'onlyOneBusinessRevisionCommitted':
          finalResource['resourceRevision'] == 2,
      'actualResourceNotPolluted': (finalResource['data'] as Map)['a'] == 15,
      'mainAgentReportedActualUnpollutedValue':
          summary?['a'] == 15 && summary?['polluted'] == false,
      'oldAgentSnapshotsUnchangedDuringNewTask': List.generate(
        oldAfter.length,
        (i) => jsonEncode(oldAfter[i].toJson()) == oldBaseline[i],
      ).every((v) => v),
    });
    if (revocationFault != RemoteRevokeFault.none &&
        !protectUnconfirmedWindow) {
      final faults = (faultStateBeforeNew!['revokeFaults'] as List).cast<Map>();
      final activeOld =
          (faultStateBeforeNew['activeScopeCounts'] as Map)['1'] ?? 0;
      final afterLate = faultStateAfterLateRevokes == null
          ? const <Map>[]
          : (faultStateAfterLateRevokes!['revokeFaults'] as List).cast<Map>();
      checks.addAll({
        'immediateStartBeforeLocalSettlementRejected':
            prematureStartError != null &&
            prematureStartError.contains('writer') &&
            prematureModelCalls == 0,
        'cancellationFailureWasSurfaced':
            cancellationOutcome['error'] != null &&
            oldDoneOutcome['error'] != null,
        'oldTreeLocallyCancelledDespiteUnknownRemoteAck': oldTree.every(
          (s) => s.status == RunStatus.cancelled && s.pending.isEmpty,
        ),
        'allOldTreeRevocationsActuallyFaulted': faults.length == oldTree.length,
        'newTaskOnlyStartsAfterDurableGenerationTwo':
            activationObservations.isNotEmpty &&
            activationObservations
                .where((o) => o['task'] == 'new')
                .isNotEmpty &&
            activationObservations
                .where((o) => o['task'] == 'new')
                .every((o) => o['generation'] == 2),
        'oldLocalCancellationNeverStartsOldModelWorkAgain':
            !activationObservations.any(
              (o) => o['task'] == 'old' && o['generation'] == 2,
            ),
        'faultTruthMatchesMode':
            revocationFault == RemoteRevokeFault.timeoutBeforeCommit
            ? activeOld == oldTree.length &&
                  faults.every((f) => f['applied'] == false)
            : activeOld == 0 &&
                  faults.every(
                    (f) =>
                        f['applied'] == true &&
                        f['acknowledgementDropped'] == true,
                  ),
        'delayedOldRevokesDoNotInvalidateNewGeneration':
            revocationFault != RemoteRevokeFault.timeoutBeforeCommit ||
            afterLate.length == oldTree.length &&
                afterLate.every((f) => f['currentGenerationAtApply'] == 2) &&
                ((faultStateAfterLateRevokes!['activeScopeCounts'] as Map)['2']
                            as int? ??
                        0) >
                    0,
        'cancellationErrorMatchesInjectedTransportFault':
            revocationFault == RemoteRevokeFault.timeoutBeforeCommit
            ? cancellationOutcome['errorType'] == 'TimeoutException'
            : [
                'HttpException',
                'SocketException',
              ].contains(cancellationOutcome['errorType']),
      });
    }
    if (protectUnconfirmedWindow) {
      checks.addAll({
        'cancelCompletedOnlyWithConfirmedStopEvidence':
            cancellationOutcome['status'] == 'cancelled' &&
            oldDoneOutcome['status'] == 'cancelled' &&
            oldStopProofs!.length == oldTree.length &&
            oldStopProofs.every(
              (p) => p['stopped'] == true && p['revokeErrorType'] != null,
            ),
        'immediateNewTaskBlockedUntilStopConfirmed':
            prematureStartError != null &&
            prematureStartError.contains('writer') &&
            prematureModelCalls == 0,
        'newGenerationWasUnconfirmedAtOldSubmission':
            unconfirmedWindowResource!['generation'] == 1 &&
            unconfirmedWindowResource['resourceRevision'] == 1,
        'oldSubmissionWasDeniedWithoutAdvancingGeneration':
            resultData?['currentGeneration'] == 1 &&
            resultData?['executed'] == false,
        'replacementModelsOnlyRunAfterGenerationTwoConfirmed':
            activationObservations
                .where((o) => o['task'] == 'new')
                .isNotEmpty &&
            activationObservations
                .where((o) => o['task'] == 'new')
                .every((o) => o['generation'] == 2),
      });
    }
    if (protectCancellationWaiting) {
      checks.addAll({
        'oldAttemptOccurredDuringCancellationWait':
            cancellationStillPendingAtSubmission,
        'oldLeaseWasStillValidAtSubmission':
            pendingCancellationLease!['stopped'] == false &&
            (pendingCancellationLease['expiresAtMs'] as int) >
                (pendingCancellationLease['serverNowMs'] as int),
        'oldValidCredentialDeniedByLiveOwner':
            resultData?['code'] == 'task_commit_admission_closed' &&
            resultData?['executed'] == false &&
            resultData?['currentGeneration'] == 1,
        'cancelWaitWriteDidNotChangeResource':
            pendingCancellationResource!['resourceRevision'] == 1 &&
            (pendingCancellationResource['data'] as Map)['a'] == 99 &&
            pendingCancellationResource['generation'] == 1,
      });
    }
    return {
      'passed': checks.values.every((v) => v),
      'checks': checks,
      'oldWriterDepth': oldWriterDepth,
      'restartService': restartService,
      'revocationFault': revocationFault.name,
      'protectUnconfirmedWindow': protectUnconfirmedWindow,
      'protectCancellationWaiting': protectCancellationWaiting,
      'pendingCancellationLease': pendingCancellationLease,
      'pendingCancellationResource': pendingCancellationResource,
      'unconfirmedWindowResource': unconfirmedWindowResource,
      'oldStopProofs': oldStopProofs,
      'cancellationOutcome': cancellationOutcome,
      'oldDoneOutcome': oldDoneOutcome,
      'immediateStartError': prematureStartError,
      'startAfterCancelError': startAfterCancelError,
      'faultStateBeforeNewSubmit': faultStateBeforeNew,
      'faultStateAfterLateRevokes': faultStateAfterLateRevokes,
      'activationObservations': activationObservations,
      'newTaskPolluted': (finalResource['data'] as Map)['a'] != 15,
      'hostPid': pid,
      'servicePids': servicePids,
      'workerPid': worker!.process.pid,
      'initialResource': initial,
      'resourceAfterCancellation': afterCancel,
      'finalResource': finalResource,
      'oldSubmissionResult': workerResult,
      'finalAnswer': result.history.last.text,
      'hostActions': actions,
      'modelTrace': trace,
      'oldSessions': oldTree.map((s) => s.toJson()).toList(),
      'newSessions': newTree.map((s) => s.toJson()).toList(),
    };
  } finally {
    deadline?.cancel();
    if (service != null) {
      try {
        await service.control('release_revokes');
        await service.control('release_activation');
        await service.control('release');
      } catch (_) {}
    }
    await worker?.close();
    if (fresh == null && replacementOpening != null) {
      try {
        fresh = await replacementOpening;
      } catch (_) {}
    }
    if (fresh != null && !fresh.isSettled) {
      await _observeOutcome(fresh.cancel());
    }
    if (old != null && !old.isSettled) {
      await _observeOutcome(old.cancel());
      await _observeOutcome(old.done);
    }
    if (service != null) await service.close();
    await onlineAuthorization?.close();
    await directory.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _observeOutcome(Future<SessionSnapshot> future) =>
    future.then(
      (s) => <String, Object?>{'status': s.status.name},
      onError: (Object error) => <String, Object?>{
        'error': error.toString(),
        'errorType': error.runtimeType.toString(),
      },
    );

class _ActivationAuditModel implements ModelAdapter {
  _ActivationAuditModel(
    this.model,
    this.client,
    this.observations, {
    required this.onPremature,
  });
  final ModelAdapter model;
  final FencedResourceClient client;
  final List<Map<String, Object?>> observations;
  final void Function() onPremature;
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken token,
  ) async* {
    final user = request.messages
        .lastWhere((m) => m.role == MessageRole.user && !m.runtimeNotice)
        .text;
    if (user.contains('EARLY_REVOCATION_FAULT_PROBE')) onPremature();
    final state = (await client.inspect()).data;
    observations.add({
      'task': user.contains(uncooperativeNewMarker) ? 'new' : 'old',
      'generation': state['generation'],
      'resourceRevision': state['resourceRevision'],
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    yield* model.stream(request, token);
  }
}

/// Runs child and grandchild submissions, with and without service restart.
Future<Map<String, Object?>> validateRemoteFencedModes(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final restart in [false, true]) {
    for (final depth in [1, 2]) {
      stdout.writeln('REMOTE_FENCE_MODE depth=$depth restart=$restart');
      reports.add(
        await validateRemoteFencedCancellation(
          model,
          oldWriterDepth: depth,
          restartService: restart,
        ),
      );
    }
  }
  return {
    'passed': reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports)
        'depth_${r['oldWriterDepth']}_restart_${r['restartService']}':
            r['passed'] == true,
    },
    'cases': reports,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateRemoteFencedModes,
  label: 'REMOTE_FENCED_CANCEL',
);
