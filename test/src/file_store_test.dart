import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

Future<String> workerPath() async {
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:cutdex_agent/cutdex_agent.dart'),
  );
  return File.fromUri(
    library!.resolve('../test/fixtures/crash_worker.dart'),
  ).path;
}

Future<Process> waitingWorker(Directory root, String boundary) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    await workerPath(),
    root.path,
    boundary,
  ]);
  final stderrText = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(stderrText.write);
  addTearDown(() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  });
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 20));
  expect(line, boundary, reason: stderrText.toString());
  return process;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cutdex-agent-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('checkpoint revisions persist across store instances', () async {
    final store = FileSessionStore(root);
    final first = SessionSnapshot(id: 'session');
    await store.save(first, expectedRevision: null);
    await store.save(
      first.update({'revision': 1, 'system': 'updated'}),
      expectedRevision: 0,
    );
    final other = FileSessionStore(root);
    expect((await other.read('session'))!.system, 'updated');
    expect((await other.revisions('session')).map((s) => s.revision), [0, 1]);
  });

  test(
    'lease cache preserves revisions and expires when ownership changes',
    () async {
      final store = FileSessionStore(root);
      final lease = await store.acquire('session');
      var snapshot = SessionSnapshot(id: 'session');
      await store.save(snapshot, expectedRevision: null);
      for (var revision = 1; revision <= 5; revision++) {
        snapshot = snapshot.update({
          'revision': revision,
          'system': '$revision',
        });
        await store.save(snapshot, expectedRevision: revision - 1);
        expect((await store.read('session'))!.revision, revision);
      }
      await expectLater(
        store.save(snapshot, expectedRevision: 3),
        throwsStateError,
      );
      expect((await store.read('session'))!.revision, 5);
      expect((await store.revisions('session')).length, 6);
      await store.release('session', lease);
      final other = FileSessionStore(root);
      await other.save(snapshot.update({'revision': 6}), expectedRevision: 5);
      final nextLease = await store.acquire('session');
      expect((await store.read('session'))!.revision, 6);
      await store.release('session', nextLease);
    },
  );

  test('compare-and-set serializes concurrent saves', () async {
    final store = FileSessionStore(root);
    final initial = SessionSnapshot(id: 'session');
    await store.save(initial, expectedRevision: null);
    final results = await Future.wait([
      for (var i = 0; i < 2; i++)
        store
            .save(
              initial.update({'revision': 1, 'system': '$i'}),
              expectedRevision: 0,
            )
            .then((_) => true, onError: (Object _) => false),
    ]);
    expect(results.where((r) => r).length, 1);
  });

  test(
    'same-process second store cannot acquire or save over a live lease',
    () async {
      final first = FileSessionStore(root);
      final lease = await first.acquire('session');
      final other = FileSessionStore(root);
      await expectLater(other.acquire('session'), throwsStateError);
      await expectLater(
        other.save(SessionSnapshot(id: 'session'), expectedRevision: null),
        throwsStateError,
      );
      await first.release('session', lease);
      final next = await other.acquire('session');
      await other.release('session', next);
    },
  );

  test(
    'live process lease excludes another writer and SIGKILL releases it',
    () async {
      final process = await waitingWorker(root, 'lock');
      final store = FileSessionStore(root);
      await expectLater(
        store.acquire('session'),
        throwsA(isA<FileSystemException>()),
      );
      expect(process.kill(ProcessSignal.sigkill), isTrue);
      await process.exitCode;
      final lease = await store.acquire('session');
      await store.release('session', lease);
    },
  );

  for (final tail in ['header', 'payload']) {
    test('torn final $tail is ignored and repaired on next save', () async {
      final store = FileSessionStore(root);
      final snapshot = SessionSnapshot(id: 'session');
      await store.save(snapshot, expectedRevision: null);
      final file =
          (await root.list().where((f) => f.path.endsWith('.journal')).single)
              as File;
      final bytes = tail == 'header'
          ? [0, 1, 2]
          : [...(await file.readAsBytes()).take(12), 1, 2];
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      expect((await store.read('session'))!.revision, 0);
      await store.save(snapshot.update({'revision': 1}), expectedRevision: 0);
      expect((await store.revisions('session')).length, 2);
    });
  }

  test(
    'complete corrupt frame fails closed rather than rolling history back',
    () async {
      final store = FileSessionStore(root);
      await store.save(SessionSnapshot(id: 'session'), expectedRevision: null);
      final file =
          (await root.list().where((f) => f.path.endsWith('.journal')).single)
              as File;
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 2] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(store.read('session'), throwsFormatException);
    },
  );

  for (final boundary in [
    'before_call',
    'after_start',
    'after_commit',
    'before_result',
    'after_result',
  ]) {
    test(
      'SIGKILL at $boundary recovers in new process with exactly one fake edit',
      () async {
        final process = await waitingWorker(root, boundary);
        expect(process.kill(ProcessSignal.sigkill), isTrue);
        await process.exitCode;
        final recovered = await Process.run(Platform.resolvedExecutable, [
          await workerPath(),
          root.path,
          'recover',
        ]).timeout(const Duration(seconds: 20));
        expect(recovered.exitCode, 0, reason: '${recovered.stderr}');
        expect('${recovered.stdout}'.trim(), 'completed');
        final executions = await File(
          '${root.path}/executions.txt',
        ).readAsLines();
        expect(executions.length, 1);
        final snapshot = (await FileSessionStore(root).read('session'))!;
        expect(snapshot.status, RunStatus.completed);
        expect(
          snapshot.history.where((m) => m.role == MessageRole.tool).length,
          1,
        );
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
