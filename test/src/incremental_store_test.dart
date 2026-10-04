import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:cutdex_agent/src/storage/journal_codec.dart';
import 'package:test/test.dart';

String journalPath(Directory root, String id) =>
    '${root.path}/${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.journal';

List<SessionSnapshot> historyFixture(int count) {
  var current = SessionSnapshot(id: 'session');
  final states = [current];
  for (var i = 1; i < count; i++) {
    current = current.update({
      'revision': i,
      'history': [
        ...current.history.map((m) => m.toJson()),
        AgentMessage(
          role: MessageRole.user,
          text: '$i:${'context ' * 100}',
        ).toJson(),
      ],
      'queued': i.isEven ? ['instruction $i'] : <String>[],
      'error': i % 3 == 0 ? 'recoverable' : null,
    });
    states.add(current);
  }
  return states;
}

Future<void> writeLegacy(Directory root, List<SessionSnapshot> states) async {
  final writer = await File(
    journalPath(root, 'session'),
  ).open(mode: FileMode.write);
  try {
    for (final state in states) {
      await writer.writeFrom(journalFrame(state.toJson()));
    }
    await writer.flush();
  } finally {
    await writer.close();
  }
}

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('agent-delta-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    'incremental writes preserve every revision with bounded snapshot duplication',
    () async {
      final states = historyFixture(270);
      final store = FileSessionStore(root);
      final lease = await store.acquire('session');
      for (final state in states) {
        await store.save(
          state,
          expectedRevision: state.revision == 0 ? null : state.revision - 1,
        );
      }
      await store.release('session', lease);
      final recovered = await FileSessionStore(root).revisions('session');
      expect(recovered.map((s) => s.toJson()), states.map((s) => s.toJson()));
      final path = journalPath(root, 'session');
      final journalBytes = await File(path).length();
      final checkpointBytes = await File('$path.checkpoint').length();
      final fullBytes = states.fold<int>(
        0,
        (n, s) => n + journalFrame(s.toJson()).length,
      );
      expect(journalBytes + checkpointBytes, lessThan(fullBytes ~/ 20));
      final cache =
          jsonDecode(
                utf8.decode(
                  (await File('$path.checkpoint').readAsBytes()).sublist(12),
                ),
              )
              as Map;
      expect((cache['state'] as Map)['revision'], 256);
      expect(
        (await FileSessionStore(root).read('session'))!.toJson(),
        states.last.toJson(),
      );
      await FileSessionStore(root).verify('session');
    },
  );

  test('legacy migration retains all revisions and is idempotent', () async {
    final states = historyFixture(180);
    await writeLegacy(root, states);
    final path = journalPath(root, 'session');
    final before = await File(path).length();
    final store = FileSessionStore(root);
    expect((await store.read('session'))!.toJson(), states.last.toJson());
    await store.migrate('session');
    expect(
      (await store.revisions('session')).map((s) => s.toJson()),
      states.map((s) => s.toJson()),
    );
    final migrated = await File(path).readAsBytes();
    expect(
      migrated.length + await File('$path.checkpoint').length(),
      lessThan(before ~/ 10),
    );
    await store.migrate('session');
    expect(await File(path).readAsBytes(), migrated);
    await store.save(
      states.last.update({'revision': 180}),
      expectedRevision: 179,
    );
    expect((await FileSessionStore(root).read('session'))!.revision, 180);
  });

  test(
    'save automatically migrates legacy and preserves pending recovery data',
    () async {
      final first = SessionSnapshot(id: 'session');
      final pending = first.update({
        'revision': 1,
        'pending': [
          CallRecord(
            call: ToolCall(id: 'call', name: 'edit'),
            operationId: 'operation',
            status: CallStatus.started,
          ).toJson(),
        ],
      });
      await writeLegacy(root, [first, pending]);
      final store = FileSessionStore(root);
      await store.save(pending.update({'revision': 2}), expectedRevision: 1);
      final restored = (await store.read('session'))!;
      expect(restored.pending.single.operationId, 'operation');
      expect(restored.pending.single.status, CallStatus.started);
      expect((await store.revisions('session')).length, 3);
    },
  );

  test(
    'corrupt legacy never replaces original, abandoned staging is ignored',
    () async {
      await writeLegacy(root, historyFixture(3));
      final path = journalPath(root, 'session');
      await File('$path.migrating').writeAsString('abandoned write');
      final store = FileSessionStore(root);
      expect((await store.read('session'))!.revision, 2);
      final bytes = await File(path).readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await File(path).writeAsBytes(bytes, flush: true);
      await expectLater(store.migrate('session'), throwsFormatException);
      expect(await File(path).readAsBytes(), bytes);
      await writeLegacy(root, historyFixture(3));
      await store.migrate('session');
      expect(await File('$path.migrating').exists(), isFalse);
      expect((await store.read('session'))!.revision, 2);
    },
  );

  test(
    'missing, torn, and stale generation checkpoints fall back to journal',
    () async {
      final states = historyFixture(140);
      await writeLegacy(root, states);
      final store = FileSessionStore(root);
      await store.migrate('session');
      final checkpoint = File('${journalPath(root, 'session')}.checkpoint');
      final valid = await checkpoint.readAsBytes();
      await checkpoint.delete();
      expect((await store.read('session'))!.revision, 139);
      await checkpoint.writeAsBytes(valid.take(20).toList());
      expect((await store.read('session'))!.revision, 139);
      final data = (jsonDecode(utf8.decode(valid.sublist(12))) as Map)
          .cast<String, Object?>();
      data['generation'] = 'obsolete-generation';
      await checkpoint.writeAsBytes(journalFrame(data));
      expect((await store.read('session'))!.revision, 139);
    },
  );

  test(
    'audit checks old frames even when startup can use a recent checkpoint',
    () async {
      await writeLegacy(root, historyFixture(140));
      final store = FileSessionStore(root);
      await store.migrate('session');
      final file = File(journalPath(root, 'session'));
      final bytes = await file.readAsBytes();
      final firstSize = ByteData.sublistView(bytes).getUint32(0) + 12;
      bytes[firstSize + 12] ^= 1;
      await file.writeAsBytes(bytes);
      expect((await store.read('session'))!.revision, 139);
      await expectLater(store.verify('session'), throwsFormatException);
      await expectLater(store.revisions('session'), throwsFormatException);
    },
  );

  for (final boundary in ['staged', 'verified', 'replaced']) {
    test(
      'SIGKILL at migration $boundary preserves every recoverable revision',
      () async {
        final states = historyFixture(20);
        await writeLegacy(root, states);
        final original = await File(journalPath(root, 'session')).readAsBytes();
        final package = await Isolate.resolvePackageUri(
          Uri.parse('package:cutdex_agent/cutdex_agent.dart'),
        );
        final worker = File.fromUri(
          package!.resolve('../test/fixtures/migration_worker.dart'),
        );
        final process = await Process.start(Platform.resolvedExecutable, [
          worker.path,
          root.path,
          boundary,
        ]);
        final errors = process.stderr.transform(utf8.decoder).join();
        addTearDown(() async {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        });
        final ready = File('${root.path}/ready');
        final timeout = Stopwatch()..start();
        while (!await ready.exists() &&
            timeout.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await ready.exists(), isTrue);
        expect(process.kill(ProcessSignal.sigkill), isTrue);
        await process.exitCode;
        expect(await errors, isEmpty);
        if (boundary != 'replaced') {
          expect(
            await File(journalPath(root, 'session')).readAsBytes(),
            original,
          );
        }
        final recovered = FileSessionStore(root);
        expect(
          (await recovered.revisions('session')).map((s) => s.toJson()),
          states.map((s) => s.toJson()),
        );
        await recovered.migrate('session');
        await recovered.verify('session');
        await recovered.save(
          states.last.update({'revision': 20}),
          expectedRevision: 19,
        );
        expect((await recovered.read('session'))!.revision, 20);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }

  test('delta rejects an invalid base even with a valid CRC', () async {
    final store = FileSessionStore(root);
    final first = SessionSnapshot(id: 'session');
    await store.save(first, expectedRevision: null);
    final file = File(journalPath(root, 'session'));
    final initial =
        jsonDecode(utf8.decode((await file.readAsBytes()).sublist(12))) as Map;
    final delta = journalRecord(
      first.toJson(),
      first.update({'revision': 1}).toJson(),
      initial['generation'] as String,
    );
    delta['baseRevision'] = 42;
    await file.writeAsBytes(journalFrame(delta), mode: FileMode.append);
    await expectLater(store.read('session'), throwsFormatException);
  });
}
