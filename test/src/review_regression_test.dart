import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show ScriptedModel, callThenAnswer, start, tool;

class WriteGateStore extends InMemorySessionStore {
  WriteGateStore(this.matches);
  final bool Function(SessionSnapshot) matches;
  final entered = Completer<void>();
  final releaseGate = Completer<void>();
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    if (!entered.isCompleted && matches(snapshot)) {
      entered.complete();
      await releaseGate.future;
    }
    await super.save(snapshot, expectedRevision: expectedRevision);
  }
}

class MemoryGate extends InMemoryMemoryProvider {
  final entered = Completer<void>();
  final releaseGate = Completer<void>();
  @override
  Future<List<AgentMemory>> search({
    required String scope,
    required String query,
    required int limit,
    required CancellationToken cancellation,
  }) async {
    if (!entered.isCompleted) {
      entered.complete();
      await releaseGate.future;
    }
    return [];
  }
}

void main() {
  test(
    'restart after stop reconciles committed calls but cancels planned calls',
    () async {
      final root = await Directory.systemTemp.createTemp('stopped-checkpoint-');
      addTearDown(() => root.delete(recursive: true));
      final store = FileSessionStore(root);
      final committed = ToolCall(id: 'first', name: 'edit');
      final planned = ToolCall(id: 'second', name: 'edit');
      await store.save(
        SessionSnapshot(
          id: 'stopped',
          runId: 'run',
          status: RunStatus.running,
          stopRequested: true,
          history: [
            AgentMessage(role: MessageRole.user, text: 'edit twice'),
            AgentMessage(
              role: MessageRole.assistant,
              calls: [committed, planned],
            ),
          ],
          pending: [
            CallRecord(
              call: committed,
              operationId: 'first-op',
              status: CallStatus.started,
            ),
            CallRecord(call: planned, operationId: 'second-op'),
          ],
        ),
        expectedRevision: null,
      );
      var executions = 0;
      var models = 0;
      final manager = SessionManager(
        store: FileSessionStore(root),
        model: ScriptedModel((_, _) async* {
          models++;
          yield ModelResponse(text: 'unexpected');
        }),
        tools: [
          AgentTool(
            name: 'edit',
            description: 'edit',
            parameters: {},
            validate: (_) => null,
            execute: (_, _) async {
              executions++;
              return ToolResult('unexpected');
            },
            recover: (_, _) async =>
                ToolRecovery.completed(ToolResult('already saved')),
          ),
        ],
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await (await manager.resume('stopped')).done;
        expect(result.status, RunStatus.cancelled);
        expect(result.pending, isEmpty);
        expect(
          result.history.where((m) => m.role == MessageRole.tool),
          hasLength(2),
        );
      }
      expect(executions, 0);
      expect(models, 0);
      final result = await (await manager.prompt(
        'stopped',
        'new question',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(result.stopRequested, isFalse);
      expect(executions, 0);
      expect(models, 1);
    },
  );

  for (final cancel in [false, true]) {
    test(
      '${cancel ? 'cancel' : 'pause'} during tool-start checkpoint prevents dispatch',
      () async {
        var executions = 0;
        final store = WriteGateStore(
          (s) => s.pending.any((r) => r.status == CallStatus.started),
        );
        final manager = SessionManager(
          model: callThenAnswer(),
          store: store,
          tools: [
            tool(
              execute: (_, _) async {
                executions++;
                return ToolResult('committed');
              },
            ),
          ],
        );
        final run = await start(manager);
        await store.entered.future;
        final interrupted = cancel ? run.cancel() : run.pause();
        store.releaseGate.complete();
        final snapshot = await interrupted;
        expect(executions, 0);
        if (cancel) {
          expect(snapshot.pending, isEmpty);
          expect(snapshot.stopRequested, isTrue);
          expect(snapshot.history.last.isError, isTrue);
        } else {
          expect(snapshot.pending.single.status, CallStatus.planned);
        }
        expect(
          snapshot.status,
          cancel ? RunStatus.cancelled : RunStatus.paused,
        );
        final resumed = await (await manager.resume(snapshot.id)).done;
        expect(
          resumed.status,
          cancel ? RunStatus.cancelled : RunStatus.completed,
        );
        expect(executions, cancel ? 0 : 1);
      },
    );

    test(
      '${cancel ? 'cancel' : 'pause'} during model checkpoint prevents provider dispatch',
      () async {
        final store = WriteGateStore((s) => s.turns == 1);
        final model = ScriptedModel((_, _) async* {
          yield ModelResponse(text: 'done');
        });
        final manager = SessionManager(model: model, store: store);
        final run = await start(manager);
        await store.entered.future;
        final interrupted = cancel ? run.cancel() : run.pause();
        store.releaseGate.complete();
        final snapshot = await interrupted;
        expect(model.requests, isEmpty);
        expect(snapshot.turns, 0);
        expect(
          snapshot.status,
          cancel ? RunStatus.cancelled : RunStatus.paused,
        );
      },
    );
  }

  test(
    'steering accepted while context is building reaches first model call',
    () async {
      final memory = MemoryGate();
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      final manager = SessionManager(
        model: model,
        store: InMemorySessionStore(),
        contextBuilder: ContextBuilder(memory: memory),
      );
      final session = await manager.create(memoryScope: 'project');
      final run = await manager.prompt(session.id, 'original');
      await memory.entered.future;
      await run.steer('new constraint');
      memory.releaseGate.complete();
      await run.done;
      expect(model.requests.first.messages.last.text, 'new constraint');
      expect(model.requests.length, 1);
    },
  );

  test(
    'steering during model checkpoint rebuilds request without spending a turn',
    () async {
      final store = WriteGateStore((s) => s.turns == 1);
      final model = ScriptedModel((_, _) async* {
        yield ModelResponse(text: 'done');
      });
      final manager = SessionManager(model: model, store: store);
      final run = await start(manager);
      await store.entered.future;
      final steering = run.steer('new constraint');
      store.releaseGate.complete();
      await steering;
      final snapshot = await run.done;
      expect(model.requests.first.messages.last.text, 'new constraint');
      expect(model.requests.length, 1);
      expect(snapshot.turns, 1);
    },
  );

  test(
    'corrupted complete journal length fails closed rather than discarding a revision',
    () async {
      final directory = await Directory.systemTemp.createTemp('agent-review-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileSessionStore(directory);
      await store.save(SessionSnapshot(id: 'session'), expectedRevision: null);
      final file =
          (await directory
                  .list()
                  .where((f) => f.path.endsWith('.journal'))
                  .single)
              as File;
      final bytes = await file.readAsBytes();
      final header = ByteData.sublistView(bytes);
      header.setUint32(0, header.getUint32(0) + 10);
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(store.read('session'), throwsFormatException);
    },
  );
}
