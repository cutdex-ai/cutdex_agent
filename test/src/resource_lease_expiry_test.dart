import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

void main() {
  test(
    'enabling finite leases rejects historical unbounded credentials',
    () async {
      final storage = InMemorySessionStore();
      final legacy = FencedResourceStore(storage, leaseDuration: null);
      final created = await legacy.activate(
        resourceId: 'shared',
        activationId: 'legacy',
        sessionId: 'root',
        runId: 'old',
        expectedGeneration: 0,
      );
      final old = RemoteWritePermit.fromJson(
        (created.data['permit'] as Map).cast<String, Object?>(),
      );
      final upgraded = FencedResourceStore(storage);
      expect(
        (await upgraded.commit(
          old,
          operationId: 'legacy-late',
          patch: {'a': 10},
        )).data['code'],
        'task_write_lease_expired',
      );
      expect((await upgraded.leaseStatus(old)).data['stopped'], isTrue);
    },
  );
  late FencedResourceStore resources;
  late RemoteWritePermit root;
  late RemoteWritePermit leaf;
  var millis = 100000;
  setUp(() async {
    millis = 100000;
    resources = FencedResourceStore(
      InMemorySessionStore(),
      initialData: {'a': 99},
      leaseDuration: const Duration(seconds: 2),
      now: () => DateTime.fromMillisecondsSinceEpoch(millis),
    );
    final r = await resources.activate(
      resourceId: 'shared',
      activationId: 'root',
      sessionId: 'root',
      runId: 'root',
      expectedGeneration: 0,
    );
    root = RemoteWritePermit.fromJson(
      (r.data['permit'] as Map).cast<String, Object?>(),
    );
    final c = await resources.activate(
      resourceId: 'shared',
      activationId: 'leaf',
      sessionId: 'leaf',
      runId: 'leaf',
      expectedGeneration: 1,
      parentScopeId: root.scopeId,
      parentRunId: root.runId,
    );
    leaf = RemoteWritePermit.fromJson(
      (c.data['permit'] as Map).cast<String, Object?>(),
    );
  });
  test(
    'expired parent stops descendants without changing resource generation',
    () async {
      millis += 2000;
      final result = await resources.commit(
        leaf,
        operationId: 'late',
        patch: {'a': 10},
      );
      expect(result.data['code'], 'task_write_lease_expired');
      expect(result.data['executed'], isFalse);
      final state = (await resources.inspect('shared')).data;
      expect(state['generation'], 1);
      expect((state['data'] as Map)['a'], 99);
      expect(state['resourceRevision'], 1);
    },
  );
  test(
    'expiry confirmation seals permission despite clock rollback and delayed renewal',
    () async {
      millis += 2001;
      expect((await resources.leaseStatus(root)).data['stopped'], isTrue);
      millis -= 5000;
      final renew = await resources.renew(
        root,
        renewalId: 'old-renew',
        expectedExpiryMs: root.initialExpiryMs!,
      );
      expect(renew.data['code'], 'task_write_lease_expired');
      expect(
        (await resources.commit(
          leaf,
          operationId: 'old',
          patch: {'a': 10},
        )).isError,
        isTrue,
      );
    },
  );
  test(
    'renewal retry is idempotent and stale deadline cannot extend again',
    () async {
      millis += 500;
      final first = await resources.renew(
        root,
        renewalId: 'first',
        expectedExpiryMs: root.initialExpiryMs!,
      );
      millis += 500;
      expect(
        (await resources.renew(
          root,
          renewalId: 'first',
          expectedExpiryMs: root.initialExpiryMs!,
        )).toJson(),
        first.toJson(),
      );
      expect(
        (await resources.renew(
          root,
          renewalId: 'delayed',
          expectedExpiryMs: root.initialExpiryMs!,
        )).data['code'],
        'lease_renewal_conflict',
      );
      expect(
        (await resources.leaseStatus(root)).data['expiresAtMs'],
        first.data['expiresAtMs'],
      );
    },
  );
  test('renewing child cannot extend an expired ancestor', () async {
    millis += 1000;
    await resources.renew(
      leaf,
      renewalId: 'leaf-first',
      expectedExpiryMs: leaf.initialExpiryMs!,
    );
    millis += 1001;
    expect(
      (await resources.renew(
        leaf,
        renewalId: 'leaf-again',
        expectedExpiryMs: 103000,
      )).data['code'],
      'task_write_lease_expired',
    );
  });
  test('expiry and revocation survive reopening the persisted store', () async {
    // Reopening against the same store exercises checkpoint state, rather than
    // relying on the first service object's local timers or maps.
    millis += 2000;
    await resources.leaseStatus(root);
    final reopened = FencedResourceStore(
      resources.store,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect((await reopened.leaseStatus(root)).data['stopped'], isTrue);
    expect(
      (await reopened.commit(
        leaf,
        operationId: 'reopened',
        patch: {'a': 10},
      )).isError,
      isTrue,
    );
  });
}
