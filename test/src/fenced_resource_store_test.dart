import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

void main() {
  late FencedResourceStore resources;
  late RemoteWritePermit root;
  late RemoteWritePermit child;
  late RemoteWritePermit grandchild;
  Future<RemoteWritePermit> activate(
    String name, {
    RemoteWritePermit? parent,
    int generation = 0,
  }) async {
    final result = await resources.activate(
      resourceId: 'shared',
      activationId: name,
      sessionId: name,
      runId: '$name-run',
      expectedGeneration: generation,
      parentScopeId: parent?.scopeId,
      parentRunId: parent?.runId,
    );
    expect(result.isError, isFalse);
    return RemoteWritePermit.fromJson(
      (result.data['permit'] as Map).cast<String, Object?>(),
    );
  }

  setUp(() async {
    resources = FencedResourceStore(
      InMemorySessionStore(),
      initialData: {'a': 99},
    );
    root = await activate('root');
    child = await activate('child', parent: root);
    grandchild = await activate('grandchild', parent: child);
  });
  test(
    'server-issued generation is inherited and accepted writes persist receipts',
    () async {
      expect(grandchild.generation, 1);
      final result = await resources.commit(
        grandchild,
        operationId: 'write',
        patch: {'a': 15},
      );
      expect(result.isError, isFalse);
      expect((result.data['data'] as Map)['a'], 15);
      expect(
        (await resources.receipt(grandchild, 'write')).toJson(),
        result.toJson(),
      );
    },
  );
  test(
    'new generation rejects both descendants and all business data remains unchanged',
    () async {
      final fresh = await activate('new', generation: 1);
      await resources.commit(fresh, operationId: 'new', patch: {'a': 15});
      for (final old in [child, grandchild]) {
        final result = await resources.commit(
          old,
          operationId: 'late',
          patch: {'a': 10},
        );
        expect(result.data['code'], 'stale_task_generation');
        expect(result.data['executed'], isFalse);
      }
      final state = (await resources.inspect('shared')).data;
      expect((state['data'] as Map)['a'], 15);
      expect(state['resourceRevision'], 2);
    },
  );
  test(
    'ancestor revocation rejects descendants before any new root is active',
    () async {
      await resources.revoke(child);
      expect(
        (await resources.commit(
          grandchild,
          operationId: 'late',
          patch: {'a': 10},
        )).data['code'],
        'task_write_revoked',
      );
      expect(
        (await resources.commit(
          root,
          operationId: 'root-write',
          patch: {'a': 15},
        )).isError,
        isFalse,
      );
    },
  );
  test('old revoke cannot revoke the fresh generation', () async {
    final fresh = await activate('new', generation: 1);
    await resources.revoke(root);
    expect(
      (await resources.commit(
        fresh,
        operationId: 'new',
        patch: {'a': 15},
      )).isError,
      isFalse,
    );
  });
  test('forged capabilities and forged generation are rejected', () async {
    for (final forged in [
      {...child.toJson(), 'capability': 'forged'},
      {...child.toJson(), 'generation': 2},
      {...child.toJson(), 'runId': 'other'},
    ]) {
      expect(
        (await resources.commit(
          RemoteWritePermit.fromJson(forged),
          operationId: 'bad',
          patch: {'a': 10},
        )).data['code'],
        'invalid_write_permit',
      );
    }
    expect((await resources.inspect('shared')).data['resourceRevision'], 1);
  });
  test(
    'duplicate activation cannot rotate generation and revoked activation cannot resurrect',
    () async {
      final duplicate = await activate('root');
      expect(duplicate.toJson(), root.toJson());
      expect((await resources.inspect('shared')).data['generation'], 1);
      await resources.revoke(root);
      final replay = await resources.activate(
        resourceId: 'shared',
        activationId: 'root',
        sessionId: 'root',
        runId: 'root-run',
        expectedGeneration: 0,
      );
      expect(replay.data['code'], 'task_write_revoked');
      expect((await resources.inspect('shared')).data['generation'], 1);
    },
  );
  test('delayed control activation loses generation compare-and-set', () async {
    await activate('new', generation: 1);
    final stale = await resources.activate(
      resourceId: 'shared',
      activationId: 'delayed-control',
      sessionId: 'old',
      runId: 'old',
      expectedGeneration: 1,
    );
    expect(stale.data['code'], 'stale_task_generation');
    expect((await resources.inspect('shared')).data['generation'], 2);
  });
  test(
    'retry deduplicates writes and changed payload cannot reuse its operation',
    () async {
      final first = await resources.commit(
        child,
        operationId: 'same',
        patch: {'a': 15},
      );
      expect(
        (await resources.commit(
          child,
          operationId: 'same',
          patch: {'a': 15},
        )).toJson(),
        first.toJson(),
      );
      expect(
        (await resources.commit(
          child,
          operationId: 'same',
          patch: {'a': 20},
        )).data['code'],
        'operation_id_conflict',
      );
      expect((await resources.inspect('shared')).data['resourceRevision'], 2);
    },
  );
  test(
    'missing network receipt is unknown rather than safe to replay',
    () async {
      expect(
        (await resources.receipt(child, 'in-flight')).data['code'],
        'outcome_unknown',
      );
    },
  );
  test(
    'receipt recovery and deduplication survive renewed permits for the same logical run',
    () async {
      final prior = await resources.commit(
        child,
        operationId: 'child-operation',
        patch: {
          'a': 15,
          'nested': {'x': 1, 'y': 2},
        },
      );
      await resources.revoke(root);
      final reopenedRoot = await resources.activate(
        resourceId: 'shared',
        activationId: 'root-resume',
        sessionId: 'root',
        runId: 'root-run',
        expectedGeneration: 1,
      );
      final rootPermit = RemoteWritePermit.fromJson(
        (reopenedRoot.data['permit'] as Map).cast<String, Object?>(),
      );
      final reopenedChild = await resources.activate(
        resourceId: 'shared',
        activationId: 'child-resume',
        sessionId: 'child',
        runId: 'child-run',
        expectedGeneration: 2,
        parentScopeId: rootPermit.scopeId,
        parentRunId: rootPermit.runId,
      );
      final newPermit = RemoteWritePermit.fromJson(
        (reopenedChild.data['permit'] as Map).cast<String, Object?>(),
      );
      expect(
        (await resources.receipt(newPermit, 'child-operation')).toJson(),
        prior.toJson(),
      );
      final retry = await resources.commit(
        newPermit,
        operationId: 'child-operation',
        patch: {
          'nested': {'y': 2, 'x': 1},
          'a': 15,
        },
      );
      expect(retry.toJson(), prior.toJson());
      expect((await resources.inspect('shared')).data['resourceRevision'], 2);
      expect(
        (await resources.receipt(rootPermit, 'child-operation')).data['code'],
        'receipt_owner_mismatch',
      );
      expect(
        (await resources.commit(
          rootPermit,
          operationId: 'child-operation',
          patch: {'a': 20},
        )).data['code'],
        'operation_id_conflict',
      );
    },
  );
  test(
    'simultaneous submissions and rotation are serialized at the resource end',
    () async {
      final responses = await Future.wait([
        resources.activate(
          resourceId: 'shared',
          activationId: 'new',
          sessionId: 'new',
          runId: 'new-run',
          expectedGeneration: 1,
        ),
        resources.commit(child, operationId: 'child-late', patch: {'a': 10}),
        resources.commit(
          grandchild,
          operationId: 'leaf-late',
          patch: {'a': 20},
        ),
      ]);
      expect(responses.first.isError, isFalse);
      expect(
        responses.skip(1).map((r) => r.data['code']),
        everyElement('stale_task_generation'),
      );
      expect((await resources.inspect('shared')).data['resourceRevision'], 1);
    },
  );
  test(
    'disk restart preserves generations, revocations, resources and receipts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cutdex-fence-disk-',
      );
      try {
        final first = FencedResourceStore(
          FileSessionStore(directory),
          initialData: {'a': 99},
        );
        final initial = await first.activate(
          resourceId: 'shared',
          activationId: 'first',
          sessionId: 'root',
          runId: 'old',
          expectedGeneration: 0,
        );
        final old = RemoteWritePermit.fromJson(
          (initial.data['permit'] as Map).cast<String, Object?>(),
        );
        await first.commit(old, operationId: 'first-write', patch: {'a': 12});
        await first.revoke(old);
        final reopened = FencedResourceStore(FileSessionStore(directory));
        final next = await reopened.activate(
          resourceId: 'shared',
          activationId: 'second',
          sessionId: 'root',
          runId: 'new',
          expectedGeneration: 1,
        );
        final fresh = RemoteWritePermit.fromJson(
          (next.data['permit'] as Map).cast<String, Object?>(),
        );
        await reopened.commit(
          fresh,
          operationId: 'second-write',
          patch: {'a': 15},
        );
        expect(
          (await reopened.commit(
            old,
            operationId: 'late',
            patch: {'a': 10},
          )).data['code'],
          'stale_task_generation',
        );
        expect(
          ((await reopened.receipt(old, 'first-write')).data['data']
              as Map)['a'],
          12,
        );
        final state = (await reopened.inspect('shared')).data;
        expect((state['data'] as Map)['a'], 15);
        expect(state['resourceRevision'], 3);
        expect(
          jsonEncode(state),
          isNot(contains(old.toJson()['capability'] as String)),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
