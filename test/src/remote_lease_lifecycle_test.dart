import 'dart:async';
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';
import '../../tool/remote_resource_test_processes.dart';
import 'agent_test.dart' show ScriptedModel;

class GatedStatusClient extends FencedResourceClient {
  GatedStatusClient({
    required super.baseUrl,
    required super.resourceId,
    required super.controlKey,
  });
  final requested = Completer<void>();
  final available = Completer<void>();
  @override
  Future<ToolResult> leaseStatus(RemoteWritePermit permit) async {
    if (!requested.isCompleted) requested.complete();
    await available.future;
    return super.leaseStatus(permit);
  }
}

void main() {
  test(
    'healthy renewal keeps an active run writable beyond its initial deadline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cutdex-active-lease-',
      );
      final service = await RemoteTestService.start(
        directory,
        'control',
        leaseDuration: const Duration(seconds: 2),
      );
      final client = FencedResourceClient(
        baseUrl: service.url,
        resourceId: 'shared',
        controlKey: 'control',
      );
      final authority = RemoteResourceTaskAuthority(client);
      final started = Completer<RemoteWritePermit>();
      final release = Completer<void>();
      AgentRun? run;
      try {
        var responses = 0;
        final manager = SessionManager(
          model: ScriptedModel((_, _) async* {
            yield responses++ == 0
                ? ModelResponse(
                    calls: [ToolCall(id: 'hold', name: 'hold')],
                  )
                : ModelResponse(text: 'done');
          }),
          store: InMemorySessionStore(),
          contextBuilder: ContextBuilder(),
          resourceTaskAuthority: authority,
          tools: [
            AgentTool(
              name: 'hold',
              description: 'hold',
              parameters: {'type': 'object'},
              validate: (_) => null,
              execute: (_, ctx) async {
                started.complete(authority.permitFor(ctx));
                await release.future;
                return ToolResult('released');
              },
            ),
          ],
        );
        final session = await manager.create();
        run = await manager.prompt(session.id, 'hold');
        final permit = await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 4500));
        expect(
          (await client.commit(
            permit,
            operationId: 'after-initial-expiry',
            patch: {'a': 15},
          )).isError,
          isFalse,
        );
        release.complete();
        expect((await run.done).status, RunStatus.completed);
        expect(authority.stopProofs.single['stopped'], isTrue);
        expect(
          (await client.commit(
            permit,
            operationId: 'after-completed',
            patch: {'a': 10},
          )).isError,
          isTrue,
        );
      } finally {
        if (!release.isCompleted) release.complete();
        if (run != null && !run.isSettled) await run.cancel();
        await service.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'missing stop confirmation holds cancellation and the session writer lease',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cutdex-unknown-stop-',
      );
      final service = await RemoteTestService.start(
        directory,
        'control',
        leaseDuration: const Duration(seconds: 2),
        revocationFault: RemoteRevokeFault.timeoutBeforeCommit,
      );
      final client = GatedStatusClient(
        baseUrl: service.url,
        resourceId: 'shared',
        controlKey: 'control',
      );
      final authority = RemoteResourceTaskAuthority(client);
      final toolStarted = Completer<void>();
      AgentRun? run;
      try {
        final model = ScriptedModel((_, _) async* {
          yield ModelResponse(
            calls: [ToolCall(id: 'hold', name: 'hold')],
          );
        });
        final manager = SessionManager(
          model: model,
          store: InMemorySessionStore(),
          contextBuilder: ContextBuilder(),
          resourceTaskAuthority: authority,
          tools: [
            AgentTool(
              name: 'hold',
              description: 'hold',
              parameters: {'type': 'object'},
              validate: (_) => null,
              execute: (_, ctx) async {
                toolStarted.complete();
                await ctx.cancellation.whenCancelled;
                return ToolResult('cancelled');
              },
            ),
          ],
        );
        final session = await manager.create();
        run = await manager.prompt(session.id, 'hold');
        await toolStarted.future;
        final cancellation = run.cancel();
        await client.requested.future;
        expect(run.isSettled, isFalse);
        expect(authority.stopProofs, isEmpty);
        await expectLater(
          manager.prompt(session.id, 'too early'),
          throwsStateError,
        );
        expect(model.requests, hasLength(1));
        client.available.complete();
        expect((await cancellation).status, RunStatus.cancelled);
        expect(
          authority.stopProofs.single['reason'],
          'task_write_lease_expired',
        );
      } finally {
        if (!client.available.isCompleted) client.available.complete();
        if (run != null && !run.isSettled) await run.cancel();
        await service.control('release_revokes');
        await service.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
