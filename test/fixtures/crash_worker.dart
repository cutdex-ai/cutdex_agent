import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

Future<void> stopAt(String name) async {
  stdout.writeln(name);
  await stdout.flush();
  // Stay alive with pending OS input until the test process sends SIGKILL.
  await stdin.drain<void>();
  throw StateError('Worker must be killed at the selected boundary');
}

class CrashStore extends FileSessionStore {
  CrashStore(super.directory, this.mode);
  final String mode;
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    if (mode == 'before_result' &&
        snapshot.pending.any((r) => r.status == CallStatus.finished)) {
      await stopAt(mode);
    }
    await super.save(snapshot, expectedRevision: expectedRevision);
    if (mode == 'before_call' &&
        snapshot.pending.any((r) => r.status == CallStatus.planned)) {
      await stopAt(mode);
    }
    if (mode == 'after_result' &&
        snapshot.pending.any((r) => r.status == CallStatus.finished)) {
      await stopAt(mode);
    }
  }
}

class Model implements ModelAdapter {
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    if (request.messages.last.role == MessageRole.tool) {
      yield ModelResponse(text: 'done');
    } else {
      yield ModelResponse(
        calls: [ToolCall(id: 'edit-1', name: 'edit')],
      );
    }
  }
}

Future<void> main(List<String> args) async {
  final root = Directory(args[0]);
  final mode = args[1];
  final store = CrashStore(root, mode);
  if (mode == 'lock') {
    await store.acquire('session');
    await stopAt('lock');
    return;
  }
  final ledger = File('${root.path}/business.json');
  final executions = File('${root.path}/executions.txt');
  final manager = SessionManager(
    model: Model(),
    store: store,
    tools: [
      AgentTool(
        name: 'edit',
        description: 'Durable fake business operation',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (_, context) async {
          if (mode == 'after_start') await stopAt(mode);
          await executions.writeAsString(
            '${context.operationId}\n',
            mode: FileMode.append,
            flush: true,
          );
          await ledger.writeAsString(
            jsonEncode({
              'operationId': context.operationId,
              'result': 'committed',
            }),
            flush: true,
          );
          if (mode == 'after_commit') await stopAt(mode);
          return ToolResult('committed');
        },
        recover: (_, context) async {
          if (!await ledger.exists()) return const ToolRecovery.notStarted();
          final record = jsonDecode(await ledger.readAsString()) as Map;
          if (record['operationId'] != context.operationId) {
            return const ToolRecovery.unknown();
          }
          return ToolRecovery.completed(ToolResult('committed'));
        },
      ),
    ],
  );
  final existing = await store.read('session');
  final AgentRun run;
  if (existing == null) {
    await manager.create(id: 'session');
    run = await manager.prompt('session', 'edit');
  } else {
    run = await manager.resume('session');
  }
  final result = await run.done;
  stdout.writeln(result.status.name);
}
